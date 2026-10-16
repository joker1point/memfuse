# foreground-app.ps1 -- "the app you are looking at is off limits" rule.
#
# Get-Candidates hands its list to Remove-ForegroundApp, which drops every
# process whose name equals the foreground window's process name. The name is
# the point, not the pid: a browser owns its window in the main process, while
# the page you are reading runs in a child process carrying the same name, so a
# pid-only rule still shoots the tab you have open (2026-10-16 - the guard
# killed a Tabbit renderer while its page was being read).
#
# The rule is one pure function, so this test pulls it out with the AST instead
# of starting a guard: no guard, no windows, no stealing your focus.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ('ok    ' + $name) }
    else { $script:fail++; Write-Host ('FAIL  ' + $name + $(if ($detail) { ' -- ' + $detail } else { '' })) }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
Check 'script parses' (@($errors).Count -eq 0) ("$(@($errors).Count) parse error(s)")

$fn = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-ForegroundApp'
    }, $true)
Check 'Remove-ForegroundApp is defined in the guard' ($null -ne $fn) ''
if (-not $fn) { Write-Host ('{0} check(s) failed' -f $script:fail); exit 1 }

# the function only reads ProcessName, so plain objects are valid stand-ins
Invoke-Expression $fn.Extent.Text

function New-Procs([string[]]$names) {
    $i = 100
    foreach ($n in $names) { $i++; [pscustomobject]@{ ProcessName = $n; Id = $i } }
}

$names = @('Tabbit Browser', 'msedge', 'Tabbit Browser', 'mf-sandbox')

$kept = @(Remove-ForegroundApp -List (New-Procs $names) -ForegroundName 'Tabbit Browser')
Check 'foreground app family is dropped' `
    ((@($kept).Count -eq 2) -and (@($kept | Where-Object { $_.ProcessName -eq 'Tabbit Browser' }).Count -eq 0)) `
    (($kept | ForEach-Object { $_.ProcessName }) -join ' | ')

Check 'the rest keeps its order' `
    (((@($kept | ForEach-Object { $_.ProcessName }) -join ',') -eq 'msedge,mf-sandbox')) `
    (($kept | ForEach-Object { $_.ProcessName }) -join ' | ')

$kept = @(Remove-ForegroundApp -List (New-Procs $names) -ForegroundName 'tabbit browser')
Check 'match is case-insensitive' (@($kept).Count -eq 2) (($kept | ForEach-Object { $_.ProcessName }) -join ' | ')

$kept = @(Remove-ForegroundApp -List (New-Procs $names) -ForegroundName 'explorer')
Check 'an unrelated foreground changes nothing' (@($kept).Count -eq 4) (($kept | ForEach-Object { $_.ProcessName }) -join ' | ')

$kept = @(Remove-ForegroundApp -List (New-Procs $names) -ForegroundName '')
Check 'no foreground information -> nothing is dropped' (@($kept).Count -eq 4) (($kept | ForEach-Object { $_.ProcessName }) -join ' | ')

$kept = @(Remove-ForegroundApp -List @() -ForegroundName 'Tabbit Browser')
Check 'an empty list stays empty' (@($kept).Count -eq 0) ''

# the wiring itself: Get-Candidates must run the list through the rule
$src = Get-Content -LiteralPath $script -Raw
Check 'Get-Candidates applies the rule' ($src -match 'Remove-ForegroundApp\s+-List\s+\$list\s+-ForegroundName\s+\(Get-ForegroundName\)') ''

if ($script:fail) { Write-Host ('{0} check(s) failed' -f $script:fail); exit 1 }
Write-Host 'all checks passed'
exit 0
