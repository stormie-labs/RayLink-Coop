# Stage 2 of docs/plans/2026-11-12-split-levels-no-reloads.md by hand: the hidden world server on this PC and the
# player's own game as its client. Starts the server, waits for its session, starts the game with -coop_connect, and
# when the game is closed lets the server save the world and quit (the end of its pipe). Then prints what matters of
# both logs.
#   powershell -ExecutionPolicy Bypass -File tools/split_test.ps1                 # the last world of the server
#   powershell -ExecutionPolicy Bypass -File tools/split_test.ps1 -World new      # a new world
# Friends join the same world at this PC's address and -Port, as they join an ordinary host.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateSet('new', 'last')][string]$World = 'last',
    [int]$Port = 27960,
    [string]$ClientFs = 'fsgame_a.ltx',   # the player's profile of this stand (the launcher writes it)
    [int]$UpTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
foreach ($need in @($exe, (Join-Path $Stand 'fsgame_server.ltx'), (Join-Path $Stand $ClientFs))) {
    if (-not (Test-Path -LiteralPath $need)) { throw "missing: $need (tools/stand_server.ps1 makes the server's files)" }
}
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
$serverLog = Join-Path $Stand ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
if (Test-Path -LiteralPath $serverLog) { Remove-Item -LiteralPath $serverLog }

$worldKey = if ($World -eq 'new') { '-coop_new' } else { '-coop_load last' }
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.WorkingDirectory = $Stand
$psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port $worldKey -coop_hidden"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$server = [System.Diagnostics.Process]::Start($psi)
Write-Host "server pid $($server.Id): $($psi.Arguments)"
try {
    $until = (Get-Date).AddSeconds($UpTimeoutS)
    $up = $false
    while ((Get-Date) -lt $until -and -not $server.HasExited) {
        if ((Test-Path -LiteralPath $serverLog) -and (Select-String -LiteralPath $serverLog -Pattern '\[coop\] dedicated: the session is up on port' -Quiet)) { $up = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $up) { throw "the server's session did not come up in $UpTimeoutS s (see $serverLog)" }
    Write-Host "the server's session is up on port $Port; starting the game"
    $game = Start-Process -FilePath $exe -WorkingDirectory $Stand -ArgumentList "-fsltx $ClientFs -coop_connect 127.0.0.1:$Port" -PassThru
    Write-Host "game pid $($game.Id). Close the game to end the test."
    $game.WaitForExit()
    Write-Host "the game exited with code $($game.ExitCode)"
}
finally {
    if (-not $server.HasExited) {
        $server.StandardInput.Close()   # -coop_hidden: the end of the pipe is "save the world and quit"
        if (-not $server.WaitForExit(120000)) { Write-Host 'the server did not quit in 120 s: killed'; $server.Kill() }
    }
    Write-Host "the server exited with code $($server.ExitCode)"
}
Write-Host '--- server log ---'
Select-String -LiteralPath $serverLog -Pattern '\[coop\] (dedicated|phase|soft move|map server)|! \[coop\]|joined|left the session|ModelPool|Lua error survived' |
    Select-Object -Last 60 | ForEach-Object { $_.Line }
