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
    [string[]]$RemoveProtect = @(),
    [switch]$ListProtected,
    [switch]$ListWindowed,
    [switch]$Pick,
    [string]$PickInput,
    [ValidateSet('safe', 'balanced', 'aggressive')][string]$Preset,
    [switch]$Help,
    [switch]$InstallTask,
    [switch]$UninstallTask
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
        if (-not $existing.Remove($key)) { if (-not $Quiet) { Write-Host ('  = {0}：不在名单里' -f $key) }; continue }
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
    foreach ($r in $rows) {
        $state = if ($r.Protected) { '已保护' } else { '可被杀' }
        Write-Host ('  {0}  {1,-24} {2,-22} {3,6} MB' -f $state, $r.Name, $r.Title, $r.WS_MB)
    }
    Write-Host ('共 {0} 个。要保护其中某个：双击 whitelist.cmd（看列表、输编号），或 -AddProtect <进程名>' -f $rows.Count)
    Write-Host '  想更省事：-Preset safe —— 有窗口的程序一律不杀，基本不用维护名单。'
}

function Show-Usage {
    Write-Host ''
    Write-Host 'memfuse —— 内存临界前的最后防线（在系统卡死之前，终止占用最大的那个进程）'
    Write-Host ''
    Write-Host '第一次用，建议按这个顺序：'
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
    Write-Host ''
}

function Invoke-PickWhitelist {
    param([string]$Answer)

    $rows = @(Get-WindowedRows)
    Write-Host ''
    Write-Host '=== memfuse 白名单：选择要保护的程序（被保护的永不被终止）==='
    $recent = Get-RecentKillName
    if ($recent) { Write-Host ('上次被守护终止的是：{0}（如果这是你在用的，建议保护它）' -f $recent) }
    Write-Host ''
    if ($rows.Count -eq 0) { Write-Host '当前没有带窗口的程序，没什么可选的。'; return }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $r = $rows[$i]
        $state = if ($r.Protected) { '[已保护]' } else { '[      ]' }
        $flag = if ($recent -and ((ConvertTo-ProcKey $r.Name) -eq (ConvertTo-ProcKey $recent))) { '   <= 上次被杀的' } else { '' }
        Write-Host ('  {0} {1,2}. {2,-24} {3,-20} {4,6} MB{5}' -f $state, ($i + 1), $r.Name, $r.Title, $r.WS_MB, $flag)
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
    Write-Host ('受保护      : 共 {0} 项（系统内置 {1} + 用户白名单 {2}）' -f ($protectSet.Count + $script:fileProtect.Count), $SystemProtected.Count, (($protectSet.Count - $SystemProtected.Count) + $script:fileProtect.Count))
    Write-Host ('有窗口的进程: {0}（宽限期 {1}s，紧急档 {2}s）' -f $WindowedAction, [math]::Max($GracefulSeconds, 1), [math]::Min([math]::Max($GracefulSeconds, 1), 3))
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
if ($Help) { Show-Usage; exit 0 }
if ($ListProtected) { Show-ProtectList; exit 0 }
if ($ListWindowed) { Show-WindowedProcesses; exit 0 }
if ($Pick) { Invoke-PickWhitelist -Answer $PickInput; exit 0 }
if (@($AddProtect).Count -gt 0 -or @($RemoveProtect).Count -gt 0) { [void](Set-ProtectEntries -Add $AddProtect -Remove $RemoveProtect); exit 0 }
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
