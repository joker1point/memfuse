# Tray mode test.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\tray-mode.ps1
#
# The tray writes  %TEMP%\mf-tray-status.txt  with its pid, its console window
# handle and the live free-memory figure. A console window belongs to
# conhost.exe, so that file is the only reliable way to reach the window from
# outside - and it doubles as the "is it alive" check.
#
# Asserted here:
#   * the tray runs with a hidden console window,
#   * the status file is fresh and carries an availability figure,
#   * closing the console (WM_CLOSE - exactly what the X button sends) hands
#     over to a hidden replacement: a console close cannot be cancelled, so
#     "minimise to tray" is implemented as "relaunch hidden".
#
# The scheduled task is never touched: this test only starts its own copy.
#
# A tray the USER started is never touched either. The status file path is
# fixed (%TEMP%\mf-tray-status.txt), so a second tray overwrites this test's
# heartbeat and the two cannot be told apart - and the cleanup must never
# KillTree a process it did not start. If a -Tray instance is already
# running the test skips cleanly (same rule as tests/windowed-protection.ps1:
# refuse to guess which one would be ours), and the final cleanup only ever
# kills the pids this test started itself.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$status = Join-Path $env:TEMP 'mf-tray-status.txt'
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('ok    {0}' -f $name) }
    else { Write-Host ('FAIL  {0}  ({1})' -f $name, $detail); $script:fail++ }
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class TW {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@

function Get-Status {
    if (-not (Test-Path -LiteralPath $status)) { return $null }
    $line = (Get-Content -Encoding UTF8 -LiteralPath $status -Raw).Trim()
    # avail is a percentage with a decimal point (e.g. 10.8%), so the pattern
    # must accept the dot as well
    if ($line -notmatch 'pid=(\d+)\s+hwnd=0x([0-9A-Fa-f]+)\s+avail=([\d.]+)%') { return $null }
    return @{ Raw = $line; Pid = [int]$Matches[1]; Hwnd = [int64]('0x' + $Matches[2]); Avail = [double]$Matches[3] }
}

function Get-TrayProcesses {
    @(Get-CimInstance Win32_Process | Where-Object {
            $_.CommandLine -like '*memory-guard.ps1*' -and $_.CommandLine -like '*-Tray*'
        })
}

function KillTree([int]$Root) {
    foreach ($k in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$Root" -ErrorAction SilentlyContinue)) { KillTree $k.ProcessId }
    Stop-Process -Id $Root -Force -ErrorAction SilentlyContinue
}

# A tray the user started must never become this test's target: the status
# file path is fixed, so a second tray would overwrite this test's heartbeat
# (the test cannot tell them apart) and the cleanup below must not kill it.
$foreign = @(Get-TrayProcesses)
if ($foreign.Count -gt 0) {
    $pids = (($foreign | ForEach-Object { $_.ProcessId }) -join ', ')
    Write-Host ('[SKIP] a -Tray instance is already running (pid {0}) - refusing to guess which one would be ours.' -f $pids)
    exit 0
}

Remove-Item -LiteralPath $status -Force -ErrorAction SilentlyContinue
Start-Process powershell -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Tray') | Out-Null
Start-Sleep -Seconds 7

$first = Get-Status
Check 'tray wrote a status file' ([bool]$first) $status
if (-not $first) {
    foreach ($x in Get-TrayProcesses) { KillTree $x.ProcessId }
    Write-Host '1 check(s) failed'; exit 1
}
Check 'the tray process is alive' ([bool](Get-Process -Id $first.Pid -ErrorAction SilentlyContinue)) ('pid ' + $first.Pid)
Check 'the console window is hidden' (-not [TW]::IsWindowVisible([IntPtr]$first.Hwnd)) $first.Raw
Check 'status carries an availability figure' ($first.Avail -gt 0) $first.Raw

# the "minimise to tray" part: WM_CLOSE is what the X button sends
[void][TW]::PostMessage([IntPtr]$first.Hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
$second = $null
for ($i = 0; $i -lt 45 -and -not $second; $i++) {   # ~31s: a fresh PowerShell is slow to come up when memory is tight
    Start-Sleep -Milliseconds 700
    $s = Get-Status
    if ($s -and $s.Pid -ne $first.Pid) { $second = $s }
}

# The old process dies asynchronously: Windows ends it a few seconds after
# CTRL_CLOSE_EVENT no matter what the handler does, and on a memory-tight
# machine (this tool exists because memory is tight) that can take much
# longer. Sample it with a poll, not a single read.
$gone = $false
for ($i = 0; $i -lt 40 -and -not $gone; $i++) {
    if (-not (Get-Process -Id $first.Pid -ErrorAction SilentlyContinue)) { $gone = $true; break }
    Start-Sleep -Milliseconds 500
}
Check 'the closed process is gone' $gone ('pid ' + $first.Pid + ' still here')
Check 'a hidden replacement took over' ([bool]$second) 'status file still shows the old pid'
if ($second) {
    Check 'the replacement is alive' ([bool](Get-Process -Id $second.Pid -ErrorAction SilentlyContinue)) ('pid ' + $second.Pid)
    Check 'the replacement has no visible window' (-not [TW]::IsWindowVisible([IntPtr]$second.Hwnd)) $second.Raw
    KillTree $second.Pid
}

Start-Sleep -Seconds 2
# Only ever clean up what this test started: a tray the user launched while
# the test was running must survive (the skip guard above covers the common
# case; this scoping covers the race).
$own = New-Object 'System.Collections.Generic.List[int]'
if ($first) { $own.Add($first.Pid) }
if ($second) { $own.Add($second.Pid) }
$left = @(Get-TrayProcesses | Where-Object { $own.Contains($_.ProcessId) })
Check 'no leftovers of our own' ($left.Count -eq 0) ('left: ' + (($left | ForEach-Object { $_.ProcessId }) -join ','))
foreach ($x in $left) { KillTree $x.ProcessId }

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
