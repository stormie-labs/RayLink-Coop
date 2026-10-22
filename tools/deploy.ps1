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

  With -Profile (GAMMA, default root E:\AnomalyCoopGamma) the root is built from that MO2 profile instead
  (tools\mo2_stand.py, docs\MO2_GAMMA.md, section 3): the game, the profile's enabled mods and MO2's overwrite are
  materialized as hard links in MO2's priority order, our layers go in as copies - Engine (our exe in bin\ +
  engine\gamedata) under the mods, Core (gamedata\) and GAMMA (gamedata_gamma\, if present) on top. db\ is then a
  real folder of links, bin_b\ mirrors bin\ with links, the mods' appdata\ files go into appdata_a\ and appdata_b\.

.EXAMPLE
  .\deploy.ps1                       # stock Anomaly stand: E:\AnomalyCoop
  .\deploy.ps1 -Profile G.A.M.M.A    # GAMMA stand from E:\GAMMA's profile: E:\AnomalyCoopGamma
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
    [switch]$SkipGameBin,
    [string]$Profile  = '',          # MO2 profile to build the stand from (G.A.M.M.A); empty = stock Anomaly
    [string]$Mo2Dir   = 'E:\GAMMA',  # MO2 instance (portable) that owns the profile
    [string]$GammaGamedata = (Join-Path $PSScriptRoot '..\gamedata_gamma')
)

$ErrorActionPreference = 'Stop'
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)

function Assert-Path([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
}

if ($Profile -and -not $PSBoundParameters.ContainsKey('TestRoot')) { $TestRoot = 'E:\AnomalyCoopGamma' }

Assert-Path $GameDir 'Game folder'
Assert-Path $BuiltExe 'Built exe'
Assert-Path $EngineGamedata 'Engine gamedata'
$gameBin = Join-Path $GameDir 'bin'
$fsgame = Join-Path $GameDir 'fsgame.ltx'
Assert-Path $gameBin 'bin'
Assert-Path $fsgame 'fsgame.ltx'

# The two kinds of root never take each other's place: the GAMMA stand is hard links to the mods' own files (robocopy
# below would write straight into them), the stock root's db is a junction to the real game's archives.
$standDb = Join-Path $TestRoot 'db'
if ($Profile) {
    if ((Test-Path -LiteralPath $standDb) -and ((Get-Item -LiteralPath $standDb -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "$standDb is a junction (a stock deploy root?): the GAMMA stand needs a root of its own (default E:\AnomalyCoopGamma)"
    }
} elseif (Test-Path -LiteralPath (Join-Path $TestRoot '.mo2_stand.json')) {
    throw "$TestRoot is a GAMMA stand built by mo2_stand.py (its files are hard links to the mods): use -Profile, or another -TestRoot for the stock stand"
}

New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null

if (-not $SkipGameBin) {
    Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $gameBin $ExeName) -Force
    Write-Host "also: $gameBin\$ExeName"
}

if ($Profile) {
    # 1-3. the stand from the MO2 profile; Engine = our exe under bin\ (staged in the repo's temp\) + engine gamedata
    $engineStage = Join-Path $PSScriptRoot '..\temp\stand_engine'
    New-Item -ItemType Directory -Force -Path (Join-Path $engineStage 'bin') | Out-Null
    Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $engineStage "bin\$ExeName") -Force
    $standArgs = @((Join-Path $PSScriptRoot 'mo2_stand.py'), '--mo2', $Mo2Dir, '--profile', $Profile, '--game', $GameDir,
                   '--out', $TestRoot, '--layer-bottom', $engineStage, '--layer-bottom', "gamedata=$EngineGamedata",
                   '--layer-top', "gamedata=$ModGamedata",
                   '--report', (Join-Path $PSScriptRoot '..\temp\mo2_stand_report.txt'))
    if (Test-Path -LiteralPath $GammaGamedata) { $standArgs += @('--layer-top', "gamedata=$GammaGamedata") }
    & python @standArgs
    if ($LASTEXITCODE -ne 0) { throw "mo2_stand.py failed: $LASTEXITCODE" }

    # bin_b: the engine refuses a second instance from the same exe folder; it holds only our hard links
    $binA = Join-Path $TestRoot 'bin'
    $binB = Join-Path $TestRoot 'bin_b'
    if (Test-Path -LiteralPath $binB) {
        if ((Get-Item -LiteralPath $binB -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "bin_b is a link, not a folder: $binB"
        }
        Get-ChildItem -LiteralPath $binB -Recurse -File -Force | Remove-Item -Force
    }
    Get-ChildItem -LiteralPath $binA -Recurse -File -Force | ForEach-Object {
        $dst = Join-Path $binB $_.FullName.Substring($binA.Length + 1)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType HardLink -Path $dst -Target $_.FullName -ErrorAction SilentlyContinue | Out-Null
    }
    # A file in bin_b that could not be removed (held by a scanner, a stale game) kept the OLD exe and the client
    # came up with the previous protocol (night run 2026-10-23): the two exes must be the same build, or no deploy.
    $exeA = Join-Path $binA $ExeName
    $exeB = Join-Path $binB $ExeName
    if ((Get-FileHash -LiteralPath $exeA).Hash -ne (Get-FileHash -LiteralPath $exeB -ErrorAction SilentlyContinue).Hash) {
        Copy-Item -LiteralPath $exeA -Destination $exeB -Force
        if ((Get-FileHash -LiteralPath $exeA).Hash -ne (Get-FileHash -LiteralPath $exeB).Hash) {
            throw "bin_b keeps another exe than bin: $exeB (is a game still running from it?)"
        }
        Write-Host "bin_b: the exe was copied (the hard link could not replace the old one)"
    }
    Write-Host "exe: $binA\$ExeName, $binB\$ExeName (same build)"
    $fsgame = Join-Path $TestRoot 'fsgame.ltx'  # the stand's copy: a mod may replace it
} else {
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
}

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
    $modsAppdata = Join-Path $TestRoot 'appdata'
    if ($Profile -and (Test-Path -LiteralPath $modsAppdata)) {
        # files the mods put into appdata\ (shader presets): in MO2 the game sees them in its own appdata
        & robocopy $modsAppdata $appdata /E /XF user.ltx /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy mods' appdata failed: $LASTEXITCODE" }
        $global:LASTEXITCODE = 0
    }
    Write-Host "instance ${inst}: $TestRoot\fsgame_$inst.ltx, $appdata"
}
