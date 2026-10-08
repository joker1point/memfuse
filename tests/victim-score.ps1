# Unit checks for the -PreferIdle victim scoring.
#
# The scoring function is extracted from the guard with the PowerShell AST and
# evaluated on its own: loading memory-guard.ps1 normally would start the guard
# and begin watching memory, which a test must never do.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\victim-score.ps1

$ErrorActionPreference = 'Stop'

$guard = Join-Path (Split-Path -Parent $PSScriptRoot) 'memory-guard.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guard, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "memory-guard.ps1 has $($errors.Count) parse error(s)" }

$fn = $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-VictimScore'
    }, $true)
if ($fn.Count -ne 1) { throw "expected exactly one Get-VictimScore, found $($fn.Count)" }
Invoke-Expression $fn[0].Extent.Text

$script:failed = 0
function Check {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ne $Expected) {
        Write-Host ("FAIL  {0}: got {1}, want {2}" -f $Name, $Actual, $Expected)
        $script:failed++
    } else {
        Write-Host ("ok    {0}" -f $Name)
    }
}

$MB = 1MB

Check 'idle keeps full working set'   (Get-VictimScore -WorkingSet64 (900 * $MB) -CpuKnown -Busy:$false) (900 * $MB)
Check 'unknown cpu is neutral'        (Get-VictimScore -WorkingSet64 (900 * $MB)) (900 * $MB)
Check 'minimized x0.7'                (Get-VictimScore -WorkingSet64 (900 * $MB) -Minimized -CpuKnown -Busy:$false) ([math]::Round(900 * $MB * 0.7))
Check 'busy x0.7'                     (Get-VictimScore -WorkingSet64 (900 * $MB) -CpuKnown -Busy) ([math]::Round(900 * $MB * 0.7))
Check 'foreground x0.2'               (Get-VictimScore -WorkingSet64 (900 * $MB) -Foreground -CpuKnown -Busy:$false) ([math]::Round(900 * $MB * 0.2))
Check 'minimized+busy+foreground'     (Get-VictimScore -WorkingSet64 (900 * $MB) -Minimized -Foreground -CpuKnown -Busy) ([math]::Round(900 * $MB * 0.7 * 0.7 * 0.2))

# the two claims that matter: idle beats a bigger foreground app, but a big busy
# process still beats a small idle one (memory relief is still the job)
Check 'idle 600MB beats foreground 900MB' ([bool](
        (Get-VictimScore -WorkingSet64 (600 * $MB) -CpuKnown -Busy:$false) -gt
        (Get-VictimScore -WorkingSet64 (900 * $MB) -Foreground -CpuKnown -Busy:$false))) $true
Check 'busy 900MB beats idle 500MB' ([bool](
        (Get-VictimScore -WorkingSet64 (900 * $MB) -CpuKnown -Busy) -gt
        (Get-VictimScore -WorkingSet64 (500 * $MB) -CpuKnown -Busy:$false))) $true

if ($script:failed) { throw "$($script:failed) check(s) failed" }
Write-Host 'all checks passed'
