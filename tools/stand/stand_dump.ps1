# A minidump of a stand process that hangs, taken before the stand kills it.
#
# A server that stops answering and does not quit leaves nothing that tells which thread holds what: its log may have stopped
# long before. The dump, read with the .pdb beside the exe, names the stacks of every thread at that moment. One file per
# name, written over; a failure is said and never throws.
#
# Header-only for the stand: no other helper of the stand is needed (tests/tools/test_stand_dump.py dot-sources this file alone).

# The dumps lie beside the stand's logs in the repository, never in a stand.
$script:StandDumpDir = Join-Path $PSScriptRoot '..\..\temp\stand'

$script:StandDumpType = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class RayLinkStandDump
{
    [DllImport("dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(IntPtr process, uint processId, SafeFileHandle file, uint type,
        IntPtr exception, IntPtr userStream, IntPtr callback);
}
'@

# MiniDumpWithDataSegs | MiniDumpWithHandleData | MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo: every thread's
# stack and what it points at, the handles (the critical sections and events a thread waits on), no full memory (a game has GBs).
$script:StandDumpFlags = [uint32](0x0001 -bor 0x0004 -bor 0x0040 -bor 0x1000)

function Save-StandDump {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Name   # the file is <Name>.dmp in $script:StandDumpDir
    )
    $Path = Join-Path $script:StandDumpDir "$Name.dmp"
    try {
        if ($Process.HasExited) {
            Write-Host "dump: process $($Process.Id) has exited, no dump"
            return $false
        }
        if (-not ('RayLinkStandDump' -as [type])) { Add-Type -TypeDefinition $script:StandDumpType }
        if (-not (Test-Path -LiteralPath $script:StandDumpDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $script:StandDumpDir }
        $file = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $ok = [RayLinkStandDump]::MiniDumpWriteDump($Process.Handle, [uint32]$Process.Id, $file.SafeFileHandle,
                $script:StandDumpFlags, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
            $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        } finally {
            $file.Dispose()
        }
        if (-not $ok) {
            Write-Host ("dump: process {0}: MiniDumpWriteDump failed (error 0x{1:X8})" -f $Process.Id, $err)
            return $false
        }
        Write-Host ("dump: process {0} -> {1} ({2} KB)" -f $Process.Id, $Path, [int]((Get-Item -LiteralPath $Path).Length / 1KB))
        return $true
    } catch {
        Write-Host "dump: process $($Process.Id): $_"
        return $false
    }
}

# When a log file was last written, against now: a process whose log stopped long before it hung says so.
function Get-StandLogAge([string]$Log) {
    if (-not (Test-Path -LiteralPath $Log -PathType Leaf)) { return "no log $Log" }
    $at = (Get-Item -LiteralPath $Log).LastWriteTime
    return ("log last written {0:HH:mm:ss.fff}, {1:N1} s ago" -f $at, ((Get-Date) - $at).TotalSeconds)
}
