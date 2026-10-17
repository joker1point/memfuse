# json-interface.ps1 -- the read-only "hand it to an agent" interface.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\json-interface.ps1
#
# What it proves (both switches exit before the guard branch, so this test never
# starts the guard, never kills, never demotes and never rewrites the whitelist):
#
#   -Json -OutFile <path>
#       * the file is written, is valid JSON, and carries schema memfuse.status v1;
#       * the documented fields exist with sane values (memory / tier / thresholds
#         / candidates / demoted / protected / todayLog / paths);
#       * every candidate row has name + pid + workingSetMB;
#       * "read-only" is asserted, not assumed - protect-list.txt and the log
#         directory are hashed before and after and must be byte-identical.
#       * the same JSON also comes out on stdout when -OutFile is omitted.
#   -AgentGuide
#       * prints the handover note with the real script path interpolated, and
#         names the actions an agent may ask for (including the ExeTrace link).
#
# No sandbox process is needed: this interface is about state, not about a victim.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'memory-guard.ps1'
$protectFile = Join-Path $root 'protect-list.txt'
$logDir = Join-Path $root 'logs'
$fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host ('ok    {0}' -f $name) }
    else { Write-Host ('FAIL  {0}  ({1})' -f $name, $detail); $script:fail++ }
}

function Invoke-Guard([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $extra
    & powershell @argList 2>&1 | Out-String
}

function Get-TreeHash([string]$dir) {
    # Name + length + last-write-time of every file under $dir, in one string.
    if (-not (Test-Path -LiteralPath $dir)) { return '<missing>' }
    return (@(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';')
}

$tmp = Join-Path $env:TEMP ('mf-json-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$jsonPath = Join-Path $tmp 'status.json'
$guidePath = Join-Path $tmp 'agent-guide.md'

# Chinese comes back through the child's stdout: decode it as UTF-8 here, or the
# parent would read it with the console code page (GBK) and every Chinese
# assertion below would fail on mojibake instead of on a real defect.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

try {
    # ---------------------------------------------------------------- read-only baseline
    $protectBefore = if (Test-Path -LiteralPath $protectFile) { (Get-FileHash -LiteralPath $protectFile -Algorithm SHA256).Hash } else { '<missing>' }
    $logBefore = Get-TreeHash $logDir

    # ---------------------------------------------------------------- -Json -OutFile
    $out = Invoke-Guard @('-Json', '-OutFile', $jsonPath)
    Check '-Json exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE :: " + $out.Trim())
    Check '-Json writes the file' (Test-Path -LiteralPath $jsonPath) $out.Trim()
    Check '-Json keeps the console quiet about internals' ($out -notmatch 'Unhandled|Exception') $out.Trim()

    $raw = if (Test-Path -LiteralPath $jsonPath) { Get-Content -LiteralPath $jsonPath -Raw } else { '' }
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json } catch { }
    Check 'output parses as JSON (BOM readable by PowerShell)' ($null -ne $doc) $raw.Substring(0, [math]::Min(120, $raw.Length))

    if ($doc) {
        Check 'schema is memfuse.status v1' ($doc.schema -eq 'memfuse.status' -and $doc.schemaVersion -eq 1) ("schema=$($doc.schema) v=$($doc.schemaVersion)")
        Check 'memory block has totals' ($doc.memory.totalMB -gt 0 -and $doc.memory.freeMB -ge 0 -and $doc.memory.freePercent -ge 0) ($doc.memory | ConvertTo-Json -Compress)
        Check 'free percent matches free/total' ([math]::Abs([double]$doc.memory.freePercent - [math]::Round(100.0 * $doc.memory.freeMB / [math]::Max($doc.memory.totalMB, 1), 1)) -le 0.2) ("$($doc.memory.freePercent) vs $($doc.memory.freeMB)/$($doc.memory.totalMB)")
        Check 'commit percent is a percentage' ($doc.memory.commitPercent -ge 0 -and $doc.memory.commitPercent -le 100) ("$($doc.memory.commitPercent)")
        Check 'tier is one of the three bands' (@('healthy', 'warn', 'critical') -contains $doc.tier) ("tier=$($doc.tier)")
        Check 'thresholds mirror the defaults' ($doc.thresholds.warnPercent -eq 12 -and $doc.thresholds.criticalPercent -eq 7 -and $doc.thresholds.maxKillsPerHour -ge 1) ($doc.thresholds | ConvertTo-Json -Compress)
        Check 'thresholds carry the demote tier' ($doc.thresholds.demoteEnabled -eq $true -and $doc.thresholds.demoteHoldSec -ge 0) ($doc.thresholds | ConvertTo-Json -Compress)
        Check 'paths point at the real files' ($doc.paths.protectFile -eq $protectFile -and $doc.paths.script -eq $script) ("$($doc.paths.protectFile)")

        $cand = @($doc.candidates)
        $shape = $true
        foreach ($c in $cand) {
            if (-not $c.name -or $c.pid -le 0 -or $c.workingSetMB -lt 0) { $shape = $false }
        }
        Check 'candidate rows have name/pid/workingSetMB' $shape ($doc.candidates | ConvertTo-Json -Compress)
        Check 'candidates are not the foreground app (family)' (($cand | Where-Object { $_.name -eq (Get-Process -Id $PID).ProcessName }).Count -eq 0) ($doc.candidates | ConvertTo-Json -Compress)

        Check 'demoted list is an array' ($null -ne $doc.demoted) ($doc.demoted | ConvertTo-Json -Compress)
        $entries = @($doc.protected.fileEntries | Where-Object { $_ })   # 去掉 JSON null 带来的伪元素
        Check 'protected counts agree with entries' ([int]$doc.protected.fileEntryCount -eq $entries.Count) ("count=$($doc.protected.fileEntryCount) entries=$($entries.Count)")
        Check 'protected includes the built-in set' ($doc.protected.builtinCount -gt 5) ("builtin=$($doc.protected.builtinCount)")
        Check 'log tail is capped by LogTail' (@($doc.todayLog.tail).Count -le 60) ("tail=$(@($doc.todayLog.tail).Count) lines=$($doc.todayLog.lines)")
    }

    # ---------------------------------------------------------------- stdout mode
    $plain = Invoke-Guard @('-Json')
    Check '-Json without -OutFile prints JSON to stdout' ($plain -match '"schema"\s*:\s*"memfuse\.status"') ($plain.Substring(0, [math]::Min(120, $plain.Length)))

    # ---------------------------------------------------------------- read-only proof
    $protectAfter = if (Test-Path -LiteralPath $protectFile) { (Get-FileHash -LiteralPath $protectFile -Algorithm SHA256).Hash } else { '<missing>' }
    Check 'protect-list.txt untouched by the read path' ($protectBefore -eq $protectAfter) ("before=$protectBefore after=$protectAfter")
    Check 'log dir untouched by the read path' ($logBefore -eq (Get-TreeHash $logDir)) 'log dir changed'

    # ---------------------------------------------------------------- -AgentGuide
    $guide = Invoke-Guard @('-AgentGuide')
    Check '-AgentGuide exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
    Check 'guide interpolates the real script path' ($guide -match [regex]::Escape($script)) ($guide.Substring(0, [math]::Min(160, $guide.Length)))
    Check 'guide documents the read entry (-Json -OutFile)' ($guide -match '-Json -OutFile') ''
    Check 'guide documents the whitelist action' ($guide -match '-AddProtect') ''
    Check 'guide states the read-only boundary' ($guide -match '(?i)read-only|只读') ''
    Check 'guide covers the ExeTrace link' ($guide -match '--whitelist') ''

    # ---------------------------------------------------------------- -AgentGuide -OutFile
    # The reliable path for agents: a UTF-8 BOM file, not a redirected pipe.
    $out = Invoke-Guard @('-AgentGuide', '-OutFile', $guidePath)
    Check '-AgentGuide -OutFile exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE :: " + $out.Trim())
    $guideRaw = if (Test-Path -LiteralPath $guidePath) { Get-Content -LiteralPath $guidePath -Raw } else { '' }
    Check '-AgentGuide -OutFile writes the note' ($guideRaw -match '交给 Agent 的接口说明') $guideRaw.Substring(0, [math]::Min(120, $guideRaw.Length))
    Check 'landed note keeps the Chinese boundary text' ($guideRaw -match '只读') ''
    Check 'landed note carries the read entry too' ($guideRaw -match '-Json -OutFile') ''
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host ('{0} check(s) failed' -f $fail); exit 1 }
Write-Host 'all checks passed'
exit 0
