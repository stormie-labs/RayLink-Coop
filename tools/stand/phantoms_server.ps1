# Build 57, step S3 of docs/plans/2026-11-18-two-modes.md (TZ 6.3, the owner: the psy phantoms of a bloodsucker are unseen in the
# SERVER mode). A world server this script owns, a test player, and the map server of his level: 20 s after he stands there the
# map server makes a psysucker squad 20 m from him; a psysucker that fights him spawns m_phantom_bloodsucker at him (if the fight
# gives none in 60 s, the map server makes two by the fight's own call). The client must have every phantom of the map server
# as a live object, and none more (coop_zz_phantoms.script, roles ms and ph). Before protocol 33 the phantom stayed an offline
# entity on the client: the world server sent its spawn twice, and nothing said whose online flag it was.
# Made from carry_server.ps1.
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script phantoms_server.ps1 -Out b57_phantoms.out -ScriptArgs '-Tag b57'
# The last line is "phantoms: PASS" or "phantoms: FAIL (<why>)".
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [int]$Port = 27993,
    [string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$AfterS = 6,
    [int]$StepsTimeoutS = 480
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
. (Join-Path $PSScriptRoot 'stand_dump.ps1')  # Save-StandDump: the stacks of a server that hangs, before the kill
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx'))) { throw 'no fsgame_t.ltx: run auto_world.ps1 once' }
$serverLog = Join-Path $Stand ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
$clientLog = Join-Path $Stand ('appdata_t\logs\xray_' + $env:USERNAME + '.log')
$msLog = Join-Path $Stand ('appdata_ms1\logs\xray_' + $env:USERNAME + '.log')
$scripts = Join-Path $Stand 'gamedata\scripts'
$probe = Join-Path $scripts 'coop_zz_phantoms.script'
$shared = Join-Path $Stand 'zz_phantoms.txt'  # the map server's list of its phantoms, read by the client
foreach ($stale in @('coop_zz_npcprobe.script', 'coop_zz_lone.script')) { Remove-StandFile -Path (Join-Path $scripts $stale) }
foreach ($f in @($serverLog, $clientLog, $msLog, $shared)) { Remove-StandFile -Path $f }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_phantoms.script') -To $probe

function Wait-Log([string]$file, [string]$pattern, [int]$seconds, $proc) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $file) -and (Select-String -LiteralPath $file -Pattern $pattern -Quiet)) { return $true }
        if ($proc -and $proc.HasExited) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}
$stage = Join-Path $Stand 'appdata_server\coop_new_world.ltx'
Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = phantoms`n" -Encoding ([System.Text.Encoding]::ASCII)
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $exe
$psi.WorkingDirectory = $Stand
$psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stage -silent_error_mode -dbg"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true
$server = [System.Diagnostics.Process]::Start($psi)
$in = [System.IO.StreamWriter]::new($server.StandardInput.BaseStream, [System.Text.UTF8Encoding]::new($false))
$in.AutoFlush = $true
$in.NewLine = "`n"
Write-Host "server pid $($server.Id)"
$client = $null
try {
    if (-not (Wait-Log $serverLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS $server)) { throw 'the server did not come up' }
    Write-Host 'the session is up'
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -coop_nick tester -coop_autochoose stalker -coop_probe ph -coop_connect 127.0.0.1:$Port"
    $null = $client.Handle
    Write-Host "client pid $($client.Id)"
    if (-not (Wait-Log $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS $client)) {
        if ($client.HasExited) { Write-Host ("the client's process ended by itself: exit code {0} (0x{0:X8})" -f $client.ExitCode) }
        throw 'the client did not get into the world'
    }
    Write-Host 'the client is in the world'
    if (-not (Wait-Log $clientLog '\[ph\] ph done' $StepsTimeoutS $client)) { Write-Host "! the client's steps did not end in $StepsTimeoutS s" }
    $until = (Get-Date).AddSeconds($AfterS)
    while ((Get-Date) -lt $until -and -not $server.HasExited) { Start-Sleep -Seconds 2 }
    Write-Host ("server alive {0} s after the request: {1}{2}" -f $AfterS, (-not $server.HasExited), $(if ($server.HasExited) { ', exit code ' + $server.ExitCode + (' (0x{0:X8})' -f $server.ExitCode) } else { '' }))
    if (-not $server.HasExited) {
        # the server's own console: who stands where, and the world's counters (spawns out)
        foreach ($line in @('srv_levels_status', 'coop_status')) { $in.WriteLine($line); Start-Sleep -Seconds 4 }
    }
}
finally {
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
    if (-not $server.HasExited) {
        Start-Sleep -Seconds 4
        try { $in.WriteLine('quit'); $in.Close() } catch { }
        if (-not $server.WaitForExit(150000)) {
            Write-Host '! the server did not quit in 150 s: stopped by force'
            $null = Save-StandDump -Process $server -Name "${Tag}_phantoms_server_hung"
            Stop-Process -Id $server.Id -Force
        }
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    Write-Host ("server exit code: {0}" -f $(if ($server.HasExited) { $server.ExitCode } else { 'still running' }))
    foreach ($pair in @(@($clientLog, 'client'), @($serverLog, 'server'), @($msLog, 'ms1'), @($shared, 'list'))) {
        if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $OutDir "${Tag}_phantoms_$($pair[1]).log") -Force }
    }
    Remove-StandFile -Path $probe
    Remove-StandFile -Path $shared
}
Write-Host '--- client ---'
Show-StandLogLines $clientLog '\[ph\]|mirror: .* (comes online now|left on the vote)|mirror without a game vertex' 80
Write-Host '--- world server ---'
Show-StandLogLines $serverLog '\[coop\] trunk: a spawn|world out: |map server .* starts for level' 40
Write-Host '--- map server 1 ---'
Show-StandLogLines $msLog '\[ph\]' 60
$verdict = $null
if (Test-Path -LiteralPath $clientLog) {
    $verdict = Select-String -LiteralPath $clientLog -Pattern '\[ph\] ph (PASS|FAIL): (.*)$' | Select-Object -Last 1
}
if (-not $verdict) { Write-Host 'phantoms: FAIL (the client wrote no verdict)' }
elseif ($verdict.Matches[0].Groups[1].Value -eq 'PASS') { Write-Host 'phantoms: PASS' }
else { Write-Host ('phantoms: FAIL ({0})' -f $verdict.Matches[0].Groups[2].Value) }
