# Tests for QuMeterCore (config round-trip, task XML, status.json) and the headless engine.
#   pwsh -NoProfile -File tests/Test-QuMeterCore.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
. (Join-Path $root 'QuSnmp.ps1')
. (Join-Path $root 'QuMeterCore.ps1')
$script:failed = 0; $script:passed = 0
function Assert-True($cond, $name) { if ($cond) { $script:passed++; Write-Host "  PASS  $name" } else { $script:failed++; Write-Host "  FAIL  $name" } }
function Assert-Eq($a, $e, $name) { if ("$a" -eq "$e") { $script:passed++; Write-Host "  PASS  $name" } else { $script:failed++; Write-Host "  FAIL  $name  expected=[$e] actual=[$a]" } }
$tmp = Join-Path $here 'tmp-out/core'
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null


function Get-TestPython {
    foreach ($name in @('python','py','python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and ($cmd.Source -notmatch 'WindowsApps')) { return $cmd.Source }
    }
    throw 'Python not found (need a real python on PATH, not the Windows Store stub)'
}
function Get-TestPowerShell {
    if ($env:SystemRoot) {
        $sys = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $sys) { return $sys }
    }
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh -and $pwsh.Source -and ($pwsh.Source -notmatch 'WindowsApps')) { return $pwsh.Source }
    throw 'Windows PowerShell not found'
}
$script:TestPython = Get-TestPython
$script:TestPwsh = Get-TestPowerShell
Write-Host '=== Config round-trip ==='
$c = Get-QmDefaultConfig
$c.targets = @('10.0.0.10','10.0.1.0/24')
$c.community = 'shopro'; $c.timeoutMs = 2500; $c.retentionDays = 30; $c.eaFormat = 'advanced'
$c.outputFolder = '\\fileserver\meters'; $c.mpsDropFolder = 'D:\MPS\in'
$c.schedule.frequency = 'Monthly'; $c.schedule.dayOfMonth = 'Last'; $c.schedule.time = '05:30'; $c.schedule.runAs = 'SYSTEM'
$c['apiKey'] = 'should-not-be-saved'
$c['deploy'] = [ordered]@{ target = 'PAPERCUT01'; installPath = 'C:\ProgramData\QuMeter' }
$p = Join-Path $tmp 'config.json'
Save-QmConfig -Config $c -Path $p
$raw = Get-Content $p -Raw
Assert-True ($raw -notmatch 'should-not-be-saved') 'API key never written to config.json'
Assert-True ($raw -notmatch '"deploy"') 'deploy block never written to config.json'
$r = Read-QmConfig -Path $p
Assert-Eq (@($r.targets) -join ';') '10.0.0.10;10.0.1.0/24' 'targets round-trip'
Assert-Eq $r.community 'shopro' 'community round-trip'
Assert-Eq $r.timeoutMs 2500 'timeout round-trip'
Assert-Eq $r.retentionDays 30 'retention round-trip'
Assert-Eq $r.eaFormat 'advanced' 'eaFormat round-trip'
Assert-Eq $r.eaRemarks 'Imported by QuMeter' 'eaRemarks default when omitted'
Assert-Eq $r.excludeNoSerial $false 'excludeNoSerial default when omitted'
Assert-True (-not $r.Contains('deploy')) 'deploy key stripped on read of saved config'
$c.excludeNoSerial = $true
Save-QmConfig -Config $c -Path (Join-Path $tmp 'exclude-noserial.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'exclude-noserial.json')).excludeNoSerial $true 'excludeNoSerial true round-trip'
$c.excludeNoSerial = $false
Save-QmConfig -Config $c -Path (Join-Path $tmp 'exclude-noserial-off.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'exclude-noserial-off.json')).excludeNoSerial $false 'excludeNoSerial false round-trip'
$c.eaRemarks = 'Hello, "shop" meters {serial}'
Save-QmConfig -Config $c -Path (Join-Path $tmp 'remarks.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'remarks.json')).eaRemarks 'Hello, "shop" meters {serial}' 'eaRemarks with comma and quotes round-trip'
$cBlank = Get-QmDefaultConfig; $cBlank.targets = @('10.0.0.1'); $cBlank.eaRemarks = ''
Save-QmConfig -Config $cBlank -Path (Join-Path $tmp 'remarks-blank.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'remarks-blank.json')).eaRemarks '' 'empty eaRemarks stays blank'
Assert-Eq $r.outputFolder '\\fileserver\meters' 'UNC output round-trip'
Assert-Eq $r.schedule.frequency 'Monthly' 'frequency round-trip'
Assert-Eq $r.schedule.dayOfMonth 'Last' 'dayOfMonth round-trip'
$one = Get-QmDefaultConfig; $one.targets = @('10.9.9.9'); Save-QmConfig $one (Join-Path $tmp 'one.json')
Assert-Eq (@((Read-QmConfig (Join-Path $tmp 'one.json')).targets).Count) 1 'single target stays a list'
$partial = Join-Path $tmp 'partial.json'; '{ "community": "x", "schedule": { "time": "07:15" } }' | Set-Content $partial
$pr = Read-QmConfig $partial
Assert-Eq $pr.schedule.frequency 'Daily' 'missing nested keys fall back to defaults'
Assert-Eq $pr.schedule.time '07:15' 'partial nested override kept'
Assert-True (-not $pr.Contains('deploy')) 'missing deploy stays absent (no default deploy block)'
Assert-Eq $pr.eaRemarks 'Imported by QuMeter' 'missing eaRemarks falls back to default'
Assert-Eq $pr.excludeNoSerial $false 'missing excludeNoSerial falls back to false'
Assert-Eq (Test-QmConfig -Config $r -Root $tmp).Count 0 'valid config passes validation'
$bad = Get-QmDefaultConfig; $bad.schedule.time = '25:00'; $bad.schedule.frequency = 'Weekly'; $bad.schedule.dayOfWeek = 'Funday'
$errs = Test-QmConfig -Config $bad -Root $tmp
Assert-True ($errs.Count -ge 3) 'invalid config reports problems (targets, time, weekday)'
$t = ConvertTo-QmTargetList "10.0.0.1`r`n`r`n 10.0.0.2 `n10.0.0.0/30"
Assert-Eq ($t -join ';') '10.0.0.1;10.0.0.2;10.0.0.0/30' 'target text -> list'

# Leftover deploy / secret keys in an older config.json are dropped
$legacyDeploy = Join-Path $tmp 'old-deploy.json'
@'
{ "community": "x", "targets": ["10.0.0.1"], "apiKey": "qm_shouldvanish", "deploy": { "target": "PAPERCUT01", "installPath": "C:\\ProgramData\\QuMeter", "runAfterDeploy": true } }
'@ | Set-Content $legacyDeploy
$ld = Read-QmConfig $legacyDeploy
Assert-True (-not $ld.Contains('deploy')) 'Read-QmConfig drops leftover deploy block'
Assert-True (-not $ld.Contains('apiKey')) 'Read-QmConfig drops leftover apiKey'
Save-QmConfig $ld (Join-Path $tmp 'old-deploy-resaved.json')
$resaved = Get-Content (Join-Path $tmp 'old-deploy-resaved.json') -Raw
Assert-True ($resaved -notmatch '"deploy"' -and $resaved -notmatch 'qm_shouldvanish') 'resaved config has no deploy block or apiKey'

Write-Host '=== Legacy QuMeter Auto import ==='
$leg = Join-Path $tmp 'legacy'; New-Item -ItemType Directory $leg -Force | Out-Null
'{ "community":"old", "targets":["10.1.1.1"], "targetFile":"devices.txt", "outputFolder":"output", "logFolder":"logs" }' | Set-Content (Join-Path $leg 'config.json')
"# comment`n10.1.1.2`n10.1.2.0/30 # office" | Set-Content (Join-Path $leg 'devices.txt')
$li = Import-QmLegacyConfig -LegacyDir $leg
Assert-Eq ($li.targets -join ';') '10.1.1.1;10.1.1.2;10.1.2.0/30' 'legacy targets + devices.txt merged'
Assert-True ([System.IO.Path]::IsPathRooted($li.outputFolder)) 'legacy relative output made absolute'

Write-Host '=== Status JSON ==='
$sample = [ordered]@{
    schema = 1
    run = [ordered]@{ trigger = 'manual'; success = $false; partial = $false; errorStage = 'write'; error = 'No output files could be written.'; startedAt = '2026-11-18 08:00:00'; finishedAt = '2026-11-18 08:00:01'; durationSec = 1 }
    instance = [ordered]@{ computer = 'BOX'; installDir = 'C:\Q'; user = 'shop\svc'; version = '2.1.2' }
    counts = [ordered]@{ hosts = 1; ok = 0; withSerial = 0; timeout = 1; error = 0 }
    writeErrors = @('output is not a folder')
    warnings = @()
    files = [ordered]@{ general = $null; eautomate = $null; mps = $null }
}
$plain = $sample | ConvertTo-Json -Depth 8
$st = Read-QmStatus -Json $plain
Assert-Eq $st.run.errorStage 'write' 'Read-QmStatus reads plain status.json'
$txt = ConvertTo-QmStatusText $st
Assert-True ($txt -match 'FAILED' -and $txt -match 'WRITE ERROR' -and $txt -notmatch 'Authenticity') 'status text summarises failure without signing'
# Leftover signed envelope from older versions: unwrap payload, ignore hmac
$payload = '{"run":{"success":true,"trigger":"schedule"},"counts":{"hosts":1,"ok":1}}'
$legacyEnv = '{"format":"QuMeter-signed-v1","signed":true,"alg":"HMAC-SHA256","hmac":"deadbeef","payload":' + ($payload | ConvertTo-Json) + '}'
$unwrapped = Read-QmStatus -Json $legacyEnv
Assert-Eq $unwrapped.run.success $true 'Read-QmStatus unwraps leftover signed envelope'

Write-Host '=== Task XML ==='
foreach ($case in @(
    @{ f='Daily'; expect='ScheduleByDay' },
    @{ f='Weekly'; expect='ScheduleByWeek' },
    @{ f='Monthly'; expect='ScheduleByMonth' }
)) {
    $s = (Get-QmDefaultConfig).schedule; $s.frequency = $case.f; $s.dayOfWeek = 'Friday'; $s.dayOfMonth = '15'; $s.time = '06:45'
    $x = New-QmTaskXml -Schedule $s -InstallDir 'C:\ProgramData\QuMeter' -RunAs SYSTEM -StartDate ([datetime]'2026-11-14')
    $doc = [xml]$x
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable); $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    Assert-True ($null -ne $doc.SelectSingleNode("//t:$($case.expect)", $ns)) "$($case.f) trigger element"
    Assert-Eq $doc.SelectSingleNode('//t:StartBoundary',$ns).InnerText '2026-11-14T06:45:00' "$($case.f) start boundary"
    Assert-Eq $doc.SelectSingleNode('//t:Principal/t:UserId',$ns).InnerText 'S-1-5-18' "$($case.f) runs as SYSTEM"
    if ($case.f -eq 'Weekly') { Assert-True ($null -ne $doc.SelectSingleNode('//t:DaysOfWeek/t:Friday',$ns)) 'weekly day Friday' }
    if ($case.f -eq 'Monthly') { Assert-Eq $doc.SelectSingleNode('//t:DaysOfMonth/t:Day',$ns).InnerText '15' 'monthly day 15'; Assert-Eq $doc.SelectNodes('//t:Months/*',$ns).Count 12 'all 12 months' }
    $args1 = $doc.SelectSingleNode('//t:Exec/t:Arguments',$ns).InnerText
    Assert-True ($args1 -match 'QuMeterEngine\.ps1' -and $args1 -match 'config\.json') "$($case.f) runs the engine with config"
}
$xa = [xml](New-QmTaskXml -Schedule (Get-QmDefaultConfig).schedule -InstallDir 'C:\Q' -RunAs Account -UserId 'SHOP\svc&q')
Assert-Eq $xa.Task.Principals.Principal.LogonType 'Password' 'service account uses Password logon (runs logged off)'
Assert-Eq $xa.Task.Principals.Principal.UserId 'SHOP\svc&q' 'account name XML-escaped correctly'
Assert-True (-not ((New-QmTaskXml -Schedule (Get-QmDefaultConfig).schedule -InstallDir 'C:\Q' -RunAs Account -UserId 'a\b') -match 'Password>[^<]*[^d]<')) 'no password in task XML'
Assert-Eq (Get-QmScheduleText @{ frequency='Monthly'; dayOfMonth='Last'; time='06:00' }) 'on the last day of each month at 06:00' 'schedule text'

Write-Host '=== Scripts parse ==='
foreach ($f in @('QuMeterCore.ps1','QuMeterEngine.ps1','QuMeter.ps1','QuSnmp.ps1','tests/Test-QuMeterCore.ps1','tests/Test-QuSnmp.ps1')) {
    $fp = Join-Path $root $f
    if (Test-Path $fp) {
        $tok = $null; $pe = $null
        [System.Management.Automation.Language.Parser]::ParseFile($fp, [ref]$tok, [ref]$pe) | Out-Null
        Assert-Eq $pe.Count 0 "$f parses"
    }
}

Write-Host '=== Engine end-to-end (simulator) ==='
$port = 11621
$ready = Join-Path $tmp 'ready.txt'
if (Test-Path -LiteralPath $ready) { Remove-Item -LiteralPath $ready -Force }
$sim = Start-Process -FilePath $script:TestPython -ArgumentList @((Join-Path $here 'snmp_sim.py'),'--host','127.0.0.1','--port',"$port",'--profile','default','--ready-file',$ready) -PassThru -RedirectStandardError (Join-Path $tmp 'sim.err')
try {
    $deadline = (Get-Date).AddSeconds(8); while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    $inst = Join-Path $tmp 'inst'; New-Item -ItemType Directory $inst -Force | Out-Null
    foreach ($f in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','e-automate.mapping.json')) { Copy-Item (Join-Path $root $f) $inst }
    $ec = Get-QmDefaultConfig
    $ec.targets = @('127.0.0.1'); $ec.port = $port; $ec.timeoutMs = 800; $ec.retries = 0
    $ec.mpsDropFolder = 'mps'; $ec.retentionDays = 30
    Save-QmConfig $ec (Join-Path $inst 'config.json')
    New-Item -ItemType Directory (Join-Path $inst 'output') -Force | Out-Null
    $old = Join-Path $inst 'output/QuMeter_20200101_000000.csv'; 'old' | Set-Content $old; (Get-Item $old).LastWriteTime = (Get-Date).AddDays(-60)
    $prog = Join-Path $tmp 'progress.txt'
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') -ProgressFile $prog -Trigger manual | Out-Null
    Assert-Eq $LASTEXITCODE 0 'engine exit code 0'
    $outs = @(Get-ChildItem (Join-Path $inst 'output') -Filter 'QuMeter_*.csv' | ForEach-Object Name)
    Assert-True (@($outs | Where-Object { $_ -match '^QuMeter_\d{8}_\d{6}\.csv$' }).Count -eq 1) 'dated general CSV written'
    Assert-True (@($outs | Where-Object { $_ -match '^QuMeter_eautomate_\d{8}_\d{6}\.csv$' }).Count -eq 1) 'dated e-automate CSV written'
    Assert-True (@(Get-ChildItem (Join-Path $inst 'mps') -Filter 'QuMeter_mps_*.csv').Count -eq 1) 'MPS drop CSV written'
    Assert-True (-not (Test-Path $old)) 'retention removed 60-day-old file'
    Assert-True (@(Get-ChildItem (Join-Path $inst 'logs') -Filter 'QuMeter_*.log').Count -eq 1) 'daily log written'
    $eaTxt = Get-Content (Get-ChildItem (Join-Path $inst 'output') -Filter 'QuMeter_eautomate_*.csv')[0].FullName -Raw
    Assert-True ($eaTxt -match 'TESTSN001' -and $eaTxt -match 'Equipment Number,Model,Serial,B\\W,Color,Total Count,Remarks,Reading Date' -and $eaTxt -match 'Imported by QuMeter') 'e-automate CSV content'
    $pt = Get-Content $prog -Raw
    Assert-True ($pt -match 'PROGRESS 1/1' -and $pt -match 'STEP ' -and $pt -match 'DONE 0') 'progress file has PROGRESS/STEP/DONE'
    $stj = Get-Content (Join-Path $inst 'logs/status.json') -Raw
    $se = Read-QmStatus -Json $stj
    Assert-True ($stj -notmatch '"payload"' -and $stj -notmatch '"hmac"') 'status.json is plain JSON (not a signed envelope)'
    Assert-Eq $se.run.success $true 'status success'
    Assert-Eq $se.counts.ok 1 'status ok count'
    Assert-Eq $se.devices[0].serial 'TESTSN001' 'status per-device serial'
    Assert-Eq $se.run.trigger 'manual' 'status trigger is manual'

    # Unreachable printer + unwritable output -> errors in status
    # Use a file path as the output folder so writes fail on Windows and Linux (/proc is Linux-only).
    $badOut = Join-Path $tmp 'not-a-directory'
    'block' | Set-Content -LiteralPath $badOut
    $ec2 = Read-QmConfig (Join-Path $inst 'config.json'); $ec2.targets = @('127.0.0.1'); $ec2.port = 1; $ec2.timeoutMs = 200
    $ec2.outputFolder = $badOut; $ec2.mpsDropFolder = ''
    Save-QmConfig $ec2 (Join-Path $inst 'config.json')
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') | Out-Null
    Assert-Eq $LASTEXITCODE 1 'nothing writable -> exit 1'
    $se3 = Read-QmStatus -Json (Get-Content (Join-Path $inst 'logs/status.json') -Raw)
    Assert-Eq $se3.devices[0].status 'Timeout' 'per-device timeout in status'
    Assert-True (@($se3.writeErrors).Count -ge 2) 'write errors listed in status'
    Assert-Eq $se3.run.errorStage 'write' 'error stage = write'
    $txt = ConvertTo-QmStatusText $se3
    Assert-True ($txt -match 'FAILED' -and $txt -match 'WRITE ERROR' -and $txt -notmatch 'Authenticity') 'status text summarises failure'

    # Config error
    '{ "targets": [], "version": "v9" }' | Set-Content (Join-Path $inst 'config.json')
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') | Out-Null
    Assert-Eq $LASTEXITCODE 1 'config error -> exit 1'
    $se4 = Read-QmStatus -Json (Get-Content (Join-Path $inst 'logs/status.json') -Raw)
    Assert-True ($se4.run.errorStage -eq 'config' -and $se4.run.error -match 'No printers') 'config error in status'
} finally { try { if ($sim -and -not $sim.HasExited) { Stop-Process -Id $sim.Id -Force } } catch {} }

Write-Host ''
Write-Host "Results: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
