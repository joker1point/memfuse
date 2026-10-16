# demote.ps1 -- the degrade tier: demote + trim instead of killing.
#
# While memory is only in the warn band the guard must NOT kill anything: it
# lowers the priority of the largest process it is not using (BelowNormal),
# trims its working set, and puts the priority back when memory recovers or
# DemoteHoldSec elapsed.
#
# The test builds a controlled victim (a copy of powershell.exe named
# mf-demote-sandbox holding ~400 MB of *touched* pages), makes it the ONLY
# candidate by writing every other running process into a temp protect-list,
# and runs the real guard with -WarnPercent 99 -CriticalPercent 3
# -SustainSamples 99 so that the degrade tier is always active and the kill
# path can never fire.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$realProtect = Join-Path $root 'protect-list.txt'
$sandboxName = 'mf-demote-sandbox'

$tmp = Join-Path $env:TEMP ('mf-demote-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$sandboxExe = Join-Path $tmp ($sandboxName + '.exe')
$logDir = Join-Path $tmp 'logs'
New-Item -ItemType Directory -Path $logDir | Out-Null

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ('ok    ' + $name) }
    else { $script:fail++; Write-Host ('FAIL  ' + $name + $(if ($detail) { ' -- ' + $detail } else { '' })) }
}

$sandbox = $null
$guard = $null
$realBackup = $null
try {
    # 1) the victim: a renamed powershell holding ~400 MB for five minutes.
    #    The byte array must be touched page by page - a fresh array is
    #    zero-filled lazily and never shows up in the working set.
    Copy-Item -LiteralPath $psExe -Destination $sandboxExe -Force
    # Fill natively: a PowerShell page-by-page loop over 400 MB takes tens of
    # seconds, and the array must really be touched to show up in the working
    # set (a fresh array is zero-filled lazily).
    $cmd = '$a = New-Object byte[] 419430400; $r = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $r.GetBytes($a); $r.Dispose(); Start-Sleep -Seconds 300'
    $sandbox = Start-Process -FilePath $sandboxExe -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd) -PassThru
    $ws = 0
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        $sb = Get-Process -Id $sandbox.Id -ErrorAction SilentlyContinue
        if (-not $sb) { break }
        $ws = [int]($sb.WS / 1MB)
        if ($ws -ge 200) { break }
    }
    Check 'sandbox is up and holding memory' ($ws -ge 200) ("ws=$ws" + 'MB')

    # 2) every other running process goes on a temp whitelist, so the sandbox
    #    is the only candidate the test guard can ever touch
    $protectFile = Join-Path $tmp 'protect.txt'
    $names = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -ne $sandboxName } |
            Select-Object -ExpandProperty ProcessName -Unique | Sort-Object)
    [IO.File]::WriteAllLines($protectFile, $names)

    # 3) shield the sandbox from the *real* guard while the test runs
    $realBackup = Join-Path $tmp 'protect-list.backup.txt'
    Copy-Item -LiteralPath $realProtect -Destination $realBackup -Force
    Add-Content -LiteralPath $realProtect -Value $sandboxName
    Start-Sleep -Seconds 6

    # 4) run the guard: the degrade tier is forced on (warn 99) and the kill
    #    path is impossible (crit 3 + sustain 99), so nothing can be killed.
    #    No -DesktopAlert here: the alert file is only for real kills, and a
    #    false value cannot be passed through the command line (it arrives as
    #    a string and the script refuses to start).
    $ga = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script,
        '-WarnPercent', '99', '-CriticalPercent', '3', '-SustainSamples', '99',
        '-IntervalSec', '3', '-MinCandidateMB', '200', '-ProtectFile', $protectFile,
        '-DemoteCooldownSec', '0', '-DemoteHoldSec', '8', '-LogDir', $logDir)
    $guard = Start-Process -FilePath $psExe -ArgumentList $ga -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 4

    # 5) while demoted the victim sits at BelowNormal
    $seenBelow = $false
    for ($i = 0; $i -lt 12 -and -not $seenBelow; $i++) {
        Start-Sleep -Seconds 1
        $p = Get-Process -Id $sandbox.Id -ErrorAction SilentlyContinue
        if ($p -and $p.PriorityClass -eq 'BelowNormal') { $seenBelow = $true }
    }
    Check 'victim demoted to BelowNormal' $seenBelow ''

    # 6) the hold expires -> the guard restores the priority
    $restored = $false
    for ($i = 0; $i -lt 20 -and -not $restored; $i++) {
        Start-Sleep -Seconds 1
        $p = Get-Process -Id $sandbox.Id -ErrorAction SilentlyContinue
        if ($p -and $p.PriorityClass -ne 'BelowNormal') { $restored = $true }
    }
    Check 'priority restored after the hold' $restored ''

    Start-Sleep -Milliseconds 600
    $log = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    $lines = if ($log) { @(Get-Content -LiteralPath $log.FullName) } else { @() }
    Check 'DEMOTE logged for the sandbox' (@($lines | Where-Object { $_ -match ('DEMOTE ' + $sandboxName) }).Count -ge 1) ($lines -join ' | ')
    Check 'RESTORE logged for the sandbox' (@($lines | Where-Object { $_ -match ('RESTORE ' + $sandboxName) }).Count -ge 1) ($lines -join ' | ')
    Check 'nothing was killed during the test' (@($lines | Where-Object { $_ -match 'ACTION\s+killing' }).Count -eq 0) ''
    Check 'started line advertises the degrade tier' `
        (@($lines | Where-Object { $_ -match 'started - ' -and $_ -match 'demote=on' }).Count -eq 1) ($lines -join ' | ')
} finally {
    if ($guard -and -not $guard.HasExited) { Stop-Process -Id $guard.Id -Force -ErrorAction SilentlyContinue }
    if ($sandbox -and -not $sandbox.HasExited) { Stop-Process -Id $sandbox.Id -Force -ErrorAction SilentlyContinue }
    if ($realBackup -and (Test-Path $realBackup)) {
        Copy-Item -LiteralPath $realBackup -Destination $realProtect -Force
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail) { Write-Host ('{0} check(s) failed' -f $script:fail); exit 1 }
Write-Host 'all checks passed'
exit 0
