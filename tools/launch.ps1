<#
.SYNOPSIS
  Starts one coop test instance (a = host, b = client) from the test root built by deploy.ps1.

.EXAMPLE
  .\launch.ps1 a -NewGame -HostSession -StatusEvery 10     # host: new game, hosts by itself
  .\launch.ps1 b -Connect 127.0.0.1 -StatusEvery 10        # client: joins by itself
  .\launch.ps1 a -Load mysave                              # host: load a save from appdata_a\savedgames
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
    [string]$GameDir = 'E:\AnomalyCoop',
    [string]$ExeName = 'AnomalyCoopDX11AVX.exe',
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$binDir = if ($Instance -eq 'a') { Join-Path $GameDir 'bin' } else { Join-Path $GameDir 'bin_b' }
$exe = Join-Path $binDir $ExeName
if (-not (Test-Path -LiteralPath $exe)) { throw "not deployed: $exe (run deploy.ps1)" }

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

$p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $GameDir -PassThru
Write-Host "instance $Instance started: pid $($p.Id), log $GameDir\appdata_$Instance\logs"
