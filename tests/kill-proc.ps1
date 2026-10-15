# Manual kill test for -KillProc.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\kill-proc.ps1
#
# Destructive by design, so every target is one this test started itself:
#   * mf-procmem-sandbox.exe - a renamed copy of powershell.exe sleeping in
#     %TEMP%; its process name exists nowhere else on the machine;
#   * explorer - NEVER killed: the test asserts it is REFUSED (protected).
#
# The numbered-list mapping (selection -> row) is unit-tested via AST with
# synthetic rows, so no test ever has to guess which slot a real windowed
# process occupies - picking "1" on a live machine could otherwise kill
# whatever the user is working in. Same lesson as tests/windowed-protection.ps1:
# own the target, assert structure (process liveness, log keywords), never text.
#
# Isolation: logs go to a %TEMP% directory, the real protect-list.txt is never
# read (-ProtectFile defaults aside, this test passes none), the desktop alert
# file is not involved (manual kills do not write it), and the scheduled task
# is never touched.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$sandbox = Join-Path $env:TEMP 'mf-procmem-sandbox.exe'
$logDir = Join-Path $env:TEMP ('mf-kill-test-log-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('ok    {0}' -f $name) }
    else { Write-Host ('FAIL  {0}  ({1})' -f $name, $detail); $script:fail++ }
}

function Invoke-Guard([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-LogDir', $logDir) + $extra
    & powershell @argList 2>&1 | Out-String
}

function Wait-Gone([int]$Id, [int]$Seconds = 20) {
    for ($i = 0; $i -lt $Seconds * 2; $i++) {
        if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-TestLog {
    $file = Get-ChildItem -LiteralPath $logDir -Filter '*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $file) { return '' }
    return (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
}

# ---------------------------------------------------------------------------
# unit: selection -> row mapping, via AST (synthetic rows, no live processes)
# ---------------------------------------------------------------------------
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "memory-guard.ps1 has $($errors.Count) parse error(s)" }

$fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-KillTargets'
    }, $true)
if ($fn.Count -ne 1) { throw "expected exactly one Select-KillTargets, found $($fn.Count)" }
Invoke-Expression $fn[0].Extent.Text

$rows = @(
    [pscustomobject]@{ Name = 'aaa'; Pid = 11; WS_MB = 100; Title = ''; Hung = $false; Proc = $null },
    [pscustomobject]@{ Name = 'bbb'; Pid = 22; WS_MB = 200; Title = ''; Hung = $true; Proc = $null },
    [pscustomobject]@{ Name = 'ccc'; Pid = 33; WS_MB = 50; Title = ''; Hung = $false; Proc = $null }
)

$r = Select-KillTargets -Rows $rows -Selection '2'
Check 'number picks that row' ($r.Targets.Count -eq 1 -and $r.Targets[0].Pid -eq 22) ('count=' + $r.Targets.Count)
$r = Select-KillTargets -Rows $rows -Selection '1 3'
Check 'two numbers pick two rows' ($r.Targets.Count -eq 2) ('count=' + $r.Targets.Count)
$r = Select-KillTargets -Rows $rows -Selection '1,1'
Check 'same number twice is deduped' ($r.Targets.Count -eq 1 -and $r.Targets[0].Pid -eq 11) ('count=' + $r.Targets.Count)
$r = Select-KillTargets -Rows $rows -Selection '9'
Check 'out-of-range number selects nothing' ($r.Targets.Count -eq 0) ('count=' + $r.Targets.Count)
Check 'out-of-range number is noticed' (@($r.Notices).Count -eq 1 -and $r.Notices[0] -match '9') ('notices=' + @($r.Notices).Count)
$r = Select-KillTargets -Rows $rows -Selection '2 9'
Check 'valid number survives an invalid one' ($r.Targets.Count -eq 1 -and $r.Targets[0].Pid -eq 22) ('count=' + $r.Targets.Count)

# ---------------------------------------------------------------------------
# e2e: list / no-match / cancel / no-confirmation / protected refusal / kill
# ---------------------------------------------------------------------------
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $sandbox -Force
$proc = Start-Process -FilePath $sandbox -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -WindowStyle Hidden -PassThru
try {
    # list only: an empty selection cancels before anything can be killed
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', ';n')
    Check 'the list is printed' ($out -match 'pid=\d+') $out.Trim()
    Check 'empty selection kills nothing' ($out -notmatch '已终止') $out.Trim()
    Check 'sandbox survives the listing' ([bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) 'sandbox gone'

    # a name that matches nothing: notice, no kill
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', '__no_such_proc__;y')
    Check 'unknown name is echoed' ($out -match '__no_such_proc__') $out.Trim()
    Check 'unknown name kills nothing' ($out -notmatch '已终止') $out.Trim()
    Check 'sandbox still alive' ([bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) 'sandbox gone'

    # explicit "n": cancel
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', 'mf-procmem-sandbox;n')
    Check 'answering n kills nothing' ($out -notmatch '已终止') $out.Trim()
    Check 'sandbox survives a cancelled kill' ([bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) 'sandbox gone'
    Check 'cancel is logged' ((Get-TestLog) -match 'MANUAL\s+aborted by user') 'log has no aborted-by-user line'

    # no confirmation part at all: the safe default is no kill
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', 'mf-procmem-sandbox')
    Check 'missing confirmation kills nothing' ($out -notmatch '已终止') $out.Trim()
    Check 'sandbox survives an unconfirmed kill' ([bool](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) 'sandbox gone'
    Check 'unconfirmed abort is logged' ((Get-TestLog) -match 'MANUAL\s+aborted \(no confirmation') 'log has no no-confirmation line'

    # a protected process is refused, not killed (a refusal is no action, so
    # it is reported on the console only - the log records what was killed)
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', 'explorer;y')
    Check 'protected name is echoed' ($out -match 'explorer') $out.Trim()
    Check 'explorer is still alive' ([bool](Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) 'explorer was killed!'
    Check 'nothing was killed' ($out -notmatch '已终止') $out.Trim()

    # the real thing: name + y
    $out = Invoke-Guard @('-KillProc', '-KillProcInput', 'mf-procmem-sandbox;y')
    Check 'the kill is reported' ($out -match '已终止') $out.Trim()
    Check 'sandbox is gone' (Wait-Gone $proc.Id) 'sandbox still running'
    Check 'kill is logged with the MANUAL keyword' ((Get-TestLog) -match 'MANUAL\s+stopped mf-procmem-sandbox') 'log has no MANUAL stopped line'
    Check 'kill logs the working set' ((Get-TestLog) -match 'MANUAL\s+stopped mf-procmem-sandbox pid=\d+ ws=\d+MB') 'log line malformed'
    Check 'exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    foreach ($left in @(Get-Process -Name 'mf-procmem-sandbox' -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $left.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $logDir -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
