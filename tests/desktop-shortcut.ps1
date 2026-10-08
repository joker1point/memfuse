# Desktop shortcut test.
#
# Runs the shortcut code against a throw-away folder instead of the real
# desktop, and never registers/unregisters the scheduled task.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\desktop-shortcut.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\desktop-shortcut.ps1 -Launch
#
# -Launch also starts the shortcut, i.e. the double-click path: a console
# window appears for a few seconds, only the numbered menu runs (never the
# guard), then it is closed again. Off by default so CI stays headless.
param([switch]$Launch)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$dir = Join-Path $env:TEMP ('mf-shortcut-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('ok    {0}' -f $name) }
    else { Write-Host ('FAIL  {0}  ({1})' -f $name, $detail); $script:fail++ }
}

function Invoke-Guard([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $extra
    & powershell @argList 2>&1 | Out-String
}

function Get-Lnk {
    @(Get-ChildItem -LiteralPath $dir -Filter '*.lnk' -ErrorAction SilentlyContinue)
}

function KillTree([int]$root) {
    foreach ($k in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$root" -ErrorAction SilentlyContinue)) { KillTree $k.ProcessId }
    Stop-Process -Id $root -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
    # create
    $out = Invoke-Guard @('-CreateShortcut', '-ShortcutDir', $dir)
    Check 'create reports the path' ($out -match 'lnk') $out.Trim()
    $lnks = @(Get-Lnk)
    Check 'exactly one .lnk created' ($lnks.Count -eq 1) ('count=' + $lnks.Count)

    # the shortcut must point at the launcher, and start there
    if ($lnks.Count -eq 1) {
        $sh = New-Object -ComObject WScript.Shell
        $sc = $sh.CreateShortcut($lnks[0].FullName)
        $wantCmd = Join-Path $root 'memfuse.cmd'
        Check 'targets memfuse.cmd' ($sc.TargetPath -eq $wantCmd) $sc.TargetPath
        Check 'working directory is the repo' ($sc.WorkingDirectory -eq $root) $sc.WorkingDirectory
        Check 'has a description' ([bool]$sc.Description) '<empty>'
    }

    # remove, then remove again (must be harmless)
    Invoke-Guard @('-RemoveShortcut', '-ShortcutDir', $dir) | Out-Null
    Check 'removed' ((Get-Lnk).Count -eq 0) 'still there'
    $out = Invoke-Guard @('-RemoveShortcut', '-ShortcutDir', $dir)
    Check 'removing twice is harmless' ($out -notmatch 'WARN|ERROR') $out.Trim()

    if ($Launch) {
        Invoke-Guard @('-CreateShortcut', '-ShortcutDir', $dir) | Out-Null
        $lnk = (Get-Lnk)[0].FullName
        $before = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*memory-guard*' } | Select-Object -ExpandProperty ProcessId)
        Start-Process $lnk
        $menu = $null
        for ($i = 0; $i -lt 20 -and -not $menu; $i++) {
            Start-Sleep -Milliseconds 500
            $menu = @(Get-CimInstance Win32_Process | Where-Object {
                    $_.CommandLine -like '*memory-guard.ps1*' -and $_.CommandLine -like '*-Menu*' -and $before -notcontains $_.ProcessId
                }) | Select-Object -First 1
        }
        Check 'double-click opens the menu' ([bool]$menu) 'no -Menu process within 10s'
        $stray = @(Get-CimInstance Win32_Process | Where-Object {
                $_.CommandLine -like '*memory-guard.ps1*' -and $_.CommandLine -notlike '*-Menu*' -and $before -notcontains $_.ProcessId
            })
        Check 'double-click never starts the guard' ($stray.Count -eq 0) ('strays=' + $stray.Count)
        foreach ($x in @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*memory-guard.ps1*' -and $_.CommandLine -like '*-Menu*' -and $before -notcontains $_.ProcessId })) {
            $cmdRoot = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $x.ParentProcessId) -ErrorAction SilentlyContinue)
            if ($cmdRoot -and $cmdRoot.CommandLine -like '*memfuse.cmd*') { KillTree $cmdRoot.ProcessId } else { KillTree $x.ProcessId }
        }
        Start-Sleep -Seconds 1
        Check 'closed after the test' (@(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*memory-guard.ps1*' -and $_.CommandLine -like '*-Menu*' }).Count -eq 0) 'still running'
        Invoke-Guard @('-RemoveShortcut', '-ShortcutDir', $dir) | Out-Null
    }
} finally {
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
