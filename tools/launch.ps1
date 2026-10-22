<#
.SYNOPSIS
  Starts one coop test instance (a = host, b = client) from the test root built by deploy.ps1.

.EXAMPLE
  .\launch.ps1 a -NewGame -HostSession -StatusEvery 10     # host: new game, hosts by itself
  .\launch.ps1 b -Connect 127.0.0.1 -StatusEvery 10        # client: joins by itself
  .\launch.ps1 a -Load mysave                              # host: load a save from appdata_a\savedgames
  .\launch.ps1 a -NewGame -GameDir E:\AnomalyCoopGamma     # the GAMMA stand (deploy.ps1 -Profile G.A.M.M.A)
  .\launch.ps1 b -Connect 127.0.0.1 -NoStart               # prepare and print the command, start nothing
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('a', 'b')][string]$Instance,
    [switch]$NewGame,
    [string]$Load,
    [switch]$HostSession,           # -coop_host: host as soon as the level is ready
    [string]$Connect,               # -coop_connect ip[:port]: join automatically
    [string]$Nick,
    [int]$StatusEvery = 0,          # -coop_autostatus N: coop_status + dump summary every N s
    [int]$ShotEvery = 0,            # -coop_shots N: screenshot every N s (appdata_X\screenshots)
    [string]$StartFaction = 'stalker',     # -NewGame: faction picked as in the faction-select screen
    [string]$StartMap = 'rookie_village', # -NewGame: start point from plugins\new_game_start_locations.ltx (Cordon)
    # -NewGame: unpacked stock configs, for the faction's free kit and money (items\settings\new_game_loadouts.ltx)
    [string]$RefConfigs = 'D:\Projects\ForEverything\anomaly-ref\unpacked\configs',
    [string]$GameDir = 'E:\AnomalyCoop',
    [string]$ExeName = 'AnomalyCoopDX11AVX.exe',
    [string[]]$Extra = @(),
    [switch]$NoStart                # prepare everything and print the command line, but do not start the game
)

$ErrorActionPreference = 'Stop'
$binDir = if ($Instance -eq 'a') { Join-Path $GameDir 'bin' } else { Join-Path $GameDir 'bin_b' }
$exe = Join-Path $binDir $ExeName
if (-not (Test-Path -LiteralPath $exe)) { throw "not deployed: $exe (run deploy.ps1)" }

$cp1251 = [System.Text.Encoding]::GetEncoding(1251)

# The GAMMA stand is made of hard links to the mods' files (tools\mo2_stand.py): writing into an existing file could
# change a mod's original, so the old file is removed and a new one is written.
function Write-NewLines([string]$Path, [System.Collections.Generic.List[string]]$Lines) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    [System.IO.File]::WriteAllLines($Path, $Lines, $cp1251)
}

# What the faction-select screen puts into new_game_loadout / new_game_money with nothing bought:
# the free kit (value_1 = false: PDA, flashlight, backpack, faction weapon...) and [<faction>_money].
function Get-StartKit([string]$Ltx, [string]$Faction) {
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
    # ltx inheritance: parents in order, then the section's own lines override
    $resolve = {
        param($s)
        $r = [ordered]@{}
        foreach ($p in $parents[$s]) { foreach ($kv in (& $resolve $p).GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        if ($own.Contains($s)) { foreach ($kv in $own[$s].GetEnumerator()) { $r[$kv.Key] = $kv.Value } }
        $r
    }
    $kit = [System.Collections.Generic.List[string]]::new()
    foreach ($kv in (& $resolve "$($Faction)_loadout").GetEnumerator()) {
        $v = $kv.Value.Split(',')
        if ($v[0].Trim() -eq 'false') { for ($i = 0; $i -lt [int]$v[1]; $i++) { $kit.Add($kv.Key) } }
    }
    $money = (& $resolve "$($Faction)_money")['money']
    [pscustomobject]@{ Loadout = ($kit -join ','); Money = $money }
}

if ($NewGame) {
    # Anomaly's new game reads [character_creation] from axr_options.ltx (written by the faction-select
    # screen, consumed on start). Without it the game stays on the stub level fake_start; without the kit
    # the character starts with no PDA, no money and story mode off (no tasks).
    $opt = Join-Path $GameDir 'gamedata\configs\axr_options.ltx'
    # a stand with its own loadouts (GAMMA: "G.A.M.M.A. Starting Loadouts") uses them; DLTX mod_new_game_loadouts_*
    # additions are not applied here
    $kitLtx = Join-Path $GameDir 'gamedata\configs\items\settings\new_game_loadouts.ltx'
    if (-not (Test-Path -LiteralPath $kitLtx)) { $kitLtx = Join-Path $RefConfigs 'items\settings\new_game_loadouts.ltx' }
    if (-not (Test-Path -LiteralPath $kitLtx)) { throw "stock loadouts not found: $kitLtx (-RefConfigs)" }
    $kit = Get-StartKit $kitLtx $StartFaction
    if (-not $kit.Loadout) { throw "no free kit for faction '$StartFaction' in $kitLtx" }
    $charName = if ($Nick) { $Nick } elseif ($Instance -eq 'a') { 'Host' } else { 'Player_B' }
    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $opt) { $lines.AddRange([string[]][System.IO.File]::ReadAllLines($opt, $cp1251)) }
    $start = $lines.FindIndex([Predicate[string]]{ param($l) $l -match '^\[character_creation\]' })
    if ($start -ge 0) {
        $end = $lines.FindIndex($start + 1, [Predicate[string]]{ param($l) $l -match '^\[' })
        if ($end -lt 0) { $end = $lines.Count }
        $lines.RemoveRange($start, $end - $start)
    }
    # Same keys and defaults as UINewGame:OnStartGame with nothing changed (difficulty 1, economy 1, story on)
    $lines.Add('[character_creation]')
    $lines.Add('new_game_difficulty = 1')
    $lines.Add('new_game_economy = 1')
    $lines.Add('new_game_economy_treasure = 1')
    $lines.Add('new_game_story_mode = true')
    $lines.Add("new_game_character_name = $($charName -replace ' ', '_')")
    $lines.Add("new_game_faction = $StartFaction")
    $lines.Add("new_game_loadout = $($kit.Loadout)")
    $lines.Add("new_game_map = $StartMap")
    if ($kit.Money) { $lines.Add("new_game_money = $($kit.Money)") }
    Write-NewLines $opt $lines
    Write-Host "new game: $StartFaction at $StartMap as '$charName', $($kit.Money) RU, kit: $($kit.Loadout)"
}

# Test stand: the minimap is off by default in Anomaly 1.5.3 (ui_options show_minimap def=false), and the
# allies' radar markers need it. Both instances share this file.
$optFile = Join-Path $GameDir 'gamedata\configs\axr_options.ltx'
if (Test-Path -LiteralPath $optFile) {
    $cp = [System.Text.Encoding]::GetEncoding(1251)
    $ol = [System.Collections.Generic.List[string]]::new()
    $ol.AddRange([string[]][System.IO.File]::ReadAllLines($optFile, $cp))
    $i = $ol.FindIndex([Predicate[string]]{ param($l) $l -match '^\s*video/hud/show_minimap\s*=' })
    if ($i -ge 0) { $ol[$i] = '        video/hud/show_minimap           = true' }
    else {
        $s = $ol.FindIndex([Predicate[string]]{ param($l) $l -match '^\[options\]' })
        if ($s -ge 0) { $ol.Insert($s + 1, '        video/hud/show_minimap           = true') }
        else { $ol.Add('[options]'); $ol.Add('        video/hud/show_minimap           = true') } # fresh file
    }
    Write-NewLines $optFile $ol
}

$argv = @('-fsltx', "fsgame_$Instance.ltx", '-smap2048')
if ($HostSession) { $argv += @('-coop_host', '27960') }
if ($Connect) { $argv += @('-coop_connect', $Connect) }
if ($Nick) { $argv += @('-coop_nick', $Nick) }
if ($StatusEvery -gt 0) { $argv += @('-coop_autostatus', "$StatusEvery") }
if ($ShotEvery -gt 0) { $argv += @('-coop_shots', "$ShotEvery") }
$argv += $Extra
# -start must stay last: the engine runs the rest of the command line as the console command.
if ($NewGame) { $argv += @('-start', 'server(all/single/alife/new)', 'client(localhost)') }
elseif ($Load) { $argv += @('-start', "server($Load/single/alife/load)", 'client(localhost)') }

if ($NoStart) {
    Write-Host "not started: $exe $($argv -join ' ') (in $GameDir)"
    return
}
$p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $GameDir -PassThru
Write-Host "instance $Instance started: pid $($p.Id), log $GameDir\appdata_$Instance\logs"
