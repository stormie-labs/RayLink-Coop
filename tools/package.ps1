<#
.SYNOPSIS
  Builds the Mod Organizer 2 archive of Anomaly Coop: releases\anomaly-coop-<version>.zip

.DESCRIPTION
  Archive layout. Three top-level folders are three ready MO2 mods; the FOMOD installer in fomod\ModuleConfig.xml
  creates ONE MO2 mod per run (the player runs it once per part and types the mod name in the installer):
    fomod\info.xml, fomod\ModuleConfig.xml          installer (info.xml gets the version)
    Anomaly Coop - Engine\bin\AnomalyCoopDX11AVX.exe  our engine build (engine-ci bin_dbg AnomalyDX11AVX.exe, renamed)
    Anomaly Coop - Engine\gamedata\                 scripts/configs of that engine build (engine\gamedata);
                                                    lowest priority in MO2: covers only the modded exes in the game folder
    Anomaly Coop - Core\gamedata\                   our mod: gamedata\ of this project; highest priority
    Anomaly Coop - GAMMA\gamedata\                  gamedata_gamma\ of this project (patches for G.A.M.M.A. mods; an empty
                                                    folder while that directory is absent); right above Core
    Anomaly Coop - GAMMA\readme_gamma.txt           what this part is (packaging\readme_gamma.txt)
    anomaly-coop-release.txt                        version, protocol, engine and project commits, exe hash
    readme_eng.txt, readme_rus.txt                  install and play (packaging\)
  Temp/runtime files are left out (*.bak, *.tmp, *.log, *.orig, axr_options.ltx, cache_dbg.ltx, temp\ ...).
  Reads only this project's folders and writes only under releases\ of this project.
  Entries use "/" separators (written with System.IO.Compression, not Compress-Archive); empty folders get a
  directory entry ("Anomaly Coop - GAMMA/gamedata/").

  Engine build (one number from build to package): the minor part of -Version is the build, 0.28.0 = build 28. The
  engine names its build itself (engine\src\xrCore\raylink_version.h: window title, main menu, log, console `version`,
  crash dialogs): "RayLink Engine b28" for a CI tree synced with `python tools\ci_sync.py --build 28`, "RayLink Engine
  dev" without --build. This script reads that stamp out of the exe and stops when it is not the package's build.
  -EngineBuild <n> packs the exe of another build on purpose (a scripts-only build: 0.29.0 with the b28 exe),
  -EngineBuild dev a development exe, -EngineBuild any whatever the exe says (tests; also an exe without a stamp).
  The stamp goes into anomaly-coop-release.txt.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\package.ps1 -Version 0.28.0
  powershell -ExecutionPolicy Bypass -File tools\package.ps1 -Version 0.29.0 -EngineBuild 28
#>
param(
    [string]$Version = '0.1.0',
    [string]$BuiltExe = '',
    [string]$EngineBuild = '',
    [switch]$KeepStage,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($BuiltExe -eq '') { $BuiltExe = Join-Path $Root 'engine-ci\_build\_game\bin_dbg\AnomalyDX11AVX.exe' }
$ExeName = 'AnomalyCoopDX11AVX.exe'
# The three MO2 mods (folder names in the archive = the names the player types in the installer)
$EngineMod = 'Anomaly Coop - Engine'
$CoreMod = 'Anomaly Coop - Core'
$GammaMod = 'Anomaly Coop - GAMMA'
$ModGamedata = Join-Path $Root 'gamedata'
$GammaGamedata = Join-Path $Root 'gamedata_gamma'   # optional: absent until there are patches for GAMMA mods
$EngineGamedata = Join-Path $Root 'engine\gamedata'
$FomodDir = Join-Path $Root 'fomod'
$PackDir = Join-Path $Root 'packaging'
$OutDir = Join-Path $Root 'releases'
$ProtocolHeader = Join-Path $Root 'engine\src\xrCoop\coop_protocol.h'

function Assert-Path([string]$Path, [string]$What) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
}

# Everything this script touches must be inside the project.
function Assert-Inside([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Root + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path outside the project ($Root): $full"
    }
}

if ($Version -notmatch '^\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$') { throw "Version must look like 1.2.3 (got '$Version')" }
foreach ($p in @($BuiltExe, $ModGamedata, $GammaGamedata, $EngineGamedata, $FomodDir, $PackDir, $OutDir)) { Assert-Inside $p }
Assert-Path $BuiltExe 'Built exe'
Assert-Path $ModGamedata 'Mod gamedata'
Assert-Path $EngineGamedata 'Engine gamedata'
Assert-Path (Join-Path $FomodDir 'ModuleConfig.xml') 'fomod\ModuleConfig.xml'
Assert-Path (Join-Path $FomodDir 'info.xml') 'fomod\info.xml'
Assert-Path (Join-Path $PackDir 'readme_gamma.txt') 'packaging\readme_gamma.txt'
Assert-Path $ProtocolHeader 'coop_protocol.h'

# --- the exe: a complete PE file, not one the linker is still writing
$exe = Get-Item -LiteralPath $BuiltExe
$head = New-Object byte[] 2
$fs = [System.IO.File]::OpenRead($exe.FullName)
try { [void]$fs.Read($head, 0, 2) } finally { $fs.Close() }
if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { throw "Not an exe (no MZ header): $BuiltExe" }
if (-not $Force) {
    if ($exe.Length -lt 8MB) { throw "Exe is only $([math]::Round($exe.Length / 1MB, 1)) MB - a build still running? (-Force to pack anyway)" }
    $age = (Get-Date) - $exe.LastWriteTime
    if ($age.TotalSeconds -lt 60) { throw "Exe was written $([int]$age.TotalSeconds) s ago - a build still running? (-Force to pack anyway)" }
}

# --- the engine build the exe names itself: "RayLink Engine b28" / "RayLink Engine dev" (a string literal, so it ends
# with a zero byte in the exe; raylink_version.h RAYLINK_ENGINE_VERSION). -Force does not skip this check.
$packageBuild = [int]($Version.Split('.')[1])
$latin1 = [System.Text.Encoding]::GetEncoding(28591)   # one char per byte
$stamps = @([regex]::Matches($latin1.GetString([System.IO.File]::ReadAllBytes($exe.FullName)), 'RayLink Engine (b[1-9][0-9]*|dev)\x00') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if ($stamps.Count -gt 1) { throw "Exe names more than one RayLink Engine build ($($stamps -join ', ')): $BuiltExe" }
$engineLabel = if ($stamps.Count -eq 1) { $stamps[0] } else { '' }
switch -Regex ($EngineBuild) {
    '^$' { $wantLabel = "b$packageBuild"; break }
    '^any$' { $wantLabel = ''; break }
    '^dev$' { $wantLabel = 'dev'; break }
    '^[1-9][0-9]*$' { $wantLabel = "b$EngineBuild"; break }
    default { throw "-EngineBuild must be a build number, dev or any (got '$EngineBuild')" }
}
if ($wantLabel -and $engineLabel -ne $wantLabel) {
    $has = if ($engineLabel) { "RayLink Engine $engineLabel" } else { 'no RayLink Engine build stamp (an exe from before build 28?)' }
    throw ("Exe says $has, package $Version needs RayLink Engine $wantLabel ($BuiltExe). Number the build: " +
        "python tools\ci_sync.py --build $packageBuild, then MSBuild in engine-ci; or pass -EngineBuild <n> to pack " +
        "another build's exe on purpose (scripts-only build).")
}
$engineName = if ($engineLabel) { "RayLink Engine $engineLabel" } else { 'RayLink Engine (exe without a build stamp)' }

# --- facts for the release text
$protocol = (Select-String -LiteralPath $ProtocolHeader -Pattern 'kProtocolVersion\s*=\s*(\d+)' | Select-Object -First 1).Matches[0].Groups[1].Value
function Git-Describe([string]$Dir) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return 'unknown (no git)' }
    $sha = (& git -C $Dir rev-parse --short HEAD 2>$null)
    if (-not $sha) { return 'unknown' }
    $dirty = (& git --no-optional-locks -C $Dir status --porcelain --untracked-files=no 2>$null)
    if ($dirty) { return "$sha + uncommitted changes" }
    return "$sha"
}
$engineCommit = Git-Describe (Join-Path $Root 'engine')
$projectCommit = Git-Describe $Root
$exeHash = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

# --- staging
$name = "anomaly-coop-$Version"
$stage = Join-Path $OutDir "_stage\$name"
$zip = Join-Path $OutDir "$name.zip"
Assert-Inside $stage
Assert-Inside $zip
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$ExcludeNames = @('axr_options.ltx', 'cache_dbg.ltx', 'Thumbs.db', 'desktop.ini', '.DS_Store')
$ExcludeExt = @('.bak', '.tmp', '.log', '.orig', '.back', '.swp', '.pyc', '.rej', '.old')
$ExcludeDirs = @('temp', 'tmp', '__pycache__', '.git', '.vs')

function Copy-Tree([string]$From, [string]$To) {
    $count = 0
    $skipped = New-Object System.Collections.Generic.List[string]
    $base = (Resolve-Path -LiteralPath $From).Path.TrimEnd('\')
    Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($base.Length + 1)
        $parts = $rel.Split('\')
        $dirHit = $false
        for ($i = 0; $i -lt $parts.Length - 1; $i++) { if ($ExcludeDirs -contains $parts[$i].ToLowerInvariant()) { $dirHit = $true } }
        $leaf = $_.Name
        if ($dirHit -or ($ExcludeNames -contains $leaf) -or ($ExcludeExt -contains $_.Extension.ToLowerInvariant()) -or $leaf.EndsWith('~')) {
            $skipped.Add($rel)
            return
        }
        $dst = Join-Path $To $rel
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
        $count++
    }
    return [pscustomobject]@{ Count = $count; Skipped = $skipped }
}

# part 1: Engine (exe + gamedata of the engine build)
$eng = Copy-Tree $EngineGamedata (Join-Path $stage "$EngineMod\gamedata")
New-Item -ItemType Directory -Force -Path (Join-Path $stage "$EngineMod\bin") | Out-Null
Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $stage "$EngineMod\bin\$ExeName") -Force

# part 2: Core (our scripts, configs, interface)
$core = Copy-Tree $ModGamedata (Join-Path $stage "$CoreMod\gamedata")

# part 3: GAMMA (patches for G.A.M.M.A. mods; gamedata_gamma\ may be absent - then an empty gamedata\ folder)
$gammaStage = Join-Path $stage "$GammaMod\gamedata"
if (Test-Path -LiteralPath $GammaGamedata) {
    $gamma = Copy-Tree $GammaGamedata $gammaStage
} else {
    New-Item -ItemType Directory -Force -Path $gammaStage | Out-Null
    $gamma = [pscustomobject]@{ Count = 0; Skipped = (New-Object System.Collections.Generic.List[string]) }
}
Copy-Item -LiteralPath (Join-Path $PackDir 'readme_gamma.txt') -Destination (Join-Path $stage "$GammaMod\readme_gamma.txt") -Force

# fomod: ModuleConfig as is, info.xml with this version
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'fomod') | Out-Null
Copy-Item -LiteralPath (Join-Path $FomodDir 'ModuleConfig.xml') -Destination (Join-Path $stage 'fomod\ModuleConfig.xml') -Force
$utf8 = New-Object System.Text.UTF8Encoding($false)
$info = [System.IO.File]::ReadAllText((Join-Path $FomodDir 'info.xml'), $utf8)
$info = [regex]::Replace($info, '<Version>[^<]*</Version>', "<Version>$Version</Version>")
[System.IO.File]::WriteAllText((Join-Path $stage 'fomod\info.xml'), $info, $utf8)

# readmes
foreach ($r in @('readme_eng.txt', 'readme_rus.txt')) {
    $src = Join-Path $PackDir $r
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage $r) -Force }
}

# release text
$built = $exe.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
$release = @"
Anomaly Coop $Version

protocol      $protocol
engine        $engineName, commit $engineCommit (xray-monolith fork, built $built)
project       $projectCommit
exe           $EngineMod\bin\$ExeName  $([math]::Round($exe.Length / 1MB, 1)) MB  sha256 $exeHash
parts         3 MO2 mods, one installer run per part: $EngineMod, $CoreMod, $GammaMod (G.A.M.M.A. only)
files         $EngineMod\gamedata $($eng.Count), $CoreMod\gamedata $($core.Count), $GammaMod\gamedata $($gamma.Count)
packed        $((Get-Date).ToString('yyyy-MM-dd HH:mm'))
game          S.T.A.L.K.E.R. Anomaly 1.5.3 (also G.A.M.M.A.); every player of a session needs this same version.
not included  MCM, FDDA, xrMPE NPC animations (optional, separate mods - see readme)
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'anomaly-coop-release.txt'), $release.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8)

# --- zip with "/" entry names
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$stream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
$entries = 0
try {
    Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $_.LastWriteTime
        $out = $entry.Open()
        $in = [System.IO.File]::OpenRead($_.FullName)
        try { $in.CopyTo($out) } finally { $in.Close(); $out.Close() }
        $script:entries++
    }
    # empty folders (e.g. "Anomaly Coop - GAMMA/gamedata/") become directory entries
    Get-ChildItem -LiteralPath $stage -Recurse -Directory | Sort-Object FullName | ForEach-Object {
        if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) {
            $rel = $_.FullName.Substring($stage.Length + 1).Replace('\', '/') + '/'
            [void]$archive.CreateEntry($rel)
            $script:entries++
        }
    }
} finally {
    $archive.Dispose()
    $stream.Close()
}

# --- check what was written
$check = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $names = @($check.Entries | ForEach-Object { $_.FullName })
} finally { $check.Dispose() }
foreach ($must in @('fomod/ModuleConfig.xml', 'fomod/info.xml', "$EngineMod/bin/$ExeName",
                    "$CoreMod/gamedata/scripts/coop_main.script", "$GammaMod/readme_gamma.txt",
                    'anomaly-coop-release.txt')) {
    if ($names -notcontains $must) { throw "Archive misses $must" }
}
if (@($names | Where-Object { $_ -match '\\' }).Count -gt 0) { throw 'Archive has backslash entry names' }

if (-not $KeepStage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
    $stageRoot = Join-Path $OutDir '_stage'
    if ((Test-Path -LiteralPath $stageRoot) -and -not (Get-ChildItem -LiteralPath $stageRoot -Force)) { Remove-Item -LiteralPath $stageRoot -Force }
}

$skippedAll = @($core.Skipped) + @($eng.Skipped) + @($gamma.Skipped)
Write-Host "Packed $zip"
Write-Host ("  {0} entries, {1:N1} MB; protocol {2}; {3}, engine {4}; project {5}" -f $names.Count, ((Get-Item -LiteralPath $zip).Length / 1MB), $protocol, $engineName, $engineCommit, $projectCommit)
Write-Host ("  Engine: gamedata {0} files, exe {1:N1} MB; Core: gamedata {2} files; GAMMA: gamedata {3} files" -f $eng.Count, ($exe.Length / 1MB), $core.Count, $gamma.Count)
if ($skippedAll.Count -gt 0) { Write-Host ("  left out: {0}" -f ($skippedAll -join ', ')) }
