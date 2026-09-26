#Requires -Version 5.1
<#
.SYNOPSIS
    Memory Guard - kills the largest memory hog BEFORE the machine freezes.

.DESCRIPTION
    Watches available physical memory (GlobalMemoryStatusEx, near-zero cost).
    Two levels:

      WARN     avail% < WarnPercent                      -> log only
      CRITICAL avail% < CriticalPercent for N samples    -> kill the biggest
               (avail% < CriticalPercent / 2             -> act immediately)

    On CRITICAL the script picks the process with the largest working set.
    A process that owns a visible window gets a graceful close (WM_CLOSE)
    first and a longer grace period (GracefulSeconds; the emergency tier caps
    it at 3s) so unsaved work can still be saved. -WindowedAction Skip goes
    one step further and never force-kills a windowed process at all.
    Background processes are force-killed directly. After the kill the script
    waits 3s, reports how much memory was released, then keeps watching - if
    memory is still critical after the cooldown, it acts again.

    Safety rails:
      * System critical processes are protected (killing them would bugcheck
        the machine or log the user off). Application processes are NOT
        protected by default - the largest one always wins.
      * Windowed (user-facing) processes may hold unsaved work:
        -WindowedAction Close (default) = WM_CLOSE, wait, then force kill.
        -WindowedAction Skip = WM_CLOSE, wait, and if it is still alive leave
        it alone and try the next candidate (never force-kills a window).
        -WindowedAction Force = ignore windows, kill immediately.
      * Only this script's own process chain is additionally kept alive (so
        the guard cannot kill its own launcher and die with it) - disable
        with -NoSelfProtect.
      * Extra protected names can be added any time via -Protect /
        protect-list.txt. protect-list.txt is re-read while the guard runs,
        so whitelisting a process does not need a restart.
      * -ListWindowed shows who currently owns a window (i.e. who may hold
        unsaved work); -AddProtect/node,code writes the whitelist for you.
      * Processes that cannot be terminated (system / elevated) simply fail
        and the next candidate is tried.
      * Processes smaller than MinCandidateMB are ignored - killing them would
        not help and would only hurt the user.
      * Cooldown between kills + MaxKillsPerHour hard limit.
      * -DryRun logs what it WOULD kill without killing anything.

    Logs: <script dir>\logs\memory-guard-YYYYMMDD.log
    Desktop alert file on every kill: <Desktop>\memory-guard-alert.txt

.PARAMETER WarnPercent
    Log a warning when available memory drops below this percent. Default 12.

.PARAMETER CriticalPercent
    Act when available memory stays below this percent. Default 7.

.PARAMETER SustainSamples
    Consecutive samples below CriticalPercent required before acting. Default 3
    (3 x IntervalSec = 15s). Half of CriticalPercent triggers immediately.

.PARAMETER IntervalSec
    Sampling interval in seconds. Default 5.

.PARAMETER CooldownSec
    Minimum seconds between two kills. Default 60.

.PARAMETER MinCandidateMB
    Never kill a process using less than this many MB. Default 300.

.PARAMETER MaxKillsPerHour
    Hard limit on kills per rolling hour. Default 6.

.PARAMETER GracefulSeconds
    How long to wait for a windowed process to close itself (WM_CLOSE) before
    force killing. Default 15 - long enough to notice a "save changes?" dialog
    and click it. The emergency tier caps the wait at 3 seconds. Background
    processes are force-killed directly and never wait.

.PARAMETER WindowedAction
    What to do with a process that owns a visible window (it may hold unsaved
    work). One of:
      Close (default) - WM_CLOSE, wait GracefulSeconds, then force kill.
      Skip            - WM_CLOSE, wait, and if it is still alive LEAVE IT
                        ALONE and try the next candidate. A windowed process
                        is never force-killed; the machine may stay tight.
      Force           - ignore windows completely and kill immediately.
                        "Keep the machine alive at any cost".

.PARAMETER AddProtect
    Add process names to protect-list.txt and exit. Idempotent, de-duplicated,
    keeps existing comments, writes protect-list.txt.bak first. Example:
    -AddProtect node,code,'Tabbit Browser'

.PARAMETER ListProtected
    Print the effective protection list (built-in system processes + -Protect
    arguments + protect-list.txt) and exit.

.PARAMETER ListWindowed
    List the processes that currently own a visible window - the ones that may
    hold unsaved work - and exit. Use it to build your whitelist before
    letting the guard act.

.PARAMETER MaxAttemptsPerRound
    If the top candidate cannot be killed (access denied etc.), try the next
    one, up to this many candidates per round. Default 3.

.PARAMETER Protect
    Extra process names to protect, e.g. -Protect python,node,vdb_sentinel.
    Application processes are not protected by default - only the built-in
    system critical list (plus this script's own chain) is.

.PARAMETER ProtectFile
    Optional text file with one protected process name per line ('#' starts a
    comment). Default path: <script dir>\protect-list.txt. Missing file is
    fine. Use it to protect application processes you do not want killed.

.PARAMETER NoSelfProtect
    Also drop the built-in protection of this script's own process chain.
    Not recommended: the guard could then kill its own launcher (the terminal
    or IDE it was started from) and die together with it.

.PARAMETER LogDir
    Log directory. Default: <script dir>\logs

.PARAMETER DesktopAlert
    Write <Desktop>\memory-guard-alert.txt on every action. Default $true.

.PARAMETER DryRun
    Log decisions but never kill anything.

.PARAMETER Once
    Sample once, print the verdict and exit. Combine with -DryRun to preview
    which process would be killed right now.

.PARAMETER InstallTask
    Register a scheduled task (name: MemoryGuard) that runs this script hidden
    at logon. Also unregisters a previous version. No admin rights required,
    but the task runs with the current user's privileges.

.PARAMETER UninstallTask
    Unregister the MemoryGuard scheduled task and exit.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -Once -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -DryRun -Verbose

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -InstallTask

.EXAMPLE
    # who may lose unsaved work? list windowed processes, then whitelist them
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -ListWindowed
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -AddProtect node,code
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -ListProtected

.EXAMPLE
    # machine first, unsaved work last: never force-kill anything with a window
    powershell -NoProfile -ExecutionPolicy Bypass -File .\memory-guard.ps1 -WindowedAction Skip

.NOTES
    Only processes owned by the current user can be killed without elevation.
    To also kill elevated processes, run the script (or the scheduled task) as
    administrator.
#>
[CmdletBinding()]
param(
    [ValidateRange(2, 99)][int]$WarnPercent = 12,
    [ValidateRange(1, 98)][int]$CriticalPercent = 7,
    [ValidateRange(1, 120)][int]$SustainSamples = 3,
    [ValidateRange(1, 3600)][int]$IntervalSec = 5,
    [ValidateRange(0, 86400)][int]$CooldownSec = 60,
    [ValidateRange(1, 1048576)][int]$MinCandidateMB = 300,
    [ValidateRange(1, 1000)][int]$MaxKillsPerHour = 6,
    [ValidateRange(0, 300)][int]$GracefulSeconds = 15,
    [ValidateSet('Close', 'Skip', 'Force')][string]$WindowedAction = 'Close',
    [ValidateRange(1, 20)][int]$MaxAttemptsPerRound = 5,
    [string[]]$Protect = @(),
    [string]$ProtectFile,
    [string]$LogDir,
    [bool]$DesktopAlert = $true,
    [switch]$NoSelfProtect,
    [switch]$DryRun,
    [switch]$Once,
    [string[]]$AddProtect = @(),
    [switch]$ListProtected,
    [switch]$ListWindowed,
    [switch]$InstallTask,
    [switch]$UninstallTask
)

$ErrorActionPreference = 'Continue'
$TaskName = 'MemoryGuard'

# Resolve script paths defensively: $PSScriptRoot can be empty when the script
# is invoked through odd wrappers, so fall back to the command path.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProtectFile) { $ProtectFile = Join-Path $ScriptDir 'protect-list.txt' }
if (-not $LogDir) { $LogDir = Join-Path $ScriptDir 'logs' }

# ---------------------------------------------------------------------------
# native sampler (GlobalMemoryStatusEx via P/Invoke; no CIM overhead per tick)
# ---------------------------------------------------------------------------
if (-not ('MemGuard.MemInfo' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace MemGuard
{
    public static class MemInfo
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        // [0]=TotalPhysMB [1]=AvailPhysMB [2]=TotalCommitMB [3]=AvailCommitMB [4]=MemLoadPct
        public static long[] Get()
        {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (!GlobalMemoryStatusEx(ref m))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return new long[]
            {
                (long)(m.ullTotalPhys >> 20),
                (long)(m.ullAvailPhys >> 20),
                (long)(m.ullTotalPageFile >> 20),
                (long)(m.ullAvailPageFile >> 20),
                (long)m.dwMemoryLoad
            };
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# logging / alerting
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir ('memory-guard-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Write-DesktopAlert {
    param([string]$Text)
    if (-not $DesktopAlert) { return }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { return }
        Set-Content -LiteralPath (Join-Path $desktop 'memory-guard-alert.txt') -Value $Text -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# protection list
# ---------------------------------------------------------------------------
function ConvertTo-ProcKey {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name.Trim() -replace '\.exe$', '').ToLowerInvariant()
}

# Built-in protection: system critical processes only. Killing any of these
# bugchecks the machine, logs the user off, breaks the shell, or disables the
# security software (which then triggers self-repair + a full rescan).
# Application processes (browser, IDE, chat apps, ...) are deliberately NOT
# protected - the largest one still wins. Add your own names via -Protect /
# protect-list.txt if needed.
$SystemProtected = @(
    # kernel / session critical: killing these bugchecks the machine or logs you off
    'system', 'idle', 'registry', 'memory compression', 'secure system',
    'smss', 'csrss', 'wininit', 'winlogon', 'userinit', 'logonui',
    'services', 'lsass', 'lsaiso', 'fontdrvhost', 'dwm',
    # shell / OS infrastructure: killing these breaks the desktop or sessions
    'svchost', 'audiodg', 'spoolsv', 'wudfhost', 'taskhostw', 'sihost',
    'shellexperiencehost', 'startmenuexperiencehost', 'searchhost',
    'searchindexer', 'searchprotocolhost', 'textinputhost', 'ctfmon',
    'runtimebroker', 'dllhost', 'wmiprvse', 'explorer', 'conhost',
    'msiexec', 'trustedinstaller',
    # security software: killing it interrupts protection and triggers repair
    'msmpeng', 'nissrv', 'mpdefendercore', 'securityhealthservice',
    'securityhealthsystray', 'qqpctray', 'qqpcmgr', 'qqpcnetflow', 'qqpcrtp'
)

$protectSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $SystemProtected) { [void]$protectSet.Add((ConvertTo-ProcKey $name)) }
foreach ($name in $Protect) { [void]$protectSet.Add((ConvertTo-ProcKey $name)) }

# The whitelist file is kept in its own set and re-read while the guard runs
# (LastWriteTime check, one stat per sampling interval), so whitelisting a
# process - by hand or with -AddProtect - takes effect without a restart.
$script:fileProtect = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:protectFileStamp = [datetime]::MinValue

function Update-ProtectFileSet {
    $exists = Test-Path -LiteralPath $ProtectFile
    $stamp = if ($exists) { (Get-Item -LiteralPath $ProtectFile).LastWriteTimeUtc } else { [datetime]::MinValue }
    if ($stamp -eq $script:protectFileStamp) { return }
    $script:protectFileStamp = $stamp
    $script:fileProtect.Clear()
    if (-not $exists) { return }
    foreach ($raw in (Get-Content -LiteralPath $ProtectFile -Encoding UTF8)) {
        $entry = ($raw -split '#')[0].Trim()
        if ($entry) { [void]$script:fileProtect.Add((ConvertTo-ProcKey $entry)) }
    }
}

function Test-Protected {
    param([string]$Name)
    $key = ConvertTo-ProcKey $Name
    return ($protectSet.Contains($key) -or $script:fileProtect.Contains($key))
}

# load the whitelist now; the sampling loop refreshes it on every tick
Update-ProtectFileSet

# ---------------------------------------------------------------------------
# whitelist / inspection commands (run once and exit)
# ---------------------------------------------------------------------------
function Show-ProtectList {
    Write-Host '============ protected processes (never killed) ============'
    Write-Host ('built-in system critical: {0}' -f $SystemProtected.Count)
    foreach ($chunk in ($SystemProtected | Sort-Object)) { Write-Host ('    ' + $chunk) }
    if ($Protect.Count -gt 0) { Write-Host ('from -Protect: {0}' -f ($Protect -join ', ')) }
    Write-Host ('from protect-list.txt: {0}  ({1})' -f $script:fileProtect.Count, $ProtectFile)
    if ($script:fileProtect.Count -gt 0) {
        foreach ($name in ($script:fileProtect | Sort-Object)) { Write-Host ('    ' + $name) }
    }
    Write-Host '============================================================='
}

function Add-ProtectEntries {
    param([string[]]$Names)

    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $ProtectFile) {
        $lines = @(Get-Content -LiteralPath $ProtectFile -Encoding UTF8)
        foreach ($raw in $lines) {
            $entry = ($raw -split '#')[0].Trim()
            if ($entry) { [void]$existing.Add((ConvertTo-ProcKey $entry)) }
        }
        Copy-Item -LiteralPath $ProtectFile -Destination ($ProtectFile + '.bak') -Force
    } else {
        $lines = @('# memfuse / memory-guard protect list - one process name per line, # starts a comment', '')
    }

    $added = New-Object 'System.Collections.Generic.List[string]'
    # Accept every way this switch can arrive: -AddProtect node,code from a
    # PowerShell prompt (array), "-AddProtect node,code" through powershell
    # -File (a single literal string). Split on , and ; only - never on
    # whitespace, because real process names contain spaces
    # ("Tabbit Browser", "CodeBuddy CN", "Memory Compression").
    $flat = @()
    foreach ($entry in $Names) {
        foreach ($part in ($entry -split '[,;]+')) {
            if ($part.Trim()) { $flat += $part.Trim() }
        }
    }
    foreach ($name in $flat) {
        $key = ConvertTo-ProcKey $name
        if (-not $key) { continue }
        if ($protectSet.Contains($key)) {
            Write-Host ('  = {0} (already protected by the built-in system list or -Protect)' -f $key)
            continue
        }
        if (-not $existing.Add($key)) {
            Write-Host ('  = {0} (already in the protect file)' -f $key)
            continue
        }
        $lines += $key
        $added.Add($key)
    }

    if ($added.Count -eq 0) { Write-Host 'nothing added.'; return }

    # UTF-8 without BOM: a BOM would corrupt the first entry for other readers.
    [IO.File]::WriteAllText($ProtectFile, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('added {0} name(s) to {1}:' -f $added.Count, $ProtectFile)
    foreach ($name in $added) { Write-Host ('  + ' + $name) }
    Write-Host 'a running guard picks this up within one sampling interval (the file is re-read).'
}

function Show-WindowedProcesses {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    Write-Host '=== processes owning a visible window (they may hold unsaved work) ==='
    if ($procs.Count -eq 0) { Write-Host 'none found.'; return }

    $rows = foreach ($p in ($procs | Sort-Object WorkingSet64 -Descending)) {
        [pscustomobject]@{
            State = $(if (Test-Protected $p.ProcessName) { 'protected' } else { 'killable' })
            Name  = $p.ProcessName
            Pid   = $p.Id
            WS_MB = [int][math]::Round($p.WorkingSet64 / 1MB)
            Title = $p.MainWindowTitle
        }
    }
    Write-Host (($rows | Format-Table -AutoSize | Out-String -Width 220).TrimEnd())
    Write-Host ('total {0} windowed process(es). To keep one alive anyway:' -f $procs.Count)
    Write-Host ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -AddProtect <name1>,<name2>' -f $PSCommandPath)
    Write-Host '  or never force-kill windowed processes at all: -WindowedAction Skip'
    Write-Host '  note: an elevated process can own a window and still be unkillable (access denied).'
}

# own process chain: keeps the guard from killing its own launcher - and itself
# with it. Disable with -NoSelfProtect for absolutely zero protection.
$script:SelfChain = New-Object 'System.Collections.Generic.HashSet[int]'
if (-not $NoSelfProtect) {
    $cursor = $PID
    for ($depth = 0; $depth -lt 4; $depth++) {
        if ($cursor -le 0) { break }
        [void]$script:SelfChain.Add($cursor)
        try {
            $parentId = (Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $cursor) -Property ParentProcessId -ErrorAction Stop).ParentProcessId
        } catch { break }
        if (-not $parentId -or $parentId -le 0) { break }
        $cursor = [int]$parentId
    }
}

# ---------------------------------------------------------------------------
# core helpers
# ---------------------------------------------------------------------------
function Get-MemorySample {
    $s = [MemGuard.MemInfo]::Get()
    $totalMB = [long]$s[0]
    $availMB = [long]$s[1]
    $commitTotalMB = [long]$s[2]
    $commitAvailMB = [long]$s[3]
    $availPct = [math]::Round((100.0 * $availMB / [math]::Max($totalMB, 1)), 1)
    $commitPct = [math]::Round((100.0 * ($commitTotalMB - $commitAvailMB) / [math]::Max($commitTotalMB, 1)), 1)
    return [pscustomobject]@{
        TotalMB   = $totalMB
        AvailMB   = $availMB
        CommitPct = $commitPct
        AvailPct  = $availPct
    }
}

function Get-Candidates {
    param([int]$TopN)
    $minBytes = [long]$MinCandidateMB * 1MB
    $list = @()
    try {
        $list = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -gt 4 -and $_.WorkingSet64 -ge $minBytes
        })
    } catch {
        Write-Log ('WARN  failed to enumerate processes: {0}' -f $_.Exception.Message)
        return @()
    }
    $list = @($list | Where-Object {
        (-not (Test-Protected $_.ProcessName)) -and
        (-not $script:SelfChain.Contains($_.Id))
    })
    return @($list | Sort-Object WorkingSet64 -Descending | Select-Object -First $TopN)
}

function Stop-TargetProcess {
    param(
        [System.Diagnostics.Process]$Proc,
        [switch]$Emergency
    )
    $target = $Proc
    try { $target.Refresh() } catch { }
    try { if ($target.HasExited) { return 'stopped' } } catch { return 'stopped' }

    $hasWindow = $false
    try { $hasWindow = ($target.MainWindowHandle -ne [IntPtr]::Zero) } catch { }

    # graceful close first, windowed processes only. -WindowedAction Force skips
    # this phase; -WindowedAction Skip never escalates to a force kill.
    if ($hasWindow -and $WindowedAction -ne 'Force') {
        $grace = [math]::Max($GracefulSeconds, 1)
        if ($Emergency) { $grace = [math]::Min($grace, 3) }   # no time for a save dialog
        try { $null = $target.CloseMainWindow() } catch { }
        $deadline = (Get-Date).AddSeconds($grace)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            try { $target.Refresh() } catch { }
            try { if ($target.HasExited) { return 'stopped' } } catch { return 'stopped' }
        }
        if ($WindowedAction -eq 'Skip') { return 'skipped' }
    }

    try { Stop-Process -Id $target.Id -Force -ErrorAction Stop } catch {
        Write-Verbose ('Stop-Process failed: {0}' -f $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 800
    if (Get-Process -Id $target.Id -ErrorAction SilentlyContinue) { return 'failed' }
    return 'stopped'
}

function Invoke-Relief {
    param(
        [long]$TotalMB,
        [long]$AvailMB,
        [double]$AvailPct,
        [double]$CommitPct,
        [switch]$Emergency
    )

    $tag = if ($Emergency) { 'CRITICAL(emergency)' } else { 'CRITICAL' }
    $cands = @(Get-Candidates -TopN $MaxAttemptsPerRound)

    if ($cands.Count -eq 0) {
        Write-Log ('{0} avail {1}MB ({2}%) commit {3}% - no candidate >= {4}MB (all protected or too small) - manual action needed' -f $tag, $AvailMB, $AvailPct, $CommitPct, $MinCandidateMB)
        Write-DesktopAlert ('Memory Guard {0}
available: {1} MB ({2}%) - critical, but no process >= {3} MB could be killed.
Check the machine manually or lower -MinCandidateMB.
log: {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $AvailMB, $AvailPct, $MinCandidateMB, $LogFile)
        return $false
    }

    $preview = ($cands | ForEach-Object {
        '{0}#{1}={2}MB' -f $_.ProcessName, $_.Id, [int][math]::Round($_.WorkingSet64 / 1MB)
    }) -join ' | '
    Write-Log ('{0} avail {1}MB ({2}%) commit {3}% total {4}MB - candidates: {5}' -f $tag, $AvailMB, $AvailPct, $CommitPct, $TotalMB, $preview)

    $skipped = 0
    foreach ($proc in $cands) {
        $wsMB = [int][math]::Round($proc.WorkingSet64 / 1MB)
        # Capture the name up front: once the process has exited, .ProcessName
        # reads back empty and the log line / desktop alert would lose the
        # culprit's name exactly where it matters most.
        $procName = $proc.ProcessName
        if (-not $procName) { $procName = '<unknown>' }
        $path = ''
        $cmd = ''
        try { $path = [string]$proc.Path } catch { }
        try {
            $cmd = [string](Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $proc.Id) -Property CommandLine -ErrorAction SilentlyContinue).CommandLine
        } catch { }
        if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0, 300) + '...' }

        $windowed = $false
        try { $windowed = ($proc.MainWindowHandle -ne [IntPtr]::Zero) } catch { }

        if ($DryRun) {
            $note = if ($windowed) { ' [has a window -> WindowedAction=' + $WindowedAction + ']' } else { '' }
            Write-Log ('DRY-RUN would kill {0} pid={1} ws={2}MB path={3} cmd={4}{5}' -f $procName, $proc.Id, $wsMB, $path, $cmd, $note)
            return $false
        }

        Write-Log ('ACTION  killing {0} pid={1} ws={2}MB path={3} cmd={4}' -f $procName, $proc.Id, $wsMB, $path, $cmd)

        $verdict = Stop-TargetProcess -Proc $proc -Emergency:$Emergency
        if ($verdict -eq 'skipped') {
            $skipped++
            Write-Log ('SKIP    {0} pid={1} ws={2}MB owns a window and did not close itself - left alone (WindowedAction=Skip keeps unsaved work); trying next candidate' -f $procName, $proc.Id, $wsMB)
            continue
        }
        if ($verdict -eq 'failed') {
            Write-Log ('ACTION  failed to stop {0} pid={1} (access denied or still busy) - trying next candidate' -f $procName, $proc.Id)
            continue
        }

        Start-Sleep -Seconds 3
        try {
            $after = Get-MemorySample
            Write-Log ('ACTION  stopped {0} pid={1} - avail {2}MB ({3}%) -> {4}MB ({5}%) [delta {6}MB]' -f `
                $procName, $proc.Id, $AvailMB, $AvailPct, $after.AvailMB, $after.AvailPct, ($after.AvailMB - $AvailMB))
            Write-DesktopAlert ('Memory Guard {0}
before: {1} MB free ({2}%)
after : {3} MB free ({4}%)
killed: {5} (pid {6}, {7} MB)
path: {8}
cmd: {9}
log: {10}

If this was something you need, add its name to:
{11}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $AvailMB, $AvailPct, $after.AvailMB, $after.AvailPct, `
                $procName, $proc.Id, $wsMB, $path, $cmd, $LogFile, $ProtectFile)
        } catch { }

        return $true
    }

    if ($skipped -gt 0) {
        Write-Log ('ACTION  nothing done: {0} candidate(s) left alone (windowed, WindowedAction=Skip), the rest failed - machine stays tight by design' -f $skipped)
        Write-DesktopAlert ('Memory Guard {0}
available: still critical after evaluating every candidate.
reason: {1} windowed process(es) were left alone (WindowedAction=Skip).
If you want the guard to force-kill them: rerun with -WindowedAction Close,
or close / whitelist the app that is eating the memory.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $skipped)
    } else {
        Write-Log ('ACTION  all {0} candidate(s) failed - run the guard with more privileges if it must kill elevated processes' -f $cands.Count)
    }
    return $false
}

function Show-Config {
    $info = Get-MemorySample
    Write-Host '==================== Memory Guard ===================='
    Write-Host ('mode          : {0}' -f ($(if ($DryRun) { 'DRY-RUN (nothing will be killed)' } else { 'LIVE (will kill)' })))
    Write-Host ('total memory  : {0} MB' -f $info.TotalMB)
    Write-Host ('now           : {0} MB free ({1}%), commit {2}%' -f $info.AvailMB, $info.AvailPct, $info.CommitPct)
    Write-Host ('thresholds    : warn < {0}%  critical < {1}%  sustain {2} x {3}s (emergency < {4}%)' -f `
        $WarnPercent, $CriticalPercent, $SustainSamples, $IntervalSec, [math]::Round($CriticalPercent / 2.0, 1))
    Write-Host ('limits        : cooldown {0}s, max {1} kill(s)/hour, min candidate {2} MB' -f $CooldownSec, $MaxKillsPerHour, $MinCandidateMB)
    Write-Host ('protected     : {0} names ({1} built-in system + {2} user: -Protect / protect-list.txt)' -f ($protectSet.Count + $script:fileProtect.Count), $SystemProtected.Count, (($protectSet.Count - $SystemProtected.Count) + $script:fileProtect.Count))
    Write-Host ('windowed      : {0} (grace {1}s, emergency {2}s)' -f $WindowedAction, [math]::Max($GracefulSeconds, 1), [math]::Min([math]::Max($GracefulSeconds, 1), 3))
    if ($script:SelfChain.Count -gt 0) {
        Write-Host ('self chain    : pid {0} (the guard and its own launcher chain)' -f (($script:SelfChain | Sort-Object) -join ', '))
    } else {
        Write-Host 'self chain    : OFF - no extra protection for the guard itself'
    }
    Write-Host ('log file      : {0}' -f $LogFile)
    Write-Host '======================================================'
}

# ---------------------------------------------------------------------------
# scheduled task management
# ---------------------------------------------------------------------------
function Install-GuardTask {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DryRun) { $argLine += ' -DryRun' }
    if ($NoSelfProtect) { $argLine += ' -NoSelfProtect' }
    if ($WindowedAction -ne 'Close') { $argLine += (' -WindowedAction {0}' -f $WindowedAction) }
    if ($GracefulSeconds -ne 15) { $argLine += (' -GracefulSeconds {0}' -f $GracefulSeconds) }

    $action = New-ScheduledTaskAction -Execute $psExe -Argument $argLine -WorkingDirectory $PSScriptRoot

    # Trigger 1: at logon. Trigger 2 (repetition attached to the same trigger):
    # every 5 minutes. MultipleInstances=IgnoreNew makes the repeat a no-op
    # while the guard is alive, and a self-heal relaunch (within 5 minutes)
    # if it ever died.
    # Trigger A: heartbeat - first run one minute from now, then every 5
    # minutes, indefinitely. With MultipleInstances=IgnoreNew this is a no-op
    # while the guard is alive, and a self-heal relaunch if it ever died.
    # Trigger B: at logon - also starts with Windows.
    try {
        # No -RepetitionDuration => repeat indefinitely. (A TimeSpan::MaxValue
        # duration is rejected by the scheduler as out of range.)
        $heartbeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    } catch {
        Write-Host ('WARN  could not build the 5-minute self-heal trigger: {0}' -f $_.Exception.Message)
        $heartbeat = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    }
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Never time out, keep running on battery, restart up to 999 times if it
    # fails, and never run two copies at once.
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($heartbeat, $logonTrigger) -Settings $settings `
            -Description 'Kill the largest memory hog before the system freezes (tools/memory-guard)' -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host ('ERROR  task registration failed: {0}' -f $_.Exception.Message)
        return
    }
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Write-Host 'ERROR  registration reported success but the task does not exist'
        return
    }

    Write-Host ('task registered: {0}' -f $TaskName)
    Write-Host ('command       : {0} {1}' -f $psExe, $argLine)
    Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-List
    try {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host ('next run      : {0} (repeats every 5 minutes)' -f $info.NextRunTime)
    } catch { }
    Write-Host 'starts at logon and self-heals within 5 minutes if it ever dies. Start it now with:'
    Write-Host ('      Start-ScheduledTask -TaskName {0}' -f $TaskName)
}

function Uninstall-GuardTask {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host ('task removed: {0}' -f $TaskName)
    } catch {
        Write-Host ('nothing to remove (task {0} not found)' -f $TaskName)
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if ($UninstallTask) { Uninstall-GuardTask; exit 0 }
if ($ListProtected) { Show-ProtectList; exit 0 }
if ($ListWindowed) { Show-WindowedProcesses; exit 0 }
if (@($AddProtect).Count -gt 0) { Add-ProtectEntries -Names $AddProtect; exit 0 }
if ($InstallTask) { Install-GuardTask; exit 0 }
if ($WarnPercent -le $CriticalPercent) { throw 'WarnPercent must be greater than CriticalPercent' }

Show-Config
Write-Log ('started - warn<{0}% crit<{1}% sustain={2}x{3}s cooldown={4}s minCandidate={5}MB maxKills={6}/h dryRun={7}' -f `
    $WarnPercent, $CriticalPercent, $SustainSamples, $IntervalSec, $CooldownSec, $MinCandidateMB, $MaxKillsPerHour, $DryRun.IsPresent)

if ($Once) {
    $sample = Get-MemorySample
    Write-Host ('sample: {0} MB free ({1}%) of {2} MB, commit {3}%' -f $sample.AvailMB, $sample.AvailPct, $sample.TotalMB, $sample.CommitPct)
    if ($sample.AvailPct -lt $CriticalPercent) {
        Write-Host 'status: CRITICAL - evaluating candidates'
        [void](Invoke-Relief -TotalMB $sample.TotalMB -AvailMB $sample.AvailMB -AvailPct $sample.AvailPct -CommitPct $sample.CommitPct)
    } elseif ($sample.AvailPct -lt $WarnPercent) {
        Write-Host 'status: WARN - memory is low but above the critical threshold'
    } else {
        Write-Host 'status: OK'
    }
    exit 0
}

$lowStreak = 0
$lastWarn = [datetime]::MinValue
$lastKill = [datetime]::MinValue
$killTimes = New-Object 'System.Collections.Generic.List[datetime]'

while ($true) {
    Update-ProtectFileSet
    try {
        $sample = Get-MemorySample
    } catch {
        Write-Log ('ERROR sampling memory: {0}' -f $_.Exception.Message)
        Start-Sleep -Seconds $IntervalSec
        continue
    }

    if ($sample.AvailPct -lt $CriticalPercent) { $lowStreak++ } else { $lowStreak = 0 }
    Write-Verbose ('avail {0}MB ({1}%) commit {2}% streak {3}' -f $sample.AvailMB, $sample.AvailPct, $sample.CommitPct, $lowStreak)

    $now = Get-Date

    if ($sample.AvailPct -lt $WarnPercent -and ($now - $lastWarn).TotalSeconds -ge 600) {
        Write-Log ('WARN  avail {0}MB ({1}%) commit {2}% total {3}MB  [warn<{4}% crit<{5}%]' -f `
            $sample.AvailMB, $sample.AvailPct, $sample.CommitPct, $sample.TotalMB, $WarnPercent, $CriticalPercent)
        $lastWarn = $now
    }

    $emergency = ($sample.AvailPct -lt ($CriticalPercent / 2.0))
    $shouldAct = ($lowStreak -ge $SustainSamples) -or ($emergency -and $lowStreak -ge 1)

    if ($shouldAct) {
        if (($now - $lastKill).TotalSeconds -lt $CooldownSec) {
            Write-Verbose 'in cooldown - waiting'
        } else {
            $recent = @($killTimes | Where-Object { ($now - $_).TotalHours -lt 1 })
            $killTimes.Clear()
            foreach ($stamp in $recent) { $killTimes.Add($stamp) }

            if ($killTimes.Count -ge $MaxKillsPerHour) {
                if (($now - $lastKill).TotalSeconds -ge 300) {
                    Write-Log ('LIMIT hourly kill limit reached ({0}/h) - not acting this round' -f $MaxKillsPerHour)
                    $lastKill = $now
                }
            } else {
                $killed = Invoke-Relief -TotalMB $sample.TotalMB -AvailMB $sample.AvailMB `
                    -AvailPct $sample.AvailPct -CommitPct $sample.CommitPct -Emergency:$emergency
                $lastKill = Get-Date
                if ($killed) { $killTimes.Add($lastKill) }
            }
        }
    }

    Start-Sleep -Seconds $IntervalSec
}
