# Probe of the dedicated host: starts it hidden with a new or the last world, waits for a line of its log, sends Lua
# through the console (run_string needs -dbg), closes the pipe (-coop_hidden: save and quit) and prints the answers.
#   powershell -ExecutionPolicy Bypass -File tools/ded_probe.ps1 -World new -WaitFor 'g_actor is null'
param(
    [string]$GameDir = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateSet('new', 'last')][string]$World = 'new',
    [int]$Port = 27991,
    [string]$WaitFor = 'dedicated: waiting for the world \(the actor is not online',
    [int]$WaitS = 240,
    [string[]]$Lua = @(),
    [string[]]$Commands = @(),
    [int]$SettleS = 4
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $GameDir ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log }
$worldKey = if ($World -eq 'new') { '-coop_new' } else { '-coop_load last' }
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = Join-Path $GameDir 'bin\AnomalyCoopDX11AVX.exe'
$psi.WorkingDirectory = $GameDir
$psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port $worldKey -coop_hidden -dbg"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$p = [System.Diagnostics.Process]::Start($psi)
$in = [System.IO.StreamWriter]::new($p.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
$in.AutoFlush = $true
$in.NewLine = "`n"
Write-Host "pid $($p.Id): $($psi.Arguments)"
$until = (Get-Date).AddSeconds($WaitS)
$seen = $false
while ((Get-Date) -lt $until -and -not $p.HasExited) {
    if ((Test-Path -LiteralPath $log) -and (Select-String -LiteralPath $log -Pattern $WaitFor -Quiet)) { $seen = $true; break }
    Start-Sleep -Seconds 2
}
Write-Host "waited for '$WaitFor': $seen"
if (-not $p.HasExited) {
    foreach ($line in $Lua) { $in.WriteLine('run_string ' + $line); Start-Sleep -Milliseconds 400 }
    foreach ($line in $Commands) { $in.WriteLine($line); Start-Sleep -Milliseconds 400 }
    Start-Sleep -Seconds $SettleS
    $in.Close()
    if (-not $p.WaitForExit(90000)) { Write-Host 'the server did not exit in 90 s: killed'; $p.Kill() }
}
Write-Host "exit code $($p.ExitCode)"
Select-String -LiteralPath $log -Pattern 'PROBE|\[coop\] dedicated|! \[coop\]|Unknown command|ModelPool|Lua error survived' | ForEach-Object { $_.Line }
