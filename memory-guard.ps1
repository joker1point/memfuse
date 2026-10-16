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
      * Cooldown between kills + MaxKillsPerHour hard limit. The emergency
        tier (below half the critical line) relaxes both: 3 s cooldown and
        3x the hourly budget, so a machine that is about to hard-freeze is
        not left waiting for the hour to roll.
      * While memory is only in the warn band the guard degrades instead of
        killing: the largest process it is not using goes BelowNormal and its
        working set is trimmed; the priority comes back when memory recovers
        or DemoteHoldSec elapsed (-NoDemote disables that tier).
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
    Minimum seconds between two kills (normal tier). Default 60.

.PARAMETER EmergencyCooldownSec
    Cooldown used in the emergency tier (available memory below half the
    critical line, i.e. < 3.5% by default). Default 3 - with the 5 s sampling
    interval that means "no extra wait". The hourly kill cap is also tripled
    in this tier (MaxKillsPerHour * 3).

.PARAMETER MinCandidateMB
    Never kill a process using less than this many MB. Default 300.

.PARAMETER MaxKillsPerHour
    Hard limit on kills per rolling hour (normal tier). Default 6; the
    emergency tier allows up to three times this.

.PARAMETER NoDemote
    Disable the degrade tier. By default, while memory is only in the warn band
    (below WarnPercent, above the critical line) the guard demotes the largest
    process it is not using right now to BelowNormal and trims its working set
    instead of killing anything. -NoDemote restores the old kill-only
    behaviour.

.PARAMETER DemoteCooldownSec
    Minimum seconds between two demotions. Default 120.

.PARAMETER DemoteHoldSec
    How long a demoted process keeps the lowered priority at most (default
    600 s). The priority is also restored as soon as memory recovers. The
    demoted pids are persisted to <LogDir>\demote-state.txt, so a restarted
    guard puts stranded processes back on startup instead of leaving them
    lowered forever.

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

.PARAMETER Menu
    Show the numbered menu and exit. This is what double-clicking memfuse.cmd
    does, so a first-time user can do the whole setup (dry run -> whitelist ->
    install) by pressing numbers instead of typing commands:
      1 dry run   2 protect list   3 guard toggle   4 process memory   5 kill
    Closing the window quits (0 stays accepted as an unlisted exit key). The
    tray entry is not on the menu - it lives in tray.cmd.
    In a non-interactive shell (no console attached) it prints the usage text
    instead of waiting for input, so nothing can hang.

.PARAMETER MenuInput
    Scripted answers for -Menu, e.g. "2,1,0" (menu choice 2, picker answer 1,
    then quit through the unlisted 0 key). Exists so the test suite can drive
    the menu without a console.

.PARAMETER AddProtect
    Add process names to protect-list.txt and exit. Idempotent, de-duplicated,
    keeps existing comments, writes protect-list.txt.bak first. Example:
    -AddProtect node,code,'Tabbit Browser'

.PARAMETER ListProtected
    Print the effective protection list (built-in system processes + -Protect
    arguments + protect-list.txt) and exit. The tray's "查看保护名单" entry runs
    this in a console window.

.PARAMETER ShowProtectFile
    Print protect-list.txt itself - its path, its numbered content and the three
    supported ways to change it - and exit. The tray's "编辑名单文件" entry runs
    this in a console window (launched with -NoExit, so its prompt stays).
    Toggle a single name with -AddProtect / -RemoveProtect.

.PARAMETER ShowLog
    Print the tail of today's log (how many lines: -LogTail) and exit. The
    tray's "看今天的日志" entry runs this in a console window.

.PARAMETER LogTail
    How many lines -ShowLog prints. Default 60.

.PARAMETER ListWindowed
    List the processes that currently own a visible window - the ones that may
    hold unsaved work - and exit. Use it to build your whitelist before
    letting the guard act.

:.PARAMETER ShowProcMem
    Show how much memory the named process(es) use, then exit. The name is
    matched case-insensitively against the process name (.exe optional), so
    -ShowProcMem chatgpt finds "ChatGPT". Wildcards work (-ShowProcMem 'chat*')
    and several names can be queried at once (-ShowProcMem chatgpt,code).
    Every match is listed with its working set, window title and protected
    status, followed by the total and its share of physical memory. The figure
    is the same working set the guard uses when it picks a victim, so "is it
    the biggest one?" is directly answerable.

:.PARAMETER KillProc
    Manually kill a process you pick from a list, then exit. The list shows
    the processes that own a visible window (what "working or frozen" looks
    like from the outside), frozen ones first, biggest first. Type numbers
    (space separated) to kill those entries, or type a process name to kill
    every match (a hung background process has no window, so the name path
    covers it). Killing requires an explicit y confirmation; anything else
    cancels. Processes on the built-in/whitelist protection list are never
    listed and are refused when named. Windowed processes that still respond
    get a WM_CLOSE first (same -WindowedAction / -GracefulSeconds policy as
    the guard); hung or windowless ones are force-killed right away. The
    hourly kill limit does not apply - that brake protects the machine from
    the guard, not the user from himself. Scripted form: -KillProcInput "1;y"
    (selection ; confirmation).

:.PARAMETER KillProcInput
    Scripted answers for -KillProc: "<selection>;<confirmation>", e.g. "1;y"
    (kill entry 1), "1 3;y", "node;y". The confirmation part is mandatory in
    a non-interactive shell - without it nothing is killed. Exists so the
    test suite can drive the flow without a console.

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
    Log decisions but never kill anything. Would-kills still consume the
    hourly brake (cooldown and cap), so the preview stays faithful.

.PARAMETER Once
    Sample once, print the verdict and exit. Combine with -DryRun to preview
    which process would be killed right now.

.PARAMETER InstallTask
    Register a scheduled task (name: MemoryGuard) that runs this script hidden
    at logon. Also unregisters a previous version. No admin rights required,
    but the task runs with the current user's privileges.

.PARAMETER UninstallTask
    Unregister the MemoryGuard scheduled task and exit. Also removes the
    desktop shortcut, if one was created.

.PARAMETER CreateShortcut
    Put a desktop shortcut ("memfuse 内存保险丝.lnk") next to the user. It
    points at memfuse.cmd, so a later double-click reopens the numbered menu
    without hunting for the extracted folder. -InstallTask does this too.

.PARAMETER RemoveShortcut
    Delete that desktop shortcut and exit.

.PARAMETER ShortcutDir
    Which folder gets the shortcut. Default: the user's Desktop. Mainly for
    tests, so a suite can exercise this without touching the real desktop.

.PARAMETER Tray
    Live in the notification area instead of a window. The console window is
    hidden and an icon appears with a right-click menu (menu / protected list /
    protect-list.txt / today's log / the folder). The tooltip shows the current
    free-memory percentage, so "is it alive" is answerable at a glance.
    Double-clicking the icon opens the menu directly (same action as the first
    right-click entry).

    The X button of a console window cannot be cancelled (Windows kills the
    process a few seconds after CTRL_CLOSE_EVENT no matter what the handler
    does), so closing the window does not "prevent" anything: the process
    relaunches itself hidden - with the same arguments - and the tray stays. If
    the scheduled task is not installed, tray mode also keeps guarding; if the
    task is running, it is a companion only, so two guards never race.

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
    [ValidateRange(0, 3600)][int]$EmergencyCooldownSec = 3,
    [ValidateRange(1, 1048576)][int]$MinCandidateMB = 300,
    [ValidateRange(1, 1000)][int]$MaxKillsPerHour = 6,
    [switch]$NoDemote,
    [ValidateRange(0, 86400)][int]$DemoteCooldownSec = 120,
    [ValidateRange(0, 86400)][int]$DemoteHoldSec = 600,
    [ValidateRange(0, 300)][int]$GracefulSeconds = 15,
    [ValidateSet('Close', 'Skip', 'Force')][string]$WindowedAction = 'Close',
    [ValidateRange(1, 20)][int]$MaxAttemptsPerRound = 5,
    [string[]]$Protect = @(),
    [string]$ProtectFile,
    [string]$LogDir,
    [bool]$DesktopAlert = $true,
    [switch]$PreferIdle,
    [switch]$NoSelfProtect,
    [switch]$DryRun,
    [switch]$Once,
    [string[]]$AddProtect = @(),
    [string[]]$RemoveProtect = @(),
    [switch]$ListProtected,
    [switch]$ListWindowed,
    [switch]$ShowProtectFile,
    [switch]$ShowLog,
    [ValidateRange(1, 10000)][int]$LogTail = 60,
    [string[]]$ShowProcMem = @(),
    [switch]$KillProc,
    [string]$KillProcInput,
    [switch]$Pick,
    [string]$PickInput,
    [switch]$Menu,
    [string]$MenuInput,
    [ValidateSet('safe', 'balanced', 'aggressive')][string]$Preset,
    [switch]$Help,
    [switch]$InstallTask,
    [switch]$UninstallTask,
    [switch]$CreateShortcut,
    [switch]$RemoveShortcut,
    [string]$ShortcutDir,
    [switch]$Tray
)

$ErrorActionPreference = 'Continue'
$TaskName = 'MemoryGuard'

# -Preset is a one-word shortcut for the three common policies, so a user does
# not have to remember parameter names at all:
#   safe       - never force-kill anything that owns a window (data first)
#   balanced   - default: ask it to close, wait, then force kill
#   aggressive - kill immediately (machine first)
if ($Preset) {
    switch ($Preset) {
        'safe' { $WindowedAction = 'Skip'; $GracefulSeconds = 30 }
        'balanced' { $WindowedAction = 'Close'; $GracefulSeconds = 15 }
        'aggressive' { $WindowedAction = 'Force'; $GracefulSeconds = 5 }
    }
}

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
function Get-TitleWidth {
    param([int]$Reserved = 46)
    # Window titles are unbounded, so a row could wrap on a 120-column console
    # and the list became unreadable (seen in real use). Truncate instead of
    # wrapping - the process name is what identifies a row anyway.
    $width = 120
    try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -ge 70) { $width = $w } } catch { }
    return [int][math]::Max(18, $width - $Reserved)
}

function Shorten-Text {
    param([string]$Text, [int]$Max)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return '…' }
    return $Text.Substring(0, $Max - 1) + '…'
}

function Show-ProtectList {
    Write-Host '============ 受保护进程（永不被终止）============'
    Write-Host ('系统内置（杀了会导致蓝屏/注销，共 {0} 项）：' -f $SystemProtected.Count)
    foreach ($name in ($SystemProtected | Sort-Object)) { Write-Host ('    ' + $name) }
    if ($Protect.Count -gt 0) { Write-Host ('来自 -Protect 参数：{0}' -f ($Protect -join ', ')) }
    Write-Host ('来自白名单文件（{0} 项）：{1}' -f $script:fileProtect.Count, $ProtectFile)
    if ($script:fileProtect.Count -gt 0) {
        $running = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { [void]$running.Add((ConvertTo-ProcKey $p.ProcessName)) }
        foreach ($name in ($script:fileProtect | Sort-Object)) {
            $note = if ($running.Contains($name)) { '' } else { '    （当前没有这个进程在运行——拼错了？还是只是没打开？）' }
            Write-Host ('    ' + $name + $note)
        }
    }
    Write-Host '================================================='
}

function Show-ProtectFile {
    # The raw whitelist file the way a console can show it: what is in it, where
    # it is, and the three supported ways to change it. The tray's "编辑名单文件"
    # entry runs this in a console launched with -NoExit, so the prompt stays and
    # the -AddProtect / -RemoveProtect lines below can be pasted straight in.
    try { $Host.UI.RawUI.WindowTitle = 'memfuse · 保护名单文件' } catch { }
    Write-Host ''
    Write-Host ('名单文件：{0}' -f $ProtectFile)
    if (-not (Test-Path -LiteralPath $ProtectFile)) {
        Write-Host '（还没有这个文件——加第一条保护项时会自动创建）'
    } else {
        $lines = @(Get-Content -LiteralPath $ProtectFile -Encoding UTF8)
        Write-Host ('共 {0} 行（# 开头是注释，其余每行一个进程名）：' -f $lines.Count)
        $n = 0
        foreach ($line in $lines) { $n++; Write-Host ('  {0,3}  {1}' -f $n, $line) }
    }
    Write-Host ''
    Write-Host '改它的三种方式（守护每 5 秒重读文件，改完即时生效、不用重启）：'
    Write-Host '  1) 加一项 : memfuse.cmd -AddProtect "进程名"      （多个用逗号分隔）'
    Write-Host '  2) 去一项 : memfuse.cmd -RemoveProtect "进程名"'
    Write-Host '  3) 直接编辑上面那个文件（一行一个名字）'
    Write-Host '  更省事的选择界面：双击 whitelist.cmd（列出有窗口的程序，输编号即可）'
    Write-Host ''
}

function Show-TodayLog {
    # Today's log, tailed: enough to see what the guard just did, without opening
    # an editor on a file that grows all day. -LogTail controls how many lines.
    param([int]$Tail = 60)
    try { $Host.UI.RawUI.WindowTitle = 'memfuse · 今天的日志' } catch { }
    Write-Host ''
    Write-Host ('日志文件：{0}' -f $LogFile)
    if (-not (Test-Path -LiteralPath $LogFile)) {
        Write-Host '（今天还没有日志——守护还没跑过？装上它：memfuse.cmd → 按 3）'
        return
    }
    $lines = @(Get-Content -LiteralPath $LogFile -Encoding UTF8)
    $n = [math]::Min($Tail, $lines.Count)
    Write-Host ('共 {0} 行，下面是最新 {1} 行：' -f $lines.Count, $n)
    Write-Host ''
    if ($n -gt 0) { foreach ($line in $lines[($lines.Count - $n)..($lines.Count - 1)]) { Write-Host $line } }
    Write-Host ''
    Write-Host ('实时跟踪（Ctrl+C 停）：Get-Content -LiteralPath "{0}" -Wait -Tail 20' -f $LogFile)
    Write-Host ''
}

function ConvertTo-NameList {
    # Accept every way names can arrive: -AddProtect node,code from a PowerShell
    # prompt (array), "-AddProtect node,code" through powershell -File (a single
    # literal string), quotes, full-width spaces. Split on , and ; only - never
    # on whitespace, because real process names contain spaces
    # ("Tabbit Browser", "CodeBuddy CN", "Memory Compression").
    param([string[]]$Names)
    $out = @()
    foreach ($entry in $Names) {
        if (-not $entry) { continue }
        foreach ($part in ($entry -split '[,;]+')) {
            $p = $part -replace '["“”'']', ''
            $p = ($p -replace [char]0x3000, ' ').Trim()
            if ($p) { $out += $p }
        }
    }
    return $out
}

function Get-ProtectFileLines {
    if (Test-Path -LiteralPath $ProtectFile) { return @(Get-Content -LiteralPath $ProtectFile -Encoding UTF8) }
    return @('# memfuse 白名单：每行一个进程名（.exe 可省略），# 开头为注释', '')
}

function Set-ProtectEntries {
    param(
        [string[]]$Add = @(),
        [string[]]$Remove = @(),
        [switch]$Quiet
    )

    $lines = @(Get-ProtectFileLines)
    $existing = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($raw in $lines) {
        $entry = ($raw -split '#')[0].Trim()
        if ($entry) { [void]$existing.Add((ConvertTo-ProcKey $entry)) }
    }
    if (Test-Path -LiteralPath $ProtectFile) { Copy-Item -LiteralPath $ProtectFile -Destination ($ProtectFile + '.bak') -Force }

    # Which names actually exist right now? Used to warn about typos instead of
    # failing silently.
    $running = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { [void]$running.Add((ConvertTo-ProcKey $p.ProcessName)) }

    $added = New-Object 'System.Collections.Generic.List[string]'
    $removed = New-Object 'System.Collections.Generic.List[string]'

    foreach ($name in (ConvertTo-NameList -Names $Remove)) {
        $key = ConvertTo-ProcKey $name
        if (-not $key) { continue }
        if (-not $existing.Remove($key)) {
            if (-not $Quiet) {
                if ($protectSet.Contains($key)) { Write-Host ('  = {0}：系统内置保护，不能取消（它被杀会连累系统）' -f $key) }
                else { Write-Host ('  = {0}：不在名单里' -f $key) }
            }
            continue
        }
        $kept = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $lines) {
            $entry = ($line -split '#')[0].Trim()
            if ($entry -and (ConvertTo-ProcKey $entry) -eq $key) { continue }
            $kept.Add($line)
        }
        $lines = @($kept)
        $removed.Add($key)
    }

    foreach ($name in (ConvertTo-NameList -Names $Add)) {
        $key = ConvertTo-ProcKey $name
        if (-not $key) { continue }
        if ($protectSet.Contains($key)) { if (-not $Quiet) { Write-Host ('  = {0}：系统内置保护，不用添加' -f $key) }; continue }
        if (-not $existing.Add($key)) { if (-not $Quiet) { Write-Host ('  = {0}：已在名单里' -f $key) }; continue }
        if (-not $running.Contains($key)) { Write-Host ('  ! {0}：当前没有这个进程在运行——可能拼错了（也可能只是没打开）' -f $key) }
        $lines += $key
        $added.Add($key)
    }

    if ($added.Count -eq 0 -and $removed.Count -eq 0) { if (-not $Quiet) { Write-Host '名单没有变化。' }; return $false }

    # UTF-8 without BOM: a BOM would corrupt the first entry for other readers.
    [IO.File]::WriteAllText($ProtectFile, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    if (-not $Quiet) {
        foreach ($name in $removed) { Write-Host ('  - 取消保护 {0}' -f $name) }
        foreach ($name in $added) { Write-Host ('  + 加入保护 {0}' -f $name) }
        Write-Host ('已写入：{0}' -f $ProtectFile)
        Write-Host '立即生效（守护每 5 秒重读一次，不用重启）。'
    }
    return $true
}

function Get-RecentKillName {
    # Log lines stay English on purpose: they are greppable and the test suite
    # matches on them. Only the interactive screens speak Chinese.
    if (-not (Test-Path -LiteralPath $LogDir)) { return '' }
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return '' }
    $text = Get-Content -LiteralPath $files[0].FullName -Encoding UTF8 -Raw
    $m = [regex]::Matches($text, 'ACTION\s+stopped\s+(\S+)\s+pid=(\d+)')
    if ($m.Count -eq 0) { return '' }
    return $m[$m.Count - 1].Groups[1].Value
}

function Get-WindowedRows {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    $rows = @()
    foreach ($p in ($procs | Sort-Object WorkingSet64 -Descending)) {
        $rows += [pscustomobject]@{
            Name      = $p.ProcessName
            Pid       = $p.Id
            WS_MB     = [int][math]::Round($p.WorkingSet64 / 1MB)
            Title     = $p.MainWindowTitle
            Protected = (Test-Protected $p.ProcessName)
        }
    }
    return $rows
}

function Show-WindowedProcesses {
    Write-Host '=== 拥有可见窗口的进程（它们可能握着没保存的内容）==='
    $rows = @(Get-WindowedRows)
    if ($rows.Count -eq 0) { Write-Host '没找到。'; return }
    $titleWidth = Get-TitleWidth -Reserved 48
    foreach ($r in $rows) {
        $state = if ($r.Protected) { '已保护' } else { '可被杀' }
        $titleText = (Shorten-Text $r.Title $titleWidth).PadRight($titleWidth)
        Write-Host ('  {0}  {1,-24} {2} {3,6} MB' -f $state, $r.Name, $titleText, $r.WS_MB)
    }
    Write-Host ('共 {0} 个。要保护其中某个：双击 whitelist.cmd（看列表、输编号），或 -AddProtect <进程名>' -f $rows.Count)
    Write-Host '  想更省事：-Preset safe —— 有窗口的程序一律不杀，基本不用维护名单。'
}

function Test-ProcNameMatch {
    param([string]$Query, [string]$ProcessName)
    # Matching rules for -ShowProcMem, kept tiny on purpose:
    #   * a .exe suffix on either side is ignored (chatgpt == ChatGPT.exe)
    #   * plain text matches case-insensitively as a substring,
    #     so "chatgpt" finds "ChatGPT" and "code" finds "CodeBuddy CN"
    #   * wildcards pass straight through to -like: "chat*", "c?de" work
    # The process name is what Get-Process returns (never carries .exe), the
    # query is whatever the user typed, so both sides are normalised here.
    if (-not $Query -or -not $ProcessName) { return $false }
    $q = $Query.Trim().Trim('"', "'")
    $p = ($ProcessName -replace '\.exe$', '')
    if (-not $q) { return $false }
    $q = ($q -replace '\.exe$', '')
    if (-not $q) { return $false }
    if ($q -match '[\*\?]') { return ($p -like $q) }
    return ($p.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Show-ProcMemory {
    param([string[]]$Names)

    # Names may arrive as an array (PowerShell prompt) or as one literal
    # "chatgpt,code" string (powershell -File); ConvertTo-NameList handles both.
    $queries = @(ConvertTo-NameList -Names $Names)
    if ($queries.Count -eq 0) {
        Write-Host '用法：-ShowProcMem <进程名>（如 chatgpt、chat*、code,node）'
        return
    }

    $info = Get-MemorySample
    $procs = @(Get-Process -ErrorAction SilentlyContinue)
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $rows = @()
    foreach ($proc in $procs) {
        if (-not $proc.ProcessName) { continue }
        $hit = $false
        foreach ($q in $queries) { if (Test-ProcNameMatch -Query $q -ProcessName $proc.ProcessName) { $hit = $true; break } }
        if (-not $hit) { continue }
        if (-not $seen.Add([int]$proc.Id)) { continue }   # same pid matched by two queries
        $title = ''
        try { $title = [string]$proc.MainWindowTitle } catch { }
        $rows += [pscustomobject]@{
            Name      = $proc.ProcessName
            Pid       = $proc.Id
            WS_MB     = [int][math]::Round($proc.WorkingSet64 / 1MB)
            Title     = $title
            Protected = (Test-Protected $proc.ProcessName)
        }
    }

    $label = ($queries -join '、')
    Write-Host ('=== 进程内存占用：{0} ===' -f $label)
    if ($rows.Count -eq 0) {
        Write-Host ('没有找到名字里含 {0} 的进程（当前 {1} 个进程在运行）。' -f $label, $procs.Count)
        Write-Host '  可能是拼写问题；换个写法试试：'
        Write-Host '    -ShowProcMem chat*        通配符（* 和 ? 都支持）'
        Write-Host '    -ShowProcMem code,node    一次查多个名字'
        Write-Host '    -ListWindowed             看看当前有窗口的进程都有谁'
        return
    }

    $rows = @($rows | Sort-Object WS_MB -Descending)
    $titleWidth = Get-TitleWidth -Reserved 58
    foreach ($r in $rows) {
        $state = if ($r.Protected) { '已保护' } else { '可被杀' }
        $line = '  {0}  {1,-26} pid={2,-7} {3,6} MB' -f $state, $r.Name, $r.Pid, $r.WS_MB
        if ($r.Title) { $line += '  ' + (Shorten-Text $r.Title $titleWidth) }
        Write-Host $line
    }
    $totalMB = [int](($rows | Measure-Object -Property WS_MB -Sum).Sum)
    $sharePct = [math]::Round((100.0 * $totalMB / [math]::Max([long]$info.TotalMB, 1)), 1)
    Write-Host ('共 {0} 个进程，工作集合计 {1} MB（占物理内存 {2}%）。' -f $rows.Count, $totalMB, $sharePct)
    Write-Host '  口径：工作集 WorkingSet，与守护挑进程时用的是同一个数；'
    Write-Host '  「已保护」= 守护永远不会终止它（想改：双击 whitelist.cmd）。'
}

# ---------------------------------------------------------------------------
# -KillProc: the user kills a process by hand (the guard's opposite number)
#
# The guard decides alone under memory pressure; this is the deliberate,
# confirmed version. It reuses the guard's two safety ideas instead of
# inventing weaker ones:
#   * the same protection list (system critical + protect-list.txt) decides
#     what may never appear as a target - protected names are not listed and
#     are refused when typed;
#   * the same Stop-TargetProcess policy applies (WM_CLOSE first for a
#     windowed process that still responds, force kill for the rest).
# One difference is deliberate: a process that stopped responding cannot
# process WM_CLOSE anyway, so its graceful wait is capped at 3s - waiting
# 15s for a save dialog that will never appear only wastes the user's time.
# ---------------------------------------------------------------------------
function Get-KillCandidateRows {
    param(
        [string[]]$Names = @(),
        [switch]$WindowedOnly
    )
    # Two sources, one row shape:
    #   no names    -> processes that own a visible window ("working or
    #                  frozen", as visible from the outside)
    #   names given -> every process whose name matches (-ShowProcMem rules),
    #                  windowed or not: a hung background process has no
    #                  window, so the list alone would never offer it
    # Both drop what the guard never touches: built-in/whitelist protected
    # names, this script's own process chain, and the system pseudo-processes.
    $rows = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -le 4) { continue }
        if (-not $p.ProcessName) { continue }
        if (Test-Protected $p.ProcessName) { continue }
        if ($script:SelfChain -and $script:SelfChain.Contains([int]$p.Id)) { continue }
        if ($Names.Count -gt 0) {
            $hit = $false
            foreach ($q in $Names) { if (Test-ProcNameMatch -Query $q -ProcessName $p.ProcessName) { $hit = $true; break } }
            if (-not $hit) { continue }
        } elseif ($WindowedOnly) {
            $hasWindow = $false
            try { $hasWindow = ($p.MainWindowHandle -ne [IntPtr]::Zero) } catch { }
            if (-not $hasWindow) { continue }
        }
        $hung = $false
        try { $hung = -not $p.Responding } catch { }
        $title = ''
        try { $title = [string]$p.MainWindowTitle } catch { }
        $rows += [pscustomobject]@{
            Name  = $p.ProcessName
            Pid   = $p.Id
            WS_MB = [int][math]::Round($p.WorkingSet64 / 1MB)
            Title = $title
            Hung  = $hung
            Proc  = $p
        }
    }
    # frozen first - they are the reason this feature exists - then biggest
    return @($rows | Sort-Object @{Expression = 'Hung'; Descending = $true }, @{Expression = 'WS_MB'; Descending = $true })
}

function Show-KillList {
    param([array]$Rows)
    Write-Host '=== 可以强杀的进程（带窗口的；无响应的排在最前面）==='
    Write-Host '（系统关键进程和白名单里的进程不在此列——它们本来就不该被强杀）'
    if ($Rows.Count -eq 0) {
        Write-Host '  当前没有符合条件的进程（也可以直接输进程名——后台卡死的进程没有窗口）。'
        return
    }
    $titleWidth = Get-TitleWidth -Reserved 60
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $r = $Rows[$i]
        $flag = if ($r.Hung) { '[无响应]' } else { '[      ]' }
        $titleText = if ($r.Title) { '  ' + (Shorten-Text $r.Title $titleWidth) } else { '' }
        Write-Host ('  {0} {1,2}. {2,-24} pid={3,-7} {4,6} MB{5}' -f $flag, ($i + 1), $r.Name, $r.Pid, $r.WS_MB, $titleText)
    }
    Write-Host ''
    Write-Host '输入编号（空格分隔可多个）终止对应进程；也可以直接输进程名（如 node）终止所有匹配项；直接回车 = 取消'
}

function Select-KillTargets {
    param(
        [array]$Rows,
        [string]$Selection
    )
    # "1 3" picks entries from the printed list; anything else is a process
    # name (all matches). Returns the chosen rows plus notices for what was
    # ignored or refused - kept apart from the killing code so the mapping
    # can be tested on its own (tests/kill-proc.ps1).
    $targets = @()
    $notices = @()
    $numbers = @()
    $names = @()
    foreach ($token in ($Selection -split '[\s,]+')) {
        if (-not $token) { continue }
        $n = 0
        if ([int]::TryParse($token, [ref]$n)) { $numbers += $n } else { $names += $token }
    }
    foreach ($n in $numbers) {
        if ($n -lt 1 -or $n -gt $Rows.Count) { $notices += ('  ! 编号 {0} 超范围，已忽略' -f $n); continue }
        $targets += $Rows[$n - 1]
    }
    if ($names.Count -gt 0) {
        foreach ($name in (ConvertTo-NameList -Names $names)) {
            $matched = @(Get-KillCandidateRows -Names @($name))
            if ($matched.Count -eq 0) {
                # "no such process" and "it is protected" must not look alike
                $blocked = @()
                foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
                    if ($p.ProcessName -and (Test-ProcNameMatch $name $p.ProcessName) -and (Test-Protected $p.ProcessName)) { $blocked += $p.ProcessName }
                }
                if ($blocked.Count -gt 0) {
                    $notices += ('  = {0}：在保护名单里，不能杀（系统关键进程或你加过白的）' -f $name)
                } else {
                    $notices += ('  = {0}：没有找到匹配的进程' -f $name)
                }
                continue
            }
            $targets += $matched
        }
    }
    $seenPid = New-Object 'System.Collections.Generic.HashSet[int]'
    $unique = @()
    foreach ($t in $targets) { if ($seenPid.Add([int]$t.Pid)) { $unique += $t } }
    return [pscustomobject]@{ Targets = @($unique); Notices = @($notices) }
}

function Stop-ManualTarget {
    param([pscustomobject]$Row)
    # Same evidence trail as the guard's own kills: path + full command line,
    # so "what did I just kill" stays answerable afterwards.
    $proc = $Row.Proc
    $wsMB = $Row.WS_MB
    $path = ''
    $cmd = ''
    try { $path = [string]$proc.Path } catch { }
    try {
        $cmd = [string](Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $Row.Pid) -Property CommandLine -ErrorAction SilentlyContinue).CommandLine
    } catch { }
    if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0, 300) + '...' }
    Write-Log ('MANUAL  killing {0} pid={1} ws={2}MB path={3} cmd={4}' -f $Row.Name, $Row.Pid, $wsMB, $path, $cmd)
    $verdict = Stop-TargetProcess -Proc $proc -Emergency:$Row.Hung
    switch ($verdict) {
        'skipped' {
            Write-Log ('MANUAL  skipped {0} pid={1} ws={2}MB owns a window and did not close itself - left alone (WindowedAction=Skip keeps unsaved work)' -f $Row.Name, $Row.Pid, $wsMB)
            Write-Host ('  跳过 {0} pid={1}：有窗口且没自己关，当前策略是「有窗口不杀」' -f $Row.Name, $Row.Pid)
        }
        'failed' {
            Write-Log ('MANUAL  failed to stop {0} pid={1} (access denied or still busy)' -f $Row.Name, $Row.Pid)
            Write-Host ('  失败 {0} pid={1}：没有权限或仍在忙（提权进程需要以管理员身份运行）' -f $Row.Name, $Row.Pid)
        }
        default {
            Write-Log ('MANUAL  stopped {0} pid={1} ws={2}MB' -f $Row.Name, $Row.Pid, $wsMB)
            Write-Host ('  已终止 {0} pid={1}（{2} MB）' -f $Row.Name, $Row.Pid, $wsMB)
        }
    }
    return ($verdict -eq 'stopped')
}

function Invoke-KillProc {
    param(
        [string]$Selection,
        [string]$Confirm
    )

    $rows = @(Get-KillCandidateRows -WindowedOnly)
    Show-KillList -Rows $rows

    $interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
    if (-not $Selection -and -not $interactive) {
        Write-Host '（当前没有可交互的控制台，也未提供 -KillProcInput，已取消）'
        return
    }
    if (-not $Selection) { $Selection = [string](Read-Host '编号或进程名') }
    if (-not $Selection.Trim()) { Write-Host '已取消，什么都没杀。'; return }

    $picked = Select-KillTargets -Rows $rows -Selection $Selection
    foreach ($note in $picked.Notices) { Write-Host $note }
    $targets = @($picked.Targets)
    if ($targets.Count -eq 0) { Write-Host '没有可终止的目标，已取消。'; return }

    Write-Host ''
    Write-Host ('即将终止 {0} 个进程：' -f $targets.Count)
    foreach ($t in $targets) {
        $flag = if ($t.Hung) { '（无响应）' } else { '' }
        Write-Host ('  {0}  pid={1}  {2} MB{3}' -f $t.Name, $t.Pid, $t.WS_MB, $flag)
    }
    Write-Host '未保存的工作会丢。有窗口且仍在响应的进程会先收到关闭请求。'

    # No confirmation in a non-interactive shell means no kill - the safe
    # default, so a script can never destroy something by forgetting a flag.
    if (-not $Confirm -and -not $interactive) {
        Write-Host '（未提供确认，已取消——强杀必须显式确认）'
        Write-Log 'MANUAL  aborted (no confirmation given)'
        return
    }
    if (-not $Confirm) { $Confirm = [string](Read-Host '确认终止吗？输入 y 回车（其它内容 = 取消）') }
    if (@('y', 'yes', '是') -notcontains $Confirm.Trim().ToLower()) {
        Write-Host '已取消，什么都没杀。'
        Write-Log 'MANUAL  aborted by user'
        return
    }

    $before = Get-MemorySample
    $killed = 0
    foreach ($t in $targets) {
        if (Stop-ManualTarget -Row $t) { $killed++ }
    }
    if ($killed -gt 0) {
        Start-Sleep -Seconds 3
        try {
            $after = Get-MemorySample
            Write-Host ('可用内存 {0} MB（{1}%）→ {2} MB（{3}%）[delta {4}MB]' -f $before.AvailMB, $before.AvailPct, $after.AvailMB, $after.AvailPct, ($after.AvailMB - $before.AvailMB))
            Write-Log ('MANUAL  done ({0} stopped): avail {1}MB ({2}%) -> {3}MB ({4}%) [delta {5}MB]' -f $killed, $before.AvailMB, $before.AvailPct, $after.AvailMB, $after.AvailPct, ($after.AvailMB - $before.AvailMB))
        } catch { }
    } else {
        Write-Host '没有任何进程被终止。'
        Write-Log 'MANUAL  done (nothing stopped)'
    }
}

function Show-Usage {
    Write-Host ''
    Write-Host 'memfuse —— 内存临界前的最后防线（在系统卡死之前，终止占用最大的那个进程）'
    Write-Host ''
    Write-Host '第一次用，最省事的走法：双击 memfuse.cmd，出现数字菜单，按 1 → 2 → 3。'
    Write-Host ''
    Write-Host '想敲命令的话，按这个顺序：'
    Write-Host '  1) 先演练（什么都不杀，只看它想杀谁）'
    Write-Host '        memfuse.cmd -Once -DryRun'
    Write-Host '  2) 把你在乎的程序保护起来（双击 whitelist.cmd 最省事）'
    Write-Host '        whitelist.cmd                       看列表、输入编号即可'
    Write-Host '        memfuse.cmd -AddProtect 微信,Code'
    Write-Host '        memfuse.cmd -RemoveProtect 微信     取消保护'
    Write-Host '  3) 装上守护（登录自启 + 每 5 分钟心跳自愈，不需要管理员）'
    Write-Host '        memfuse.cmd -InstallTask'
    Write-Host ''
    Write-Host '三档预设（不知道选哪个就 balanced）：'
    Write-Host '  -Preset safe         有窗口的程序一律不杀（数据优先，名单几乎不用维护）'
    Write-Host '  -Preset balanced     先请它自己关，等不到就强杀（默认）'
    Write-Host '  -Preset aggressive   直接强杀（机器优先）'
    Write-Host ''
    Write-Host '其他常用：-ListWindowed 谁有窗口 | -ListProtected 现有名单 | -UninstallTask 卸载'
    Write-Host '  查进程内存  : memfuse.cmd -ShowProcMem chatgpt   看指定进程占多少内存'
    Write-Host '                 （名字大小写无所谓；支持通配符 chat*、一次多个 code,node）'
    Write-Host '  强杀指定进程: memfuse.cmd -KillProc   列出可杀的进程，输编号或名字，确认后终止'
    Write-Host ''
}

# ---------------------------------------------------------------------------
# the double-click menu: the whole first-time setup behind single digits
# ---------------------------------------------------------------------------
function Show-Menu {
    param([string]$Scripted)

    # -MenuInput "2,1,0" = menu choice 2, let the picker answer 1, then quit.
    # 0 is no longer listed on the menu (closing the window quits), but it stays
    # a valid answer so scripted runs keep working.
    # Without a console the menu prints the usage text instead of waiting for
    # input, so nothing can ever hang in an automated context.
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    if ($Scripted) {
        foreach ($part in ($Scripted -split '[,;\s]+')) { if ($part.Trim()) { $queue.Enqueue($part.Trim()) } }
    }

    while ($true) {
        Update-ProtectFileSet
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $state = if ($task) { '已安装（{0}）' -f $task.State } else { '未安装' }

        Write-Host ''
        Write-Host '================ memfuse（内存保险丝）================'
        Write-Host ('  当前：守护 {0} ｜ 白名单 {1} 项' -f $state, $script:fileProtect.Count)
        Write-Host '  现在什么都没启动 —— 下面的动作都是你自己按出来的。'
        Write-Host ''
        Write-Host '   1  先演练一次（什么都不杀，只看它想杀谁）'
        Write-Host '   2  保护名单（看 / 加 / 删：列表里输编号，含"没在运行"检查）'
        Write-Host '   3  守护开关（已安装 → 卸载；未安装 → 安装）'
        Write-Host '   4  查进程内存占用（输入名字，如 chatgpt）'
        Write-Host '   5  强杀指定进程（列出可杀的进程，输编号或名字，确认后终止）'
        Write-Host ''
        Write-Host '  退出：直接关闭窗口（想让图标常驻通知区：双击 tray.cmd）'
        Write-Host ''

        $answer = ''
        if ($queue.Count -gt 0) {
            $answer = $queue.Dequeue()
            Write-Host ('请输入数字（1-5），回车确认： {0}' -f $answer)
        } elseif ([Console]::IsInputRedirected) {
            Show-Usage
            return
        } else {
            $answer = [string](Read-Host '请输入数字（1-5），回车确认')
        }

        switch ($answer.Trim()) {
            '0' { Write-Host ''; Write-Host '已退出。什么都没启动 —— 双击 memfuse.cmd 可以随时回到这里。'; return }
            '1' {
                Write-Host ''
                Write-Host '>>> 演练：只看不动手，什么都不杀'
                & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Once -DryRun
                Write-Host '>>> 演练结束：上面那句 "would kill ..." 就是"如果它真动手，会挑谁"。'
                Write-Host '    （如果只看到一行 started，说明此刻内存正常、它无事可做 —— 这是好事。）'
            }
            '2' {
                Write-Host ''
                Write-Host '>>> 保护名单：列表里选谁就保护谁（对同一个编号再选一次 = 取消保护）'
                if ($queue.Count -gt 0) { Invoke-PickWhitelist -Answer $queue.Dequeue() }
                elseif ([Console]::IsInputRedirected) { Write-Host '（当前没有可交互的控制台，已跳过）' }
                else { Invoke-PickWhitelist }
            }
            '3' {
                Write-Host ''
                if ($task) {
                    Write-Host '>>> 守护开关：当前已安装 → 卸载'
                    $yes = ''
                    if ($queue.Count -gt 0) { $yes = $queue.Dequeue() }
                    elseif ([Console]::IsInputRedirected) { Write-Host '（当前没有可交互的控制台，已跳过卸载）'; continue }
                    else { $yes = [string](Read-Host '确定卸载吗？输入 y 回车（其它内容 = 取消）') }
                    if (@('y', 'yes', '是') -contains $yes.Trim().ToLower()) { Write-Host ''; Uninstall-GuardTask }
                    else { Write-Host '已取消，什么都没变。' }
                } else {
                    Write-Host '>>> 守护开关：当前未安装 → 安装'
                    Install-GuardTask
                    Write-Host '>>> 装好了。现在可以关掉这个窗口 —— 之后它自己会跑。'
                    Write-Host '    以后改白名单：双击桌面上那个「memfuse 内存保险丝」快捷方式，按 2 就行。'
                }
            }
            '4' {
                Write-Host ''
                Write-Host '>>> 查进程内存占用（输入进程名，如 chatgpt；支持通配符 chat*，多个用逗号分隔；直接回车 = 取消）'
                $name = ''
                if ($queue.Count -gt 0) { $name = $queue.Dequeue(); Write-Host ('进程名： {0}' -f $name) }
                elseif ([Console]::IsInputRedirected) { Write-Host '（当前没有可交互的控制台，已跳过）' }
                else { $name = [string](Read-Host '进程名') }
                if ($name.Trim()) { Show-ProcMemory -Names $name }
                else { Write-Host '已取消，什么都没查。' }
            }
            '5' {
                Write-Host ''
                Write-Host '>>> 强杀指定进程（列表里输编号；也可以直接输进程名）'
                $sel = ''
                $cfm = ''
                if ($queue.Count -gt 0) { $sel = $queue.Dequeue(); Write-Host ('选择： {0}' -f $sel) }
                if ($queue.Count -gt 0) { $cfm = $queue.Dequeue(); Write-Host ('确认： {0}' -f $cfm) }
                Invoke-KillProc -Selection $sel -Confirm $cfm
            }
            default { Write-Host ('没看懂「{0}」—— 请输入 1 到 5 之间的数字（退出：直接关闭窗口）。' -f $answer) }
        }

        if ($queue.Count -eq 0 -and -not [Console]::IsInputRedirected) { $null = Read-Host '（按回车回到菜单）' }
    }
}

function Invoke-PickWhitelist {
    param([string]$Answer)

    # Only show what the user can actually change: processes protected by the
    # built-in system list (explorer, svchost, ...) must never be listed here -
    # picking one can only produce a confusing "cannot change that" answer.
    $rows = @(Get-WindowedRows | Where-Object { -not $protectSet.Contains((ConvertTo-ProcKey $_.Name)) })
    Write-Host ''
    Write-Host '=== memfuse 保护名单：列表里选谁就保护谁（被保护的永不被终止）==='
    Write-Host ('（系统内置 {0} 项不在此列——它们本来就杀不得）' -f $SystemProtected.Count)
    $runningNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { [void]$runningNames.Add((ConvertTo-ProcKey $p.ProcessName)) }
    if ($script:fileProtect.Count -gt 0) {
        $names = @($script:fileProtect | Sort-Object)
        $idle = @($names | Where-Object { -not $runningNames.Contains($_) })
        $suffix = if ($idle.Count -gt 0) { ('；当前没在运行：{0}（拼错了？还是只是没打开？）' -f ($idle -join '、')) } else { '；当前都在运行' }
        Write-Host ('名单文件 {0} 项：{1}{2}' -f $names.Count, ($names -join '、'), $suffix)
    } else {
        Write-Host '名单文件还是空的——下面列表里选编号就能加。'
    }
    $recent = Get-RecentKillName
    if ($recent) { Write-Host ('上次被守护终止的是：{0}（如果这是你在用的，建议保护它）' -f $recent) }
    Write-Host ''
    if ($rows.Count -eq 0) { Write-Host '当前没有带窗口的程序，没什么可选的。'; return }
    $titleWidth = Get-TitleWidth -Reserved 52
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $state = if ($r.Protected) { '[已保护]' } else { '[      ]' }
        $flag = if ($recent -and ((ConvertTo-ProcKey $r.Name) -eq (ConvertTo-ProcKey $recent))) { '   <= 上次被杀的' } else { '' }
        $titleText = (Shorten-Text $r.Title $titleWidth).PadRight($titleWidth)
        Write-Host ('  {0} {1,2}. {2,-24} {3} {4,6} MB{5}' -f $state, ($i + 1), $r.Name, $titleText, $r.WS_MB, $flag)
    }
    Write-Host ''
    Write-Host '输入编号（空格分隔，回车结束；直接回车 = 取消；对已保护的项输入编号 = 取消保护）'

    if (-not $Answer) {
        if (-not [Environment]::UserInteractive) { return }
        $Answer = Read-Host '编号'
    }
    if (-not $Answer.Trim()) { Write-Host '已取消，名单没变。'; return }

    $add = @()
    $remove = @()
    foreach ($token in ($Answer -split '[\s,]+')) {
        if (-not $token) { continue }
        $n = 0
        if (-not [int]::TryParse($token, [ref]$n)) { Write-Host ('  ! 看不懂这个输入，已忽略：{0}' -f $token); continue }
        if ($n -lt 1 -or $n -gt $rows.Count) { Write-Host ('  ! 编号超范围，已忽略：{0}' -f $n); continue }
        $r = $rows[$n - 1]
        if ($r.Protected) { $remove += $r.Name } else { $add += $r.Name }
    }
    if ($add.Count -eq 0 -and $remove.Count -eq 0) { Write-Host '没有可应用的改动。'; return }
    [void](Set-ProtectEntries -Add $add -Remove $remove)
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

# ---------------------------------------------------------------------------
# -PreferIdle: choosing a victim that the user is not working in
#
# Freeing memory is still the job, so the working set stays the base of the
# score. On top of it, three cheap signals say "the user is probably not working
# in this right now": it is not the foreground window, its window is minimised,
# or it used almost no CPU during the last sampling interval. Each one discounts
# the candidate, so a large unused process beats an equally large one the user is
# looking at - without ever preferring a tiny process just because it is idle.
# Every discount is recorded and logged, so a kill can always be explained.
# ---------------------------------------------------------------------------
Add-Type -Namespace MemGuard -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
'@

function Get-ForegroundPid {
    try {
        $h = [MemGuard.Win]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return 0 }
        $fgPid = 0
        [void][MemGuard.Win]::GetWindowThreadProcessId($h, [ref]$fgPid)
        return [int]$fgPid
    } catch {
        return 0
    }
}

function Get-ForegroundName {
    # Process name of the window you are working in right now. Everything that
    # carries this name is out of reach while it is in the foreground - see
    # Remove-ForegroundApp.
    $fgPid = Get-ForegroundPid
    if ($fgPid -eq 0) { return '' }
    try {
        $p = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
        if ($p) { return [string]$p.ProcessName }
    } catch { }
    return ''
}

function Remove-ForegroundApp {
    # Drop every candidate belonging to the app you are looking at right now.
    #
    # Checking the pid is not enough: a browser owns its window in the main
    # process, while the page you are reading lives in a *child* process with
    # the same name. A pid-only rule happily kills the very tab you have open
    # (2026-10-16: the guard shot a Tabbit renderer twice in one afternoon), so
    # the whole same-named family is skipped instead. The kill path, the demote
    # tier and the dry-run preview all enumerate through Get-Candidates, so this
    # is the one place to enforce it. Nothing is shielded permanently: once the
    # window goes to the background, the app is a candidate again.
    param([array]$List, [string]$ForegroundName)
    if (-not $ForegroundName) { return $List }
    return @($List | Where-Object { $_.ProcessName -ne $ForegroundName })
}

function Update-CpuSnapshot {
    # One dictionary per sampling tick; the difference between two ticks is what
    # tells whether a process was actually doing work.
    $snap = @{}
    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            try { $snap[[int]$p.Id] = [double]$p.TotalProcessorTime.TotalSeconds } catch { }
        }
    } catch { }
    $script:cpuPrev = $script:cpuNow
    $script:cpuNow = $snap
}

function Get-VictimScore {
    param(
        [long]$WorkingSet64,
        [switch]$Foreground,
        [switch]$Minimized,
        [switch]$Busy,
        [switch]$CpuKnown
    )
    # Discounts stay mild for "working" signals on purpose: a build or an encode
    # in the background still deserves to survive, but a 900MB busy process must
    # not lose to a 500MB idle one - relieving memory is still the job. Only the
    # foreground window gets a hard discount: that is the app the user is typing
    # into right now.
    $score = [double]$WorkingSet64
    if ($Minimized) { $score *= 0.7 }
    if ($CpuKnown -and $Busy) { $score *= 0.7 }
    if ($Foreground) { $score *= 0.2 }
    return [math]::Round($score)
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
    # Whatever app owns the foreground window right now (whole name family) is
    # not a candidate at all - neither for a kill nor for a demotion.
    $list = @(Remove-ForegroundApp -List $list -ForegroundName (Get-ForegroundName))
    if (-not $PreferIdle) {
        return @($list | Sort-Object WorkingSet64 -Descending | Select-Object -First $TopN)
    }

    # -PreferIdle: score every candidate and remember why, so the log can show it.
    $fgPid = Get-ForegroundPid
    $busySeconds = 0.3 * $IntervalSec
    $script:lastPickReason = @{}
    $scored = @($list | ForEach-Object {
        $minimized = $false
        try { $minimized = ($_.MainWindowHandle -ne [IntPtr]::Zero -and [MemGuard.Win]::IsIconic($_.MainWindowHandle)) } catch { }
        $known = $false
        $busy = $false
        if ($script:cpuNow -and $script:cpuPrev -and
            $script:cpuNow.ContainsKey([int]$_.Id) -and $script:cpuPrev.ContainsKey([int]$_.Id)) {
            $known = $true
            $busy = (($script:cpuNow[[int]$_.Id] - $script:cpuPrev[[int]$_.Id]) -ge $busySeconds)
        }
        $isForeground = ($_.Id -eq $fgPid)
        $reason = @()
        if ($isForeground) { $reason += 'foreground' }
        if ($minimized) { $reason += 'minimized' }
        if ($known) { $reason += $(if ($busy) { 'cpu-busy' } else { 'cpu-idle' }) } else { $reason += 'cpu-unknown' }
        $script:lastPickReason[[int]$_.Id] = ($reason -join ',')
        [pscustomobject]@{
            Proc  = $_
            Score = Get-VictimScore -WorkingSet64 $_.WorkingSet64 -Foreground:$isForeground -Minimized:$minimized -Busy:$busy -CpuKnown:$known
        }
    })
    return @($scored | Sort-Object Score -Descending | Select-Object -First $TopN | ForEach-Object { $_.Proc })
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
        $tag = ''
        if ($PreferIdle -and $script:lastPickReason -and $script:lastPickReason.ContainsKey([int]$_.Id)) {
            $tag = '[' + $script:lastPickReason[[int]$_.Id] + ']'
        }
        '{0}#{1}={2}MB{3}' -f $_.ProcessName, $_.Id, [int][math]::Round($_.WorkingSet64 / 1MB), $tag
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

        $why = ''
        if ($PreferIdle -and $script:lastPickReason -and $script:lastPickReason.ContainsKey([int]$proc.Id)) {
            $why = ' reason=' + $script:lastPickReason[[int]$proc.Id]
        }

        if ($DryRun) {
            $note = if ($windowed) { ' [has a window -> WindowedAction=' + $WindowedAction + ']' } else { '' }
            Write-Log ('DRY-RUN would kill {0} pid={1} ws={2}MB path={3} cmd={4}{5}{6}' -f $procName, $proc.Id, $wsMB, $path, $cmd, $note, $why)
            # Count the would-kill against the hourly brake exactly like a real
            # kill would: a preview that never consumes the budget would lie
            # about how many times the guard is still willing to act.
            return $true
        }

        Write-Log ('ACTION  killing {0} pid={1} ws={2}MB path={3} cmd={4}{5}' -f $procName, $proc.Id, $wsMB, $path, $cmd, $why)

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
            Write-DesktopAlert ('memfuse 内存守护  {0}
──────────────────────────────────────────
可用内存：{1} MB（{2}%）→ {3} MB（{4}%）
被终止的进程：{5}（PID {6}，{7} MB）
程序路径：{8}
启动命令：{9}
本次日志：{10}
──────────────────────────────────────────
如果这个程序你需要，别让它再被杀：
  双击 whitelist.cmd → 在列表里找到 {5} → 输入对应编号
（白名单改完立即生效，不用重启守护）' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $AvailMB, $AvailPct, $after.AvailMB, $after.AvailPct, `
                $procName, $proc.Id, $wsMB, $path, $cmd, $LogFile)
        } catch { }

        return $true
    }

    if ($skipped -gt 0) {
        Write-Log ('ACTION  nothing done: {0} candidate(s) left alone (windowed, WindowedAction=Skip), the rest failed - machine stays tight by design' -f $skipped)
        Write-DesktopAlert ('memfuse 内存守护  {0}
──────────────────────────────────────────
内存仍然紧张，但所有候选都被放过了。
原因：{1} 个有窗口的进程被跳过（当前策略是「有窗口不杀」）
你可以：关掉占内存的程序，或换成机器优先的策略：
  memfuse.cmd -Preset aggressive -InstallTask
──────────────────────────────────────────' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $skipped)
    } else {
        Write-Log ('ACTION  all {0} candidate(s) failed - run the guard with more privileges if it must kill elevated processes' -f $cands.Count)
    }
    return $false
}

function Show-Config {
    $info = Get-MemorySample
    Write-Host '==================== memfuse 内存守护 ===================='
    Write-Host ('运行模式    : {0}' -f ($(if ($DryRun) { '演练（什么都不杀）' } else { '实战（会终止进程）' })))
    Write-Host ('物理内存    : {0} MB' -f $info.TotalMB)
    Write-Host ('当前        : 可用 {0} MB（{1}%），提交内存 {2}%' -f $info.AvailMB, $info.AvailPct, $info.CommitPct)
    Write-Host ('阈值        : 警告 < {0}%  临界 < {1}%  连续 {2} 次 × {3}s（紧急 < {4}%）' -f `
        $WarnPercent, $CriticalPercent, $SustainSamples, $IntervalSec, [math]::Round($CriticalPercent / 2.0, 1))
    Write-Host ('刹车        : 冷却 {0}s，每小时最多 {1} 次，候选不小于 {2} MB' -f $CooldownSec, $MaxKillsPerHour, $MinCandidateMB)
    Write-Host ('紧急档      : 可用 < {0}% 时冷却压到 {1}s、上限放宽到 {2}/h（要堵死时优先救回来）' -f [math]::Round($CriticalPercent / 2.0, 1), $EmergencyCooldownSec, ($MaxKillsPerHour * 3))
    if ($NoDemote) {
        Write-Host '降级档      : 已关闭（-NoDemote）'
    } else {
        Write-Host ('降级档      : 可用 < {0}% 时把最大的非前台进程降到 BelowNormal + 回收工作集（不杀；内存恢复或 {1}s 后还原）' -f $WarnPercent, $DemoteHoldSec)
    }
    Write-Host ('受保护      : 共 {0} 项（系统内置 {1} + 用户白名单 {2}）' -f ($protectSet.Count + $script:fileProtect.Count), $SystemProtected.Count, (($protectSet.Count - $SystemProtected.Count) + $script:fileProtect.Count))
    Write-Host ('有窗口的进程: {0}（宽限期 {1}s，紧急档 {2}s）' -f $WindowedAction, [math]::Max($GracefulSeconds, 1), [math]::Min([math]::Max($GracefulSeconds, 1), 3))
    Write-Host ('选择策略    : {0}' -f ($(if ($PreferIdle) { '优先挑未在使用（体积 × 使用信号折扣）' } else { '谁大挑谁（默认）' })))
    if ($script:SelfChain.Count -gt 0) {
        Write-Host ('自我保护    : pid {0}（守护自身及启动它的链）' -f (($script:SelfChain | Sort-Object) -join ', '))
    } else {
        Write-Host '自我保护    : 关闭 —— 守护自身没有任何额外保护'
    }
    Write-Host ('日志        : {0}' -f $LogFile)
    Write-Host '=========================================================='
}

# ---------------------------------------------------------------------------
# scheduled task management
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# desktop shortcut: one double-click to come back here (whitelist edits)
# ---------------------------------------------------------------------------
function Get-ShortcutPath {
    $dir = $ShortcutDir
    if (-not $dir) { $dir = [Environment]::GetFolderPath('Desktop') }
    if (-not $dir) { return $null }
    return (Join-Path $dir 'memfuse 内存保险丝.lnk')
}

function Set-Shortcut {
    param([switch]$Remove)

    $lnk = Get-ShortcutPath
    if (-not $lnk) { Write-Host 'WARN  找不到桌面目录，已跳过快捷方式'; return }
    $dir = Split-Path -Parent $lnk
    if (-not (Test-Path -LiteralPath $dir)) { Write-Host ('WARN  目录不存在，已跳过：{0}' -f $dir); return }

    if ($Remove) {
        if (-not (Test-Path -LiteralPath $lnk)) { Write-Host '没有快捷方式需要删除（本来就没有）'; return }
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $lnk) { Write-Host ('WARN  删不掉：{0}' -f $lnk) }
        else { Write-Host ('已删除快捷方式：{0}' -f $lnk) }
        return
    }

    # Point at the launcher when it sits next to this script; otherwise fall
    # back to powershell.exe so a standalone memory-guard.ps1 still works.
    # Never ship a .lnk file inside the repo: a shortcut stores an absolute
    # path, so one built on another machine would be a dead link.
    $cmd = Join-Path $PSScriptRoot 'memfuse.cmd'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    if (Test-Path -LiteralPath $cmd) {
        $sc.TargetPath = $cmd
        $sc.Arguments = ''
    } else {
        $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $sc.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Menu' -f $PSCommandPath)
    }
    $sc.WorkingDirectory = $PSScriptRoot
    $sc.Description = 'memfuse 内存保险丝：双击打开菜单（保护程序 / 看名单 / 卸载）'
    try {
        $sc.Save()
        Write-Host ('快捷方式已就位：{0}' -f $lnk)
        Write-Host '  以后改白名单：双击它 → 按 2。不用再找这个文件夹。'
    } catch {
        Write-Host ('WARN  快捷方式创建失败：{0}' -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# tray mode / close-to-background
#
# Two hard facts drive the design:
#   1. A console window's X cannot be cancelled. Windows sends
#      CTRL_CLOSE_EVENT, waits for the handler, then terminates the process
#      anyway. So "minimise to tray" is implemented as: spawn an equivalent
#      hidden instance and let this one die.
#   2. Two guards killing at the same time would double the kills, so tray mode
#      only guards when the scheduled task is absent.
# ---------------------------------------------------------------------------
function Initialize-ControlHelper {
    if ($script:ControlReady) { return }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -Namespace MF -Name Control -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
public delegate bool HandlerRoutine(uint t);
public static string Script = "";
public static string Extra = "";
public static bool OnClose(uint t) {
    // Only CTRL_CLOSE_EVENT (2): CTRL_LOGOFF_EVENT would spawn a doomed copy
    // every time the user logs off.
    if (t == 2) {
        try {
            var psi = new System.Diagnostics.ProcessStartInfo("powershell.exe",
                "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + Script + "\"" + Extra);
            psi.UseShellExecute = false;
            System.Diagnostics.Process.Start(psi);
        } catch { }
    }
    return false;
}
public static void Hook(string script, string extra) {
    Script = script;
    Extra = extra;
    SetConsoleCtrlHandler(new HandlerRoutine(OnClose), true);
}
'@
    $script:ControlReady = $true
}

function Enable-CloseToBackground {
    # Closing this window relaunches the same command hidden, so the work keeps
    # running without a window. -Once runs are excluded: they are meant to end.
    param([switch]$CanGuard)

    if ($Once) { return }
    try {
        Initialize-ControlHelper
        $extra = ''
        try {
            $cmd = [Environment]::CommandLine
            $i = $cmd.IndexOf($PSCommandPath, [StringComparison]::OrdinalIgnoreCase)
            if ($i -ge 0) { $extra = $cmd.Substring($i + $PSCommandPath.Length).TrimStart('"', ' ') }
        } catch { }
        if ($extra -notmatch '-Tray') {
            if ($CanGuard -and -not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { $extra = ($extra + ' -Tray').Trim() }
        }
        [MF.Control]::Hook($PSCommandPath, (' ' + $extra))
        Write-Log ('close-to-background: armed (closing the window relaunches it hidden: {0})' -f $extra)
    } catch {
        Write-Log ('close-to-background: not armed ({0})' -f $_.Exception.Message)
    }
}

function Show-Tray {
    Initialize-ControlHelper

    # The tray is an entry point + live status, not a second guard: two guards
    # killing at the same time would double the kills. If the task is missing,
    # the tray says so and the menu installs it.
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $statusFile = Join-Path $env:TEMP 'mf-tray-status.txt'

    [void][MF.Control]::ShowWindow([MF.Control]::GetConsoleWindow(), 0)   # SW_HIDE
    Enable-CloseToBackground -CanGuard

    $ni = New-Object System.Windows.Forms.NotifyIcon
    try { $ni.Icon = [System.Drawing.SystemIcons]::Shield } catch { $ni.Icon = [System.Drawing.SystemIcons]::Application }
    $ni.Text = 'memfuse 内存守护'

    # Double-click opens the menu - the first thing anyone tries with a tray
    # icon, and the same action as the first context-menu entry below. Without
    # this the icon looks broken: right-click works, double-click does nothing.
    $ni.Add_DoubleClick({
        try { Start-Process -FilePath (Join-Path $PSScriptRoot 'memfuse.cmd') } catch { }
    })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $mi = $menu.Items.Add('打开菜单（1 演练 / 2 保护名单 / 3 守护开关；双击图标同效）')
    $mi.add_Click({ Start-Process -FilePath (Join-Path $PSScriptRoot 'memfuse.cmd') })
    # The three "look at something" entries all open a *console*, not an editor:
    # the same view the command line gives, nothing to install, and -NoExit keeps
    # the window (and its prompt) around. The old spelling started a bare
    # powershell that printed and vanished - which read as "the entry is broken".
    $mi = $menu.Items.Add('查看保护名单')
    $mi.add_Click({ Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ListProtected') })
    $mi = $menu.Items.Add('编辑名单文件 protect-list.txt')
    $mi.add_Click({ Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ShowProtectFile') })
    $mi = $menu.Items.Add('看今天的日志')
    $mi.add_Click({ Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ShowLog') })
    $mi = $menu.Items.Add('打开工具所在文件夹')
    $mi.add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $PSScriptRoot })
    $mi = $menu.Items.Add('退出托盘（守护若在跑则不受影响）')
    $mi.add_Click({ $script:trayStop = $true })
    $ni.ContextMenuStrip = $menu
    $ni.Visible = $true
    $script:trayStop = $false

    Write-Host '托盘已就位：右键托盘图标可打开菜单 / 名单 / 日志。这个窗口可以关掉，它会转入后台继续。'
    Write-Host ('守护状态：{0}' -f $(if ($task) { $task.State } else { '未安装 —— 右键托盘图标 → 打开菜单 → 按 3 装上' }))

    $tick = 0
    while (-not $script:trayStop) {
        [System.Windows.Forms.Application]::DoEvents()

        if ($tick % 2 -eq 0) {
            try {
                $s = Get-MemorySample
                $state = if ($task) { '运行中' } else { '未安装' }
                $ni.Text = ('memfuse · 可用 {0}% · 守护{1}' -f $s.AvailPct, $state)
                # hwnd included: a console window belongs to conhost.exe, so
                # nobody outside can find it by this process id - and it is what
                # the tray test (and any future script) needs to show/hide it.
                $hwnd = [MF.Control]::GetConsoleWindow()
                [IO.File]::WriteAllText($statusFile,
                    ('{0}  pid={1}  hwnd=0x{2:X}  avail={3}%  commit={4}%  task={5}' -f (Get-Date -Format 'HH:mm:ss'), $PID, [int64]$hwnd, $s.AvailPct, $s.CommitPct, $state),
                    (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }

        $tick++
        Start-Sleep -Milliseconds 450
    }

    $ni.Visible = $false
    $ni.Dispose()
    Write-Host '托盘已退出。'
}

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
    Write-Host ''
    Set-Shortcut
}

function Uninstall-GuardTask {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host ('task removed: {0}' -f $TaskName)
    } catch {
        Write-Host ('nothing to remove (task {0} not found)' -f $TaskName)
    }
    Set-Shortcut -Remove
}

# ---------------------------------------------------------------------------
# degrade tier: demote + trim instead of killing while memory is only "warn"
#
# Killing is the last resort. Between the warn line and the critical line the
# guard now does something reversible instead: the largest process it is NOT
# using right now loses its priority (BelowNormal) and gives its pages back
# (EmptyWorkingSet -> standby list). The priority is restored as soon as memory
# recovers or DemoteHoldSec elapsed; the pages come back on demand by
# themselves. Nothing is terminated here.
# ---------------------------------------------------------------------------
if (-not ('MemGuard.Mem' -as [type])) {
    Add-Type -Namespace MemGuard -Name Mem -MemberDefinition @'
[DllImport("psapi.dll", SetLastError = true)] public static extern bool EmptyWorkingSet(IntPtr hProcess);
'@
}

$script:demoted = @{}          # pid -> original priority class
$script:demoteSince = @{}      # pid -> when it was demoted
$script:lastDemote = [datetime]::MinValue

# The two maps above live in RAM, but this process can be restarted at any
# moment (heartbeat self-heal, manual restart, a release). Persist them next to
# the logs so the next instance can put back whatever the previous one left
# lowered instead of stranding it at BelowNormal forever (2026-10-16: caught it
# the hard way - two processes were left lowered by a restart).
$DemoteStateFile = Join-Path $LogDir 'demote-state.txt'

function Save-DemoteState {
    try {
        if ($script:demoted.Count -eq 0) {
            if (Test-Path -LiteralPath $DemoteStateFile) { Remove-Item -LiteralPath $DemoteStateFile -Force }
            return
        }
        $rows = foreach ($thePid in @($script:demoted.Keys)) {
            $nm = ''
            try { $p = Get-Process -Id $thePid -ErrorAction SilentlyContinue; if ($p) { $nm = $p.ProcessName } } catch { }
            $since = if ($script:demoteSince.ContainsKey($thePid)) { $script:demoteSince[$thePid].ToString('s') } else { '' }
            '{0}|{1}|{2}|{3}' -f $thePid, $script:demoted[$thePid], $since, $nm
        }
        [IO.File]::WriteAllLines($DemoteStateFile, @($rows))
    } catch { }
}

function Invoke-Demote {
    $fgPid = Get-ForegroundPid
    $target = $null
    foreach ($c in @(Get-Candidates -TopN 5)) {
        # never slow down the window the user is working in right now
        if ($fgPid -ne 0 -and [int]$c.Id -eq $fgPid) { continue }
        if ($script:demoted.ContainsKey([int]$c.Id)) { continue }
        $target = $c
        break
    }
    if (-not $target) { return $false }

    $before = 0
    try { $before = [int]($target.WorkingSet64 / 1MB) } catch { }
    $orig = ''
    try { $orig = [string]$target.PriorityClass } catch { }

    $prio = $false
    try { $target.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal; $prio = $true } catch { }

    $trim = $false
    try { $trim = [MemGuard.Mem]::EmptyWorkingSet($target.Handle) } catch { }

    $after = 0
    try { $after = [int]($target.WorkingSet64 / 1MB) } catch { }

    if ($prio) {
        $script:demoted[[int]$target.Id] = $orig
        $script:demoteSince[[int]$target.Id] = Get-Date
        Save-DemoteState
    }
    $note = ''
    if (-not $prio) { $note += ' (priority change refused)' }
    if ($trim) { $note += ' + working set trimmed' }
    Write-Log ('DEMOTE {0} pid={1} ws={2}MB->{3}MB priority={4}{5}' -f `
            $target.ProcessName, $target.Id, $before, $after, $(if ($prio) { 'BelowNormal' } else { 'unchanged' }), $note)
    return $prio
}

function Restore-Demoted {
    param([string]$Reason)
    if ($script:demoted.Count -eq 0) { return }
    foreach ($thePid in @($script:demoted.Keys)) {
        $orig = $script:demoted[$thePid]
        $p = Get-Process -Id $thePid -ErrorAction SilentlyContinue
        if (-not $p) {
            $script:demoted.Remove($thePid)
            $script:demoteSince.Remove($thePid)
            continue
        }
        $back = if ($orig) { $orig } else { 'Normal' }
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$back
            Write-Log ('RESTORE {0} pid={1} -> {2} ({3})' -f $p.ProcessName, $thePid, $back, $Reason)
        } catch {
            Write-Log ('RESTORE  failed for {0} pid={1}: {2}' -f $p.ProcessName, $thePid, $_.Exception.Message)
        }
        $script:demoted.Remove($thePid)
        $script:demoteSince.Remove($thePid)
    }
    Save-DemoteState
}

function Restore-StrandedDemotes {
    # A previous instance may have been restarted while it held processes at
    # BelowNormal: its RAM maps are gone, the state file is not. Put them back
    # before this instance starts lowering anything of its own.
    if (-not (Test-Path -LiteralPath $DemoteStateFile)) { return }
    $rows = @(Get-Content -LiteralPath $DemoteStateFile -ErrorAction SilentlyContinue)
    $restored = 0
    foreach ($row in $rows) {
        $parts = @($row -split '\|')
        if ($parts.Count -lt 2) { continue }
        $thePid = 0
        if (-not [int]::TryParse($parts[0].Trim(), [ref]$thePid)) { continue }
        $orig = $parts[1].Trim()
        if (-not $orig) { $orig = 'Normal' }
        $p = Get-Process -Id $thePid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        # Only touch a process that is still sitting exactly where we left it;
        # if it re-raised itself (or someone else changed it), leave it alone.
        $cur = ''
        try { $cur = [string]$p.PriorityClass } catch { }
        if ($cur -ne 'BelowNormal') { continue }
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$orig
            Write-Log ('RESTORE {0} pid={1} -> {2} (stranded by a guard restart)' -f $p.ProcessName, $thePid, $orig)
            $restored++
        } catch {
            Write-Log ('RESTORE  failed for {0} pid={1}: {2}' -f $p.ProcessName, $thePid, $_.Exception.Message)
        }
    }
    Remove-Item -LiteralPath $DemoteStateFile -Force -ErrorAction SilentlyContinue
    if ($restored -gt 0) { Write-Log ('took over {0} stranded demotion(s) from a previous instance' -f $restored) }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if ($Menu) { Show-Menu -Scripted $MenuInput; exit 0 }
if ($Tray) { Show-Tray; exit 0 }
if ($UninstallTask) { Uninstall-GuardTask; exit 0 }
if ($Help) { Show-Usage; exit 0 }
if ($ListProtected) { Show-ProtectList; exit 0 }
if ($ListWindowed) { Show-WindowedProcesses; exit 0 }
if ($ShowProtectFile) { Show-ProtectFile; exit 0 }
if ($ShowLog) { Show-TodayLog -Tail $LogTail; exit 0 }
if (@($ShowProcMem).Count -gt 0) { Show-ProcMemory -Names $ShowProcMem; exit 0 }
# -KillProcInput "<selection>;<confirmation>" - e.g. "1;y" or "node;y".
# Process names can never contain ';', so the split is unambiguous.
if ($KillProc) {
    $sel = $KillProcInput
    $cfm = ''
    if ($KillProcInput -and $KillProcInput -match ';') {
        $parts = $KillProcInput -split ';', 2
        $sel = $parts[0]
        $cfm = $parts[1]
    }
    Invoke-KillProc -Selection $sel -Confirm $cfm
    exit 0
}
if ($Pick) { Invoke-PickWhitelist -Answer $PickInput; exit 0 }
if (@($AddProtect).Count -gt 0 -or @($RemoveProtect).Count -gt 0) { [void](Set-ProtectEntries -Add $AddProtect -Remove $RemoveProtect); exit 0 }
if ($InstallTask) { Install-GuardTask; exit 0 }
if ($CreateShortcut) { Set-Shortcut; exit 0 }
if ($RemoveShortcut) { Set-Shortcut -Remove; exit 0 }

# From here on this process runs for a long time (a guard), so closing its
# console window must not silently end the protection: the handler relaunches
# the same command hidden.
Enable-CloseToBackground

if ($WarnPercent -le $CriticalPercent) { throw 'WarnPercent must be greater than CriticalPercent' }

Show-Config
Write-Log ('started - warn<{0}% crit<{1}% sustain={2}x{3}s cooldown={4}s minCandidate={5}MB maxKills={6}/h emergencyCooldown={7}s emergencyMaxKills={8}/h demote={9} demoteHold={10}s dryRun={11}' -f `
    $WarnPercent, $CriticalPercent, $SustainSamples, $IntervalSec, $CooldownSec, $MinCandidateMB, $MaxKillsPerHour, $EmergencyCooldownSec, ($MaxKillsPerHour * 3), $(if ($NoDemote) { 'off' } else { 'on' }), $DemoteHoldSec, $DryRun.IsPresent)

# Take over whatever a previous instance left lowered (see Restore-StrandedDemotes).
# A dry run never changes the machine, so it leaves the state file to a real one.
if (-not $DryRun) { Restore-StrandedDemotes }

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
$healthyStreak = 0
$lastWarn = [datetime]::MinValue
$lastKill = [datetime]::MinValue
$killTimes = New-Object 'System.Collections.Generic.List[datetime]'

# -PreferIdle needs two CPU snapshots to see who is actually working, plus the
# per-candidate reason strings so every choice can be explained in the log.
$script:cpuPrev = $null
$script:cpuNow = $null
$script:lastPickReason = @{}

while ($true) {
    Update-ProtectFileSet
    try {
        $sample = Get-MemorySample
        if ($PreferIdle) { Update-CpuSnapshot }
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

    # Degrade tier: while memory is in the warn band (and nothing is about to
    # be killed) make the biggest process give way instead of shooting it:
    # lower its priority, hand its pages back. Both are reversible.
    if ($sample.AvailPct -ge $WarnPercent) { $healthyStreak++ } else { $healthyStreak = 0 }
    if ($script:demoted.Count -gt 0) {
        $heldLong = $false
        foreach ($stamp in @($script:demoteSince.Values)) {
            if (((Get-Date) - $stamp).TotalSeconds -ge $DemoteHoldSec) { $heldLong = $true; break }
        }
        if ($healthyStreak -ge $SustainSamples) { Restore-Demoted -Reason 'memory recovered' }
        elseif ($heldLong) { Restore-Demoted -Reason ('hold {0}s elapsed' -f $DemoteHoldSec) }
    }
    # One process at a time: the machine sits in the warn band for hours on end,
    # and demoting a new one every cooldown would leave a trail of sluggish
    # applications behind. Wait for the current one to be restored first.
    if (-not $NoDemote -and -not $shouldAct -and -not $emergency -and $sample.AvailPct -lt $WarnPercent -and $script:demoted.Count -eq 0) {
        if (($now - $script:lastDemote).TotalSeconds -ge $DemoteCooldownSec) {
            if ($DryRun) {
                $peek = @(Get-Candidates -TopN 1)
                if ($peek.Count -gt 0) {
                    Write-Log ('DRY-RUN would demote {0} pid={1} ws={2}MB (BelowNormal + trim)' -f $peek[0].ProcessName, $peek[0].Id, [int]($peek[0].WorkingSet64 / 1MB))
                    $script:lastDemote = $now
                }
            } elseif (Invoke-Demote) {
                $script:lastDemote = $now
            }
        }
    }

    # The brake keeps the guard out of a kill-respawn-kill arms race, but when
    # the machine is about to hard-freeze (< half the critical line) standing
    # still is worse than the fight: the emergency tier cuts the cooldown to
    # EmergencyCooldownSec and triples the hourly budget. The normal tier is
    # unchanged (CooldownSec / MaxKillsPerHour).
    $effectiveCooldown = if ($emergency) { $EmergencyCooldownSec } else { $CooldownSec }
    $effectiveCap = if ($emergency) { $MaxKillsPerHour * 3 } else { $MaxKillsPerHour }

    if ($shouldAct) {
        if (($now - $lastKill).TotalSeconds -lt $effectiveCooldown) {
            Write-Verbose 'in cooldown - waiting'
        } else {
            $recent = @($killTimes | Where-Object { ($now - $_).TotalHours -lt 1 })
            $killTimes.Clear()
            foreach ($stamp in $recent) { $killTimes.Add($stamp) }

            if ($killTimes.Count -ge $effectiveCap) {
                if (($now - $lastKill).TotalSeconds -ge 300) {
                    $tier = if ($emergency) { ' emergency' } else { '' }
                    Write-Log ('LIMIT hourly kill limit reached ({0}/h{1}) - not acting this round' -f $effectiveCap, $tier)
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
