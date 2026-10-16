# view-modes.ps1 -- the three console views behind the tray's right-click menu.
#
# "查看保护名单" / "编辑名单文件" / "看今天的日志" must be readable *in a console*:
# the tray opens a console window and keeps it open with -NoExit, where the old
# spelling either launched notepad or started a bare powershell that printed and
# vanished (which reads as "the entry is broken").
#
# Those views are plain script modes, so they can be checked without a tray, a
# click or a window:
#   -ListProtected -ProtectFile <tmp>     effective list + "not running" hint
#   -ShowProtectFile -ProtectFile <tmp>   the raw file + how to change it
#   -ShowLog -LogDir <tmp> -LogTail N     the tail of today's log
# Plus a static wiring check on the tray handlers themselves, because the
# regression that is invisible here - "the window flashed and closed" - lives in
# the -NoExit argument, not in the view.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:pass = 0
$script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ('ok    ' + $name) }
    else { $script:fail++; Write-Host ('FAIL  ' + $name + $(if ($detail) { ' -- ' + $detail } else { '' })) }
}
function Run-Guard([string[]]$extra) {
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $script @extra 2>&1
    return @{ Code = $LASTEXITCODE; Text = (@($out) -join "`n") }
}

$tmp = Join-Path $env:TEMP ('mf-view-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # a whitelist file with a comment, one name that cannot be running, one real one
    $protect = Join-Path $tmp 'protect.txt'
    [IO.File]::WriteAllLines($protect, @('# comment line', 'mf-absent-viewcheck', 'explorer'))

    # 1) -ListProtected: the effective list, plus the "not running -> typo?" hint
    $r = Run-Guard @('-ListProtected', '-ProtectFile', $protect)
    Check 'ListProtected exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'ListProtected lists the file entries' (($r.Text -match 'mf-absent-viewcheck') -and ($r.Text -match 'explorer')) ''
    Check 'ListProtected flags the name that is not running' ($r.Text -match '当前没有这个进程在运行') ''
    Check 'ListProtected prints the file path' ($r.Text -match [regex]::Escape($protect)) ''

    # 2) -ShowProtectFile: the raw file, numbered, plus how to change it
    $r = Run-Guard @('-ShowProtectFile', '-ProtectFile', $protect)
    Check 'ShowProtectFile exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'ShowProtectFile prints the path' ($r.Text -match [regex]::Escape($protect)) ''
    Check 'ShowProtectFile prints the raw content (comment included)' (($r.Text -match '# comment line') -and ($r.Text -match 'mf-absent-viewcheck')) ''
    Check 'ShowProtectFile teaches both commands' (($r.Text -match '-AddProtect') -and ($r.Text -match '-RemoveProtect')) ''
    Check 'ShowProtectFile points at the picker' ($r.Text -match 'whitelist\.cmd') ''

    # a fresh machine has no protect-list.txt yet
    $missing = Join-Path $tmp 'no-such-file.txt'
    $r = Run-Guard @('-ShowProtectFile', '-ProtectFile', $missing)
    Check 'ShowProtectFile survives a missing file' (($r.Code -eq 0) -and ($r.Text -match '还没有这个文件')) ("exit=$($r.Code)")

    # 3) -ShowLog: the tail of today's log, not the whole file
    $logDir = Join-Path $tmp 'logs'
    New-Item -ItemType Directory -Path $logDir | Out-Null
    $logFile = Join-Path $logDir ('memory-guard-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
    [IO.File]::WriteAllLines($logFile, (1..20 | ForEach-Object { 'line-{0:d2}' -f $_ }))
    $r = Run-Guard @('-ShowLog', '-LogDir', $logDir, '-LogTail', '5')
    Check 'ShowLog exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'ShowLog prints the log path' ($r.Text -match [regex]::Escape($logFile)) ''
    Check 'ShowLog says how many lines it printed' (($r.Text -match '共 20 行') -and ($r.Text -match '最新 5 行')) ''
    Check 'ShowLog prints exactly the last 5 lines' (($r.Text -match 'line-20') -and ($r.Text -match 'line-16') -and ($r.Text -notmatch 'line-15')) ''
    Check 'ShowLog shows the follow hint' ($r.Text -match '-Wait') ''

    $emptyDir = Join-Path $tmp 'empty'
    New-Item -ItemType Directory -Path $emptyDir | Out-Null
    $r = Run-Guard @('-ShowLog', '-LogDir', $emptyDir)
    Check 'ShowLog survives "no log yet"' (($r.Code -eq 0) -and ($r.Text -match '今天还没有日志')) ("exit=$($r.Code)")

    # 4) wiring: every view entry keeps its console open, and no editor is involved
    $src = Get-Content -LiteralPath $script -Raw
    Check 'tray 查看保护名单 keeps its window open' ($src -match "-NoExit'[^\r\n]*-ListProtected") ''
    Check 'tray 编辑名单文件 opens the file view' ($src -match "-NoExit'[^\r\n]*-ShowProtectFile") ''
    Check 'tray 看今天的日志 opens the log view' ($src -match "-NoExit'[^\r\n]*-ShowLog") ''
    Check 'no editor is launched from the tray' ($src -notmatch 'notepad') ''
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:fail) { Write-Host ('{0} check(s) failed' -f $script:fail); exit 1 }
Write-Host 'all checks passed'
exit 0
