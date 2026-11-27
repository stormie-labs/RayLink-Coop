# A minidump of a stand process that hangs, taken before the stand kills it (Stop-S7World: a world server that did not quit).
#
# Dev 66c creator10_server (2026-11-27): the world server stopped answering at 08:47:13.09 (the client: "the host does not answer
# (2005 ms)" at 15.097, dropped 30.0 s later at 43.099), its log file was last written at 08:46:26.35 while the process still
# served the client for 47 s (welcome, world download, Enter, story resync), and it did not quit in 150 s. The stand then killed
# it, and nothing told which thread held what. The dump below, read with the .pdb beside the exe, names the stacks of the main
# thread and of the log thread at that moment. One file per call, written over; a failure is said and never throws.
#
# Header-only for the stand: no other helper of the stand is needed (tests/tools/test_stand_dump.py dot-sources this file alone).

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
        [Parameter(Mandatory = $true)][string]$Path
    )
    try {
        if ($Process.HasExited) {
            Write-Host "dump: process $($Process.Id) has exited, no dump"
            return $false
        }
        if (-not ('RayLinkStandDump' -as [type])) { Add-Type -TypeDefinition $script:StandDumpType }
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Path $dir }
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
