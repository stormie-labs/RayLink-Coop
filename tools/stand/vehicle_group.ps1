# Dev 57 F5-VEH-7, Co-op. The playing host decides the client's seat and simulates the car.
# Run on the prepared stand through tools\stand_hostplay.ps1.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27998,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 900,
    [int]$JoinTimeoutS = 600
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
$Stand = (Get-StandFullPath $Stand).TrimEnd('\')

$encoding = [Text.Encoding]::GetEncoding(1251)
$ascii = [Text.Encoding]::ASCII
$exeName = 'AnomalyCoopDX11AVX.exe'
$exe = Join-Path $Stand "bin\$exeName"
$clientExe = Join-Path $Stand "bin_b\$exeName"
$options = Join-Path $Stand 'gamedata\configs\axr_options.ltx'
$optionsBackup = Join-Path $script:StandDir "vehicle_options_$PID.ltx"
$probe = Join-Path $Stand 'gamedata\scripts\coop_zz_vehicle.script'
$stepFile = Join-Path $Stand 'zz_vehicle_step.txt'
$hostFs = Join-Path $Stand 'fsgame_vehicle_h.ltx'
$hostData = Join-Path $Stand 'appdata_vehicle_h'
$logName = "logs\xray_$($env:USERNAME).log"
$hostLog = Join-Path $hostData $logName
$clientLog = Join-Path $Stand "appdata_t\$logName"
$logs = @($hostLog, $clientLog)
$authorityProcess = $client = $null
$installedHostFs = $installedProbe = $installedStep = $backedUpOptions = $started = $false
$stepFailure = $null   # the text of the step that failed: stopping the games afterwards never replaces it
$scenario = 'vehicle_group'
$step = 'setup'
$mark = '\[vehicle-stand\] '
$badLine = "$($mark)FAIL\b"
# The probe asks for a seat with the console command (coop_vehicle_enter), not the stock Use at a door, so the
# deciding side's door check (log only in 57, coop_vehicles_seat.cpp) says what it would refuse: expected here only.
$expectedTrust = '^\s*(?:\[[0-9:.]+\] +)?\[coop-trust\] ! veh_enter_door: character \d+: at no door of car \d+ by his look \(would be refused: let through, \d+ of \d+ failed\)\s*$'
$seatTable = '\[coop\]\s+vehicles: \d+ seated in \d+ car\(s\) \[car/seat=character:'

function Set-VehicleStep([string]$Instruction) {
    $script:step = ($Instruction -split ' ', 2)[0]
    Write-StandText -Path $stepFile -Text ($Instruction + [Environment]::NewLine) -Encoding $ascii
}

function Wait-VehicleLine([string[]]$Files, [string]$Pattern, [int]$Seconds, [int]$After = 0, [switch]$AfterQuit) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($authorityProcess -and $authorityProcess.HasExited) { throw "authority process exited ($($authorityProcess.ExitCode))" }
        if (-not $AfterQuit -and $client -and $client.HasExited) { throw "test client exited ($($client.ExitCode))" }
        foreach ($log in $logs) {
            if (Test-Path -LiteralPath $log -PathType Leaf) {
                $bad = Select-StandLogLine $log $badLine -Live | Where-Object Line -NotMatch $expectedTrust | Select-Object -First 1
                if ($bad) { throw (Hide-Hex $bad.Line) }
            }
        }
        foreach ($file in $Files) {
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $hit = Select-String -LiteralPath $file -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
                if ($hit) { return $hit }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $($Files -join ', ')"
}

function Wait-VehicleSeatTable([string]$Label, [string]$Rows, [string]$Tail = '') {
    $marker = Wait-VehicleLine $authorityLog "$mark$Label status\s*$" 20
    $null = Wait-VehicleLine $authorityLog "$seatTable$Rows[^\]]*\]$Tail" 5 $marker.LineNumber
}

function Wait-VehicleGrant([int]$Seat, [string]$Label) {
    $asked = Wait-VehicleLine $clientLog "$($mark)client asked $Label seat=$Seat\s*$" 10
    $grant = Wait-VehicleLine $clientLog "\[coop\] vehicle: car $car seat $Seat granted\b" 5 $asked.LineNumber
    Wait-VehicleLine $clientLog "$($mark)client $Label seat=$Seat car=$car\s*$" 5 $grant.LineNumber
}

function Keep-VehicleLog([string]$File, [string]$Label) {
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        Copy-StandFile -From $File -To (Join-Path $script:StandDir "$($Tag)_$($scenario)_$Label.log")
        Select-StandLogLine $File "$mark|\[coop\]\s+vehicles?:|$badLine" |
            ForEach-Object {
                $line = $_.Line
                if ($line -match $expectedTrust) { $line = $line -replace '\[coop-trust\] ! ', '[coop-trust] ' }
                Write-Host (Hide-Hex $line)
            }
    }
}

# The carry_group new-game setup uses the faction's free kit and starting money.
function Get-StalkerKit([string]$File) {
    $sections = @{}
    $section = $null
    foreach ($raw in [IO.File]::ReadAllLines($File, $encoding)) {
        $line = ($raw -replace ';.*$', '').Trim()
        if ($line -match '^\[([^\]]+)\]\s*(?::\s*(.+))?$') {
            $section = @{ Values = [ordered]@{}; Parents = @() }
            $sections[$Matches[1]] = $section
            if ($Matches[2]) { $section.Parents = @($Matches[2].Split(',') | ForEach-Object { $_.Trim() }) }
        } elseif ($section -and $line -match '^([^=\s]+)\s*=\s*(.*)$') {
            $section.Values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $resolve = {
        param($name)
        $result = [ordered]@{}
        foreach ($parent in $sections[$name].Parents) {
            foreach ($entry in (& $resolve $parent).GetEnumerator()) { $result[$entry.Key] = $entry.Value }
        }
        foreach ($entry in $sections[$name].Values.GetEnumerator()) { $result[$entry.Key] = $entry.Value }
        $result
    }
    $items = foreach ($entry in (& $resolve 'stalker_loadout').GetEnumerator()) {
        $parts = $entry.Value.Split(',')
        if ($parts[0].Trim() -eq 'false') {
            for ($i = 0; $i -lt [int]$parts[1]; $i++) { $entry.Key }
        }
    }
    if (-not $items) { throw 'no free kit for stalker' }
    return @{ Items = $items -join ','; Money = (& $resolve 'stalker_money')['money'] }
}

try {
    try {
        if ($Stand -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
        Assert-NoJunction -Dir $Stand
        if (Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
        if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }
        if (-not (Test-Path -LiteralPath (Join-Path $Stand 'fsgame_t.ltx') -PathType Leaf)) { throw 'no prepared fsgame_t.ltx' }
        foreach ($path in @($probe, $stepFile, $optionsBackup, $hostFs)) {
            if (Test-Path -LiteralPath $path) { throw "scenario file already exists: $path" }
        }

        Copy-StandTree -From (Join-Path $Stand 'bin') -To (Join-Path $Stand 'bin_b')
        $fsText = [IO.File]::ReadAllText((Join-Path $Stand 'fsgame.ltx'), $encoding)
        $fsPattern = '(?m)^(\$app_data_root\$\s*=.*\|\s*)appdata\\'
        if ($fsText -notmatch $fsPattern) { throw 'fsgame.ltx format unexpected' }
        $replacement = '$' + '{1}appdata_vehicle_h\'
        $installedHostFs = $true
        Write-StandText -Path $hostFs -Text ($fsText -replace $fsPattern, $replacement) -Encoding $encoding
        $profile = @{
            From = Join-Path $Stand 'appdata_t'
            To = $hostData
            ExcludeFiles = @('coop_player.key', 'axr_options.ltx')
            ExcludeDirs = @('savedgames', 'logs', 'raylink', 'screenshots')
        }
        Copy-StandTree @profile
        foreach ($log in $logs) { Remove-StandFile -Path $log }

        $kit = Get-StalkerKit (Join-Path $Stand 'gamedata\configs\items\settings\new_game_loadouts.ltx')
        Copy-StandFile -From $options -To $optionsBackup
        $backedUpOptions = $true
        $optionsText = [IO.File]::ReadAllText($optionsBackup, $encoding)
        $prefix = [regex]::Replace($optionsText, '(?ms)^\[character_creation\][^\r\n]*(?:\r?\n|\z).*?(?=^\[|\z)', '').TrimEnd()
        $creation = @(
            '[character_creation]', 'new_game_difficulty = 1', 'new_game_economy = 1', 'new_game_economy_treasure = 1',
            'new_game_story_mode = true', 'new_game_character_name = VehicleHost', 'new_game_faction = stalker',
            "new_game_loadout = $($kit.Items)", 'new_game_map = rookie_village'
        )
        if ($kit.Money) { $creation += "new_game_money = $($kit.Money)" }
        Write-StandLines -Path $options -Lines (@($prefix, '') + $creation) -Encoding $encoding
        $installedProbe = $true
        Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_vehicle.script') -To $probe
        $installedStep = $true
        Set-VehicleStep 'ready'

        $step = 'host_start'
        $hostArgs = "-fsltx fsgame_vehicle_h.ltx -coop_nick vehicle_host -coop_host $Port -coop_probe vehicle_h -dbg -silent_error_mode -start server(all/single/alife/new) client(localhost)"
        $authorityProcess = Start-Process -FilePath $exe -WorkingDirectory $Stand -PassThru -ArgumentList $hostArgs
        $null = $authorityProcess.Handle
        $started = $true
        $until = [DateTime]::UtcNow.AddSeconds($UpTimeoutS)
        while (-not (Get-NetUDPEndpoint -LocalPort $Port -OwningProcess $authorityProcess.Id -ErrorAction SilentlyContinue)) {
            if ($authorityProcess.HasExited -or [DateTime]::UtcNow -ge $until) { throw 'the host did not open its session' }
            Start-Sleep -Seconds 1
        }
        $step = 'join'
        $clientArgs = "-fsltx fsgame_t.ltx -coop_nick vehicle_tester -coop_autochoose stalker -coop_connect 127.0.0.1:$Port -coop_probe vehicle_ag -silent_error_mode"
        $client = Start-Process -FilePath $clientExe -WorkingDirectory $Stand -PassThru -ArgumentList $clientArgs
        $null = $client.Handle
        $null = Wait-VehicleLine $clientLog '\[coop\] phase loading-world -> live' $JoinTimeoutS
        $ready = Wait-VehicleLine $clientLog "$($mark)client ready map=([a-z0-9_]+)\s*$" 60
        $placed = Wait-VehicleLine $clientLog "$($mark)client placed pos=((-?\d+\.\d+ ){2}-?\d+\.\d+)\s*$" 5
        $map = [regex]::Escape($ready.Matches[0].Groups[1].Value)
        $authorityLog = $hostLog
        $null = Wait-VehicleLine $authorityLog "$($mark)host ready map=$map\s*$" 60

        Set-VehicleStep ('spawn ' + $placed.Matches[0].Groups[1].Value)
        $spawn = Wait-VehicleLine $authorityLog "$($mark)spawned car=(\d{1,5}) body=(\d{1,5}) distance=[\d.]+\s*$" 45
        $car = [int]$spawn.Matches[0].Groups[1].Value
        $body = [int]$spawn.Matches[0].Groups[2].Value
        if ($car -le 0 -or $car -ge 65535 -or $body -le 0 -or $body -ge 65535) { throw 'invalid fixture IDs' }
        $driverRow = "(?=[^\]]* $car/0=$body(?= |\]))"
        $passengerRow = "(?=[^\]]* $car/1=$body(?= |\]))"
        $noPassenger = "(?![^\]]* $car/1=)"
        $emptyCar = "(?![^\]]* $car/\d+=)"

        Set-VehicleStep "online $car"
        $null = Wait-VehicleLine $clientLog "$($mark)client online car=$car local=\d+\s*$" 30

        Set-VehicleStep 'driver'
        $driverSeat = Wait-VehicleGrant 0 'seated'
        Set-VehicleStep 'prepare'
        Wait-VehicleSeatTable 'driver' $driverRow

        Set-VehicleStep 'drive'
        $null = Wait-VehicleLine $clientLog '\[coop\] vehicle: drive 0x0001 for 3000 ms\s*$' 10 $driverSeat.LineNumber
        Start-Sleep -Milliseconds 3000
        Set-VehicleStep 'drive_sample'
        $null = Wait-VehicleLine $authorityLog "$($mark)drive moved=[\d.]+ pos=" 10
        Start-Sleep -Milliseconds 1000
        Set-VehicleStep 'replica_sample'
        $sample = Wait-VehicleLine $authorityLog "$($mark)authority pos=((-?\d+\.\d+ ){2}-?\d+\.\d+)\s*$" 10
        Set-VehicleStep ('replica ' + $sample.Matches[0].Groups[1].Value)
        $null = Wait-VehicleLine $clientLog "$($mark)replica pos=.* delta=[\d.]+\s*$" 10

        Set-VehicleStep 'driver_exit'
        $null = Wait-VehicleLine $clientLog "\[coop\] vehicle: out of car $car seat 0 \(exit\)" 10 $driverSeat.LineNumber
        $null = Wait-VehicleLine $clientLog "$($mark)client exited seat=0 distance=" 10
        Set-VehicleStep 'driver_clear'
        Wait-VehicleSeatTable 'driver exit' $emptyCar '.*\breleased 1 \(exit 1\)'

        Set-VehicleStep 'passenger_prepare'
        $null = Wait-VehicleLine $authorityLog "$($mark)host seated car=$car\s*$" 10
        $hostRow = "(?=[^\]]* $car/0=\d+\(own\)(?= |\]))"
        Wait-VehicleSeatTable 'host' ($hostRow + $noPassenger)
        Set-VehicleStep 'passenger'
        $passengerSeat = Wait-VehicleGrant 1 'seated'
        Set-VehicleStep 'passenger_status'
        Wait-VehicleSeatTable 'passenger' ($hostRow + $passengerRow)

        Set-VehicleStep 'follow_start'
        $null = Wait-VehicleLine $clientLog "$($mark)client following\s*$" 10
        Set-VehicleStep 'host_drive'
        $null = Wait-VehicleLine $authorityLog "$($mark)host moved=[\d.]+ pos=" 10
        Start-Sleep -Milliseconds 1000
        Set-VehicleStep 'follow_sample'
        $null = Wait-VehicleLine $clientLog "$($mark)client followed car=" 10

        Set-VehicleStep 'passenger_exit'
        $null = Wait-VehicleLine $clientLog "\[coop\] vehicle: out of seat 1 of car $car \(a passenger\)" 10 $passengerSeat.LineNumber
        $null = Wait-VehicleLine $clientLog "$($mark)client exited seat=1 distance=" 10
        Set-VehicleStep 'passenger_clear'
        Wait-VehicleSeatTable 'passenger exit' $noPassenger '.*\breleased 2 \(exit 2\)'

        Set-VehicleStep 'reboard'
        $quitSeat = Wait-VehicleGrant 1 'reboarded'
        Set-VehicleStep 'reboard_status'
        Wait-VehicleSeatTable 'reboard' $passengerRow

        Set-VehicleStep 'quit'
        $null = Wait-VehicleLine $clientLog "$($mark)client quit seat=1\s*$" 10 $quitSeat.LineNumber -AfterQuit
        if (-not $client.WaitForExit(15000)) { throw 'test client did not quit' }
        if ($client.ExitCode -ne 0) { throw "test client failed to quit cleanly ($($client.ExitCode))" }

        Set-VehicleStep 'disconnect'
        $marker = Wait-VehicleLine $authorityLog "$($mark)disconnect status\s*$" 30 -AfterQuit
        $released = Wait-VehicleLine $authorityLog "$seatTable$noPassenger[^\]]*\].*\breleased 3 \((?<reasons>[^)]+)\)" 20 $marker.LineNumber -AfterQuit
        $reasons = $released.Matches[0].Groups['reasons'].Value
        if ($reasons -notmatch '(?:^|, )disconnect 1(?:, |$)') {
            throw "expected disconnect 1 for the released seat, got '$reasons'"
        }
    }
    catch {
        $stepFailure = "$_"
        throw
    }
    finally {
        try {
            # A killed game that is slow to leave must not replace the step's own failure or cost the logs: both games are
            # told to stop, the logs are kept, and a process that still runs fails the scenario only when nothing else did.
            $stuck = @()
            foreach ($proc in @($client, $authorityProcess)) {
                if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
            }
            foreach ($proc in @($client, $authorityProcess)) {
                if ($proc -and -not $proc.WaitForExit(30000)) { $stuck += $proc.Id }
            }
            if ($started) {
                Keep-VehicleLog $hostLog 'host'
                Keep-VehicleLog $clientLog 'client'
            }
            if ($stuck -and $stepFailure) { Write-Host "! stand process $($stuck -join ', ') did not stop in 30 s" }
            elseif ($stuck) { throw "stand process $($stuck -join ', ') did not stop in 30 s" }
        }
        finally {
            if ($installedHostFs) { Remove-StandFile -Path $hostFs }
            if ($installedStep) { Remove-StandFile -Path $stepFile }
            if ($installedProbe) { Remove-StandFile -Path $probe }
            if ($backedUpOptions) {
                Copy-StandFile -From $optionsBackup -To $options
                Remove-StandFile -Path $optionsBackup
            }
        }
    }
}
catch {
    Write-Host ('vehicle_group: FAIL {0} ({1})' -f $step, (Hide-Hex "$_"))
    throw
}
Write-Host 'vehicle_group: PASS'
