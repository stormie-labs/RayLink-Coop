# 2026-11-18, step S0 of docs/plans/2026-11-18-two-modes.md: single player WITHOUT any -coop_ key (regressions R2 and R3 of
# builds 52-54 crossed the line "inside / outside a session"). A new game, a save, a load of that save, one minute alive after
# the load, no error line (coop_zz_sp.script, started by the key -zz_sp <token>).
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script sp_smoke.ps1 -Out b57_sp.out -ScriptArgs '-Tag b57'
# The last line is "sp_smoke: PASS" or "sp_smoke: FAIL (<why>)".
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [string]$Tag = 'b57',
    [string]$Faction = 'stalker',
    [string]$Map = 'rookie_village',
    [int]$StepsTimeoutS = 900,
    # 2026-11-25: no audio output on the machine (headphones unplugged: every endpoint Unknown) makes the engine stop at once with
    # "OpenAL: Can't create sound device". -NoSound starts the game with the engine's -nosound key; the run says so in its result.
    [switch]$NoSound
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link (TZ R21)
# Tracked in tools\stand (docs/MODES.md section 10): the probes come from this folder; logs and the stand's
# settings kept for the restore go to the repository's temp\stand (ignored: the run history).
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'appdata_t'))) { throw 'no appdata_t: run auto_world.ps1 once' }
# Additional errors the run must not show.
$bad = 'SCRIPT ERROR|attempt to |! \[SCRIPT|xr_conditions fail|xr_effects fail|Cannot find saved game'

function New-Profile([string]$letter) {
    $name = "appdata_$letter"
    $text = [System.IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$name\"
    if ($text -notmatch [regex]::Escape("$name\")) { throw 'fsgame.ltx format unexpected' }
    Write-StandText -Path (Join-Path $Stand "fsgame_$letter.ltx") -Text $text -Encoding $cp1251
    $appdata = Join-Path $Stand $name
    New-Item -ItemType Directory -Force -Path $appdata | Out-Null
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To $appdata -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')
    # The stand runs unattended: nobody presses a key. Stock's "press any key" screen after a load (keypress_on_start,
    # GamePersistent game_loaded: the pause reason "tutorial_start") held the single player game paused, and the probe's
    # steps never came (2026-11-21, five runs). A session skips that screen itself (coop::skip_keypress_on_load).
    # g_always_active: a window without the focus stays active (a locked desktop), as ms_crash_server sets it.
    $user = Join-Path $appdata 'user.ltx'
    $lines = @([IO.File]::ReadAllLines($user, $cp1251) | Where-Object { $_ -notmatch '^\s*(g_always_active|keypress_on_start)\s' })
    Write-StandLines -Path $user -Lines ($lines + 'g_always_active on' + 'keypress_on_start off') -Encoding $cp1251
    $global:LASTEXITCODE = 0
    return $appdata
}
function Get-StartKit([string]$Ltx, [string]$Fac) {
    $own = @{}; $parents = @{}; $cur = $null
    foreach ($raw in [System.IO.File]::ReadAllLines($Ltx, $cp1251)) {
        $l = ($raw -replace ';.*$', '').Trim()
        if (-not $l) { continue }
        if ($l -match '^\[([^\]]+)\]\s*(?::\s*(.+))?$') {
            $cur = $Matches[1]
            $own[$cur] = [ordered]@{}
            $parents[$cur] = if ($Matches[2]) { @($Matches[2].Split(',') | ForEach-Object { $_.Trim() }) } else { @() }
            continue
        }
        if ($cur -and $l -match '^([^=\s]+)\s*=\s*(.*)$') { $own[$cur][$Matches[1]] = $Matches[2].Trim() }
    }
    $resolve = {
        param($s)
        $r = [ordered]@{}
        foreach ($p in $parents[$s]) { foreach ($kv in (& $resolve $p).GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        if ($own.Contains($s)) { foreach ($kv in $own[$s].GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        $r
    }
    $kit = [System.Collections.Generic.List[string]]::new()
    foreach ($kv in (& $resolve "$($Fac)_loadout").GetEnumerator()) {
        $v = $kv.Value.Split(',')
        if ($v[0].Trim() -eq 'false') { for ($i = 0; $i -lt [int]$v[1]; $i++) { $kit.Add($kv.Key) } }
    }
    [pscustomobject]@{ Loadout = ($kit -join ','); Money = (& $resolve "$($Fac)_money")['money'] }
}
function Wait-Log([string]$file, [string]$pattern, [int]$seconds, $proc) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $file) -and (Select-String -LiteralPath $file -Pattern $pattern -Quiet)) { return $true }
        if ($proc -and $proc.HasExited) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}
function Show-Lines([string]$file, [string]$pattern, [int]$most) {
    if (-not (Test-Path -LiteralPath $file)) { Write-Host "  no log $file"; return }
    Select-String -LiteralPath $file -Pattern $pattern | Select-Object -Last $most | ForEach-Object {
        $l = $_.Line -replace '[0-9a-fA-F]{32,}', '<hidden>'
        if ($l.Length -gt 420) { $l = $l.Substring(0, 420) }
        Write-Host "  $l"
    }
}

$token = 'sp' + (Get-Date -Format 'HHmmss')
$data = New-Profile 's'
$log = Join-Path $data ('logs\xray_' + $env:USERNAME + '.log')
Remove-StandFile -Path $log
$saves = Join-Path $data 'savedgames'
if (Test-Path -LiteralPath $saves) { Get-ChildItem -LiteralPath $saves -Filter 'zz_sp_smoke*' | ForEach-Object { Remove-StandFile -Path $_.FullName } }
$scripts = Join-Path $Stand 'gamedata\scripts'
Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_sp.script') -To (Join-Path $scripts 'coop_zz_sp.script')
Get-ChildItem -LiteralPath $Stand -Filter 'zz_sp_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }

$opt = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optKeep = Join-Path $OutDir 'axr_options.before_sp.ltx'
if (-not (Test-Path -LiteralPath $optKeep)) { Copy-Item -LiteralPath $opt -Destination $optKeep }
$kit = Get-StartKit (Join-Path $Stand 'gamedata\configs\items\settings\new_game_loadouts.ltx') $Faction
if (-not $kit.Loadout) { throw "no free kit for faction '$Faction'" }
$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]][System.IO.File]::ReadAllLines($opt, $cp1251))
$start = $lines.FindIndex([Predicate[string]] { param($l) $l -match '^\[character_creation\]' })
if ($start -ge 0) {
    $end = $lines.FindIndex($start + 1, [Predicate[string]] { param($l) $l -match '^\[' })
    if ($end -lt 0) { $end = $lines.Count }
    $lines.RemoveRange($start, $end - $start)
}
$lines.Add('[character_creation]')
$lines.Add('new_game_difficulty = 1')
$lines.Add('new_game_economy = 1')
$lines.Add('new_game_economy_treasure = 1')
$lines.Add('new_game_story_mode = true')
$lines.Add('new_game_character_name = Loner')
$lines.Add("new_game_faction = $Faction")
$lines.Add("new_game_loadout = $($kit.Loadout)")
$lines.Add("new_game_map = $Map")
if ($kit.Money) { $lines.Add("new_game_money = $($kit.Money)") }
Write-StandLines -Path $opt -Lines $lines -Encoding $cp1251

$game = $null
$why = ''
try {
    # no -coop_ key: the plain single player game of the stand's exe
    $game = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_s.ltx -zz_sp $token -silent_error_mode$(if ($NoSound) { ' -nosound' } else { '' }) -start server(all/single/alife/new) client(localhost)"
    $null = $game.Handle
    Write-Host "game pid $($game.Id)"
    if ($NoSound) { Write-Host 'sound: off (-nosound): the run checks no sound' }
    if (-not (Wait-Log $log '\[sp\] the steps start' 900 $game)) { throw 'the new game did not start' }
    Write-Host ("in the new game ({0:HH:mm:ss})" -f (Get-Date))
    if (-not (Wait-Log $log '\[sp\] load zz_sp_smoke asked' 180 $game)) { throw 'the save and the load were not asked' }
    if (-not (Wait-Log $log '\[sp\] after the load' 600 $game)) { throw 'the save did not load' }
    Write-Host ("the save is loaded ({0:HH:mm:ss})" -f (Get-Date))
    if (-not (Wait-Log $log '\[sp\] done' 180 $game)) { throw 'the game did not live 60 s after the load' }
    $alive = -not $game.HasExited
    Write-Host "steps done; game alive $alive"
    if (-not $alive) { $why = 'the game ended' }
    $saved = Test-Path -LiteralPath (Join-Path $saves 'zz_sp_smoke.scop')
    Write-Host "save file: $saved"
    if (-not $saved -and -not $why) { $why = 'no save file' }
    if (-not $why -and (Select-StandLogLine $log $bad | Select-Object -First 1)) { $why = 'error lines in the log' }
}
catch {
    $why = "$_"
    if ($game -and $game.HasExited) { Write-Host ("the game ended by itself: exit code {0} (0x{0:X8})" -f $game.ExitCode) }
    Write-Host "! $why"
}
finally {
    if ($why -and $game -and -not $game.HasExited) {
        # b57i: a forced stop left the log cut 1 s after the steps start, so nothing told a hang from a game that ran on.
        # On a failure the game is asked to close first (WM_CLOSE flushes its log); the CPU it burns says busy or waiting.
        $game.Refresh(); $cpu0 = $game.TotalProcessorTime
        Start-Sleep -Seconds 5
        $game.Refresh(); $cpu1 = $game.TotalProcessorTime
        Write-Host ("the game is still running: {0:N1} s of CPU in 5 s, responding {1}" -f ($cpu1 - $cpu0).TotalSeconds, $game.Responding)
        $null = $game.CloseMainWindow()
        if ($game.WaitForExit(20000)) { Write-Host 'closed on WM_CLOSE (its log is complete)' }
        else { Write-Host '! did not close on WM_CLOSE in 20 s: the main thread does not take window messages' }
    }
    if ($game -and -not $game.HasExited) { Stop-Process -Id $game.Id -Force }
    Start-Sleep -Seconds 3
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $OutDir "${Tag}_sp.log") -Force }
    Get-ChildItem -LiteralPath $scripts -Filter 'coop_zz_*.script' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Get-ChildItem -LiteralPath $Stand -Filter 'zz_sp_*.txt' | ForEach-Object { Remove-StandFile -Path $_.FullName }
    Copy-StandFile -From $optKeep -To $opt
}
Write-Host '--- the probe ---'
Show-Lines $log '\[sp\]' 40
Write-Host '--- errors ---'
Show-StandLogLines $log $bad 30
if ($why) { Write-Host "sp_smoke: FAIL ($why)" } else { Write-Host 'sp_smoke: PASS' }
