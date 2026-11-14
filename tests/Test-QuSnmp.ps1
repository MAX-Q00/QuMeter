# Unit + end-to-end tests for QuSnmp. Run from anywhere:
#   pwsh -NoProfile -File /workspace/QuMeter/tests/Test-QuSnmp.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path -Parent $here
. (Join-Path $root 'QuSnmp.ps1')
Initialize-QuSnmp

$script:failed = 0
$script:passed = 0
function Assert-True($cond, $name) {
    if ($cond) { $script:passed++; Write-Host "  PASS  $name" }
    else { $script:failed++; Write-Host "  FAIL  $name" }
}
function Assert-Eq($actual, $expected, $name) {
    $ok = "$actual" -eq "$expected"
    if ($ok) { $script:passed++; Write-Host "  PASS  $name" }
    else { $script:failed++; Write-Host "  FAIL  $name  expected=[$expected] actual=[$actual]" }
}

Write-Host '=== BER encode/decode ==='
$oid = '1.3.6.1.2.1.1.1.0'
$enc = [QuMeterSnmp.Ber]::EncodeOid($oid)
# 1.3 -> 43 (0x2b), then 6,1,2,1,1,1,0
$oidBodyPos = 2  # tag + short length (OID body is 8 bytes, length is 1 byte)
Assert-Eq $enc[0] 6 'OID tag is 0x06'
Assert-Eq $enc[1] 8 'OID 1.3.6.1.2.1.1.1.0 body length 8'
Assert-Eq $enc[2] 0x2b 'OID first byte is 1.3 (43)'
$dec = [QuMeterSnmp.Ber]::DecodeOid($enc[2..($enc.Length-1)])
Assert-Eq $dec $oid 'OID round-trip 1.3.6.1.2.1.1.1.0'

foreach ($pair in @(
    @{ n = 0 }, @{ n = 127 }, @{ n = 128 }, @{ n = 255 }, @{ n = 256 },
    @{ n = -1 }, @{ n = 2147483647 }, @{ n = -2147483648 }
)) {
    $bytes = [QuMeterSnmp.Ber]::IntegerBytes([int64]$pair.n, $false)
    $back = [QuMeterSnmp.Ber]::DecodeSignedInteger($bytes)
    Assert-Eq $back $pair.n "INTEGER round-trip $($pair.n)"
}

$u = [QuMeterSnmp.Ber]::DecodeUnsignedInteger([QuMeterSnmp.Ber]::IntegerBytes([uint64]4294967295))
Assert-Eq $u 4294967295 'unsigned 2^32-1 round-trip'
$u2 = [QuMeterSnmp.Ber]::DecodeUnsignedInteger([QuMeterSnmp.Ber]::IntegerBytes([uint64]128))
Assert-Eq $u2 128 'unsigned 128 has no sign issues'

# 128 as signed integer must be 00 80
$b128 = [QuMeterSnmp.Ber]::IntegerBytes([int64]128, $false)
Assert-True ($b128.Length -eq 2 -and $b128[0] -eq 0 -and $b128[1] -eq 0x80) 'signed 128 encodes as 00 80'

# Length long-form
$longLen = [QuMeterSnmp.Ber]::EncodeLength(200)
Assert-True ($longLen[0] -eq 0x81 -and $longLen[1] -eq 200) 'length 200 is 81 c8'

# Length short-form
$shortLen = [QuMeterSnmp.Ber]::EncodeLength(127)
Assert-True ($shortLen.Length -eq 1 -and $shortLen[0] -eq 127) 'length 127 is short form'

Write-Host '=== SNMP request/response codec ==='
$oids = [string[]]@('1.3.6.1.2.1.1.1.0','1.3.6.1.2.1.43.10.2.1.4.1.1')
$pkt = [QuMeterSnmp.SnmpCodec]::BuildRequest([QuMeterSnmp.SnmpVersion]::V2c, 'public', [QuMeterSnmp.SnmpPduType]::GetRequest, 42, $oids)
Assert-Eq $pkt[0] 0x30 'request starts with SEQUENCE'
$pos = 0
$tlv = [QuMeterSnmp.Ber]::ReadTlv($pkt, [ref]$pos)
Assert-Eq $tlv.Tag 0x30 'outer tag SEQUENCE'

# Craft a GetResponse and parse it
function New-TestResponse($requestId, $pairs) {
    # $pairs = list of @{Oid=; Tag=; Int=; Str=; Error=}
    $binds = New-Object System.Collections.Generic.List[byte]
    # We will build via Python? No - build with Ber helpers in a small inline way is hard in PS.
    # Instead: start the simulator and talk to it. Codec parse is covered by e2e.
    # Additional: parse a hand-built null bind response by requesting against sim.
    $null
}

Write-Host '=== HP symbol-set strip ==='
$roman = [byte[]](0x01, 0x15) + [System.Text.Encoding]::ASCII.GetBytes('HPFALLBACK')
Assert-Eq ([QuMeterSnmp.ValueFormat]::StripHpSymbolSet($roman)) 'HPFALLBACK' 'strip Roman-8 0x0115 prefix'
$plain = [System.Text.Encoding]::ASCII.GetBytes('TESTSN001')
Assert-Eq ([QuMeterSnmp.ValueFormat]::StripHpSymbolSet($plain)) 'TESTSN001' 'leave plain ASCII serial alone'
Assert-Eq ([QuMeterSnmp.ValueFormat]::StripHpSymbolSet([byte[]]@())) '' 'empty bytes -> empty string'

Write-Host '=== Target parser ==='
$p = [QuMeterSnmp.TargetParser]::Parse("10.0.0.1`n10.0.0.2-10.0.0.4 # comment`n10.1.1.0/30`n10.2.2.5-7`n# ignore`nprinter.shop.local", 1024)
# 10.0.0.1 + .2-.4 + 10.1.1.0/30 (.0-.3) + 10.2.2.5-7 + hostname = 12
Assert-Eq $p.Count 12 'parsed 12 unique targets'
Assert-True ($p.Contains('10.0.0.3')) 'range includes 10.0.0.3'
Assert-True ($p.Contains('10.1.1.0') -and $p.Contains('10.1.1.3')) 'cidr /30 includes network and broadcast'
Assert-True ($p.Contains('10.2.2.7')) 'short range 10.2.2.5-7'
Assert-True ($p.Contains('printer.shop.local')) 'hostname passed through'
$dup = [QuMeterSnmp.TargetParser]::Parse("10.0.0.1,10.0.0.1", 100)
Assert-Eq $dup.Count 1 'duplicates collapsed'

Write-Host '=== CSV export ==='
$r = New-Object QuMeterSnmp.PrinterReading
$r.Ip='10.0.0.9'; $r.Model='HP Color LaserJet E57540'; $r.Serial='TESTSN001'
$r.Total='123456'; $r.Mono='100000'; $r.Color='23456'; $r.SysDescr='HP Color LaserJet E57540'
$r.Status='OK'; $r.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$r.SerialSource='prtGeneralSerialNumber'; $r.ModelSource='hrDeviceDescr'; $r.TotalSource='prtMarkerLifeCount'
$tmp = Join-Path $here 'tmp-out'
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$gen = Join-Path $tmp 'general.csv'
$ea  = Join-Path $tmp 'ea.csv'
$adv = Join-Path $tmp 'ea-adv.csv'
$mps = Join-Path $tmp 'mps.csv'
Export-QuMeterGeneralCsv -Readings @($r) -Path $gen
$map = Get-DefaultEaMapping
Export-QuMeterEaCsv -Readings @($r) -Path $ea -Mapping $map
$map2 = Get-DefaultEaMapping
$map2.format = 'advanced'
Export-QuMeterEaCsv -Readings @($r) -Path $adv -Mapping $map2
Export-QuMeterMpsCsv -Readings @($r) -Path $mps
$genTxt = Get-Content -LiteralPath $gen -Raw
$eaTxt  = Get-Content -LiteralPath $ea -Raw
$advTxt = Get-Content -LiteralPath $adv -Raw
Assert-True ($eaTxt -match 'Equipment Number,Model,Serial,B\\W,Color,Total Count,Remarks,Reading Date') 'basic EA header matches official columns'
Assert-True ($eaTxt -match 'TESTSN001') 'basic EA includes serial'
Assert-True ($eaTxt -match '123456') 'basic EA includes total'
Assert-True ($eaTxt -match '11/14/2026') 'basic EA date uses M/d/yyyy'
Assert-True ($advTxt -match 'Meter Type,Reading,Credits,Remarks') 'advanced EA header'
Assert-True ((Select-String -LiteralPath $adv -Pattern 'TESTSN001' -AllMatches).Matches.Count -ge 1) 'advanced EA has identity'
Assert-True ($mps -and (Get-Content $mps -Raw) -match 'SerialNumber,Model,IPAddress,TotalCount') 'MPS generic header'
$blank = New-Object QuMeterSnmp.PrinterReading
$blank.Ip='10.0.0.8'; $blank.Status='OK'; $blank.Serial=''; $blank.Total='5'; $blank.ReadAt=Get-Date
$ea2 = Join-Path $tmp 'ea-noserial.csv'
Export-QuMeterEaCsv -Readings @($blank) -Path $ea2 -Mapping $map
$ea2lines = @(Get-Content $ea2 | Select-Object -Skip 1 | Where-Object { $_.Trim() })
Assert-Eq $ea2lines.Count 0 'e-automate export skips rows with no serial'

Write-Host '=== End-to-end GET/GETNEXT against local simulator ==='
$port1 = 11611
$port2 = 11612
$ready1 = Join-Path $tmp 'ready1.txt'
$ready2 = Join-Path $tmp 'ready2.txt'
$py = Join-Path $here 'snmp_sim.py'
$p1 = Start-Process -FilePath 'python3' -ArgumentList @($py,'--host','127.0.0.1','--port',"$port1",'--profile','default','--ready-file',$ready1) -PassThru -RedirectStandardError (Join-Path $tmp 'sim1.err')
$p2 = Start-Process -FilePath 'python3' -ArgumentList @($py,'--host','127.0.0.1','--port',"$port2",'--profile','fallback','--ready-file',$ready2) -PassThru -RedirectStandardError (Join-Path $tmp 'sim2.err')
try {
    $deadline = (Get-Date).AddSeconds(8)
    while ((-not (Test-Path $ready1) -or -not (Test-Path $ready2)) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert-True (Test-Path $ready1) 'simulator 1 ready'
    Assert-True (Test-Path $ready2) 'simulator 2 ready'

    $c = New-QuSnmpClient -Community 'public' -Port $port1 -TimeoutMs 1500 -Retries 1 -Version 'v2c'
    $got = $c.Get('127.0.0.1', [string[]]@('1.3.6.1.2.1.1.1.0','1.3.6.1.2.1.43.10.2.1.4.1.1','1.3.6.1.2.1.1.9.9.9.0'))
    $sys = [QuMeterSnmp.ValueFormat]::AsDisplayString($got.Find('1.3.6.1.2.1.1.1.0'))
    $life = [QuMeterSnmp.ValueFormat]::AsMeterCount($got.Find('1.3.6.1.2.1.43.10.2.1.4.1.1'))
    $missing = $got.Find('1.3.6.1.2.1.1.9.9.9.0')
    Assert-Eq $sys 'HP Color LaserJet E57540' 'GET sysDescr'
    Assert-Eq $life '123456' 'GET prtMarkerLifeCount Counter32'
    Assert-True ($missing.IsError -and $missing.Error -eq 'noSuchObject') 'GET missing OID is noSuchObject (not guessed)'

    $nxt = $c.GetNext('127.0.0.1', '1.3.6.1.2.1.1.1')
    Assert-Eq $nxt.Variables[0].Oid '1.3.6.1.2.1.1.1.0' 'GETNEXT 1.3.6.1.2.1.1.1 -> .0'
    $walked = $c.Walk('127.0.0.1', '1.3.6.1.2.1.1.1', 8)
    Assert-True ($walked.Count -ge 1 -and $walked[0].Oid -eq '1.3.6.1.2.1.1.1.0') 'Walk sysDescr prefix'

    $reading = [QuMeterSnmp.PrinterQuery]::Query($c, '127.0.0.1')
    Assert-Eq $reading.Status 'OK' 'printer query status OK'
    Assert-Eq $reading.Serial 'TESTSN001' 'primary serial from prtGeneralSerialNumber (not HP fallback)'
    Assert-Eq $reading.SerialSource 'prtGeneralSerialNumber' 'serial source label'
    Assert-Eq $reading.Model 'HP Color LaserJet E57540' 'model from hrDeviceDescr'
    Assert-Eq $reading.Total '123456' 'lifetime total'
    Assert-Eq $reading.Mono '100000' 'HP mono page count'
    Assert-Eq $reading.Color '23456' 'HP color page count'
    Assert-Eq $reading.SysDescr 'HP Color LaserJet E57540' 'sysDescr on reading'

    $c2 = New-QuSnmpClient -Community 'public' -Port $port2 -TimeoutMs 1500 -Retries 1 -Version 'v2c'
    $r2 = [QuMeterSnmp.PrinterQuery]::Query($c2, '127.0.0.1')
    Assert-Eq $r2.Status 'OK' 'fallback profile status OK'
    Assert-Eq $r2.Serial 'HPFB999' 'serial from HP private MIB fallback, symbol set stripped'
    Assert-Eq $r2.SerialSource 'HP-LASERJET-COMMON-MIB serial-number' 'fallback serial source label'
    Assert-Eq $r2.Model 'HP LaserJet 600 M603' 'model from hrDeviceDescr walk (index .2)'
    Assert-Eq $r2.Total '7777' 'total still read'
    Assert-Eq $r2.Mono '' 'mono left blank when OID missing (not computed)'
    Assert-Eq $r2.Color '' 'color left blank when OID missing (not computed)'

    # timeout against a closed port should be Timeout, not a guessed reading
    $c3 = New-QuSnmpClient -Community 'public' -Port 1 -TimeoutMs 200 -Retries 0 -Version 'v2c'
    $r3 = [QuMeterSnmp.PrinterQuery]::Query($c3, '127.0.0.1')
    Assert-Eq $r3.Status 'Timeout' 'closed port -> Timeout'
    Assert-Eq $r3.Total '' 'timeout does not invent a total'
}
finally {
    foreach ($proc in @($p1,$p2)) {
        try { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } } catch {}
    }
}

Write-Host ''
Write-Host "Results: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
