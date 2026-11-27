# Runs one stand scenario. If a game outside the stand starts, stop only this scenario's process tree.
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script leave_group.ps1 -Out leave_lvs.out -ScriptArgs '-Role lvs'
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$ScriptArgs = '',
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    # outputs (the scenario's .out and .err): the repository's temp\stand, the run history (ignored)
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\temp\stand')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\stand_common.ps1')

function Initialize-GuardJob {
    if ('RayLinkStand.GuardJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace RayLinkStand {
    public sealed class GuardJob : IDisposable {
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimits {
            public BasicLimits Basic;
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Accounting {
            public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
            public uint Faults, Total, Active, Terminated;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern SafeFileHandle CreateJobObject(IntPtr attributes, IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref ExtendedLimits limits, int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Accounting accounting, int size, IntPtr unused);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(SafeFileHandle job, uint code);

        private readonly SafeFileHandle job;
        private static Win32Exception Error() { return new Win32Exception(Marshal.GetLastWin32Error()); }
        public GuardJob() {
            job = CreateJobObject(IntPtr.Zero, IntPtr.Zero);
            if (job.IsInvalid) throw Error();
            var limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf(typeof(ExtendedLimits)))) {
                var error = Error();
                job.Dispose();
                throw error;
            }
        }

        public void Add(Process process) {
            if (!AssignProcessToJobObject(job, process.Handle)) throw Error();
        }

        private uint Active() {
            Accounting accounting;
            if (!QueryInformationJobObject(job, 1, out accounting, Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero))
                throw Error();
            return accounting.Active;
        }

        public void Stop() {
            if (Active() == 0) return;
            if (!TerminateJobObject(job, 1)) throw Error();
            var clock = Stopwatch.StartNew();
            while (Active() != 0) {
                if (clock.ElapsedMilliseconds >= 15000) throw new TimeoutException("Stand job did not stop");
                Thread.Sleep(50);
            }
        }

        public void Dispose() { job.Dispose(); }
    }
}
'@
}

function Get-GuardBootstrap([string]$EventName, [string]$Arguments, [string]$Claim) {
    # The bootstrap cannot launch the scenario until the parent attaches it to the job. The inner
    # process keeps native -File argument binding. Forward both streams and its exit code.
    $eventLiteral = $EventName.Replace("'", "''")
    $argumentLiteral = $Arguments.Replace("'", "''")
    $claimLiteral = $Claim.Replace("'", "''")
    $bootstrap = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$start = [Threading.EventWaitHandle]::OpenExisting('$eventLiteral')
try { if (-not `$start.WaitOne(15000)) { exit 1 } } finally { `$start.Dispose() }
`$psi = [Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = Join-Path `$PSHOME 'powershell.exe'
`$psi.Arguments = '$argumentLiteral'
`$psi.UseShellExecute = `$false
`$psi.CreateNoWindow = `$true
`$psi.RedirectStandardOutput = `$true
`$psi.RedirectStandardError = `$true
`$psi.EnvironmentVariables['RAYLINK_S7_GUARD_CLAIM'] = '$claimLiteral'
`$child = [Diagnostics.Process]::Start(`$psi)
try {
    `$stdout = `$child.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
    `$stderr = `$child.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
    `$child.WaitForExit()
    # An orphan may still hold a pipe open. The outer guard stops it when this bootstrap exits.
    `$null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@(`$stdout, `$stderr), 5000)
    exit `$child.ExitCode
} finally { `$child.Dispose() }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    return "-NoProfile -EncodedCommand $encoded"
}

function Join-GuardOwned($Job, [Diagnostics.Process]$Run) {
    try {
        $Job.Add($Run)
    } catch {
        # Admission is still closed. Only this exact bootstrap was started.
        if (-not $run.HasExited) { $run.Kill() }
        $run.Dispose()
        throw
    }
}

function Test-GuardForeign([string]$Path, [string]$Stand) {
    $root = [IO.Path]::GetFullPath($Stand).TrimEnd('\','/') + '\'
    return (-not $Path -or -not [IO.Path]::GetFullPath($Path).StartsWith($root, [StringComparison]::OrdinalIgnoreCase))
}

function Clear-S7GuardClaim([string]$Stand, [string]$Claim) {
    if (-not $Claim -or -not (Test-Path -LiteralPath $Claim -PathType Leaf)) { return }
    $owner = (Get-Content -LiteralPath $Claim -Raw).Trim()
    if ($owner -cnotmatch '^(zz_s7_[a-f0-9]{12}) ([1-9]\d{0,9})$') { throw 'invalid S7 cleanup claim' }
    $leaf, $ownerPid = $Matches[1], $Matches[2]
    $runDir = Join-Path $Stand $leaf
    foreach ($file in @('gamedata\scripts\coop_zz_s7.script', 'zz_s7_step.txt',
        "gamedata\scripts\.coop_zz_s7.script.$ownerPid.new", ".zz_s7_step.txt.$ownerPid.new")) {
        Remove-StandFile -Path (Join-Path $Stand $file)
    }
    Remove-StandTree -Dir $runDir
    Remove-StandFile -Path $Claim
}

$outPath = Join-Path $OutDir $Out
$errPath = $outPath + '.err'
if (Test-GuardForeign (Get-StandFullPath $outPath) (Join-Path $script:Root 'temp')) { throw 'guard output must be in the repository temp directory' }
Assert-NoJunction -Dir ([IO.Path]::GetDirectoryName((Get-StandFullPath $outPath)))
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$line = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot $Script)`" $ScriptArgs"
$claim = ''
$mutex = $job = $admit = $run = $null
$locked = $false
$stopped = $false
$cleanup = ''
try {
    if ([IO.Path]::GetFileName($Script) -in @('ms_crash_server.ps1','save_handover_server.ps1','soak_hour_server.ps1','creator10_server.ps1')) {
        if ((Get-StandFullPath $Stand).TrimEnd('\') -ne 'E:\RayLinkGames\GAMMA\game-dev') { throw 'use the game-dev stand for S7' }
        $mutex = [Threading.Mutex]::new($false, 'RayLink_A_S7_game_dev')
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'another S7 scenario owns the stand' }
        $claim = Join-Path $script:StandDir ('s7_guard_' + [Guid]::NewGuid().ToString('N') + '.claim')
    }
    Initialize-GuardJob
    $job = [RayLinkStand.GuardJob]::new()
    $eventName = 'Local\RayLink_Stand_' + [Guid]::NewGuid().ToString('N')
    $admit = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $eventName)
    $bootstrapArgs = Get-GuardBootstrap $eventName $line $claim
    foreach ($old in @($outPath, $errPath)) { Remove-StandFile -Path $old }
    $run = Start-Process -FilePath 'powershell.exe' -ArgumentList $bootstrapArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    Join-GuardOwned $job $run
    while (-not $run.HasExited) {
        $games = Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*', 'AnomalyDX*' -ErrorAction SilentlyContinue
        $foreign = @(Get-StandForeignGame -Games $games -Stand $Stand) | Select-Object -First 1
        if ($foreign) {
            $stopped = $true
            break
        }
        $null = $admit.Set()
        Start-Sleep -Seconds 3
    }
} finally {
    # The guard's own cleanup never throws: a process of the scenario that outlives the job's kill, or a claim it cannot clear,
    # is this scenario's GUARD line (its runner fails it) and the stand run goes on.
    try {
        if ($job) {
            try { $job.Stop() } catch { $cleanup = "the scenario's processes did not stop: $($_.Exception.Message)" }
        }
        if ($claim) {
            try { Clear-S7GuardClaim $Stand $claim }
            catch { if (-not $cleanup) { $cleanup = "the S7 claim was not cleared: $($_.Exception.Message)" } }
        }
    } finally {
        if ($admit) { $admit.Dispose() }
        if ($job) { $job.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
if ($stopped) { Write-Host "GUARD: a game outside the stand started, the stand run was stopped ($($foreign.Name) pid $($foreign.Id): $(if ($foreign.Path) { $foreign.Path } else { 'no path' }))" }
else {
    Write-Host 'run finished'
    # the runner (tools\stand_common.ps1 Invoke-Scenario) fails a scenario that threw or exited non-zero (review 4, B1)
    Write-Host "scenario exit code: $($run.ExitCode)"
}
if ($cleanup) { Write-Host "GUARD: cleanup: $cleanup" }
$run.Dispose()
Get-Content -LiteralPath $outPath -Encoding UTF8 | Select-Object -Last 150
if ((Test-Path -LiteralPath $errPath) -and (Get-Item -LiteralPath $errPath).Length -gt 0) { Write-Host '--- stderr ---'; Get-Content -LiteralPath $errPath | Select-Object -Last 30 }
