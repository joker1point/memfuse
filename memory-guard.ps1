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

    On CRITICAL the script picks the process with the largest working set,
    tries a graceful close (WM_CLOSE) when it owns a window, then force-kills
    it, waits 3s and reports how much memory was released. It then keeps
    watching - if memory is still critical after the cooldown, it acts again.

    Safety rails:
      * System critical processes are protected (killing them would bugcheck
        the machine or log the user off). Application processes are NOT
        protected - the largest one always wins.
      * Only this script's own process chain is additionally kept alive (so
        the guard cannot kill its own launcher and die with it) - disable
        with -NoSelfProtect.
      * Extra protected names can be added any time via -Protect /
        protect-list.txt.
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
    force killing. Default 5. Background processes are force-killed directly.

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
    [ValidateRange(0, 300)][int]$GracefulSeconds = 5,
    [ValidateRange(1, 20)][int]$MaxAttemptsPerRound = 5,
    [string[]]$Protect = @(),
    [string]$ProtectFile,
    [string]$LogDir,
    [bool]$DesktopAlert = $true,
    [switch]$NoSelfProtect,
    [switch]$DryRun,
    [switch]$Once,
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

$userProtectedCount = 0
if (Test-Path -LiteralPath $ProtectFile) {
    foreach ($raw in (Get-Content -LiteralPath $ProtectFile -Encoding UTF8)) {
        $entry = ($raw -split '#')[0].Trim()
        if ($entry -and $protectSet.Add((ConvertTo-ProcKey $entry))) { $userProtectedCount++ }
    }
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
        (-not $protectSet.Contains((ConvertTo-ProcKey $_.ProcessName))) -and
        (-not $script:SelfChain.Contains($_.Id))
    })
    return @($list | Sort-Object WorkingSet64 -Descending | Select-Object -First $TopN)
}

function Stop-TargetProcess {
    param([System.Diagnostics.Process]$Proc)
    $target = $Proc
    try { $target.Refresh() } catch { }
    try { if ($target.HasExited) { return $true } } catch { return $true }

    # graceful close first, but only for windowed processes
    try {
        if ($target.MainWindowHandle -ne [IntPtr]::Zero) {
            $null = $target.CloseMainWindow()
            $deadline = (Get-Date).AddSeconds([math]::Max($GracefulSeconds, 1))
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                try { $target.Refresh() } catch { }
                try { if ($target.HasExited) { return $true } } catch { return $true }
            }
        }
    } catch { }

    try { Stop-Process -Id $target.Id -Force -ErrorAction Stop } catch {
        Write-Verbose ('Stop-Process failed: {0}' -f $_.Exception.Message)
    }
    Start-Sleep -Milliseconds 800
    return (-not [bool](Get-Process -Id $target.Id -ErrorAction SilentlyContinue))
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

    foreach ($proc in $cands) {
        $wsMB = [int][math]::Round($proc.WorkingSet64 / 1MB)
        $path = ''
        $cmd = ''
        try { $path = [string]$proc.Path } catch { }
        try {
            $cmd = [string](Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $proc.Id) -Property CommandLine -ErrorAction SilentlyContinue).CommandLine
        } catch { }
        if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0, 300) + '...' }

        if ($DryRun) {
            Write-Log ('DRY-RUN would kill {0} pid={1} ws={2}MB path={3} cmd={4}' -f $proc.ProcessName, $proc.Id, $wsMB, $path, $cmd)
            return $false
        }

        Write-Log ('ACTION  killing {0} pid={1} ws={2}MB path={3} cmd={4}' -f $proc.ProcessName, $proc.Id, $wsMB, $path, $cmd)

        if (-not (Stop-TargetProcess -Proc $proc)) {
            Write-Log ('ACTION  failed to stop {0} pid={1} (access denied or still busy) - trying next candidate' -f $proc.ProcessName, $proc.Id)
            continue
        }

        Start-Sleep -Seconds 3
        try {
            $after = Get-MemorySample
            Write-Log ('ACTION  stopped {0} pid={1} - avail {2}MB ({3}%) -> {4}MB ({5}%) [delta {6}MB]' -f `
                $proc.ProcessName, $proc.Id, $AvailMB, $AvailPct, $after.AvailMB, $after.AvailPct, ($after.AvailMB - $AvailMB))
            Write-DesktopAlert ('Memory Guard {0}
before: {1} MB free ({2}%)
after : {3} MB free ({4}%)
killed: {5} (pid {6}, {7} MB)
path: {8}
cmd: {9}
log: {10}

If this was something you need, add its name to:
{11}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $AvailMB, $AvailPct, $after.AvailMB, $after.AvailPct, `
                $proc.ProcessName, $proc.Id, $wsMB, $path, $cmd, $LogFile, $ProtectFile)
        } catch { }

        return $true
    }

    Write-Log ('ACTION  all {0} candidate(s) failed - run the guard with more privileges if it must kill elevated processes' -f $cands.Count)
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
    Write-Host ('protected     : {0} names ({1} system critical + {2} from protect file)' -f $protectSet.Count, $SystemProtected.Count, $userProtectedCount)
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
