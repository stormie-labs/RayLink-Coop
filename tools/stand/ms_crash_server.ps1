# Dev 57 A-S7, Server. Run through the stand guard. The other S7 scenarios load the helpers below.
param(
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    [ValidateRange(1024, 65535)][int]$Port = 27990,
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Tag = 'b57',
    [int]$UpTimeoutS = 600,
    [int]$JoinTimeoutS = 600,
    [int]$StepTimeoutS = 600,
    [switch]$DefinitionsOnly
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')
. (Join-Path $PSScriptRoot 'stand_dump.ps1')

$s7Live = '\[coop\] phase loading-world -> live\b'
$s7Load = 'host replaced the world|phase .* -> (?:receiving-world|loading-world)\b|\[coop\] load: the group moves to '
$s7Bad = '\[s7\] FAIL\b|ownership violation:|Unknown command:.*srv_|@rl error\b'
$s7Player = 'role=(?<role>s7move|s7stay) map=(?<map>\w+) peer=(?<peer>\d+) operator=(?<operator>[01]) alive=(?<alive>[01]) kits=(?<kits>\d+) character=(?<character>\d+) levelid=(?<level>\d+) god=(?<god>[01])\s*$'
$s7Counter = '\[coop\] levels: (?<held>\d+) object\(s\) online at map servers, .*\| xfer in flight (?<pending>\d+), retries \d+, completed (?<completed>\d+), rolled back (?<rolled>\d+), resyncs (?<asked>\d+) asked (?<heard>\d+) heard, violations (?<violations>\d+)\s*$'
$s7Start = '\[coop\] map server (?<slot>[1-7]) starts for level (?<level>\d+) \(.+, process (?<process>\d+)\)\s*$'
$s7God = '\[coop\] debug: my flags from the server: god on\b'
# A trip's join ends with the server's DebugState (the client logs "debug of the server" anew after its reset). The flags its actor
# had stay (coop_debug_rules.h flags_taken_at_reset), so no "my flags" line comes unless the state takes one: god off.
$s7DebugIn = '\[coop\] debug of the server: on\b'
$s7GodLost = '\[coop\] debug: (?:my flags from the server:.* on,(?: \w+)* god(?: \w+)* off|the server''s flags taken back:(?: \w+)* god\b)'
$s7From = 'l01_escape'
$s7To = 'l02_garbage'

function Find-S7Line([string[]]$Paths, [string]$Pattern, [int]$After = 0) {
    foreach ($file in $Paths) {
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $hit = Select-String -LiteralPath $file -Pattern $Pattern | Where-Object LineNumber -gt $After | Select-Object -First 1
            if ($hit) { return $hit }
        }
    }
}

function Assert-S7Logs($Context) {
    foreach ($file in $Context.Logs.Values) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $expected = $null
        if ($file -eq $Context.Logs.world -and $Context.ExpectedMapLoss) {
            $expected = Find-S7Line $file $Context.ExpectedMapLoss.Pattern $Context.ExpectedMapLoss.After
        }
        $bad = Select-StandLogLine $file $s7Bad -Live | Where-Object { -not $expected -or $_.LineNumber -ne $expected.LineNumber } |
            Select-Object -First 1
        if ($bad) { throw (Hide-Hex "$($bad.Path):$($bad.LineNumber) $($bad.Line)") }
    }
}

function Assert-S7Running($Context) {
    foreach ($proc in @($Context.World) + @($Context.Clients.Values)) {
        if ($proc -and $proc.HasExited) { throw "stand process $($proc.Id) exited ($($proc.ExitCode))" }
    }
    if ($Context.CheckAt -gt [DateTime]::UtcNow) { return }
    $Context.CheckAt = [DateTime]::UtcNow.AddSeconds(1)
    Assert-S7Logs $Context
}

function Wait-S7Line($Context, [string]$Log, [string]$Pattern, [int]$Seconds, [int]$After = 0) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        Assert-S7Running $Context
        $hit = Find-S7Line $Log $Pattern $After
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $until)
    throw "timed out waiting for '$Pattern' in $Log after line $After"
}

function Get-S7LineCount([string]$Log) {
    if (Test-Path -LiteralPath $Log -PathType Leaf) { return @(Get-Content -LiteralPath $Log).Count }
    return 0
}

function New-S7Fs($Context, [string]$Profile, [string]$Template) {
    $source = Join-Path $Context.Stand $Template
    $encoding = [Text.Encoding]::GetEncoding(1251)
    $text = [IO.File]::ReadAllText($source, $encoding)
    $seedName = if ($Profile -eq 'world') { 'appdata_server' } else { 'appdata_t' }
    $pattern = '(?im)^([ \t]*\$app_data_root\$[ \t]*=[^\r\n]*\|[ \t]*\$fs_root\$[ \t]*\|[ \t]*)' +
        $seedName + '\\[ \t]*\r?$'
    if ([regex]::Matches($text, $pattern).Count -ne 1 -or
        $text -match '(?im)^\s*\$fs_root\$\s*=' -or
        $text -notmatch '(?im)^\$logs\$\s*=.*\|\s*\$app_data_root\$\s*\|\s*logs\\' -or
        $text -notmatch '(?im)^\$game_saves\$\s*=.*\|\s*\$app_data_root\$\s*\|\s*savedgames\\') {
        throw "unexpected appdata, log or save paths in $Template"
    }
    $root = $Context.Leaf + '\' + $Profile
    $fsName = "fsgame_$Profile.ltx"
    # A nested fsgame would otherwise make LocatorAPI use its folder as the game root.
    $base = '$fs_root$ = false | false | ' + $Context.Stand + '\' + "`r`n"
    $text = $text -replace $pattern, ('${1}' + $root + '\')
    Write-StandText -Path (Join-Path $Context.Run $fsName) -Text ($base + $text) -Encoding $encoding
    $seed = Join-Path $Context.Stand $seedName
    Assert-NoJunction -Dir $seed
    $dest = Join-Path $Context.Run $Profile
    $user = Join-Path $seed 'user.ltx'
    $lines = @([IO.File]::ReadAllLines($user, $encoding) | Where-Object { $_ -notmatch '^\s*g_always_active\s' })
    Write-StandLines -Path (Join-Path $dest 'user.ltx') -Lines ($lines + 'g_always_active on') -Encoding $encoding
    $options = Join-Path $seed 'axr_options.ltx'
    if (Test-Path -LiteralPath $options -PathType Leaf) {
        Copy-StandFile -From $options -To (Join-Path $dest 'axr_options.ltx')
    }
    return "$($Context.Leaf)\$fsName"
}

function Send-S7World($Context, [string]$Command) {
    $pipe = $Context.World.StandardInput
    $pipe.WriteLine($Command)
    $pipe.Flush()
}

function Start-S7World($Context, [string]$Load = '') {
    $worldArgs = "-coop_new -coop_stage $($Context.StageName)"
    if ($Load) {
        if ($Load -notmatch '^coop_auto_[a-z0-9_-]+$') { throw 'invalid save name' }
        $worldArgs = "-coop_load $Load"
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Context.Exe
    $psi.WorkingDirectory = $Context.Stand
    $psi.Arguments = "-fsltx $($Context.Fs.world) -coop_dedicated $($Context.Port) $worldArgs -coop_operator $($Context.Token) -coop_probe s7world -silent_error_mode -dbg"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $Context.World = [Diagnostics.Process]::Start($psi)
    $null = Wait-S7Line $Context $Context.Logs.world ("\[coop\] dedicated: the session is up on port $($Context.Port)\b") $UpTimeoutS
    if ($Load) {
        $null = Wait-S7Line $Context $Context.Logs.world ("\[coop\] dedicated: the world of the save " + [regex]::Escape($Load) + '\s*$') 15
    }
}

function Stop-S7Clients($Context) {
    foreach ($proc in $Context.Clients.Values) {
        if (-not $proc.HasExited) {
            $proc.Kill()
            if (-not $proc.WaitForExit(15000)) { throw "client $($proc.Id) did not stop" }
        }
        $proc.Dispose()
    }
    $Context.Clients.Clear()
}

function Stop-S7World($Context) {
    $world = $Context.World
    if (-not $world) { return }
    try {
        if (-not $world.HasExited) {
            Send-S7World $Context 'quit'
            if (-not $world.WaitForExit(150000)) { throw 'world server did not quit in 150 s' }
        }
        if ($world.ExitCode -ne 0) { throw "world server exited with $($world.ExitCode)" }
    } finally {
        if (-not $world.HasExited) {
            # A world that does not quit hangs: its threads' stacks before the kill (stand_dump.ps1), and how long its log was silent.
            Write-Host "world server $($world.Id) is still up: $(Get-StandLogAge $Context.Logs.world)"
            $null = Save-StandDump -Process $world -Path (Join-Path $script:StandDir "$($Context.Tag)_$($Context.Name)_world_hung.dmp")
            $world.Kill()
            $null = $world.WaitForExit(15000)
        }
        $world.Dispose()
        $Context.World = $null
    }
}

function Read-S7Player($Hit) {
    $fields = $Hit.Matches[0].Groups
    return [pscustomobject]@{
        Role = $fields['role'].Value; Map = $fields['map'].Value; Line = $Hit.LineNumber
        Peer = [int]$fields['peer'].Value; Operator = [int]$fields['operator'].Value
        Alive = [int]$fields['alive'].Value; Kits = [int]$fields['kits'].Value
        Character = [int]$fields['character'].Value; Level = [int]$fields['level'].Value; God = [int]$fields['god'].Value
    }
}

function Start-S7Client($Context, [ValidateSet('s7move','s7stay')][string]$Role) {
    if (-not $Context.Fs.ContainsKey($Role)) {
        $Context.Fs[$Role] = New-S7Fs $Context $Role 'fsgame_t.ltx'
        $bin = Join-Path $Context.Run "bin_$Role"
        # The executable mutex is per bin directory. Independent copies also isolate any runtime bin files.
        Get-ChildItem -LiteralPath (Join-Path $Context.Stand 'bin') -File | ForEach-Object {
            Copy-StandFile -From $_.FullName -To (Join-Path $bin $_.Name)
        }
    }
    $exe = Join-Path $Context.Run "bin_$Role\AnomalyCoopDX11AVX.exe"
    $operator = if ($Role -eq 's7move') { " -coop_operator $($Context.Token)" } else { '' }
    $argsLine = "-fsltx $($Context.Fs[$Role]) -coop_nick $Role -coop_probe $Role -coop_autochoose stalker -coop_connect 127.0.0.1:$($Context.Port)$operator -silent_error_mode"
    $proc = Start-Process -FilePath $exe -WorkingDirectory $Context.Stand -ArgumentList $argsLine -WindowStyle Hidden -PassThru
    $Context.Clients[$Role] = $proc
    $null = $proc.Handle
    $null = Wait-S7Line $Context $Context.Logs[$Role] $s7Live $JoinTimeoutS
    $ready = Read-S7Player (Wait-S7Line $Context $Context.Logs[$Role] "\[s7\] ready $s7Player" 90)
    Set-S7Immortal $Context $Role
    return $ready
}

# b57h creator10_server: on trip 6 of 10 the creator was downed 1.5 s after his arrival on l02_garbage (damage of his own game,
# the actor its own initiator; no hit came from the map server), died, and the death drop put the staged medkit into a stash:
# "unexpected player evidence ... Kits 0". In ms_crash_server dogs downed him at the same arrival point. S7 judges transitions,
# not the Zone: both players are immortal through the server's debug (docs/DEBUG_DESIGN.md §B.9). A trip replaces the client's
# world and keeps the flags on his actor; Complete-S7Trip waits for the join's DebugState and checks that god stayed.
function Set-S7Immortal($Context, [string]$Role) {
    $worldAfter = Get-S7LineCount $Context.Logs.world
    $after = Get-S7LineCount $Context.Logs[$Role]
    Send-S7World $Context "coop_dbg god @$Role on=1"
    $null = Wait-S7Line $Context $Context.Logs.world "\[coop\] debug: #\d+ '$Role' flags: god\b" 30 $worldAfter
    $null = Wait-S7Line $Context $Context.Logs[$Role] $s7God 30 $after
}

function Set-S7Step($Context, [string]$Role, [string]$Command) {
    $Context.Step++
    Write-StandText -Path $Context.StepFile -Text "$($Context.Step) $Role $Command`n" -Encoding ([Text.Encoding]::ASCII)
    return $Context.Step
}

function Start-S7Trip($Context, $Player, [string]$Goal, [int[]]$SaveFixtures) {
    if ($Player.Map -eq $Goal) { throw "$($Player.Role) is already on $Goal" }
    $status = Get-S7Status $Context
    $source = Get-S7PlayerLevel $status $Player $Player.Map
    if (-not $status.Maps.ContainsKey($Goal)) { throw "the world did not name a level ID for $Goal" }
    $target = $status.Maps[$Goal]
    $after = Get-S7LineCount $Context.Logs[$Player.Role]
    $worldAfter = Get-S7LineCount $Context.Logs.world
    if ($SaveFixtures.Count) {
        $ids = $SaveFixtures -join ','
        $armed = $Context.Step + 1
        Send-S7World $Context "run_string coop_zz_s7.arm_save($armed, $source, $target, $($Player.Peer), $($Player.Character), '$ids')"
        $null = Wait-S7Line $Context $Context.Logs.world "\[s7\] save armed seq=$armed\s*$" 45 $worldAfter
    }
    $seq = Set-S7Step $Context $Player.Role "travel $Goal"
    $null = Wait-S7Line $Context $Context.Logs[$Player.Role] "\[s7\] trip seq=$seq role=$($Player.Role) from=$($Player.Map) to=$Goal\s*$" 60 $after
    $accepted = Wait-S7Line $Context $Context.Logs.world "\[coop\] '$($Player.Role)' leaves for level '$Goal' \(a trip\), the world stays\s*$" 90 $worldAfter
    return @{ Sequence = $seq; Goal = $Goal; SourceLevel = $source; GoalLevel = $target
        Peer = $Player.Peer; ClientLine = $after; WorldLine = $accepted.LineNumber }
}

function Complete-S7Trip($Context, $Player, $Trip) {
    $loaded = Wait-S7Line $Context $Context.Logs[$Player.Role] $s7Live $StepTimeoutS $Trip.ClientLine
    $arrival = Wait-S7Line $Context $Context.Logs[$Player.Role] "\[s7\] arrival seq=$($Trip.Sequence) $s7Player" 90 $loaded.LineNumber
    $null = Wait-S7Line $Context $Context.Logs[$Player.Role] $s7DebugIn 90 $Trip.ClientLine
    $lost = Find-S7Line $Context.Logs[$Player.Role] $s7GodLost $Trip.ClientLine
    $new = Read-S7Player $arrival
    if ($lost -or $new.God -ne 1) { throw "$($Player.Role) is not immortal after trip $($Trip.Sequence): $(if ($lost) { $lost.Line } else { 'god=0' })" }
    $worldLevel = Get-S7PlayerLevel (Get-S7Status $Context) $new $Trip.Goal
    if ($worldLevel -ne $Trip.GoalLevel) { throw 'the world changed the trip destination level ID' }
    Assert-S7Player $new $Player $Trip.Goal -ExpectedLevel $worldLevel -RequireAlive
    return $new
}

function Get-S7PlayerLevel($Status, $Player, [string]$Map) {
    $seat = $Status.Players[[int]$Player.Peer]
    if ($seat -and $seat.Map -eq $Map -and -not $Status.Maps.ContainsKey($Map)) {
        throw "the world placed $($Player.Role) on $Map, the probe named no level ID for it"
    }
    if (-not $seat -or $seat.Map -ne $Map -or -not $Status.Maps.ContainsKey($Map) -or
        $seat.Level -ne $Status.Maps[$Map]) {
        throw "the world did not place $($Player.Role) on $Map"
    }
    return $seat.Level
}

function Assert-S7Player($Current, $Before, [string]$Map, [int]$ExpectedLevel = $Before.Level,
    [switch]$RequireAlive, [switch]$SamePeer) {
    if ($Current.Map -ne $Map -or $Current.Role -ne $Before.Role -or $Current.Operator -ne $Before.Operator -or
        $Current.Character -ne $Before.Character -or $Current.Level -ne $ExpectedLevel -or
        ($RequireAlive -and $Current.Alive -ne 1) -or ($SamePeer -and $Current.Peer -ne $Before.Peer) -or
        $Current.Kits -ne $Before.Kits -or
        ($Current.Role -eq 's7move' -and ($Current.Operator -ne 1 -or $Current.Kits -ne 1))) {
        throw "unexpected player evidence for $($Before.Role) on $Map ($($Current | Out-String))"
    }
}

function Assert-S7Creator($Context, $Player) {
    $worldLevel = Get-S7PlayerLevel (Get-S7Status $Context) $Player $s7From
    Assert-S7Player $Player $Player $s7From -ExpectedLevel $worldLevel -RequireAlive
    $null = Wait-S7Line $Context $Context.Logs.world "\[coop\] 's7move' is the operator and the world's creator: his character from the staging file \(1 item\(s\)\), no window\s*$" 30
}

function Start-S7Observer($Context) {
    $observer = Start-S7Client $Context 's7stay'
    if ($observer.Operator -ne 0 -or $observer.Alive -ne 1) { throw 'observer must be a live regular player' }
    if ($observer.Map -ne $s7From) {
        $observer = Complete-S7Trip $Context $observer (Start-S7Trip $Context $observer $s7From)
    }
    return $observer
}

function Read-S7Sample($Context, $Player, [int]$Sequence) {
    $sample = Wait-S7Line $Context $Context.Logs[$Player.Role] "\[s7\] sample seq=$Sequence $s7Player" 45
    return Read-S7Player $sample
}

function Assert-S7NoLoad($Context, $Player) {
    $load = Find-S7Line $Context.Logs[$Player.Role] $s7Load $Player.Line
    if ($load) { throw (Hide-Hex "unexpected $($Player.Role) load: $($load.Line)") }
}

function Read-S7Counters([string]$Line) {
    $m = [regex]::Match($Line, $s7Counter)
    if (-not $m.Success) { return }
    return @{
        Held = [long]$m.Groups['held'].Value; Pending = [long]$m.Groups['pending'].Value
        Asked = [long]$m.Groups['asked'].Value; Heard = [long]$m.Groups['heard'].Value
        Completed = [long]$m.Groups['completed'].Value; RolledBack = [long]$m.Groups['rolled'].Value
        Violations = [long]$m.Groups['violations'].Value
    }
}

function Add-S7Object([hashtable]$Objects, [string]$Line) {
    if ($Line -notmatch '\[s7\] object id=(\d+) section=(\w+) levelid=(\d+) owner=(-?\d+)\s*$') { return }
    $id = [int]$Matches[1]
    if ($Objects.ContainsKey($id)) { throw "duplicate fixture object $id" }
    $Objects[$id] = @{ Name = $Matches[2]; Level = [int]$Matches[3]; Owner = [int]$Matches[4] }
}

function Get-S7Status($Context, [switch]$Audit, [switch]$SelectFixtures, [switch]$Stationary, [int[]]$FixtureIds) {
    $Context.Query++
    $seq = $Context.Query
    $flag = if ($Audit) { 'true' } else { 'false' }
    # -Stationary: only squads the stock simulation keeps at a smart of their level (coop_zz_s7.script stays).
    $pick = if ($Stationary) { ", 'fixed'" } else { ", 'auto'" }
    $selection = if ($SelectFixtures) { $pick } elseif ($FixtureIds.Count) { ", '$($FixtureIds -join ',')'" } else { '' }
    Send-S7World $Context "run_string coop_zz_s7.world_status($seq, $flag$selection)"
    $end = Wait-S7Line $Context $Context.Logs.world "\[s7\] status end seq=$seq\s*$" 45
    $begin = Find-S7Line $Context.Logs.world "\[s7\] status begin seq=$seq\s*$"
    if (-not $begin -or $begin.LineNumber -ge $end.LineNumber) { throw "no opening tag for status $seq" }
    $bridges = @{}
    $players = @{}
    $maps = @{}
    $objects = @{}
    $status = $null
    $auditRound = $auditBridges = $auditStart = $null
    $block = @(Get-Content -LiteralPath $Context.Logs.world -TotalCount ($end.LineNumber - 1))
    for ($i = $begin.LineNumber; $i -lt $block.Count; $i++) {
        $line = $block[$i]
        if ($line -match $s7Counter) {
            # Some builds also print a short status during the audit. The explicit status follows it.
            $status = Read-S7Counters $line
        } elseif ($Audit -and $line -cmatch '\[coop\] levels audit begin round=([1-9][0-9]{0,9}) bridges=(0|[1-9][0-9]{0,9})\s*$') {
            if ($null -ne $auditRound) { throw "multiple native audit rounds in status $seq" }
            $auditRound = [uint32]$Matches[1]
            $auditBridges = [uint32]$Matches[2]
            $auditStart = $i + 1
        } elseif ($line -match '\[coop\] levels: +#(\d+) on level (\d+) \[(\w+)\]') {
            $players[[int]$Matches[1]] = @{ Level = [int]$Matches[2]; Map = $Matches[3] }
        } elseif ($line -match '\[s7\] world bridge peer=(25[7-9]|26[0-3]) levelid=(\d+)\s*$') {
            $map = [int]$Matches[2]
            if ($bridges.ContainsKey($map)) { throw "multiple bridges for level $map" }
            $bridges[$map] = [int]$Matches[1]
        } elseif ($line -match '\[s7\] world map=(\w+) levelid=(\d+)\s*$') {
            $maps[$Matches[1]] = [int]$Matches[2]
        } else {
            Add-S7Object $objects $line
        }
    }
    if (-not $status) { throw "no native ownership counters for status $seq" }
    if ($status.Violations -ne 0) { throw "$($status.Violations) ownership violations" }
    $status.Bridges = $bridges
    $status.Players = $players
    $status.Maps = $maps
    $status.Objects = $objects
    $status.LogEnd = $end.LineNumber
    $status.AuditRound = $auditRound
    $status.AuditBridges = $auditBridges
    $status.AuditStart = $auditStart
    return $status
}

function Test-S7AuditAcks([string]$Path, $Audit, $Sample) {
    # The native world logs these only after accepting the full-book report for this round
    # from the transport connection it challenged. Local holder snapshots cannot attest to that.
    $pattern = "\[coop\] levels audit ack round=$($Audit.AuditRound) peer=(25[7-9]|26[0-3]) mask=ffffffff\s*$"
    $seen = @{}
    foreach ($hit in (Select-String -LiteralPath $Path -Pattern $pattern -CaseSensitive)) {
        if ($hit.LineNumber -le $Audit.AuditStart -or $hit.LineNumber -gt $Sample.LogEnd) { continue }
        $peer = [int]$hit.Matches[0].Groups[1].Value
        if ($peer -notin $Audit.Bridges.Values) { throw "unexpected native audit acknowledgement from bridge $peer" }
        if ($seen.ContainsKey($peer)) { throw "duplicate native audit acknowledgement from bridge $peer" }
        $seen[$peer] = $true
    }
    return $seen.Count -eq $Audit.Bridges.Count
}

function Assert-S7BridgeReplies([hashtable]$LinesByLevel, [hashtable]$Expected, [int]$Sequence) {
    if ($Expected.Count -eq 0 -or $LinesByLevel.Count -ne $Expected.Count) { throw 'incomplete bridge audit' }
    foreach ($map in $Expected.Keys) {
        $begin = "\[s7\] bridge begin seq=$Sequence peer=$($Expected[$map]) levelid=$map\s*$"
        $end = "\[s7\] bridge end seq=$Sequence\s*$"
        $holder = '\[coop\] levels: holding \d+ object\(s\), (?:idle|busy), granted '
        $state = 0
        foreach ($line in $LinesByLevel[$map]) {
            if ($state -eq 0 -and $line -match $begin) { $state = 1 }
            elseif ($state -eq 1 -and $line -match $holder) { $state = 2 }
            elseif ($state -eq 2 -and $line -match $end) { $state = 3 }
            elseif ($line -match '\[s7\] bridge (?:begin|end)' -or $line -match $holder) { $state = -1 }
        }
        if ($state -ne 3) { throw "no unique fresh native holder reply from bridge for level $map" }
    }
}

function Assert-S7Fixtures([hashtable]$Expected, [hashtable]$Actual) {
    if ($Expected.Count -eq 0 -or $Actual.Count -ne $Expected.Count) { throw 'fixture object count changed' }
    foreach ($id in $Expected.Keys) {
        $before = $Expected[$id]
        $after = $Actual[$id]
        if (-not $after -or $after.Name -ne $before.Name -or $after.Level -ne $before.Level -or $after.Owner -ne $before.Owner) {
            $now = if ($after) { "$($after.Name) level $($after.Level) owner $($after.Owner)" } else { 'not listed' }
            throw "fixture object $id changed section, level, or owner ($($before.Name) level $($before.Level) owner $($before.Owner) -> $now)"
        }
    }
}

function Assert-S7Audit($Context, [int[]]$Levels, [switch]$SelectFixtures, [switch]$Stationary, [int[]]$FixtureIds) {
    $until = [DateTime]::UtcNow.AddSeconds(90)
    do {
        $before = Get-S7Status $Context
        if ($before.Bridges.Count -eq $Levels.Count -and $before.Pending -eq 0 -and
            @($Levels | Where-Object { -not $before.Bridges.ContainsKey($_) }).Count -eq 0) {
            $sent = Get-S7Status $Context -Audit
            if (-not $sent.AuditRound) { throw 'no native audit round logged for srv_levels_audit' }
            if ($sent.AuditBridges -eq $Levels.Count -and $sent.Bridges.Count -eq $Levels.Count -and
                @($Levels | Where-Object { $sent.Bridges[$_] -ne $before.Bridges[$_] }).Count -eq 0) {
                # Independently challenge each current bridge's own holder.
                $after = @{}
                foreach ($map in $Levels) {
                    $log = $Context.Logs["ms$($sent.Bridges[$map] - 256)"]
                    $after[$map] = Get-S7LineCount $log
                }
                $seq = Set-S7Step $Context 'all' 'bridge'
                $replies = @{}
                foreach ($map in $Levels) {
                    $peer = $sent.Bridges[$map]
                    $log = $Context.Logs["ms$($peer - 256)"]
                    $last = Wait-S7Line $Context $log "\[s7\] bridge end seq=$seq\s*$" 45 $after[$map]
                    $replies[$map] = @(Get-Content -LiteralPath $log -TotalCount $last.LineNumber |
                        Select-Object -Skip $after[$map])
                }
                Assert-S7BridgeReplies $replies $sent.Bridges $seq
                do {
                    $status = Get-S7Status $Context -SelectFixtures:$SelectFixtures -Stationary:$Stationary -FixtureIds $FixtureIds
                    if ($status.Bridges.Count -ne $Levels.Count -or
                        @($Levels | Where-Object { $status.Bridges[$_] -ne $sent.Bridges[$_] }).Count -ne 0) { break }
                    if ($status.Pending -eq 0 -and $status.Held -gt 0 -and (Test-S7AuditAcks $Context.Logs.world $sent $status)) {
                        $status.AuditRound = $sent.AuditRound
                        $status.AuditBridges = $sent.AuditBridges
                        Write-Host "ownership audit: $($status.Held) objects held, $($Levels.Count) full-book acknowledgements for round $($sent.AuditRound), 0 in flight, 0 violations"
                        return $status
                    }
                    Start-Sleep -Milliseconds 500
                } while ([DateTime]::UtcNow -lt $until)
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $until)
    throw 'ownership audit did not confirm every expected bridge on a settled, nonempty ledger'
}

function Get-S7MapProcess($Context, $Player, [int]$After = 0) {
    $start = Wait-S7Line $Context $Context.Logs.world ("\[coop\] map server [1-7] starts for level $($Player.Level) \(.+, process \d+\)\s*$") $StepTimeoutS $After
    $m = [regex]::Match($start.Line, $s7Start)
    $slot = [int]$m.Groups['slot'].Value
    $processId = [int]$m.Groups['process'].Value
    $null = Wait-S7Line $Context $Context.Logs.world "\[coop\] map server $slot leads level $($Player.Level)\s*$" $StepTimeoutS $start.LineNumber
    $proc = Get-Process -Id $processId
    try {
        $handle = $proc.Handle
        $owner = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId"
        if ($proc.HasExited -or $proc.Path -ne $Context.Exe -or $owner.ParentProcessId -ne $Context.World.Id -or
            $owner.CommandLine -notmatch '\s-coop_mapserver\s') {
            throw "PID $processId is not the map server started by this world"
        }
        return @{ Process = $proc; Handle = $handle; Slot = $slot; Line = $start.LineNumber }
    } catch {
        $proc.Dispose()
        throw
    }
}

function Stop-S7MapProcess($Victim) {
    if (-not ('RayLinkStand.S7Fault' -as [type])) {
        Add-Type -Namespace RayLinkStand -Name S7Fault -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool TerminateProcess(System.IntPtr process, uint exitCode);
'@
    }
    if ($Victim.Process.HasExited) { throw 'the map server exited before fault injection' }
    if (-not [RayLinkStand.S7Fault]::TerminateProcess($Victim.Handle, 1)) {
        throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    if (-not $Victim.Process.WaitForExit(15000)) { throw 'fault injection did not exit the map process' }
}

function Save-S7Logs($Context, [string]$Suffix = '') {
    foreach ($key in $Context.Logs.Keys) {
        $file = $Context.Logs[$key]
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $out = Join-Path $script:StandDir "$($Context.Tag)_$($Context.Name)_$key$Suffix.log"
            Copy-StandFile -From $file -To $out
        }
    }
}

function Clear-S7Logs($Context) {
    foreach ($file in $Context.Logs.Values) { Remove-StandFile -Path $file }
    $Context.CheckAt = [DateTime]::MinValue
}

function Invoke-S7Run([string]$Name, [scriptblock]$Body) {
    $standPath = (Get-StandFullPath $Stand).TrimEnd('\')
    if ($standPath -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand' }
    Assert-NoJunction -Dir $standPath
    Assert-NoJunction -Dir (Join-Path $standPath 'bin')
    if (Get-Process -Name 'AnomalyCoop*','AnomalyDX*','RayLinkServer*' -ErrorAction SilentlyContinue) { throw 'a game is running' }
    if (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue) { throw "UDP port $Port is taken" }

    $leaf = 'zz_s7_' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $run = Join-Path $standPath $leaf
    $probe = Join-Path $standPath 'gamedata\scripts\coop_zz_s7.script'
    $stepFile = Join-Path $standPath 'zz_s7_step.txt'
    foreach ($path in @($run, $probe, $stepFile)) {
        if (Test-Path -LiteralPath $path) { throw "scenario path already exists: $path" }
    }
    if ($env:RAYLINK_S7_GUARD_CLAIM) {
        # The guard owns the mutex until the job is empty and this claim is cleared.
        Write-StandText -Path $env:RAYLINK_S7_GUARD_CLAIM -Text "$leaf $PID" -Encoding ([Text.Encoding]::ASCII)
    }
    $ctx = @{
        Name = $Name; Stand = $standPath; Run = $run; Leaf = $leaf; Port = $Port; Tag = $Tag
        Exe = Join-Path $standPath 'bin\AnomalyCoopDX11AVX.exe'
        World = $null; Clients = @{}; Logs = @{}; Fs = @{}
        StepFile = $stepFile; StageName = 'creator.ltx'; Token = [Guid]::NewGuid().ToString('N')
        Step = 0; Query = 0; CheckAt = [DateTime]::MinValue
    }
    $logName = "logs\xray_$($env:USERNAME).log"
    foreach ($key in @('world', 's7move', 's7stay')) { $ctx.Logs[$key] = Join-Path $run "$key\$logName" }
    foreach ($slot in 1..7) { $ctx.Logs["ms$slot"] = Join-Path $run "appdata_ms$slot\$logName" }
    $finished = $false
    try {
        $ctx.Fs.world = New-S7Fs $ctx 'world' 'fsgame_server.ltx'
        Copy-StandFile -From (Join-Path $PSScriptRoot 'coop_zz_s7.script') -To $probe
        $stageFile = Join-Path $run "world\$($ctx.StageName)"
        $stage = "[world]`nfaction = stalker`ntitle = $Name`nstory = 0`nroutes = 0`n[creator]`nname = s7move`nmap = rookie_village`nloadout = medkit`nmoney = 3000`n"
        Write-StandText -Path $stageFile -Text $stage -Encoding ([Text.Encoding]::ASCII)
        & $Body $ctx
        Assert-S7Running $ctx
        $finished = $true
    } catch {
        Write-Host ("$Name`: FAIL ({0})" -f (Hide-Hex "$_"))
        throw
    } finally {
        if (-not $finished -and @($ctx.Clients.Values | Where-Object { -not $_.HasExited }).Count) {
            # b57i creator10_server: the clients were killed 30 ms after the probe's FAIL, before the client's health ledger
            # (15 s windows, engine xrCoop/coop_health_ledger.h) named what wrote his health. The probe flushes 20 s after it.
            Write-Host 'the processes stay up 17 s after the failure (the health ledger, flushed logs)'
            Start-Sleep -Seconds 17
        }
        try {
            try { Stop-S7Clients $ctx } finally { Stop-S7World $ctx }
        } finally {
            try {
                Save-S7Logs $ctx
                if ($finished) { Assert-S7Logs $ctx }
            } finally {
                foreach ($path in @($probe, $stepFile)) { Remove-StandFile -Path $path }
                if (Test-Path -LiteralPath $run -PathType Container) {
                    Assert-NoJunction -Dir $run
                    Get-ChildItem -LiteralPath $run -Recurse -File -Force | ForEach-Object { Remove-StandFile -Path $_.FullName }
                }
            }
        }
    }
    Write-Host "$Name`: PASS"
}

function Invoke-S7Scenario([string]$Name, [scriptblock]$Body) {
    if ($env:RAYLINK_S7_GUARD_CLAIM) {
        Invoke-S7Run $Name $Body
        return
    }
    $guard = [Threading.Mutex]::new($false, 'RayLink_A_S7_game_dev')
    try {
        try { $locked = $guard.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'another S7 scenario owns the stand' }
        try { Invoke-S7Run $Name $Body } finally { $guard.ReleaseMutex() }
    } finally {
        $guard.Dispose()
    }
}

if ($DefinitionsOnly) { return }

Invoke-S7Scenario 'ms_crash_server' {
    param($ctx)
    Start-S7World $ctx
    $mover = Start-S7Client $ctx 's7move'
    Assert-S7Creator $ctx $mover
    $observer = Start-S7Observer $ctx
    $null = Get-S7PlayerLevel (Get-S7Status $ctx) $observer $s7From
    $mover = Complete-S7Trip $ctx $mover (Start-S7Trip $ctx $mover $s7To)
    $victim = Get-S7MapProcess $ctx $mover
    $other = Get-S7MapProcess $ctx $observer
    $levels = @($mover.Level, $observer.Level)
    # Squads that stay at a smart of their level: a free sim squad may walk to the next level while the map restarts (b57h).
    $snapshot = Assert-S7Audit $ctx $levels -SelectFixtures -Stationary
    $fixtures = @{}
    foreach ($map in $levels) {
        $ids = @($snapshot.Objects.Keys | Where-Object {
            $snapshot.Objects[$_].Level -eq $map -and $snapshot.Objects[$_].Owner -eq $map
        } | Sort-Object | Select-Object -First 2)
        if ($ids.Count -eq 0) { throw "no held fixture objects on level $map" }
        foreach ($id in $ids) { $fixtures[$id] = $snapshot.Objects[$id] }
    }
    $worldId = $ctx.World.Id
    $worldLine = Get-S7LineCount $ctx.Logs.world
    $clientLine = Get-S7LineCount $ctx.Logs.s7move

    $victimLog = $ctx.Logs["ms$($victim.Slot)"]
    if (Test-Path -LiteralPath $victimLog -PathType Leaf) {
        Copy-StandFile -From $victimLog -To (Join-Path $script:StandDir "${Tag}_ms_crash_server_victim.log")
    }
    Stop-S7MapProcess $victim
    # Only this occurrence, in the world log after injecting the fault, is expected.
    $loss = "$script:StandBang\[coop\] map server of level $($mover.Level) is gone: its objects are at their last confirmed state, 1 failure\(s\) in a row\s*$"
    $ctx.ExpectedMapLoss = @{ Pattern = $loss; After = $worldLine }
    $lost = Wait-S7Line $ctx $ctx.Logs.world $loss 60 $worldLine
    $cameHome = Find-S7Line $ctx.Logs.world "\[coop\] levels: map server $($victim.Slot) leads no level now, (?<count>[1-9]\d*) object\(s\) came home\s*$" $worldLine
    $victimCount = @($fixtures.Values | Where-Object Owner -eq $mover.Level).Count
    if (-not $cameHome -or $cameHome.LineNumber -ge $lost.LineNumber -or
        [int]$cameHome.Matches[0].Groups['count'].Value -lt $victimCount) {
        throw 'the failed map returned fewer objects than its fixture count'
    }
    $fresh = Get-S7MapProcess $ctx $mover $lost.LineNumber
    if ($fresh.Process.Id -eq $victim.Process.Id -or $other.Process.HasExited -or $ctx.World.Id -ne $worldId) {
        throw 'the failed map did not get a new process, or another server went down'
    }
    $null = Wait-S7Line $ctx $ctx.Logs.s7move '\[coop\] host replaced the world \(st_coop_levels_server_restart, epoch \d+\), rejoining\s*$' $StepTimeoutS $clientLine
    $null = Wait-S7Line $ctx $ctx.Logs.s7move $s7Live $StepTimeoutS $clientLine
    $seq = Set-S7Step $ctx 'all' 'sample'
    $returned = Read-S7Sample $ctx $mover $seq
    $stayed = Read-S7Sample $ctx $observer $seq
    $status = Get-S7Status $ctx
    Assert-S7Player $returned $mover $s7To -ExpectedLevel (Get-S7PlayerLevel $status $returned $s7To) -RequireAlive
    Assert-S7Player $stayed $observer $s7From -ExpectedLevel (Get-S7PlayerLevel $status $observer $s7From) -RequireAlive -SamePeer
    Assert-S7NoLoad $ctx $observer
    $recovered = Assert-S7Audit $ctx $levels -FixtureIds @($fixtures.Keys)
    Assert-S7Fixtures $fixtures $recovered.Objects
    if ($fresh.Process.HasExited -or $other.Process.HasExited -or $ctx.World.Id -ne $worldId) {
        throw 'the post-recovery audit did not finish with the same world and expected map processes'
    }
    Write-Host "map server $($victim.Process.Id) replaced by $($fresh.Process.Id); $($cameHome.Matches[0].Groups['count'].Value) objects returned"
    Write-Host "world $worldId and the other map stayed up; $($fixtures.Count) fixture objects retained their owners by level: $($fixtures.Keys -join ',')"
}
