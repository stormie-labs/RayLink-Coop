<#
.SYNOPSIS
  Starts one coop test instance (a = host, b = client) prepared by deploy.ps1.

.EXAMPLE
  .\launch.ps1 a -NewGame          # host: straight into a new game
  .\launch.ps1 b                   # client: main menu; then in console: coop_connect 127.0.0.1
  .\launch.ps1 a -Load mysave      # host: load a save from appdata_coop_a\savedgames
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('a', 'b')][string]$Instance,
    [switch]$NewGame,
    [string]$Load,
    [string]$GameDir = 'E:\Anomaly',
    [string]$ExeName = 'AnomalyCoopDX11AVX.exe',
    [string[]]$Extra = @()
)

$ErrorActionPreference = 'Stop'
$binDir = if ($Instance -eq 'a') { Join-Path $GameDir 'bin' } else { Join-Path $GameDir 'bin_coop_b' }
$exe = Join-Path $binDir $ExeName
if (-not (Test-Path -LiteralPath $exe)) { throw "not deployed: $exe (run deploy.ps1)" }

$argv = @('-fsltx', "fsgame_coop_$Instance.ltx", '-smap2048')
if ($NewGame) { $argv += @('-start', 'server(all/single/alife/new)', 'client(localhost)') }
elseif ($Load) { $argv += @('-start', "server($Load/single/alife/load)", 'client(localhost)') }
$argv += $Extra

$p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $GameDir -PassThru
Write-Host "instance $Instance started: pid $($p.Id), log $GameDir\appdata_coop_$Instance\logs"
