# Tests for QuMeterCore (config round-trip, API key/HMAC, run requests, task XML, deploy package) and the headless engine.
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
    $sys = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sys) { return $sys }
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
$c.deploy.target = 'PAPERCUT01'; $c.deploy.runAs = 'Account'; $c.deploy.runAsUser = 'SHOP\svc-qumeter'; $c.deploy.useCurrentLogin = $false
$c['apiKey'] = 'should-not-be-saved'
$p = Join-Path $tmp 'config.json'
Save-QmConfig -Config $c -Path $p
$raw = Get-Content $p -Raw
Assert-True ($raw -notmatch 'should-not-be-saved') 'API key never written to config.json'
$r = Read-QmConfig -Path $p
Assert-Eq (@($r.targets) -join ';') '10.0.0.10;10.0.1.0/24' 'targets round-trip'
Assert-Eq $r.community 'shopro' 'community round-trip'
Assert-Eq $r.timeoutMs 2500 'timeout round-trip'
Assert-Eq $r.retentionDays 30 'retention round-trip'
Assert-Eq $r.eaFormat 'advanced' 'eaFormat round-trip'
Assert-Eq $r.eaRemarks 'Imported by QuMeter' 'eaRemarks default when omitted'
$c.eaRemarks = 'Hello, "shop" meters {serial}'
Save-QmConfig -Config $c -Path (Join-Path $tmp 'remarks.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'remarks.json')).eaRemarks 'Hello, "shop" meters {serial}' 'eaRemarks with comma and quotes round-trip'
$cBlank = Get-QmDefaultConfig; $cBlank.targets = @('10.0.0.1'); $cBlank.eaRemarks = ''
Save-QmConfig -Config $cBlank -Path (Join-Path $tmp 'remarks-blank.json')
Assert-Eq (Read-QmConfig (Join-Path $tmp 'remarks-blank.json')).eaRemarks '' 'empty eaRemarks stays blank'
Assert-Eq $r.outputFolder '\\fileserver\meters' 'UNC output round-trip'
Assert-Eq $r.schedule.frequency 'Monthly' 'frequency round-trip'
Assert-Eq $r.schedule.dayOfMonth 'Last' 'dayOfMonth round-trip'
Assert-Eq $r.deploy.target 'PAPERCUT01' 'deploy target round-trip'
Assert-Eq $r.deploy.runAsUser 'SHOP\svc-qumeter' 'run-as user round-trip'
Assert-Eq $r.deploy.useCurrentLogin $false 'bool round-trip'
$one = Get-QmDefaultConfig; $one.targets = @('10.9.9.9'); Save-QmConfig $one (Join-Path $tmp 'one.json')
Assert-Eq (@((Read-QmConfig (Join-Path $tmp 'one.json')).targets).Count) 1 'single target stays a list'
$partial = Join-Path $tmp 'partial.json'; '{ "community": "x", "schedule": { "time": "07:15" } }' | Set-Content $partial
$pr = Read-QmConfig $partial
Assert-Eq $pr.schedule.frequency 'Daily' 'missing nested keys fall back to defaults'
Assert-Eq $pr.schedule.time '07:15' 'partial nested override kept'
Assert-Eq $pr.deploy.installPath 'C:\ProgramData\QuMeter' 'deploy defaults present'
Assert-Eq $pr.eaRemarks 'Imported by QuMeter' 'missing eaRemarks falls back to default'
Assert-Eq (Test-QmConfig -Config $r -Root $tmp).Count 0 'valid config passes validation'
$bad = Get-QmDefaultConfig; $bad.schedule.time = '25:00'; $bad.schedule.frequency = 'Weekly'; $bad.schedule.dayOfWeek = 'Funday'
$errs = Test-QmConfig -Config $bad -Root $tmp
Assert-True ($errs.Count -ge 3) 'invalid config reports problems (targets, time, weekday)'
$t = ConvertTo-QmTargetList "10.0.0.1`r`n`r`n 10.0.0.2 `n10.0.0.0/30"
Assert-Eq ($t -join ';') '10.0.0.1;10.0.0.2;10.0.0.0/30' 'target text -> list'

Write-Host '=== Legacy QuMeter Auto import ==='
$leg = Join-Path $tmp 'legacy'; New-Item -ItemType Directory $leg -Force | Out-Null
'{ "community":"old", "targets":["10.1.1.1"], "targetFile":"devices.txt", "outputFolder":"output", "logFolder":"logs" }' | Set-Content (Join-Path $leg 'config.json')
"# comment`n10.1.1.2`n10.1.2.0/30 # office" | Set-Content (Join-Path $leg 'devices.txt')
$li = Import-QmLegacyConfig -LegacyDir $leg
Assert-Eq ($li.targets -join ';') '10.1.1.1;10.1.1.2;10.1.2.0/30' 'legacy targets + devices.txt merged'
Assert-True ([System.IO.Path]::IsPathRooted($li.outputFolder)) 'legacy relative output made absolute'

Write-Host '=== API key / HMAC ==='
$k = New-QmApiKey
Assert-True ($k -match '^qm_[A-Za-z0-9]{32}$') 'generated key format'
Assert-True ((New-QmApiKey) -ne $k) 'keys are random'
Assert-Eq (Get-QmHmac -Key 'key' -Text 'The quick brown fox jumps over the lazy dog') 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8' 'HMAC-SHA256 RFC test vector'
$obj = [ordered]@{ a = 1; b = 'x' }
$env1 = Read-QmSignedEnvelope -Json (New-QmSignedEnvelope -Object $obj -Key $k) -Key $k
Assert-True ($env1.Verified -and $env1.Data.b -eq 'x') 'signed status verifies with same key'
$env2 = Read-QmSignedEnvelope -Json (New-QmSignedEnvelope -Object $obj -Key $k) -Key 'wrong'
Assert-True ((-not $env2.Verified) -and $env2.Problem -match 'mismatch') 'wrong key -> mismatch reported'
$tampered = (New-QmSignedEnvelope -Object $obj -Key $k) -replace '\\"x\\"', '\"y\"'
$env3 = Read-QmSignedEnvelope -Json $tampered -Key $k
Assert-True ((-not $env3.Verified) -and $env3.Data.b -eq 'y') 'tampered payload fails verification'
$env4 = Read-QmSignedEnvelope -Json (New-QmSignedEnvelope -Object $obj) -Key $k
Assert-True ((-not $env4.Verified) -and $env4.Problem -match 'NOT signed') 'unsigned status flagged when GUI has key'
$env5 = Read-QmSignedEnvelope -Json 'garbage{' -Key $k
Assert-True ($env5.Problem -match 'Unreadable') 'garbage status reported, no throw'

Write-Host '=== Run requests ==='
$rq = New-QmRunRequest -Key $k -Target 'PAPERCUT01'
$ok = Test-QmRunRequest -Json $rq.Json -InstanceKey $k
Assert-True ($ok.Accepted -and $ok.RequestId -eq $rq.RequestId) 'signed request accepted, id carried'
$no = Test-QmRunRequest -Json $rq.Json -InstanceKey 'other'
Assert-True ((-not $no.Accepted) -and $no.Reason -match 'mismatch' -and $no.RequestId -eq $rq.RequestId) 'wrong key rejected with id kept'
$uns = New-QmRunRequest -Target 'X'
Assert-True (-not (Test-QmRunRequest -Json $uns.Json -InstanceKey $k).Accepted) 'unsigned request rejected when instance has key'
Assert-True ((Test-QmRunRequest -Json $uns.Json -InstanceKey '').Accepted) 'unsigned request accepted when instance has no key'
$stalePayload = [ordered]@{ action='run'; requestId='old'; issuedAtUtc=[DateTime]::UtcNow.AddHours(-3).ToString('o') }
Assert-True ((Test-QmRunRequest -Json (New-QmSignedEnvelope $stalePayload $k) -InstanceKey $k).Reason -match 'stale') 'stale request rejected'

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

Write-Host '=== UNC path / target config ==='
$u = Get-QmUncPath -Target 'PAPERCUT01' -LocalPath 'C:\ProgramData\QuMeter'
Assert-Eq $u.Path '\\PAPERCUT01\C$\ProgramData\QuMeter' 'admin share path from C:'
Assert-Eq (Get-QmUncPath -Target 'S' -LocalPath 'D:\Apps\QuMeter' -Share 'Apps$').Path '\\S\Apps$\Apps\QuMeter' 'custom share'
$cfgD = Read-QmConfig -Path $p
$cfgD.deploy.outputFolder = '\\fileserver\meters'; $cfgD.deploy.mpsDropFolder = ''
$tc = New-QmTargetConfig -Config $cfgD
Assert-True (-not $tc.Contains('deploy')) 'target config has no deploy block'
Assert-Eq $tc.outputFolder '\\fileserver\meters' 'target output folder applied'
Assert-Eq $tc.logFolder 'logs' 'target logs kept in install dir'
Assert-Eq $tc.schedule.runAs 'Account' 'target run-as from deploy settings'

Write-Host '=== Deploy package ==='
$zip = Join-Path $tmp 'QuMeterAuto-Deploy.zip'
New-QmDeployPackage -Config $cfgD -AppDir $root -OutZip $zip -ApiKey $k | Out-Null
Assert-True (Test-Path $zip) 'package zip created'
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$za = [System.IO.Compression.ZipFile]::OpenRead($zip)
$names = @($za.Entries | ForEach-Object { $_.FullName })
foreach ($n in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','config.json','e-automate.mapping.json','Install.ps1','Install.bat','Uninstall.bat','RunOnce.bat','README-DEPLOY.txt','package.json','apikey.install')) {
    Assert-True ($names -contains $n) "package contains $n"
}
$sr = New-Object System.IO.StreamReader(($za.Entries | Where-Object FullName -eq 'config.json').Open()); $pc = $sr.ReadToEnd(); $sr.Close()
$sr = New-Object System.IO.StreamReader(($za.Entries | Where-Object FullName -eq 'apikey.install').Open()); $pk = $sr.ReadToEnd(); $sr.Close()
$za.Dispose()
Assert-True ($pc -notmatch [regex]::Escape($k)) 'package config.json does not contain the API key'
Assert-True ($pc -notmatch '"deploy"') 'package config.json has no deploy block'
Assert-Eq $pk $k 'apikey.install carries the key for Install.ps1'
$zip2 = Join-Path $tmp 'nokey.zip'
New-QmDeployPackage -Config $cfgD -AppDir $root -OutZip $zip2 | Out-Null
$za = [System.IO.Compression.ZipFile]::OpenRead($zip2); $n2 = @($za.Entries | ForEach-Object FullName); $za.Dispose()
Assert-True ($n2 -notcontains 'apikey.install') 'package without key has no apikey.install'
foreach ($f in @('QuMeterCore.ps1','QuMeterEngine.ps1','QuMeter.ps1','deploy/Install.ps1')) {
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
    [System.IO.File]::WriteAllText((Join-Path $inst 'apikey.install'), $k)
    $rq2 = New-QmRunRequest -Key $k -Target 'local'
    [System.IO.File]::WriteAllText((Join-Path $inst 'request.json'), $rq2.Json)
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
    Assert-True (-not (Test-Path (Join-Path $inst 'request.json'))) 'request.json consumed'
    $stj = Get-Content (Join-Path $inst 'logs/status.json') -Raw
    $se = Read-QmSignedEnvelope -Json $stj -Key $k
    Assert-True $se.Verified 'status.json signed with installed API key (verified)'
    Assert-Eq $se.Data.run.requestId $rq2.RequestId 'status carries the request id'
    Assert-Eq $se.Data.run.success $true 'status success'
    Assert-Eq $se.Data.counts.ok 1 'status ok count'
    Assert-Eq $se.Data.devices[0].serial 'TESTSN001' 'status per-device serial'
    Assert-True ($stj -notmatch [regex]::Escape($k)) 'API key not present in status.json'
    $logTxt = (Get-ChildItem (Join-Path $inst 'logs') -Filter 'QuMeter_*.log' | Get-Content -Raw)
    Assert-True ($logTxt -notmatch [regex]::Escape($k)) 'API key not present in log'

    # Wrong-key request is rejected and reported
    $bad = New-QmRunRequest -Key 'not-the-key' -Target 'local'
    [System.IO.File]::WriteAllText((Join-Path $inst 'request.json'), $bad.Json)
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') | Out-Null
    Assert-Eq $LASTEXITCODE 3 'wrong-key request -> exit 3'
    $se2 = Read-QmSignedEnvelope -Json (Get-Content (Join-Path $inst 'logs/status.json') -Raw) -Key $k
    Assert-True ($se2.Data.run.errorStage -eq 'auth' -and $se2.Data.run.requestId -eq $bad.RequestId -and $se2.Data.run.error -match 'mismatch') 'rejection reported in status with request id'

    # Unreachable printer + unwritable output -> errors in status
    # Use a file path as the output folder so writes fail on Windows and Linux (/proc is Linux-only).
    $badOut = Join-Path $tmp 'not-a-directory'
    'block' | Set-Content -LiteralPath $badOut
    $ec2 = Read-QmConfig (Join-Path $inst 'config.json'); $ec2.targets = @('127.0.0.1'); $ec2.port = 1; $ec2.timeoutMs = 200
    $ec2.outputFolder = $badOut; $ec2.mpsDropFolder = ''
    Save-QmConfig $ec2 (Join-Path $inst 'config.json')
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') | Out-Null
    Assert-Eq $LASTEXITCODE 1 'nothing writable -> exit 1'
    $se3 = Read-QmSignedEnvelope -Json (Get-Content (Join-Path $inst 'logs/status.json') -Raw) -Key $k
    Assert-Eq $se3.Data.devices[0].status 'Timeout' 'per-device timeout in status'
    Assert-True (@($se3.Data.writeErrors).Count -ge 2) 'write errors listed in status'
    Assert-Eq $se3.Data.run.errorStage 'write' 'error stage = write'
    $txt = ConvertTo-QmStatusText $se3.Data $se3
    Assert-True ($txt -match 'FAILED' -and $txt -match 'WRITE ERROR' -and $txt -match 'verified') 'status text summarises failure'

    # Config error
    '{ "targets": [], "version": "v9" }' | Set-Content (Join-Path $inst 'config.json')
    & $script:TestPwsh -NoProfile -File (Join-Path $inst 'QuMeterEngine.ps1') -ConfigPath (Join-Path $inst 'config.json') | Out-Null
    Assert-Eq $LASTEXITCODE 1 'config error -> exit 1'
    $se4 = Read-QmSignedEnvelope -Json (Get-Content (Join-Path $inst 'logs/status.json') -Raw) -Key $k
    Assert-True ($se4.Data.run.errorStage -eq 'config' -and $se4.Data.run.error -match 'No printers') 'config error in status'
} finally { try { if ($sim -and -not $sim.HasExited) { Stop-Process -Id $sim.Id -Force } } catch {} }

Write-Host ''
Write-Host "Results: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
