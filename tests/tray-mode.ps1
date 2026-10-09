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
for ($i = 0; $i -lt 20 -and -not $second; $i++) {
    Start-Sleep -Milliseconds 700
    $s = Get-Status
    if ($s -and $s.Pid -ne $first.Pid) { $second = $s }
}

Check 'the closed process is gone' (-not [bool](Get-Process -Id $first.Pid -ErrorAction SilentlyContinue)) ('pid ' + $first.Pid + ' still here')
Check 'a hidden replacement took over' ([bool]$second) 'status file still shows the old pid'
if ($second) {
    Check 'the replacement is alive' ([bool](Get-Process -Id $second.Pid -ErrorAction SilentlyContinue)) ('pid ' + $second.Pid)
    Check 'the replacement has no visible window' (-not [TW]::IsWindowVisible([IntPtr]$second.Hwnd)) $second.Raw
    KillTree $second.Pid
}

Start-Sleep -Seconds 2
$left = @(Get-TrayProcesses)
Check 'no leftovers' ($left.Count -eq 0) ('left: ' + $left.Count)
foreach ($x in $left) { KillTree $x.ProcessId }

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
