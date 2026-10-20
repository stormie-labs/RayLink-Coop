<#
.SYNOPSIS
  Installs the built exe and our gamedata into the Anomaly folder for a two-instance test on one PC.

.DESCRIPTION
  Never touches the game's own files, only adds ours:
  - bin\<ExeName>               our exe next to the stock ones (instance A, host);
  - bin_coop_b\                 folder for instance B: the engine refuses a second instance started
                                from the same exe folder (mutex on the folder path, xrEngine/x_ray.cpp);
                                its files are hard links to bin, they take no space;
  - gamedata_coop\              gamedata of our engine revision (engine\gamedata) + our mod (gamedata\);
  - fsgame_coop_a.ltx / _b.ltx  copies of the game's fsgame.ltx with an own appdata per instance
                                (log, user.ltx, saves, shader cache, player key) and gamedata_coop;
  - appdata_coop_a\ / _b\       user.ltx copied from the game's appdata + windowed mode, g_always_active.
  Safe to re-run: links and the gamedata mirror are rebuilt, existing user.ltx files are kept.
#>
param(
    [string]$GameDir  = 'E:\Anomaly',
    [string]$BuiltExe = (Join-Path $PSScriptRoot '..\engine\_build\_game\bin_dbg\AnomalyDX11AVX.exe'),
    [string]$EngineGamedata = (Join-Path $PSScriptRoot '..\engine\gamedata'),
    [string]$ModGamedata = (Join-Path $PSScriptRoot '..\gamedata'),
    [string]$ExeName  = 'AnomalyCoopDX11AVX.exe',
    [string]$VidMode  = '1280x720'
)

$ErrorActionPreference = 'Stop'
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)

function Assert-Path([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
}

Assert-Path $GameDir 'Game folder'
Assert-Path $BuiltExe 'Built exe'
Assert-Path $EngineGamedata 'Engine gamedata'
$bin = Join-Path $GameDir 'bin'
$fsgame = Join-Path $GameDir 'fsgame.ltx'
Assert-Path $bin 'bin'
Assert-Path $fsgame 'fsgame.ltx'

# 1. exe of instance A: in the stock bin under our own name
$exeA = Join-Path $bin $ExeName
Copy-Item -LiteralPath $BuiltExe -Destination $exeA -Force
Write-Host "exe A: $exeA"

# 2. bin_coop_b: hard links to everything in bin except the other exes
$binB = Join-Path $GameDir 'bin_coop_b'
New-Item -ItemType Directory -Force -Path $binB | Out-Null
Get-ChildItem -LiteralPath $binB -File | Remove-Item -Force
Get-ChildItem -LiteralPath $bin -File |
    Where-Object { $_.Extension -ne '.exe' -or $_.Name -eq $ExeName } |
    ForEach-Object {
        New-Item -ItemType HardLink -Path (Join-Path $binB $_.Name) -Target $_.FullName | Out-Null
    }
Write-Host "exe B: $(Join-Path $binB $ExeName)"

# 3. gamedata: engine revision first, our mod on top
$gdCoop = Join-Path $GameDir 'gamedata_coop'
& robocopy $EngineGamedata $gdCoop /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy engine gamedata failed: $LASTEXITCODE" }
if (Test-Path -LiteralPath $ModGamedata) {
    & robocopy $ModGamedata $gdCoop /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy mod gamedata failed: $LASTEXITCODE" }
}
Write-Host "gamedata: $gdCoop"

# 4. fsgame + appdata per instance
$fsText = [System.IO.File]::ReadAllText($fsgame, $cp1251)
$userLtx = Join-Path $GameDir 'appdata\user.ltx'
$settings = [ordered]@{
    'rs_screenmode'   = 'windowed'
    'vid_mode'        = $VidMode
    'g_always_active' = 'on'
}

foreach ($inst in 'a', 'b') {
    $appdataName = "appdata_coop_$inst"
    $text = $fsText -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$appdataName\"
    $text = $text -replace '(?m)^(\$game_data\$\s*=.*\|\s*)gamedata\\', '${1}gamedata_coop\'
    if ($text -notmatch [regex]::Escape("$appdataName\") -or $text -notmatch 'gamedata_coop\\') {
        throw 'fsgame.ltx format unexpected: app_data_root/game_data lines not rewritten'
    }
    $fsOut = Join-Path $GameDir "fsgame_coop_$inst.ltx"
    [System.IO.File]::WriteAllText($fsOut, $text, $cp1251)

    $appdata = Join-Path $GameDir $appdataName
    New-Item -ItemType Directory -Force -Path $appdata | Out-Null
    $userOut = Join-Path $appdata 'user.ltx'
    if (-not (Test-Path -LiteralPath $userOut)) {
        $lines = [System.Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $userLtx) {
            $lines.AddRange([string[]][System.IO.File]::ReadAllLines($userLtx, $cp1251))
        }
        foreach ($key in $settings.Keys) {
            $line = "$key $($settings[$key])"
            $idx = $lines.FindIndex([Predicate[string]]{ param($l) $l -match "^$key\s" })
            if ($idx -ge 0) { $lines[$idx] = $line } else { $lines.Add($line) }
        }
        $lines.Add("coop_nick player_$inst")
        [System.IO.File]::WriteAllLines($userOut, $lines, $cp1251)
    }
    Write-Host "instance ${inst}: $fsOut, $appdata"
}
