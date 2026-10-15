# Memory query test for -ShowProcMem.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\proc-memory.ps1
#
# Two levels, same as tests/victim-score.ps1 + tests/windowed-protection.ps1:
#
#   unit     - Test-ProcNameMatch is extracted from the guard with the AST and
#             evaluated on its own (loading memory-guard.ps1 would start the
#             guard and begin watching memory, which a test must never do).
#   e2e      - the sandbox is a renamed copy of powershell.exe sleeping in
#             %TEMP%; its process name (mf-procmem-sandbox) exists nowhere else
#             on the machine, so a match proves the query found THAT process.
#             Same "own the target" idea as the windowed-protection sandbox.
#
# Nothing is ever killed, the guard is never started, no desktop file, no log
# dir and no protect-list.txt are touched: -ShowProcMem exits before the guard
# branch. The scheduled task (if installed) is irrelevant to this test.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$sandbox = Join-Path $env:TEMP 'mf-procmem-sandbox.exe'
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('ok    {0}' -f $name) }
    else { Write-Host ('FAIL  {0}  ({1})' -f $name, $detail); $script:fail++ }
}

function Invoke-Guard([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $extra
    & powershell @argList 2>&1 | Out-String
}

# ---------------------------------------------------------------------------
# unit: the matching function, via AST
# ---------------------------------------------------------------------------
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "memory-guard.ps1 has $($errors.Count) parse error(s)" }

$fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ProcNameMatch'
    }, $true)
if ($fn.Count -ne 1) { throw "expected exactly one Test-ProcNameMatch, found $($fn.Count)" }
Invoke-Expression $fn[0].Extent.Text

Check 'substring, case-insensitive'  ([bool](Test-ProcNameMatch 'chatgpt' 'ChatGPT')) ''
Check 'query with .exe suffix'       ([bool](Test-ProcNameMatch 'chatgpt.exe' 'ChatGPT')) ''
Check 'process name with .exe'       ([bool](Test-ProcNameMatch 'chatgpt' 'ChatGPT.exe')) ''
Check 'all caps query'               ([bool](Test-ProcNameMatch 'CHATGPT' 'chatgpt')) ''
Check 'substring of a longer name'   ([bool](Test-ProcNameMatch 'code' 'CodeBuddy CN')) ''
Check 'no false substring'           (-not (Test-ProcNameMatch 'codebuddy' 'Code')) 'matched'
Check 'wildcard star matches'        ([bool](Test-ProcNameMatch 'chat*' 'ChatGPT')) ''
Check 'wildcard star misses'         (-not (Test-ProcNameMatch 'chat*' 'CodeBuddy')) 'matched'
Check 'wildcard question mark'       ([bool](Test-ProcNameMatch '?ode' 'Code')) ''
Check 'empty query matches nothing'  (-not (Test-ProcNameMatch '' 'Code')) 'matched'
Check 'empty process name'           (-not (Test-ProcNameMatch 'code' '')) 'matched'

# ---------------------------------------------------------------------------
# e2e: query the sandbox by name / with .exe / wrong case / wildcard /
#      together with a name that does not exist / a name that matches nothing
# ---------------------------------------------------------------------------
Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Destination $sandbox -Force
$proc = Start-Process -FilePath $sandbox -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru
try {
    $out = Invoke-Guard @('-ShowProcMem', 'mf-procmem-sandbox')
    Check 'finds the sandbox by name'      ($out -match 'mf-procmem-sandbox') $out.Trim()
    Check 'prints a pid'                   ($out -match 'pid=\d+') $out.Trim()
    Check 'prints a working set in MB'     ($out -match '\d+ MB') $out.Trim()
    Check 'prints the total line'          ($out -match '[\d.]+%') $out.Trim()

    $out = Invoke-Guard @('-ShowProcMem', 'MF-PROCMEM-SANDBOX.EXE')
    Check '.exe suffix + wrong case hit'   ($out -match 'pid=\d+') $out.Trim()

    $out = Invoke-Guard @('-ShowProcMem', 'mf-proc*')
    Check 'wildcard hit'                   ($out -match 'pid=\d+') $out.Trim()

    $out = Invoke-Guard @('-ShowProcMem', 'mf-procmem-sandbox,__no_such_proc__')
    Check 'multi-name: hit survives a miss' ($out -match 'mf-procmem-sandbox') $out.Trim()

    # protected processes are informational too: the query never hides them
    $out = Invoke-Guard @('-ShowProcMem', 'svchost')
    Check 'protected names are still listed' ($out -match 'pid=\d+') $out.Trim()

    $out = Invoke-Guard @('-ShowProcMem', '__no_such_proc__')
    Check 'no match: prints no pid'        ($out -notmatch 'pid=') $out.Trim()
    Check 'no match: echoes the query'     ($out -match '__no_such_proc__') $out.Trim()
    Check 'no match: exits 0'              ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")

    # a blank name is dropped by the -File argument layer when truly empty,
    # so a single space is what "user pressed enter on nothing" looks like
    $out = Invoke-Guard @('-ShowProcMem', ' ')
    Check 'blank name prints the usage'  ($out -match 'ShowProcMem <') $out.Trim()
    Check 'blank name exits 0'           ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
} finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    foreach ($left in @(Get-Process -Name 'mf-procmem-sandbox' -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $left.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
