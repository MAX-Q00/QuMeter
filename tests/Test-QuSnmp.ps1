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



Write-Host '=== Remarks templates ==='
Assert-Eq (Format-QuMeterRemarks -Template '' -Reading $r) '' 'empty remarks template stays blank'
Assert-Eq (Format-QuMeterRemarks -Template 'Imported by QuMeter' -Reading $r) 'Imported by QuMeter' 'plain remarks unchanged'
$tok = Format-QuMeterRemarks -Template '{date} {ip} {serial} {model}' -Reading $r -DateFormat 'M/d/yyyy'
Assert-True ($tok -match '11/14/2026' -and $tok -match '10.0.0.9' -and $tok -match 'TESTSN001' -and $tok -match 'HP Color LaserJet E57540') 'remarks tokens date ip serial model'
$quotedPath = Join-Path $tmp 'ea-remarks-comma.csv'
$mapQ = Get-DefaultEaMapping
$mapQ.remarks = 'Hello, "world" {serial}'
Export-QuMeterEaCsv -Readings @($r) -Path $quotedPath -Mapping $mapQ
$qTxt = Get-Content -LiteralPath $quotedPath -Raw
Assert-True ($qTxt -match '"Hello, ""world"" TESTSN001"') 'remarks with comma and quotes are CSV-escaped'
$blankPath = Join-Path $tmp 'ea-remarks-blank.csv'
$mapB = Get-DefaultEaMapping
$mapB.remarks = ''
Export-QuMeterEaCsv -Readings @($r) -Path $blankPath -Mapping $mapB
$bLine = @(Get-Content $blankPath | Select-Object -Skip 1)[0]
Assert-True ($bLine -match '123456,,11/14/2026') 'empty remarks leave a blank CSV field'

Write-Host '=== Timeout filter, responding IP list, Excel and import exports ==='
function Get-TestXlsxXml([string]$Path, [string]$Entry) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $e = $zip.GetEntry($Entry)
        Assert-True ($null -ne $e) "xlsx has $Entry"
        if (-not $e) { return '' }
        $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $zip.Dispose() }
}
$ok = New-Object QuMeterSnmp.PrinterReading
$ok.Ip='10.0.0.9'; $ok.Model='HP Color LaserJet E57540'; $ok.Serial='TESTSN001'
$ok.Total='123456'; $ok.Mono='100000'; $ok.Color='23456'; $ok.SysDescr='HP Color LaserJet E57540'
$ok.Status='OK'; $ok.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$to = New-Object QuMeterSnmp.PrinterReading
$to.Ip='10.0.0.10'; $to.Status='Timeout'; $to.ErrorMessage='timed out'; $to.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$err = New-Object QuMeterSnmp.PrinterReading
$err.Ip='10.0.0.11'; $err.Status='Error'; $err.ErrorMessage='SNMP error'; $err.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$lead = New-Object QuMeterSnmp.PrinterReading
$lead.Ip='10.0.0.12'; $lead.Model='Xerox Demo'; $lead.Serial='0012345'
$lead.Total='50'; $lead.Mono='50'; $lead.Color=''; $lead.SysDescr='Xerox WorkCentre'
$lead.Status='OK'; $lead.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$mix = @($ok, $to, $err, $lead)
$all = Get-QuMeterVisibleReadings -Readings $mix -ExcludeTimedOut $false
$filt = Get-QuMeterVisibleReadings -Readings $mix -ExcludeTimedOut $true
Assert-Eq $all.Count 4 'unfiltered list keeps timed-out IPs'
Assert-Eq $filt.Count 3 'exclude timed out drops only Timeout rows'
Assert-True (@($filt | Where-Object { $_.Status -eq 'Timeout' }).Count -eq 0) 'filtered list has no Timeout status'
Assert-True (@($filt | Where-Object { $_.Ip -eq '10.0.0.11' }).Count -eq 1) 'error responses stay in the filtered list'
$ipText = Get-QuMeterRespondedIpText -Readings $mix
Assert-True ($ipText -match '10\.0\.0\.9') 'responding list includes OK IP'
Assert-True ($ipText -match '10\.0\.0\.11') 'responding list includes Error IP (did not time out)'
Assert-True ($ipText -notmatch '10\.0\.0\.10') 'responding list omits timed-out IP'
Assert-True ($ipText -match "`r`n" -or $ipText -match "`n") 'responding list is one IP per line'
$can = New-Object QuMeterSnmp.PrinterReading
$can.Ip='10.0.0.13'; $can.Status='Cancelled'; $can.ErrorMessage='Scan cancelled.'; $can.ReadAt = Get-Date
$ipCancel = Get-QuMeterRespondedIpText -Readings @($ok, $to, $err, $lead, $can)
Assert-True ($ipCancel -match '10\.0\.0\.9') 'responding list still includes OK IP when a row is Cancelled'
Assert-True ($ipCancel -notmatch '10\.0\.0\.13') 'responding list omits Cancelled IP'
Assert-Eq (Get-QuMeterManufacturer $ok) 'HP' 'manufacturer from HP sysDescr'
Assert-Eq (Get-QuMeterManufacturer $lead) 'Xerox' 'manufacturer from Xerox sysDescr'

$xlsx = Join-Path $tmp 'meters.xlsx'
$eaX  = Join-Path $tmp 'ea.xlsx'
$fma  = Join-Path $tmp 'fmaudit.csv'
$genF = Join-Path $tmp 'general-filtered.csv'
Export-QuMeterExcel -Readings $mix -Path $xlsx -Mapping $map -ExcludeTimedOut $true
Export-QuMeterEaXlsx -Readings $filt -Path $eaX -Mapping $map
Export-QuMeterMpsFmAuditCsv -Readings $filt -Path $fma
Export-QuMeterGeneralCsv -Readings $filt -Path $genF
$wb = Get-TestXlsxXml $xlsx 'xl/workbook.xml'
Assert-True ($wb -match 'name="Results"') 'excel workbook has Results sheet'
Assert-True ($wb -match 'name="e-automate"') 'excel workbook has e-automate sheet'
Assert-True ($wb -match 'name="MPS"') 'excel workbook has MPS sheet'
Assert-True ($wb -match 'name="FMAudit"') 'excel workbook has FMAudit sheet'
$resultsXml = Get-TestXlsxXml $xlsx 'xl/worksheets/sheet1.xml'
Assert-True ($resultsXml -match 'TESTSN001') 'excel Results includes OK serial'
Assert-True ($resultsXml -match '0012345') 'excel Results preserves leading-zero serial as text'
Assert-True ($resultsXml -notmatch '10.0.0.10') 'excel Results omits timed-out IP when excluded'
Assert-True ($resultsXml -match '10.0.0.11') 'excel Results keeps Error IP when excluded timeouts only'
Assert-True ($resultsXml -match '<v>123456</v>') 'excel writes meter totals as numbers'
$fmaTxt = Get-Content -LiteralPath $fma -Raw
Assert-True ($fmaTxt -match 'IP Address,Manufacturer,Model,Serial Number,Description,Total Pages,Mono Pages,Color Pages') 'FMAudit-style header uses published audit field names'
Assert-True ($fmaTxt -match 'TESTSN001') 'FMAudit-style includes serial'
Assert-True ($fmaTxt -match 'HP') 'FMAudit-style includes manufacturer'
Assert-True ($fmaTxt -notmatch '10.0.0.10') 'FMAudit-style skips non-OK rows'
$genFtxt = Get-Content -LiteralPath $genF -Raw
Assert-True ($genFtxt -notmatch '10.0.0.10') 'filtered general CSV omits timed-out IP'

Write-Host '=== Exclude IPs with no serial number ==='
Assert-Eq (Test-QuMeterHasSerial $ok) $true 'real serial is present'
$blankSn = New-Object QuMeterSnmp.PrinterReading
$blankSn.Ip='10.0.0.20'; $blankSn.Status='OK'; $blankSn.Serial=''; $blankSn.Model='Blank'; $blankSn.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$wsSn = New-Object QuMeterSnmp.PrinterReading
$wsSn.Ip='10.0.0.21'; $wsSn.Status='OK'; $wsSn.Serial='   '; $wsSn.Model='Whitespace'; $wsSn.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$naSn = New-Object QuMeterSnmp.PrinterReading
$naSn.Ip='10.0.0.22'; $naSn.Status='OK'; $naSn.Serial='N/A'; $naSn.Model='NA'; $naSn.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$unkSn = New-Object QuMeterSnmp.PrinterReading
$unkSn.Ip='10.0.0.23'; $unkSn.Status='OK'; $unkSn.Serial='Unknown'; $unkSn.Model='Unk'; $unkSn.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
$zeroSn = New-Object QuMeterSnmp.PrinterReading
$zeroSn.Ip='10.0.0.24'; $zeroSn.Status='OK'; $zeroSn.Serial='0'; $zeroSn.Model='Zero'; $zeroSn.ReadAt = [datetime]::Parse('2026-11-14 08:30:00')
Assert-Eq (Test-QuMeterHasSerial $blankSn) $false 'blank serial is missing'
Assert-Eq (Test-QuMeterHasSerial $wsSn) $false 'whitespace serial is missing'
Assert-Eq (Test-QuMeterHasSerial $naSn) $false 'N/A serial is missing'
Assert-Eq (Test-QuMeterHasSerial $unkSn) $false 'unknown serial is missing'
Assert-Eq (Test-QuMeterHasSerial $zeroSn) $false '0 serial is missing'
Assert-Eq (Test-QuMeterHasSerial $lead) $true 'leading-zero serial is present'
$mixSn = @($ok, $to, $err, $lead, $blankSn, $wsSn, $naSn, $unkSn, $zeroSn)
$noSn = Get-QuMeterVisibleReadings -Readings $mixSn -ExcludeTimedOut $false -ExcludeNoSerial $true
Assert-Eq $noSn.Count 2 'exclude no-serial keeps only readings with a real serial'
Assert-True (@($noSn | Where-Object { $_.Ip -eq '10.0.0.9' }).Count -eq 1) 'exclude no-serial keeps OK serial'
Assert-True (@($noSn | Where-Object { $_.Ip -eq '10.0.0.12' }).Count -eq 1) 'exclude no-serial keeps leading-zero serial'
Assert-True (@($noSn | Where-Object { $_.Ip -eq '10.0.0.10' }).Count -eq 0) 'exclude no-serial drops timed-out IP with no serial'
Assert-True (@($noSn | Where-Object { $_.Ip -eq '10.0.0.11' }).Count -eq 0) 'exclude no-serial drops error IP with no serial'
Assert-True (@($noSn | Where-Object { $_.Ip -eq '10.0.0.22' }).Count -eq 0) 'exclude no-serial drops N/A serial'
$both = Get-QuMeterVisibleReadings -Readings $mixSn -ExcludeTimedOut $true -ExcludeNoSerial $true
Assert-Eq $both.Count 2 'both filters together still keep real serials'
$ipAll = Get-QuMeterRespondedIpText -Readings $mixSn
Assert-True ($ipAll -match '10\.0\.0\.22') 'responding list includes N/A serial when filter is off'
$ipSn = Get-QuMeterRespondedIpText -Readings $mixSn -ExcludeNoSerial $true
Assert-True ($ipSn -match '10\.0\.0\.9') 'responding list keeps real serial when filter is on'
Assert-True ($ipSn -match '10\.0\.0\.12') 'responding list keeps leading-zero serial when filter is on'
Assert-True ($ipSn -notmatch '10\.0\.0\.10') 'responding list still omits timed-out IP'
Assert-True ($ipSn -notmatch '10\.0\.0\.11') 'responding list omits error IP with no serial when filter is on'
Assert-True ($ipSn -notmatch '10\.0\.0\.20') 'responding list omits blank serial'
Assert-True ($ipSn -notmatch '10\.0\.0\.22') 'responding list omits N/A serial when filter is on'
Assert-True ($ipSn -notmatch '10\.0\.0\.23') 'responding list omits unknown serial when filter is on'
Assert-True ($ipSn -notmatch '10\.0\.0\.24') 'responding list omits 0 serial when filter is on'
$xlsxSn = Join-Path $tmp 'meters-noserial.xlsx'
$genSn = Join-Path $tmp 'general-noserial.csv'
$mpsSn = Join-Path $tmp 'mps-noserial.csv'
$fmaSn = Join-Path $tmp 'fmaudit-noserial.csv'
$eaSn  = Join-Path $tmp 'ea-noserial-filter.csv'
Export-QuMeterExcel -Readings $mixSn -Path $xlsxSn -Mapping $map -ExcludeTimedOut $true -ExcludeNoSerial $true
Export-QuMeterGeneralCsv -Readings $noSn -Path $genSn
Export-QuMeterMpsCsv -Readings $noSn -Path $mpsSn
Export-QuMeterMpsFmAuditCsv -Readings $noSn -Path $fmaSn
Export-QuMeterEaCsv -Readings $noSn -Path $eaSn -Mapping $map
$xlsxSnXml = Get-TestXlsxXml $xlsxSn 'xl/worksheets/sheet1.xml'
Assert-True ($xlsxSnXml -match 'TESTSN001') 'excel Results keeps real serial when no-serial excluded'
Assert-True ($xlsxSnXml -match '0012345') 'excel Results keeps leading-zero serial when no-serial excluded'
Assert-True ($xlsxSnXml -notmatch '10\.0\.0\.20') 'excel Results omits blank serial when excluded'
Assert-True ($xlsxSnXml -notmatch '10\.0\.0\.22') 'excel Results omits N/A serial when excluded'
Assert-True ($xlsxSnXml -notmatch '10\.0\.0\.10') 'excel Results still omits timed-out IP when both filters on'
$genSnTxt = Get-Content -LiteralPath $genSn -Raw
Assert-True ($genSnTxt -match 'TESTSN001' -and $genSnTxt -notmatch '10\.0\.0\.22' -and $genSnTxt -notmatch '10\.0\.0\.24') 'filtered general CSV omits placeholder serials'
$mpsSnTxt = Get-Content -LiteralPath $mpsSn -Raw
Assert-True ($mpsSnTxt -match 'TESTSN001' -and $mpsSnTxt -notmatch '10\.0\.0\.20' -and $mpsSnTxt -notmatch '10\.0\.0\.23') 'filtered MPS CSV omits no-serial IPs'
$fmaSnTxt = Get-Content -LiteralPath $fmaSn -Raw
Assert-True ($fmaSnTxt -match 'TESTSN001' -and $fmaSnTxt -notmatch '10\.0\.0\.22') 'filtered FMAudit CSV omits no-serial IPs'
$eaSnTxt = Get-Content -LiteralPath $eaSn -Raw
Assert-True ($eaSnTxt -match 'TESTSN001' -and $eaSnTxt -notmatch '10\.0\.0\.22' -and $eaSnTxt -notmatch '10\.0\.0\.24') 'filtered e-automate CSV omits no-serial IPs'
$eaWb = Get-TestXlsxXml $eaX 'xl/workbook.xml'
Assert-True ($eaWb -match 'name="Guide"') 'e-automate xlsx has Guide sheet'
Assert-True ($eaWb -match 'name="Import"') 'e-automate xlsx has Import sheet'
$importXml = Get-TestXlsxXml $eaX 'xl/worksheets/sheet2.xml'
Assert-True ($importXml -match '<row r="3">') 'e-automate Import has row 3 (Source)'
Assert-True ($importXml -match 'SNMP') 'e-automate Import includes Source SNMP'
Assert-True ($importXml -match '<row r="8">') 'e-automate Import has header row 8'
Assert-True ($importXml -match 'Equipment Number') 'e-automate Import row 8 includes Equipment Number'
Assert-True ($importXml -match 'B\\W' -or $importXml -match 'B\\\\W' -or $importXml -match '>B\\W<') 'e-automate Import includes B\W column'
Assert-True ($importXml -match '<row r="9">') 'e-automate Import data starts on row 9'
Assert-True ($importXml -match 'TESTSN001') 'e-automate Import includes serial on a data row'
Assert-True ($importXml -notmatch '10.0.0.10') 'e-automate Import omits timed-out devices'

Write-Host '=== End-to-end GET/GETNEXT against local simulator ==='

$port1 = 11611
$port2 = 11612
$ready1 = Join-Path $tmp 'ready1.txt'
$ready2 = Join-Path $tmp 'ready2.txt'
foreach ($rf in @($ready1, $ready2)) { if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force } }
$py = Join-Path $here 'snmp_sim.py'
$python = $null
foreach ($name in @('python','py','python3')) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -and ($cmd.Source -notmatch 'WindowsApps')) { $python = $cmd.Source; break }
}
if (-not $python) { throw 'Python not found (need a real python on PATH, not the Windows Store stub)' }
$p1 = Start-Process -FilePath $python -ArgumentList @($py,'--host','127.0.0.1','--port',"$port1",'--profile','default','--ready-file',$ready1) -PassThru -RedirectStandardError (Join-Path $tmp 'sim1.err')
$p2 = Start-Process -FilePath $python -ArgumentList @($py,'--host','127.0.0.1','--port',"$port2",'--profile','fallback','--ready-file',$ready2) -PassThru -RedirectStandardError (Join-Path $tmp 'sim2.err')
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

Write-Host '=== Manual scan cancel ==='
$cCancel = New-QuSnmpClient -Community 'public' -Port 1 -TimeoutMs 2000 -Retries 0 -Version 'v2c'
$already = New-Object QuMeterSnmp.ScanCancel
$already.Cancel()
$cCancel.Cancel = $already
$pre = [QuMeterSnmp.PrinterQuery]::Query($cCancel, '127.0.0.1')
Assert-Eq $pre.Status 'Cancelled' 'Query with a cancelled token is Cancelled, not Timeout or OK'
$cCancel.Cancel = $null
$hosts = @('127.0.0.1','127.0.0.2','127.0.0.3','127.0.0.4','127.0.0.5','127.0.0.6','127.0.0.7','127.0.0.8','127.0.0.9','127.0.0.10')
$tok = New-Object QuMeterSnmp.ScanCancel
$tok.Cancel()
$sw = [Diagnostics.Stopwatch]::StartNew()
$cancelledAll = [QuMeterSnmp.PrinterQuery]::QueryMany($cCancel, [string[]]$hosts, 8, $null, $tok)
$sw.Stop()
Assert-Eq $cancelledAll.Count 10 'pre-cancelled QueryMany returns every host'
Assert-True (@($cancelledAll | Where-Object { $_.Status -eq 'Cancelled' }).Count -eq 10) 'pre-cancelled results are all Cancelled'
Assert-True ($sw.ElapsedMilliseconds -lt 1500) 'pre-cancelled QueryMany returns promptly'

$job = [QuMeterSnmp.ScanJob]::Start($cCancel, [string[]]($hosts + @('127.0.0.11','127.0.0.12','127.0.0.13','127.0.0.14','127.0.0.15','10.255.255.1','10.255.255.2','10.255.255.3','10.255.255.4','10.255.255.5')), 8)
Start-Sleep -Milliseconds 50
$job.Cancel()
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$joined = $job.Wait(4000)
$sw2.Stop()
Assert-True $joined 'cancelled ScanJob finishes within 4s'
Assert-True $job.IsCompleted 'cancelled ScanJob reports completed'
Assert-True $job.IsCancelled 'cancelled ScanJob reports cancelled'
Assert-True ($null -eq $job.Error) 'cancelled ScanJob has no error'
Assert-Eq $job.Results.Count 20 'cancelled ScanJob still returns a row per host'
$finished = @($job.Results | Where-Object { $_.Status -ne 'Cancelled' })
$pending = @($job.Results | Where-Object { $_.Status -eq 'Cancelled' })
Assert-True ($pending.Count -ge 1) 'unstarted hosts are marked Cancelled'
Assert-True (($finished.Count + $pending.Count) -eq 20) 'every host is either finished or Cancelled'
Assert-True ($sw2.ElapsedMilliseconds -lt 3500) 'cancel does not wait out the remaining probes'

Write-Host ''
Write-Host "Results: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }

