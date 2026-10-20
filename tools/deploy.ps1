<#
.SYNOPSIS
  Builds an isolated two-instance test root for Anomaly Coop next to the real game.

.DESCRIPTION
  The real install (default E:\Anomaly) is never modified, except that our exe is also copied
  into its bin under our own name (owner's request for S0).
  Test root (default E:\AnomalyCoop):
  - db\                 junction to the real game's db (archives are shared, nothing copied);
  - gamedata\           gamedata of our engine revision + our mod (archives mount at $game_data$,
                        so the folder must be called gamedata);
  - bin\, bin_b\        two exe folders (the engine refuses a second instance from the same exe
                        folder: mutex on the folder path, xrEngine/x_ray.cpp); files are hard links;
  - fsgame_a.ltx/_b.ltx the game's fsgame.ltx with an own appdata per instance;
  - appdata_a\, _b\     log, user.ltx (windowed, g_always_active, nick), saves, shader cache, player key.
  Safe to re-run: links and the gamedata mirror are rebuilt, existing user.ltx files are kept.
#>
param(
    [string]$GameDir  = 'E:\Anomaly',
    [string]$TestRoot = 'E:\AnomalyCoop',
    # test builds come from the engine-ci worktree (tools\ci_sync.py); the main tree's _build is stale
    [string]$BuiltExe = (Join-Path $PSScriptRoot '..\engine-ci\_build\_game\bin_dbg\AnomalyDX11AVX.exe'),
    [string]$EngineGamedata = (Join-Path $PSScriptRoot '..\engine\gamedata'),
    [string]$ModGamedata = (Join-Path $PSScriptRoot '..\gamedata'),
    [string]$ExeName  = 'AnomalyCoopDX11AVX.exe',
    [string]$VidMode  = '1280x720',
    [switch]$SkipGameBin
)

$ErrorActionPreference = 'Stop'
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)

function Assert-Path([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
}

Assert-Path $GameDir 'Game folder'
Assert-Path $BuiltExe 'Built exe'
Assert-Path $EngineGamedata 'Engine gamedata'
$gameBin = Join-Path $GameDir 'bin'
$fsgame = Join-Path $GameDir 'fsgame.ltx'
Assert-Path $gameBin 'bin'
Assert-Path $fsgame 'fsgame.ltx'

New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null

# 1. db: junction to the real archives
$db = Join-Path $TestRoot 'db'
if (-not (Test-Path -LiteralPath $db)) {
    New-Item -ItemType Junction -Path $db -Target (Join-Path $GameDir 'db') | Out-Null
}
Write-Host "db: $db -> $(Join-Path $GameDir 'db')"

# 2. exe folders: hard links to the game's DLLs/configs + our exe
$tmpExe = Join-Path $TestRoot $ExeName
Copy-Item -LiteralPath $BuiltExe -Destination $tmpExe -Force
foreach ($name in 'bin', 'bin_b') {
    $dir = Join-Path $TestRoot $name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem -LiteralPath $dir -File | Remove-Item -Force
    Get-ChildItem -LiteralPath $gameBin -File | Where-Object { $_.Extension -ne '.exe' } | ForEach-Object {
        New-Item -ItemType HardLink -Path (Join-Path $dir $_.Name) -Target $_.FullName | Out-Null
    }
    New-Item -ItemType HardLink -Path (Join-Path $dir $ExeName) -Target $tmpExe | Out-Null
}
Write-Host "exe: $TestRoot\bin\$ExeName, $TestRoot\bin_b\$ExeName"
if (-not $SkipGameBin) {
    Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $gameBin $ExeName) -Force
    Write-Host "also: $gameBin\$ExeName"
}

# 3. gamedata: engine revision first, our mod on top
$gd = Join-Path $TestRoot 'gamedata'
# axr_options.ltx is written by the game itself (player settings): excluded files are neither copied nor purged
& robocopy $EngineGamedata $gd /MIR /XF axr_options.ltx /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy engine gamedata failed: $LASTEXITCODE" }
if (Test-Path -LiteralPath $ModGamedata) {
    & robocopy $ModGamedata $gd /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy mod gamedata failed: $LASTEXITCODE" }
}
$global:LASTEXITCODE = 0
Write-Host "gamedata: $gd"

# 4. fsgame + appdata per instance
$fsText = [System.IO.File]::ReadAllText($fsgame, $cp1251)
$userLtx = Join-Path $GameDir 'appdata\user.ltx'
$settings = [ordered]@{
    'rs_screenmode'   = 'windowed'
    'vid_mode'        = $VidMode
    'g_always_active' = 'on'
}
foreach ($inst in 'a', 'b') {
    $appdataName = "appdata_$inst"
    $text = $fsText -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$appdataName\"
    if ($text -notmatch [regex]::Escape("$appdataName\")) { throw 'fsgame.ltx format unexpected: app_data_root not rewritten' }
    [System.IO.File]::WriteAllText((Join-Path $TestRoot "fsgame_$inst.ltx"), $text, $cp1251)

    $appdata = Join-Path $TestRoot $appdataName
    New-Item -ItemType Directory -Force -Path $appdata | Out-Null
    $userOut = Join-Path $appdata 'user.ltx'
    if (-not (Test-Path -LiteralPath $userOut)) {
        $lines = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $userLtx) { $lines.AddRange([string[]][System.IO.File]::ReadAllLines($userLtx, $cp1251)) }
        foreach ($key in $settings.Keys) {
            $line = "$key $($settings[$key])"
            $idx = $lines.FindIndex([Predicate[string]]{ param($l) $l -match "^$key\s" })
            if ($idx -ge 0) { $lines[$idx] = $line } else { $lines.Add($line) }
        }
        $lines.Add("coop_nick player_$inst")
        [System.IO.File]::WriteAllLines($userOut, $lines, $cp1251)
    }
    Write-Host "instance ${inst}: $TestRoot\fsgame_$inst.ltx, $appdata"
}
