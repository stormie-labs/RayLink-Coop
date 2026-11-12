# Prepares the dedicated host's own instance on a launcher-made stand, as tools\deploy.ps1 does for its stands:
# fsgame_server.ltx (the stand's fsgame.ltx with appdata_server\) and appdata_server\ with a user.ltx and the files the
# mods keep in appdata\. Safe to re-run: an existing user.ltx is kept.
#   powershell -ExecutionPolicy Bypass -File tools/stand_server.ps1 -Stand E:\RayLinkGames\GAMMA\game-dev
param([string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev')
$ErrorActionPreference = 'Stop'
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$fsgame = Join-Path $Stand 'fsgame.ltx'
if (-not (Test-Path -LiteralPath $fsgame)) { throw "no fsgame.ltx in $Stand" }
$name = 'appdata_server'
$text = [System.IO.File]::ReadAllText($fsgame, $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$name\"
if ($text -notmatch [regex]::Escape("$name\")) { throw 'fsgame.ltx format unexpected: app_data_root not rewritten' }
[System.IO.File]::WriteAllText((Join-Path $Stand 'fsgame_server.ltx'), $text, $cp1251)
$appdata = Join-Path $Stand $name
New-Item -ItemType Directory -Force -Path $appdata | Out-Null
$user = Join-Path $appdata 'user.ltx'
if (-not (Test-Path -LiteralPath $user)) {
    [System.IO.File]::WriteAllLines($user, [string[]]@('rs_screenmode windowed', 'vid_mode 1280x720', 'g_always_active on', 'coop_nick server'), $cp1251)
}
$mods = Join-Path $Stand 'appdata'
if (Test-Path -LiteralPath $mods) {
    & robocopy $mods $appdata /E /XF user.ltx /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed: $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
}
Write-Host "server instance: $Stand\fsgame_server.ltx, $appdata"
Select-String -LiteralPath (Join-Path $Stand 'fsgame_server.ltx') -Pattern 'app_data_root' | Select-Object -First 1 | ForEach-Object { $_.Line }
