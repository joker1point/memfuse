#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end test for -WindowedAction Skip / Close.

.DESCRIPTION
    Proves the two promises by experiment instead of by reading the code:

      Skip  -> a process that owns a window and ignores WM_CLOSE survives
      Close -> the same process is force-killed after the grace period

    How it is made safe: the test starts a sacrificial tkinter window
    (which cancels WM_CLOSE and holds ~250 MB), then writes a temporary
    whitelist containing every OTHER process name on the machine. The guard
    therefore has exactly one candidate - the sacrificial process - and
    cannot touch anything else.

    Needs a Python with tkinter (pythonw). Skips cleanly when unavailable.

.NOTES
    - The repository's protect-list.txt is never touched (ProtectFile -> TEMP).
    - Logs go to TEMP, never into the repository.
    - <Desktop>\memory-guard-alert.txt is backed up and restored afterwards.
    - Exit code 0 = pass, 1 = fail, 0 with [SKIP] = cannot run here.
#>
[CmdletBinding()]
param(
    [string]$Python = 'pythonw',
    [int]$GraceSeconds = 3,
    [int]$HoldMB = 250
)

$ErrorActionPreference = 'Stop'

$guard = Join-Path (Split-Path -Parent $PSScriptRoot) 'memory-guard.ps1'
if (-not (Test-Path -LiteralPath $guard)) { throw "memory-guard.ps1 not found next to tests\ ($guard)" }

if (-not (Get-Command $Python -ErrorAction SilentlyContinue)) {
    Write-Host "[SKIP] '$Python' not found - this test needs a Python with tkinter."
    exit 0
}
$sacrificialName = [IO.Path]::GetFileNameWithoutExtension($Python)
if (@(Get-Process -Name $sacrificialName -ErrorAction SilentlyContinue).Count -ne 0) {
    Write-Host "[SKIP] '$sacrificialName' is already running - refusing to guess which one would be ours."
    exit 0
}

$tmp = Join-Path $env:TEMP ('memguard-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$probe = Join-Path $tmp 'sacrificial.py'
$protect = Join-Path $tmp 'protect-list.txt'
$logDir = Join-Path $tmp 'logs'

$py = @(
    'import tkinter as tk'
    'root = tk.Tk()'
    'root.title("memguard windowed-protection test")'
    'root.geometry("360x140")'
    'root.protocol("WM_DELETE_WINDOW", lambda: None)'
    ('hold = bytearray({0} * 1024 * 1024)' -f $HoldMB)
    'tk.Label(root, text="this window ignores close requests").pack(pady=40)'
    'root.mainloop()'
) -join "`r`n"
[IO.File]::WriteAllText($probe, $py, (New-Object System.Text.UTF8Encoding($false)))

$alert = Join-Path ([Environment]::GetFolderPath('Desktop')) 'memory-guard-alert.txt'
$alertBackup = Join-Path $tmp 'alert-backup.txt'
$hadAlert = Test-Path -LiteralPath $alert
if ($hadAlert) { Copy-Item -LiteralPath $alert -Destination $alertBackup -Force }

$sac = Start-Process $Python -ArgumentList $probe -PassThru
Start-Sleep -Seconds 5
$sac.Refresh()
if ($sac.HasExited) { Write-Host '[FAIL] the sacrificial process exited - tkinter unavailable?'; exit 1 }
if ($sac.MainWindowHandle -eq [IntPtr]::Zero) {
    Write-Host '[FAIL] the sacrificial process owns no window - cannot test window handling'
    Stop-Process -Id $sac.Id -Force
    exit 1
}
Write-Host ('[ok] sacrificial: pid {0}, {1} MB, window handle {2}' -f $sac.Id, [int]($sac.WorkingSet64 / 1MB), $sac.MainWindowHandle)

$names = @(Get-Process | Where-Object { $_.ProcessName -ne $sacrificialName } | Select-Object -ExpandProperty ProcessName -Unique)
[IO.File]::WriteAllText($protect, (($names -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[ok] whitelisted {0} names - the sacrificial process is the only candidate' -f $names.Count)

$common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $guard, '-ProtectFile', $protect, '-LogDir', $logDir,
    '-MinCandidateMB', '1', '-CriticalPercent', '95', '-WarnPercent', '99', '-SustainSamples', '1', '-CooldownSec', '0', '-Once')

Write-Host '--- phase 1: -WindowedAction Skip (must NOT be killed) ---'
Start-Process powershell -ArgumentList ($common + @('-WindowedAction', 'Skip', '-GracefulSeconds', "$GraceSeconds")) -Wait -NoNewWindow
$aliveAfterSkip = [bool](Get-Process -Id $sac.Id -ErrorAction SilentlyContinue)

Write-Host '--- phase 2: -WindowedAction Close (must eventually be killed) ---'
Start-Process powershell -ArgumentList ($common + @('-WindowedAction', 'Close', '-GracefulSeconds', "$GraceSeconds")) -Wait -NoNewWindow
$aliveAfterClose = [bool](Get-Process -Id $sac.Id -ErrorAction SilentlyContinue)

$logFile = Get-ChildItem -Path $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
$text = if ($logFile) { Get-Content -LiteralPath $logFile.FullName -Encoding UTF8 -Raw } else { '' }
$sawSkip = [bool]($text -match 'SKIP\s+\S+')
$sawStop = [bool]($text -match 'ACTION\s+stopped')

$pass = $aliveAfterSkip -and (-not $aliveAfterClose) -and $sawSkip -and $sawStop

if ($pass) {
    Write-Host '[PASS] Skip kept the windowed process alive; Close force-killed it.'
} else {
    Write-Host ('[FAIL] survived Skip = {0} (want True) | survived Close = {1} (want False) | SKIP in log = {2} | stop in log = {3}' -f `
        $aliveAfterSkip, $aliveAfterClose, $sawSkip, $sawStop)
}

if (Get-Process -Id $sac.Id -ErrorAction SilentlyContinue) { Stop-Process -Id $sac.Id -Force }
if ($hadAlert) { Copy-Item -LiteralPath $alertBackup -Destination $alert -Force }
else { Remove-Item -LiteralPath $alert -Force -ErrorAction SilentlyContinue }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($pass) { exit 0 } else { exit 1 }
