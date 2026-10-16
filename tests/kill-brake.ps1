# kill-brake.ps1 -- the emergency tier's brake.
#
# The guard's hourly kill cap is the thing that keeps it out of a
# kill-respawn-kill arms race, but it used to apply even in a true emergency
# (available memory below half the critical line), which left the machine
# waiting for the hour to roll while it was about to hard-freeze.
#
# The emergency tier now uses -EmergencyCooldownSec and 3x the hourly cap.
# This test forces the emergency tier on a healthy machine by raising
# CriticalPercent to 95 (emergency = < 47.5%, always true here) and runs a
# DryRun guard whose would-kills count against the brake, then counts them.
#
# DryRun only: nothing on the machine is ever terminated by this test.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$tmp = Join-Path $env:TEMP ('mf-brake-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ('ok    ' + $name) }
    else { $script:fail++; Write-Host ('FAIL  ' + $name + $(if ($detail) { ' -- ' + $detail } else { '' })) }
}

try {
    # CriticalPercent 95 => emergency tier is always active on a healthy box.
    # MaxKillsPerHour 1 => the emergency cap is 3, so exactly 3 would-kills
    # are allowed inside the rolling hour. Cooldowns 0 so the tier, not the
    # clock, is what limits the count.
    $ga = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script,
        '-DryRun', '-CriticalPercent', '95', '-WarnPercent', '99', '-SustainSamples', '1',
        '-CooldownSec', '0', '-EmergencyCooldownSec', '0', '-IntervalSec', '5',
        '-MaxKillsPerHour', '1', '-MinCandidateMB', '1', '-LogDir', $tmp)

    $p = Start-Process -FilePath $psExe -ArgumentList $ga -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 32
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800

    $log = Get-ChildItem -LiteralPath $tmp -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    $lines = if ($log) { @(Get-Content -LiteralPath $log.FullName) } else { @() }

    $started = @($lines | Where-Object { $_ -match 'started - ' })
    $dry = @($lines | Where-Object { $_ -match 'DRY-RUN would kill' })

    Check 'guard started with the emergency config' `
        ($started.Count -eq 1 -and $started[0] -match 'emergencyCooldown=0s emergencyMaxKills=3/h') `
        ($started -join ' | ')
    Check 'emergency tier allows 3x the hourly cap (3 would-kills with cap=1)' `
        ($dry.Count -eq 3) ("would-kill lines: $($dry.Count)")
    Check 'no 4th would-kill inside the rolling hour' ($dry.Count -lt 4) ("would-kill lines: $($dry.Count)")
    Check 'DryRun never killed anything for real' (@($lines | Where-Object { $_ -match 'ACTION\s+killing' }).Count -eq 0) 'found an ACTION line in a DryRun log'
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
