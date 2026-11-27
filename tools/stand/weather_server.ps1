# Dev 57 SS. Run on the prepared stand through tools/stand/run_guarded.ps1.param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27995,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepsTimeoutS = 480,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$prefix = '\[weather-stand\] '
$stamp = '\d{8}T\d{6}'
$patterns = @{
    ready = "${prefix}ready map=(\w+)\s*$"
    settled = "${prefix}settled map=(\w+)\s*$"
    forecast = "${prefix}forecast map=(\w+) weather=(\S+)\s*$"
    start = "${prefix}start map=(\w+) clock=($stamp) seen=($stamp)\s*$"
    end = "${prefix}end map=(\w+) seen=($stamp)\s*$"
    worldForecast = "${prefix}world forecast weather=(\S+)\s*$"
    worldStart = "${prefix}world start clock=($stamp) tf=(\d+)\s*$"
    worldEnd = "${prefix}world end seen=($stamp)\s*$"
}

function Clock-Skew([string]$A, [string]$B) {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $first = [DateTime]::ParseExact($A, "yyyyMMdd'T'HHmmss", $culture)
    $second = [DateTime]::ParseExact($B, "yyyyMMdd'T'HHmmss", $culture)
    return [Math]::Abs(($first - $second).TotalSeconds)
}

function Assert-Evidence($World, $Stay, $Move) {
    $mapA, $mapB = $Stay.ready.Groups[1].Value, $Move.ready.Groups[1].Value
    if ($mapA -eq $mapB) { throw 'both players are on one map' }
    $file = $World.forecast.Groups[1].Value
    $start = $World.start.Groups[1].Value
    $end = $World.end.Groups[1].Value
    # The Lua phase ticks once a second and interpolates in game time. Allow two real seconds.
    $tolerance = 2 * [Math]::Max(1, [int]$World.start.Groups[2].Value) + 1
    foreach ($client in @($Stay, $Move)) {
        $map = $client.ready.Groups[1].Value
        if ($client.forecast.Groups[1].Value -ne $map -or $client.forecast.Groups[2].Value -ne $file) {
            throw "$map did not render the world's forecast '$file'"
        }
        if ($client.start.Groups[1].Value -ne $map -or $client.end.Groups[1].Value -ne $map) {
            throw "$map did not start and end the emission on the same map"
        }
        if ((Clock-Skew $start $client.start.Groups[2].Value) -gt $tolerance) {
            throw "$map used a different emission clock"
        }
    }
    if ((Clock-Skew $Stay.start.Groups[3].Value $Move.start.Groups[3].Value) -gt $tolerance -or
        (Clock-Skew $Stay.end.Groups[2].Value $Move.end.Groups[2].Value) -gt $tolerance -or
        (Clock-Skew $end $Stay.end.Groups[2].Value) -gt $tolerance -or
        (Clock-Skew $end $Move.end.Groups[2].Value) -gt $tolerance) {
        throw 'the two maps did not start and end the same emission together'
    }
}

if ($DryRun) {
    function Fixture([string]$Map, [string]$File, [string]$Start, [string]$End) {
        return @{
            ready = [regex]::Match("[weather-stand] ready map=$Map", $patterns.ready)
            forecast = [regex]::Match("[weather-stand] forecast map=$Map weather=$File", $patterns.forecast)
            start = [regex]::Match("[weather-stand] start map=$Map clock=$Start seen=$Start", $patterns.start)
            end = [regex]::Match("[weather-stand] end map=$Map seen=$End", $patterns.end)
        }
    }
    $world = @{
        forecast = [regex]::Match('[weather-stand] world forecast weather=af_pre_blowout_1', $patterns.worldForecast)
        start = [regex]::Match('[weather-stand] world start clock=20120501T125959 tf=6', $patterns.worldStart)
        end = [regex]::Match('[weather-stand] world end seen=20120501T130030', $patterns.worldEnd)
    }
    $stay = Fixture 'l01_escape' 'af_pre_blowout_1' '20120501T125959' '20120501T130030'
    $move = Fixture 'l02_garbage' 'af_pre_blowout_1' '20120501T130002' '20120501T130031'
    Assert-Evidence $world $stay $move
    foreach ($bad in @(
        (Fixture 'l01_escape' 'af_pre_blowout_1' '20120501T130002' '20120501T130031'),
        (Fixture 'l02_garbage' 'af_pre_blowout_2' '20120501T130002' '20120501T130031'),
        (Fixture 'l02_garbage' 'af_pre_blowout_1' '20120501T130013' '20120501T130031'),
        (Fixture 'l02_garbage' 'af_pre_blowout_1' '20120501T130002' '20120501T130044')
    )) {
        $refused = $false
        try { Assert-Evidence $world $stay $bad } catch { $refused = $true }
        if (-not $refused) { throw 'invalid stand evidence accepted' }
    }
    Write-Host 'weather_server dry run: 5 passed, 0 failed'
    return
}

. (Join-Path $PSScriptRoot '..\stand_common.ps1')$Stand = (Get-StandFullPath $Stand).TrimEnd('\')
foreach ($path in @('E:\RayLinkGames\GAMMA\game', 'E:\Programs\RayLink', (Join-Path $env:APPDATA 'RayLink'))) {
    if (($Stand + '\').StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'use the game-dev stand' }
}
Assert-NoJunction -Dir $Stand
if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }

$stayFs = Join-Path $Stand 'fsgame_t.ltx'
$moveFs = Join-Path $Stand 'fsgame_weather.ltx'
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_weather.script'
$stageName = 'coop_weather_stage.ltx'$stage = Join-Path $Stand "appdata_server\$stageName"$exe = Join-Path $Stand 'bin\AnomalyCoopDX11AVX.exe'
$moveBin = Join-Path $Stand 'bin_weather'
$moveExe = Join-Path $moveBin 'AnomalyCoopDX11AVX.exe'
$logLeaf = "logs\xray_$($env:USERNAME).log"
$logs = @{
    world = Join-Path $Stand "appdata_server\$logLeaf"
    stay = Join-Path $Stand "appdata_t\$logLeaf"
    mover = Join-Path $Stand "appdata_weather\$logLeaf"}
foreach ($path in @($probe, $stage, "$stage.used", $moveFs)) {    if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
}

function Wait-Line([string]$File, [string]$Pattern, [int]$Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        foreach ($proc in @($server, $stayClient, $moveClient)) {
            if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
        }
        foreach ($path in $logs.Values) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $bad = Select-StandLogLine $path '\[weather-stand\] FAIL:' -Live |
                    Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        if (Test-Path -LiteralPath $File -PathType Leaf) {
            $line = Select-String -LiteralPath $File -Pattern $Pattern | Select-Object -Last 1
            if ($line) { return $line.Matches[0] }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $File"
}

function Start-Mirror([string]$Exe, [string]$Fs, [string]$Role) {
    $proc = Start-Process -FilePath $Exe -WorkingDirectory $Stand -WindowStyle Hidden -PassThru -ArgumentList `
        "-fsltx $Fs -coop_nick $Role -coop_probe $Role -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -silent_error_mode"
    $null = $proc.Handle
    return $proc
}

$server = $stayClient = $moveClient = $null
$created = [Collections.Generic.List[string]]::new()
$started = $false
try {
    $encoding = [Text.Encoding]::GetEncoding(1251)
    $text = [IO.File]::ReadAllText($stayFs, $encoding)
    $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata_t\\'
    if ($text -notmatch $fsPattern) { throw 'fsgame_t.ltx does not reference appdata_t' }
    $created.Add($moveFs)
    Write-StandText -Path $moveFs -Text ($text -replace $fsPattern, '${1}appdata_weather\') -Encoding $encoding
    Copy-StandTree -From (Join-Path $Stand 'appdata_t') -To (Join-Path $Stand 'appdata_weather') `
        -ExcludeFiles @('coop_player.key', 'axr_options.ltx') -ExcludeDirs @('savedgames', 'logs', 'raylink', 'screenshots')
    Get-ChildItem -LiteralPath (Join-Path $Stand 'bin') -File | ForEach-Object {
        Copy-StandFile -From $_.FullName -To (Join-Path $moveBin $_.Name)    }

    foreach ($path in $logs.Values) { Remove-StandFile -Path $path }
    $created.Add($probe)
    Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_weather.script') -To $probe
    $created.Add($stage)
    $created.Add("$stage.used")    Write-StandText -Path $stage -Text "[world]`nfaction = stalker`ntitle = weather`n" -Encoding ([Text.Encoding]::ASCII)

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $exe
    $psi.WorkingDirectory = $Stand
    $psi.Arguments = "-fsltx fsgame_server.ltx -coop_dedicated $Port -coop_new -coop_stage $stageName -silent_error_mode -dbg"    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $server = [Diagnostics.Process]::Start($psi)
    $started = $true
    $null = Wait-Line $logs.world '\[coop\] dedicated: the session is up on port' $UpTimeoutS
    $stayClient = Start-Mirror $exe 'fsgame_t.ltx' 'weatherstay'
    $null = Wait-Line $logs.stay '\[coop\] phase loading-world -> live' $JoinTimeoutS
    $moveClient = Start-Mirror $moveExe 'fsgame_weather.ltx' 'weathermove'
    $null = Wait-Line $logs.mover '\[coop\] phase loading-world -> live' $JoinTimeoutS    $stay = @{ ready = Wait-Line $logs.stay $patterns.ready $StepsTimeoutS }
    $move = @{ ready = Wait-Line $logs.mover $patterns.ready $StepsTimeoutS }
    # A player's process takes his map's online set in one burst after joining and stands still meanwhile; the emission
    # is measured once both have it and run on (the probe's 'settled' line), not across that standstill.
    $null = Wait-Line $logs.stay $patterns.settled $StepsTimeoutS
    $null = Wait-Line $logs.mover $patterns.settled $StepsTimeoutS
    $server.StandardInput.WriteLine('run_string coop_zz_weather.select_forecast()')
    $world = @{ forecast = Wait-Line $logs.world $patterns.worldForecast $StepsTimeoutS }
    $file = [regex]::Escape($world.forecast.Groups[1].Value)    $rendered = "${prefix}forecast map=(\w+) weather=($file)\s*$"    $stay.forecast = Wait-Line $logs.stay $rendered $StepsTimeoutS    $move.forecast = Wait-Line $logs.mover $rendered $StepsTimeoutS    $server.StandardInput.WriteLine('run_string coop_zz_weather.start_emission()')
    $world.start = Wait-Line $logs.world $patterns.worldStart $StepsTimeoutS
    $stay.start = Wait-Line $logs.stay $patterns.start 30
    $move.start = Wait-Line $logs.mover $patterns.start 30    $server.StandardInput.WriteLine('run_string coop_zz_weather.stop_emission()')
    $world.end = Wait-Line $logs.world $patterns.worldEnd $StepsTimeoutS
    $stay.end = Wait-Line $logs.stay $patterns.end 30
    $move.end = Wait-Line $logs.mover $patterns.end 30    Assert-Evidence $world $stay $move
    foreach ($log in @($logs.stay, $logs.mover)) {        foreach ($pattern in @($patterns.start, $patterns.end)) {
            if (@(Select-String -LiteralPath $log -Pattern $pattern).Count -ne 1) {
                throw "expected one emission start and one end in $log"
            }
        }
    }
    Write-Host "same forecast $($world.forecast.Groups[1].Value) and emission $($world.start.Groups[1].Value) on $($stay.ready.Groups[1].Value) and $($move.ready.Groups[1].Value)"
}
catch {    Write-Host ('weather_server: FAIL ({0})' -f (Hide-Hex "$_"))    throw}finally {
    try {
        foreach ($proc in @($moveClient, $stayClient)) {
            if ($proc -and -not $proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
        }
        if ($server -and -not $server.HasExited) {
            $server.StandardInput.WriteLine('quit')
            $server.StandardInput.Flush()
            if (-not $server.WaitForExit(150000)) {
                $server.Kill()
                throw 'the world server did not quit'
            }
        }
    }
    finally {
        foreach ($path in $created) { Remove-StandFile -Path $path }
        if ($started) {
            foreach ($name in $logs.Keys) {
                if (Test-Path -LiteralPath $logs[$name] -PathType Leaf) {
                    Copy-StandFile -From $logs[$name] -To (Join-Path $script:StandDir "${Tag}_weather_$name.log")                }
            }
        }
    }
}
Write-Host 'weather_server: PASS'
