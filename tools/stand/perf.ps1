# The measurement scenario (docs\MEASURE.md): one mode per run, the frame by the engine's timers every 10 s and, with -Lua,
# the Lua timing of coop_route; logs go to temp\stand\<Tag>_perf_<mode>_<role>.log and the measured lines are printed.
#   Coop:   host (the test player's profile, its save -Save) and one client (a profile made from it)
#           powershell -ExecutionPolicy Bypass -File tools\stand\perf.ps1 -Mode coop -Save <stem> [-Lua] [-Tag run1]
#   Server: the game starts its own world server and joins it (-coop_world_auto); the world server starts the map server
#           powershell -ExecutionPolicy Bypass -File tools\stand\perf.ps1 -Mode server [-Save <stem> | new] [-Lua] [-Tag run1]
# The probe arms 20 s after the world is up (warm-up); the window is -WindowS seconds after that.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [Parameter(Mandatory = $true)][ValidateSet('coop', 'server')][string]$Mode,
    [string]$Save = 'new',                # Server: new | <save stem>; Coop: the host's save (required)
    [switch]$Lua,                         # -coop_perf_lua: coop_route's timing on for the window
    [string]$Faction = 'stalker',
    [ValidateRange(1024, 65535)][int]$Port = 27994,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'perf',
    [int]$JoinTimeoutS = 900,
    [int]$WindowS = 170                   # 20 s of warm-up in the probe + the 150 s window
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')  # Write-Stand*, Copy-Stand*, Remove-StandFile: never write through a hard link
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
Assert-NoJunction -Dir $Stand
if ($Mode -eq 'coop' -and $Save -eq 'new') { throw 'Coop: -Save <stem> of the host''s save is required' }
$OutDir = Join-Path $PSScriptRoot '..\..\temp\stand'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$cp1251 = [System.Text.Encoding]::GetEncoding(1251)
$exeName = 'AnomalyCoopDX11AVX.exe'
$exe = Join-Path $Stand "bin\$exeName"
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared fsgame_t.ltx' }

$logName = 'logs\xray_' + $env:USERNAME + '.log'
$scripts = Join-Path $Stand 'gamedata\scripts'
$probe = Join-Path $scripts 'coop_zz_perf.script'
if (Test-Path -LiteralPath $probe) { throw "scenario file already exists: $probe" }
$keys = ' -coop_perf' + $(if ($Lua) { ' -coop_perf_lua' } else { '' })

function Wait-Line([string]$File, [string]$Pattern, [int]$Seconds, $Proc) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        if ((Test-Path -LiteralPath $File) -and (Select-String -LiteralPath $File -Pattern $Pattern -Quiet)) { return $true }
        if ($Proc -and $Proc.HasExited) { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

# a profile of the stand made from the test player's (never his key, saves or logs): fsgame_<letter>.ltx, appdata_<letter>
function New-PerfProfile([string]$Letter) {
    $name = "appdata_$Letter"
    $text = [System.IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $cp1251) -replace '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\', "`${1}$name\"
    if ($text -notmatch [regex]::Escape("$name\")) { throw 'fsgame.ltx format unexpected' }
    Write-StandText -Path (Join-Path $Stand "fsgame_$Letter.ltx") -Text $text -Encoding $cp1251
    $appdata = Join-Path $Stand $name
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To $appdata -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')
    $global:LASTEXITCODE = 0
    return $appdata
}

$roles = [ordered]@{}  # role -> log
$procs = @()
try {
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_perf.script') -To $probe
    if ($Mode -eq 'coop') {
        $clientData = New-PerfProfile 'p'
        $roles['host'] = Join-Path $Stand "appdata_t\$logName"
        $roles['client'] = Join-Path $clientData $logName
        foreach ($f in $roles.Values) { Remove-StandFile -Path $f }
        $hostGame = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -coop_nick perf_host -coop_host $Port -dbg -silent_error_mode$keys -start server($Save/single/alife/load) client(localhost)"
        $procs += $hostGame
        if (-not (Wait-Line $roles['host'] '\[coop-perf\] armed' $JoinTimeoutS $hostGame)) { throw 'the host did not get into its world' }
        $client = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_p.ltx -coop_nick perf_client -coop_autochoose $Faction -coop_connect 127.0.0.1:$Port -silent_error_mode$keys"
        $procs += $client
        if (-not (Wait-Line $roles['client'] '\[coop\] phase loading-world -> live' $JoinTimeoutS $client)) { throw 'the client did not get into the world' }
    } else {
        $roles['client'] = Join-Path $Stand "appdata_t\$logName"
        $roles['world'] = Join-Path $Stand "appdata_t_world\$logName"
        foreach ($f in $roles.Values) { Remove-StandFile -Path $f }
        $game = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList "-fsltx fsgame_t.ltx -dbg -coop_world_auto $Save -coop_world_faction $Faction$keys"
        $procs += $game
        if (-not (Wait-Line $roles['client'] '\[coop\] join complete|\[coop-world-wait\] joined' $JoinTimeoutS $game)) { throw 'the player did not join the world server' }
    }
    Write-Host ("{0}: in the world at {1:HH:mm:ss}, measuring {2} s" -f $Mode, (Get-Date), $WindowS)
    $until = (Get-Date).AddSeconds($WindowS)
    while ((Get-Date) -lt $until) {
        foreach ($p in $procs) { if ($p.HasExited) { throw "stand process $($p.Id) exited ($($p.ExitCode))" } }
        Start-Sleep -Seconds 2
    }
}
finally {
    foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    foreach ($p in $procs) { [void]$p.WaitForExit(30000) }
    # Server: the world server saves and quits when the player's pipe closes; its map servers go with it
    $until = (Get-Date).AddSeconds(150)
    while ((Get-Date) -lt $until -and (Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 2 }
    Get-Process -Name 'AnomalyCoop*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Write-Host "! left running: $($_.Id), stopped"; Stop-Process -Id $_.Id -Force }
    Remove-StandFile -Path $probe
    foreach ($role in $roles.Keys) {
        $log = $roles[$role]
        if (-not (Test-Path -LiteralPath $log)) { Write-Host "--- $role`: no log"; continue }
        Copy-Item -LiteralPath $log -Destination (Join-Path $OutDir "${Tag}_perf_${Mode}_$role.log") -Force
        Write-Host "--- $role"
        Select-String -LiteralPath $log -Pattern 'coop-perf|frame parts|coop_mapserver_stats|hud v2: frame|\[coop-route\] timing|LUA error' |
            ForEach-Object { Hide-Hex $_.Line }
    }
}
