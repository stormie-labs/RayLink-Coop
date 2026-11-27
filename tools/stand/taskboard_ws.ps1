# SS scenario taskboard_ws (A-S5S, build 57): the PDA task board of a player in a server world.
# Written for tools\stand (the lead moves it there: it loads ..\stand_common.ps1 and the probe coop_zz_tb.script next to it);
# docs/MODES.md section 10, row SS.
#
# A world server this script owns (-coop_dedicated, a new world), a test player who joins and stands on a map that map server 1 leads.
# His game asks the board the way the PDA's Refresh button does (probe coop_zz_tb.script: -coop_probe tb, 35 s after his session is
# live); every machine logs each task generation it runs ("[tb] generation for ...").
# Verdict (exit code 0 only when all hold, else the scenario throws):
#   board      the board got its answer and lists at least one task ("[tb] available tasks: N task(s)", N > 0)
#   map        map server 1 sent a nonempty reply in the probe window and the client prepared a row from it
#   world      the world server handled zero offer requests locally (its offer counters)
#   far_empty  no empty answer over the far view reached his game (coop_quests_offer status "(0 empty over the far view)")
#   alive      the world server lives after the request; no stand errors in any of the three logs
# History: 2026-11-18 (build 54) the world server answered 29 NPCs of the Bar with 29 empty lists over the far view ("на раздельных
# нет квестов"); build 55 let the client make an empty answer's list itself; S5 (A-S5S) wants the map server to make it.
#   powershell -ExecutionPolicy Bypass -File tools\stand\taskboard_ws.ps1 [-Port 27982] [-Tag b57]
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27982,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'tb',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$AskTimeoutS = 200,
    [int]$AfterS = 12,
    [switch]$CheckVerdict
)
$ErrorActionPreference = 'Stop'

function Get-BoardReplyMatch([string[]]$ClientLines, [string[]]$MapLines, [int]$MapBaseline) {
    $replies = @{}
    foreach ($line in ($MapLines | Select-Object -Skip $MapBaseline)) {
        if ($line -match '\[coop-quests\]\[offer\] board reply (peer=\d+ npc=\d+ seq=\d+) tasks=[1-9]\d*\s*$') {
            $replies[$Matches[1]] = $true
        }
    }
    $refreshing = $false
    $prepared = $null
    foreach ($line in $ClientLines) {
        if ($line -match '\[tb\] the batch is over after \d+ ms\s*$') {
            $refreshing = $true
            $prepared = $null
        } elseif ($refreshing -and $line -match '\[tb\] refresh_tasks: (.*)$') {
            if ($prepared -and $Matches[1].Trim() -eq 'ok') { return $prepared }
            $refreshing = $false
        } elseif ($refreshing -and $line -match '\[coop-quests\]\[offer\] board prepared (peer=\d+ npc=\d+ seq=\d+)\s*$') {
            if ($replies.ContainsKey($Matches[1])) { $prepared = $Matches[1] }
        }
    }
    return $null
}

# Offline regression for the log verdict. This returns before opening the stand.
if ($CheckVerdict) {
    $batch = '[tb] the batch is over after 5000 ms'
    $ok = '[tb] refresh_tasks: ok'
    $row = '[coop-quests][offer] board prepared peer=1 npc=700 seq=12'
    $reply = '[coop-quests][offer] board reply peer=1 npc=700 seq=12 tasks=1'
    $stock = '[tb] generation for 701 other_npc, sim nil: ok, 1 task(s): unrelated_task'
    $cases = @(
        @{ name = 'fallback-only board'; client = @($batch, $ok, '[tb] available tasks: 1 task(s) of 1 NPC(s) out of 1 near'); map = @($stock) }
        @{ name = 'matching prepared row'; client = @($batch, $row, $ok); map = @($stock, $reply); before = 1; pass = $true }
        @{ name = 'reply without a prepared row'; client = @($batch, $ok); map = @($reply) }
        @{ name = 'different requester'; client = @($batch, $row, $ok); map = @($reply -replace 'peer=1', 'peer=2') }
        @{ name = 'different NPC'; client = @($batch, $row, $ok); map = @($reply -replace 'npc=700', 'npc=701') }
        @{ name = 'different sequence'; client = @($batch, $row, $ok); map = @($reply -replace 'seq=12', 'seq=13') }
        @{ name = 'empty reply'; client = @($batch, $row, $ok); map = @($reply -replace 'tasks=1', 'tasks=0') }
        @{ name = 'old reply'; client = @($batch, $row, $ok); map = @($reply); before = 1 }
        @{ name = 'row outside refresh'; client = @($row, $batch, $ok); map = @($reply) }
        @{ name = 'failed refresh'; client = @($batch, $row, '[tb] refresh_tasks: ! error'); map = @($reply) }
    )
    foreach ($case in $cases) {
        $matched = Get-BoardReplyMatch -ClientLines $case.client -MapLines $case.map -MapBaseline ([int]$case.before)
        if ([bool]$matched -ne [bool]$case.pass) { throw "taskboard_ws verdict: FAIL ($($case.name))" }
    }
    Write-Host "taskboard_ws verdict: $($cases.Count) passed, 0 failed"
    return
}

. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
. (Join-Path $PSScriptRoot 'stand_dump.ps1')  # Save-StandDump: the stacks of a server that hangs, before the kill
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx'))) { throw 'no fsgame_t.ltx: run auto_world.ps1 once' }
$serverLog = Join-Path $Stand ('appdata_server\logs\xray_' + $env:USERNAME + '.log')
$clientLog = Join-Path $Stand ('appdata_t\logs\xray_' + $env:USERNAME + '.log')
$msLog = Join-Path $Stand ('appdata_ms1\logs\xray_' + $env:USERNAME + '.log')
$scripts = Join-Path $Stand 'gamedata\scripts'
$probe = Join-Path $scripts 'coop_zz_tb.script'
foreach ($stale in @('coop_zz_npcprobe.script', 'coop_zz_lone.script')) { Remove-StandFile -Path (Join-Path $scripts $stale) }
foreach ($f in @($serverLog, $clientLog, $msLog)) { Remove-StandFile -Path $f }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_tb.script') -To $probe

function Wait-Log([string]$file, [string]$pattern, [int]$seconds, $proc) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $file) -and (Select-String -LiteralPath $file -Pattern $pattern -Quiet)) { return $true }
        if ($proc -and $proc.HasExited) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}
function Get-LogLineCount([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    return @(Get-Content -LiteralPath $file -Encoding Default).Count
}

$stage = Join-Path $Stand 'appdata_server\coop_new_world.ltx'
Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = taskboard`n" -Encoding ([System.Text.Encoding]::ASCII)
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
$answered = $false
$aliveAfter = $false
try {
    if (-not (Wait-Log $serverLog '\[coop\] dedicated: the session is up on port' $UpTimeoutS $server)) { throw 'the server did not come up' }
    Write-Host 'the session is up'
    $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -coop_nick tester -coop_autochoose stalker -coop_probe tb -coop_connect 127.0.0.1:$Port"
    $null = $client.Handle
    Write-Host "client pid $($client.Id)"
    if (-not (Wait-Log $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS $client)) {
        if ($client.HasExited) { Write-Host ("the client's process ended by itself: exit code {0} (0x{0:X8})" -f $client.ExitCode) }
        throw 'the client did not get into the world'
    }
    Write-Host 'the client is in the world'
    # The probe waits 35 s from live before asking. Take the map log baseline before that request.
    $msBeforeAsk = Get-LogLineCount $msLog
    $answered = Wait-Log $clientLog '\[tb\] available tasks' $AskTimeoutS $client
    if (-not $answered) { Write-Host "! the board answer did not come in $AskTimeoutS s" }
    $until = (Get-Date).AddSeconds($AfterS)
    while ((Get-Date) -lt $until -and -not $server.HasExited) { Start-Sleep -Seconds 2 }
    $aliveAfter = -not $server.HasExited
    Write-Host ("server alive {0} s after the request: {1}{2}" -f $AfterS, $aliveAfter, $(if ($server.HasExited) { ', exit code ' + $server.ExitCode + (' (0x{0:X8})' -f $server.ExitCode) } else { '' }))
    if (-not $server.HasExited) {
        # the server's own console: its offer counters
        foreach ($line in @('coop_debug on', 'coop_dbg lua coop_quests_offer.print_status()')) { $in.WriteLine($line); Start-Sleep -Seconds 4 }
    }
}
finally {
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force }
    if (-not $server.HasExited) {
        Start-Sleep -Seconds 4
        try { $in.WriteLine('quit'); $in.Close() } catch { }
        if (-not $server.WaitForExit(150000)) {
            Write-Host '! the server did not quit in 150 s: stopped by force'
            $null = Save-StandDump -Process $server -Name "${Tag}_taskboard_ws_hung"
            Stop-Process -Id $server.Id -Force
        }
    }
    Start-Sleep -Seconds 2
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    Write-Host ("server exit code: {0}" -f $(if ($server.HasExited) { $server.ExitCode } else { 'still running' }))
    foreach ($pair in @(@($clientLog, 'client'), @($serverLog, 'server'), @($msLog, 'ms1'))) {
        if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $OutDir "${Tag}_board_$($pair[1]).log") -Force }
    }
    Remove-StandFile -Path $probe
}
Write-Host '--- client ---'
Show-StandLogLines $clientLog '\[tb\]|host refused the offer|\[coop-quests\]\[offer\]|context: role' 60
Write-Host '--- world server ---'
Show-StandLogLines $serverLog '\[tb\]|\[coop-quests\]\[offer\]|far: |generate for|context: role' 60
Write-Host '--- map server 1 ---'
Show-StandLogLines $msLog '\[tb\]|\[coop-quests\]\[offer\]|context: role' 30

# ---------------------------------------------------------------- verdict
$problems = [System.Collections.Generic.List[string]]::new()
# board: the last answer line of the probe
$tasks = -1
$hit = Select-String -LiteralPath $clientLog -Pattern '\[tb\] available tasks: (\d+) task\(s\) of (\d+) NPC' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($hit) { $tasks = [int]$hit.Matches[0].Groups[1].Value }
Write-Host ("board: {0}" -f $(if ($tasks -ge 0) { "$tasks task(s) on the board" } else { 'no answer line' }))
if (-not $answered -or $tasks -lt 1) { $problems.Add("board: the player's board lists no task (answer line: $tasks)") }
# far_empty: the client's offer counters (coop_quests_offer.print_status from the probe)
$far = -1
$status = Select-String -LiteralPath $clientLog -Pattern 'offers in (\d+) \((\d+) empty over the far view\)' -ErrorAction SilentlyContinue | Select-Object -Last 1
if ($status) { $far = [int]$status.Matches[0].Groups[2].Value }
Write-Host "far_empty: $far"
if ($far -ne 0) { $problems.Add("far_empty: answers over the far view reached the player ($far; -1: no status line)") }
# The client can build stock rows on timeout. Require a row from a reply sent in this probe window.
$clientLines = @(Get-Content -LiteralPath $clientLog -Encoding Default -ErrorAction SilentlyContinue)
$mapLines = @(Get-Content -LiteralPath $msLog -Encoding Default -ErrorAction SilentlyContinue)
$boardReply = Get-BoardReplyMatch -ClientLines $clientLines -MapLines $mapLines -MapBaseline $msBeforeAsk
if ($boardReply) {
    Write-Host "map: board prepared a row from map server 1 ($boardReply)"
} else {
    $problems.Add('map: no board row from a matching nonempty map server 1 reply in the probe window')
}
# The world counter counts calls to offer_here. Forwarding the request does not increment it.
$wsHandled = -1
$status = Select-String -LiteralPath $serverLog -Pattern '\[coop-quests\]\[offer\] requests out \d+ in (\d+) refused' -ErrorAction SilentlyContinue |
    Select-Object -Last 1
if ($status) { $wsHandled = [int]$status.Matches[0].Groups[1].Value }
Write-Host "world: $wsHandled offer request(s) handled locally"
if ($wsHandled -ne 0) { $problems.Add("world: expected zero locally handled offers ($wsHandled; -1: no status line)") }
# alive and clean
if (-not $aliveAfter) { $problems.Add('alive: the world server did not live through the request') }
foreach ($pair in @(@($clientLog, 'client'), @($serverLog, 'world server'), @($msLog, 'map server 1'))) {
    if (-not (Test-Path -LiteralPath $pair[0])) { $problems.Add("alive: no log of the $($pair[1])"); continue }
    $bad = Select-StandLogLine $pair[0] | Select-Object -First 1
    if ($bad) { $problems.Add(('alive: {0}: {1}' -f $pair[1], (Hide-Hex $bad.Line.Trim()))) }
}
if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "  ! $p" }
    throw ('taskboard_ws: FAIL ({0} problem(s))' -f $problems.Count)
}
Write-Host 'taskboard_ws: PASS'
