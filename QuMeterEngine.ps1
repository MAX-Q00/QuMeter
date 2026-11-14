# QuMeterEngine.ps1 - headless QuMeter Auto run (used by the scheduled task, "Run once now", and deployed instances).
# SNMP pull -> dated general CSV + e-automate CSV (+ optional MPS CSV) -> daily log + signed status.json.
# File output only: never writes to the e-automate database and never calls an e-automate or MPS API.
# Exit codes: 0 = success, 1 = failed, 2 = completed with errors, 3 = run request rejected (API key).
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$ProgressFile,
    [ValidateSet('schedule','manual')][string]$Trigger = 'schedule'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'QuSnmp.ps1')
. (Join-Path $here 'QuMeterCore.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$root = Split-Path -Parent $ConfigPath
if (-not $root) { $root = $here }

$script:logPath = $null
$script:statusFolder = Join-Path $root 'logs'
$script:apiKey = ''
$started = Get-Date
$status = [ordered]@{
    schema   = 1
    instance = [ordered]@{ computer = "$env:COMPUTERNAME"; installDir = $here; configPath = $ConfigPath; user = $(try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { "$env:USER" }); version = (Get-QmVersion) }
    run      = [ordered]@{ trigger = $Trigger; requestId = $null; startedAt = $started.ToString('yyyy-MM-dd HH:mm:ss'); finishedAt = $null; durationSec = 0; success = $false; partial = $false; exitCode = 1; errorStage = $null; error = $null }
    counts   = [ordered]@{ hosts = 0; ok = 0; withSerial = 0; timeout = 0; error = 0 }
    devices  = @()
    files    = [ordered]@{ general = $null; eautomate = $null; mps = $null; log = $null }
    writeErrors = @()
    warnings = @()
}

function Write-Progress2([string]$Line) {
    if (-not $ProgressFile) { return }
    try { [System.IO.File]::AppendAllText($ProgressFile, $Line + [Environment]::NewLine) } catch { }
}
function Log([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:logPath) {
        try {
            $dir = Split-Path -Parent $script:logPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
        } catch { }
    }
    Write-Progress2 "LOG $line"
    Write-Host $line
}
function Step([string]$Text) { Write-Progress2 "STEP $Text"; Log Info $Text }

function Save-Status([int]$Code) {
    $end = Get-Date
    $status.run.finishedAt = $end.ToString('yyyy-MM-dd HH:mm:ss')
    $status.run.durationSec = [math]::Round(($end - $started).TotalSeconds, 1)
    $status.run.exitCode = $Code
    $status.files.log = $script:logPath
    $json = New-QmSignedEnvelope -Object $status -Key $script:apiKey
    foreach ($folder in @($script:statusFolder, (Join-Path $root 'logs')) | Select-Object -Unique) {
        try {
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            $tmp = Join-Path $folder 'status.json.tmp'
            [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination (Join-Path $folder 'status.json') -Force
        } catch { Write-Host "Could not write status.json to ${folder}: $($_.Exception.Message)" }
    }
    Write-Progress2 "DONE $Code"
}
function Fail([string]$Stage, [string]$Message, [int]$Code = 1) {
    $status.run.errorStage = $Stage
    $status.run.error = $Message
    $status.run.success = $false
    Log Error "[$Stage] $Message"
    Save-Status $Code
    exit $Code
}

# ---- config
try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config file not found: $ConfigPath" }
    $cfg = Read-QmConfig -Path $ConfigPath
} catch { Fail 'config' $_.Exception.Message }

$logFolder = Resolve-QmPath $(if ($cfg.logFolder) { $cfg.logFolder } else { 'logs' }) $root
$outFolder = Resolve-QmPath $(if ($cfg.outputFolder) { $cfg.outputFolder } else { 'output' }) $root
$mpsFolder = Resolve-QmPath $cfg.mpsDropFolder $root
$mapPath   = Resolve-QmPath $(if ($cfg.mappingFile) { $cfg.mappingFile } else { 'e-automate.mapping.json' }) $root
$script:statusFolder = $logFolder
$script:logPath = Join-Path $logFolder ('QuMeter_{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
try { if (-not (Test-Path -LiteralPath $logFolder)) { New-Item -ItemType Directory -Path $logFolder -Force | Out-Null } }
catch { $status.warnings += "Log folder not writable ($logFolder): $($_.Exception.Message). Using $root\logs."; $script:statusFolder = Join-Path $root 'logs'; $script:logPath = Join-Path $script:statusFolder ('QuMeter_{0}.log' -f (Get-Date -Format 'yyyyMMdd')) }

Step "QuMeter Auto $(Get-QmVersion) starting on $env:COMPUTERNAME ($Trigger). Config=$ConfigPath"

# ---- API key + run request
$keyNote = $null
try { $script:apiKey = Get-QmInstanceApiKey -Dir $here -Note ([ref]$keyNote) } catch { $keyNote = "API key load failed: $($_.Exception.Message)" }
if ($keyNote) { Log Warn $keyNote; if ($keyNote -match 'could not|failed') { $status.warnings += $keyNote } }
$reqPath = Join-Path $here 'request.json'
if (Test-Path -LiteralPath $reqPath) {
    $reqJson = ''
    try { $reqJson = [System.IO.File]::ReadAllText($reqPath) } catch { }
    try { Remove-Item -LiteralPath $reqPath -Force } catch { $status.warnings += "Could not delete request.json: $($_.Exception.Message)" }
    $rq = Test-QmRunRequest -Json $reqJson -InstanceKey $script:apiKey
    $status.run.requestId = $rq.RequestId
    if (-not $rq.Accepted) { Fail 'auth' $rq.Reason 3 }
    $status.run.trigger = 'remote request'
    Log Info "Accepted run request $($rq.RequestId)$(if ($script:apiKey) { ' (API key verified)' })."
}

$problems = Test-QmConfig -Config $cfg -Root $root
$schedOnly = @($problems | Where-Object { $_ -match '^(Schedule|Frequency|Pick a day|Day of month|Task name)' })
$fatal = @($problems | Where-Object { $schedOnly -notcontains $_ })
foreach ($p in $schedOnly) { $status.warnings += $p }
if ($fatal.Count) { Fail 'config' ($fatal -join ' ') }

try {
    $mapping = Read-EaMapping -Path $mapPath
    if ($cfg.eaFormat) { $mapping.format = "$($cfg.eaFormat)" }
    if ($cfg.eaSource) { $mapping.source = "$($cfg.eaSource)" }
    if (-not $mapping.remarks -or $mapping.remarks -eq 'Imported by QuMeter') { $mapping.remarks = 'Imported by QuMeter Auto' }
} catch { Fail 'config' "e-automate mapping file is invalid ($mapPath): $($_.Exception.Message)" }

# ---- targets
Step 'Reading printer list'
$targetText = @($cfg.targets)
$targetFile = Resolve-QmPath $cfg.targetFile $root
if ($targetFile) {
    if (Test-Path -LiteralPath $targetFile) { $targetText += Get-Content -LiteralPath $targetFile; Log Info "Loaded targets from $targetFile" }
    else { $status.warnings += "targetFile not found: $targetFile"; Log Warn "targetFile not found: $targetFile" }
}
try { $hosts = [QuMeterSnmp.TargetParser]::Parse(($targetText -join "`n"), 65536) }
catch { Fail 'targets' $_.Exception.Message }
if ($hosts.Count -eq 0) { Fail 'targets' 'No printers to query. Add IPs, ranges, or CIDR in the Automate tab.' }
$status.counts.hosts = $hosts.Count

# ---- SNMP
Step ("Querying {0} address(es) over SNMP {1} (community '{2}', timeout {3} ms)" -f $hosts.Count, $cfg.version, $(if ($cfg.community -eq 'public') { 'public' } else { '***' }), $cfg.timeoutMs)
Write-Progress2 "PROGRESS 0/$($hosts.Count)"
try {
    $client = New-QuSnmpClient -Community $cfg.community -Port ([int]$cfg.port) -TimeoutMs ([int]$cfg.timeoutMs) -Retries ([int]$cfg.retries) -Version $cfg.version
    $job = [QuMeterSnmp.ScanJob]::Start($client, [string[]]$hosts, [int]$(if ($cfg.concurrency) { $cfg.concurrency } else { 32 }))
    $last = -1
    while (-not $job.Wait(500)) {
        if ($job.Done -ne $last) { $last = $job.Done; Write-Progress2 "PROGRESS $last/$($job.Total)" }
    }
    if ($job.Error) { throw $job.Error }
    $readings = $job.Results
    Write-Progress2 "PROGRESS $($job.Total)/$($job.Total)"
} catch { Fail 'snmp' "SNMP scan failed: $($_.Exception.Message)" }

$ok = @($readings | Where-Object { $_.Status -eq 'OK' })
$status.counts.ok = $ok.Count
$status.counts.withSerial = @($ok | Where-Object { $_.Serial }).Count
$status.counts.timeout = @($readings | Where-Object { $_.Status -eq 'Timeout' }).Count
$status.counts.error = $readings.Count - $ok.Count - $status.counts.timeout
$devs = @()
foreach ($r in $readings) {
    $err = $r.ErrorMessage
    if ($r.Status -eq 'OK' -and -not $r.Serial) { $err = 'No serial number reported: left out of the e-automate file (matching is by serial).' }
    $devs += [ordered]@{ ip = $r.Ip; status = $r.Status; serial = $r.Serial; model = $r.Model; total = $r.Total; mono = $r.Mono; color = $r.Color; error = $err }
    if ($r.Status -eq 'OK') { Log Info ("  {0}  serial={1} total={2} mono={3} color={4} model={5}" -f $r.Ip, $r.Serial, $r.Total, $r.Mono, $r.Color, $r.Model) }
    else { Log Warn ("  {0}  {1}: {2}" -f $r.Ip, $r.Status, $r.ErrorMessage) }
}
$status.devices = $devs
Log Info ("SNMP done: ok={0} with-serial={1} timeout={2} error={3}" -f $status.counts.ok, $status.counts.withSerial, $status.counts.timeout, $status.counts.error)

# ---- write files
Step "Writing CSV files to $outFolder"
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
try { if (-not (Test-Path -LiteralPath $outFolder)) { New-Item -ItemType Directory -Path $outFolder -Force | Out-Null } }
catch { $status.writeErrors += "Cannot create output folder ${outFolder}: $($_.Exception.Message)" }
$g = Join-Path $outFolder "QuMeter_$stamp.csv"
$e = Join-Path $outFolder "QuMeter_eautomate_$stamp.csv"
try { Export-QuMeterGeneralCsv -Readings $readings -Path $g; $status.files.general = $g; Log Info "Wrote $g" }
catch { $status.writeErrors += "General CSV to ${g}: $($_.Exception.Message)" }
try { Export-QuMeterEaCsv -Readings $readings -Path $e -Mapping $mapping; $status.files.eautomate = $e; Log Info "Wrote $e" }
catch { $status.writeErrors += "e-automate CSV to ${e}: $($_.Exception.Message)" }
if ($mpsFolder) {
    try {
        if (-not (Test-Path -LiteralPath $mpsFolder)) { New-Item -ItemType Directory -Path $mpsFolder -Force | Out-Null }
        $m = Join-Path $mpsFolder "QuMeter_mps_$stamp.csv"
        Export-QuMeterMpsCsv -Readings $readings -Path $m
        $status.files.mps = $m; Log Info "Wrote MPS drop file $m"
    } catch { $status.writeErrors += "MPS CSV to ${mpsFolder}: $($_.Exception.Message)" }
}
foreach ($w in $status.writeErrors) {
    $hint = ''
    if ($w -match '^\S*\\\\' -or $w -match '\\\\') { $hint = ' (UNC share: if the task runs as SYSTEM, the computer account needs write access; a service account is recommended)' }
    Log Error "WRITE: $w$hint"
}

# ---- retention
if ([int]$cfg.retentionDays -gt 0) {
    $cut = (Get-Date).AddDays(-[int]$cfg.retentionDays)
    $removed = 0
    foreach ($pair in @(@{ d = $outFolder; f = 'QuMeter_*.csv' }, @{ d = $logFolder; f = 'QuMeter*.log' })) {
        if ($pair.d -and (Test-Path -LiteralPath $pair.d)) {
            foreach ($old in @(Get-ChildItem -LiteralPath $pair.d -Filter $pair.f -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })) {
                try { Remove-Item -LiteralPath $old.FullName -Force; $removed++ } catch { $status.warnings += "Retention could not delete $($old.FullName)" }
            }
        }
    }
    if ($removed) { Log Info "Retention: deleted $removed file(s) older than $($cfg.retentionDays) day(s)." }
}

# ---- result
$code = 0
if ($status.writeErrors.Count -gt 0) {
    $code = 2; $status.run.partial = $true; $status.run.errorStage = 'write'
    $status.run.error = "$($status.writeErrors.Count) file write error(s)."
    if (-not $status.files.general -and -not $status.files.eautomate) { $code = 1; $status.run.partial = $false; $status.run.error = 'No output files could be written.' }
} elseif ($status.counts.ok -eq 0) {
    $code = 2; $status.run.partial = $true; $status.run.errorStage = 'snmp'
    $status.run.error = "None of the $($status.counts.hosts) printer address(es) answered SNMP. Check IPs, community, and that UDP 161 is reachable from $env:COMPUTERNAME."
}
$status.run.success = ($code -eq 0)
if ($code -eq 0 -and ($status.counts.timeout + $status.counts.error) -gt 0) { $status.warnings += "$($status.counts.timeout + $status.counts.error) printer(s) did not answer; see devices." }
Step $(if ($code -eq 0) { 'QuMeter Auto finished.' } else { "QuMeter Auto finished with errors: $($status.run.error)" })
Save-Status $code
exit $code
