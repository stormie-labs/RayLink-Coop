# Stage 1 headless check of the dedicated host (docs/plans/2026-11-12-split-levels-no-reloads.md): a hidden server with a new world or
# -coop_load last, commands through its stdin pipe, the pipe closed = save and quit. No player, no window.
#   powershell -ExecutionPolicy Bypass -File tools/ded_check.ps1 -GameDir E:\RayLinkGames\GAMMA\game-dev -World new
#   powershell -ExecutionPolicy Bypass -File tools/ded_check.ps1 -GameDir E:\RayLinkGames\GAMMA\game-dev -World last
# Exit code 0: every step passed (the last line is "PASS").
param(
    [string]$GameDir = 'E:\RayLinkGames\GAMMA\game-dev',
    [string]$Exe = 'bin\AnomalyCoopDX11AVX.exe',
    [ValidateSet('new', 'last')][string]$World = 'new',
    [int]$Port = 27960,
    [int]$UpTimeoutS = 900,      # HostAutostart gives up at 15 min itself
    [int]$QuitTimeoutS = 120,
    [switch]$Hidden = $true,
    [switch]$Bom                 # write a UTF-8 BOM before the first command, as PowerShell pipes do: it must be harmless now
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $GameDir ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }

$worldKey = if ($World -eq 'new') { '-coop_new' } else { '-coop_load last' }
$hiddenKey = if ($Hidden) { ' -coop_hidden' } else { '' }
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $GameDir $Exe
$psi.WorkingDirectory = $GameDir
$psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port $worldKey$hiddenKey -dbg"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$p = [System.Diagnostics.Process]::Start($psi)
$in = [System.IO.StreamWriter]::new($p.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($Bom.IsPresent))
$in.AutoFlush = $true
$in.NewLine = "`n"
Write-Host "pid $($p.Id): $($psi.Arguments)"

function Test-Line([string]$pattern) {
    return (Test-Path -LiteralPath $log) -and (Select-String -LiteralPath $log -Pattern $pattern -Quiet)
}

# The log first, the process second: a server that has just quit wrote its last lines before it went (2026-11-12: "the server
# exited (0) before 'the world is saved'" with the line in the log).
function Wait-Line([string]$pattern, [int]$seconds) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if (Test-Line $pattern) { return }
        if ($p.HasExited) {
            Start-Sleep -Seconds 2
            if (Test-Line $pattern) { return }
            throw "the server exited ($($p.ExitCode)) before '$pattern'"
        }
        Start-Sleep -Seconds 2
    }
    throw "no '$pattern' in $seconds s"
}

$t0 = Get-Date
Wait-Line '\[coop\] dedicated: the session is up on port' $UpTimeoutS
Write-Host ("session up after {0:N0} s" -f ((Get-Date) - $t0).TotalSeconds)
$udp = Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $p.Id
Write-Host "UDP $Port owned by the server: $([bool]$udp)"
if (-not $udp) { throw "UDP port $Port is not the server's" }

$in.WriteLine('coop_status')
Wait-Line '\[coop\] phase hosting, self' 60   # print_status: a BOM before this line made it "Unknown command" before
$in.WriteLine('coop_players')
Wait-Line '\[coop\] 0 player\(s\) in the session' 180   # a new world autosaves in its first frames: one frame took 11 s (2026-11-12)

$in.Close()  # EOF: -coop_hidden saves the world and quits
Wait-Line '\[coop\] dedicated: the world is saved, the host goes down' 90
if (-not $p.WaitForExit($QuitTimeoutS * 1000)) { throw "the server did not exit in $QuitTimeoutS s" }
Write-Host "exit code $($p.ExitCode)"
if ($p.ExitCode -ne 0) { throw "the server's exit code is $($p.ExitCode)" }
Select-String -LiteralPath $log -Pattern '\[coop\] (autostart|dedicated|phase)|! \[coop\]|Unknown command: .*coop_(status|players)|autosave|ModelPool|Lua error survived' | ForEach-Object { $_.Line }
if (Select-String -LiteralPath $log -Pattern 'Unknown command: .*coop_(status|players)' -Quiet) { throw 'a command of the pipe was not understood' }
Write-Host 'PASS'
