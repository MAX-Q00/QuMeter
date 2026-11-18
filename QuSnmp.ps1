# QuSnmp.ps1 - shared SNMP helpers for QuMeter / QuMeter Auto.
# Requires Windows PowerShell 5.1 or PowerShell 7. Loads QuSnmp.cs from this folder.
$script:QuSnmpRoot = $PSScriptRoot
if (-not $script:QuSnmpRoot) { $script:QuSnmpRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Initialize-QuSnmp {
    if ('QuMeterSnmp.SnmpClient' -as [type]) { return }
    $cs = Join-Path $script:QuSnmpRoot 'QuSnmp.cs'
    if (-not (Test-Path -LiteralPath $cs)) { throw "QuSnmp.cs not found at $cs" }
    $refs = @('System.dll', 'System.Core.dll')
    try {
        Add-Type -Path $cs -ReferencedAssemblies $refs -ErrorAction Stop
    } catch {
        # PowerShell 7 / .NET Core does not use Framework assembly names the same way.
        Add-Type -Path $cs -ErrorAction Stop
    }
}

function Get-DefaultEaMapping {
    @{
        format     = 'basic'          # basic | advanced
        source     = 'SNMP'           # must exist in e-automate Lists and Codes (not Contract, Service Call, or Web)
        dateFormat = 'M/d/yyyy'
        remarks    = 'Imported by QuMeter'
        identifyBy = 'serial'         # serial => Model + Serial, Equipment Number left blank
        columns    = @{
            equipmentNumber = 'Equipment Number'
            model           = 'Model'
            serial          = 'Serial'
            mono            = 'B\W'
            color           = 'Color'
            total           = 'Total Count'
            remarks         = 'Remarks'
            readingDate     = 'Reading Date'
        }
        advancedColumns = @{
            equipmentNumber = 'Equipment Number'
            model           = 'Model'
            serial          = 'Serial'
            source          = 'Source'
            readingDate     = 'Reading Date'
            meterType       = 'Meter Type'
            reading         = 'Reading'
            credits         = 'Credits'
            remarks         = 'Remarks'
        }
        meterTypeValues = @{
            mono  = 'B\W'
            color = 'Color'
            total = 'Total Count'
        }
        repeatIdentityOnEachRow = $true
        notes = 'Column names taken from official ECI e-automate Meter Import / Meter Import Advanced webhelp. Official importer accepts the EA_MeterImport.xlsx template (.xlsx only); paste these rows into that template starting under the header row (row 8).'
    }
}

function Read-EaMapping {
    param([string]$Path)
    $map = Get-DefaultEaMapping
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $map }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @('format','source','dateFormat','remarks','identifyBy')) {
        if ($null -ne $raw.$k -and "$($raw.$k)" -ne '') { $map[$k] = "$($raw.$k)" }
    }
    if ($null -ne $raw.repeatIdentityOnEachRow) { $map.repeatIdentityOnEachRow = [bool]$raw.repeatIdentityOnEachRow }
    if ($raw.columns) {
        foreach ($k in @($map.columns.Keys)) {
            if ($null -ne $raw.columns.$k -and "$($raw.columns.$k)" -ne '') { $map.columns[$k] = "$($raw.columns.$k)" }
        }
    }
    if ($raw.advancedColumns) {
        foreach ($k in @($map.advancedColumns.Keys)) {
            if ($null -ne $raw.advancedColumns.$k -and "$($raw.advancedColumns.$k)" -ne '') { $map.advancedColumns[$k] = "$($raw.advancedColumns.$k)" }
        }
    }
    if ($raw.meterTypeValues) {
        foreach ($k in @($map.meterTypeValues.Keys)) {
            if ($null -ne $raw.meterTypeValues.$k -and "$($raw.meterTypeValues.$k)" -ne '') { $map.meterTypeValues[$k] = "$($raw.meterTypeValues.$k)" }
        }
    }
    return $map
}

function Save-EaMapping {
    param([hashtable]$Mapping, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($Mapping | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[",\r\n]') { return '"' + ($s -replace '"','""') + '"' }
    return $s
}

function Write-QuCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)][System.Collections.IEnumerable]$Rows
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(($Headers | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
    foreach ($row in $Rows) {
        $line = foreach ($h in $Headers) { ConvertTo-CsvField $row[$h] }
        [void]$sb.AppendLine(($line -join ','))
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
}

function Convert-ReadingsToGeneralRows {
    param($Readings)
    $rows = @()
    foreach ($r in $Readings) {
        $when = $r.ReadAt
        if ($when -eq [datetime]::MinValue) { $when = Get-Date }
        $rows += @{
            'Date'          = $when.ToString('yyyy-MM-dd')
            'Time'          = $when.ToString('HH:mm:ss')
            'IP'            = $r.Ip
            'Model'         = $r.Model
            'Serial'        = $r.Serial
            'Total'         = $r.Total
            'Mono'          = $r.Mono
            'Color'         = $r.Color
            'SysDescr'      = $r.SysDescr
            'Status'        = $r.Status
            'Error'         = $r.ErrorMessage
            'SerialSource'  = $r.SerialSource
            'ModelSource'   = $r.ModelSource
            'TotalSource'   = $r.TotalSource
        }
    }
    return ,$rows
}


function Format-QuMeterRemarks {
    param(
        [string]$Template,
        $Reading,
        [string]$DateFormat = 'M/d/yyyy'
    )
    if ($null -eq $Template -or $Template -eq '') { return '' }
    $when = Get-Date
    if ($Reading -and $Reading.ReadAt -and $Reading.ReadAt -ne [datetime]::MinValue) { $when = $Reading.ReadAt }
    $repl = @{
        '{date}'   = $when.ToString($DateFormat)
        '{time}'   = $when.ToString('HH:mm:ss')
        '{ip}'     = $(if ($Reading) { [string]$Reading.Ip } else { '' })
        '{serial}' = $(if ($Reading) { [string]$Reading.Serial } else { '' })
        '{model}'  = $(if ($Reading) { [string]$Reading.Model } else { '' })
    }
    $s = [string]$Template
    foreach ($token in @('{date}','{time}','{ip}','{serial}','{model}')) {
        $value = $repl[$token]
        $i = $s.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase)
        while ($i -ge 0) {
            $s = $s.Substring(0, $i) + $value + $s.Substring($i + $token.Length)
            $i = $s.IndexOf($token, ($i + $value.Length), [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $s
}
function Convert-ReadingsToEaBasicRows {
    param($Readings, $Mapping)
    $c = $Mapping.columns
    $dateFmt = $Mapping.dateFormat
    $rows = @()
    foreach ($r in $Readings) {
        if ($r.Status -ne 'OK') { continue }
        if (-not $r.Serial) { continue }
        $when = $r.ReadAt
        if ($when -eq [datetime]::MinValue) { $when = Get-Date }
        $rows += @{
            $c.equipmentNumber = ''
            $c.model           = $r.Model
            $c.serial          = $r.Serial
            $c.mono            = $r.Mono
            $c.color           = $r.Color
            $c.total           = $r.Total
            $c.remarks         = Format-QuMeterRemarks -Template $Mapping.remarks -Reading $r -DateFormat $dateFmt
            $c.readingDate     = $when.ToString($dateFmt)
        }
    }
    return ,$rows
}

function Convert-ReadingsToEaAdvancedRows {
    param($Readings, $Mapping)
    $c = $Mapping.advancedColumns
    $types = $Mapping.meterTypeValues
    $dateFmt = $Mapping.dateFormat
    $rows = @()
    foreach ($r in $Readings) {
        if ($r.Status -ne 'OK') { continue }
        if (-not $r.Serial) { continue }
        $when = $r.ReadAt
        if ($when -eq [datetime]::MinValue) { $when = Get-Date }
        $meters = @()
        if ($r.Mono  -ne '' -and $null -ne $r.Mono)  { $meters += @{ Type = $types.mono;  Value = $r.Mono  } }
        if ($r.Color -ne '' -and $null -ne $r.Color) { $meters += @{ Type = $types.color; Value = $r.Color } }
        if ($r.Total -ne '' -and $null -ne $r.Total) { $meters += @{ Type = $types.total; Value = $r.Total } }
        $first = $true
        foreach ($m in $meters) {
            $id = $first -or [bool]$Mapping.repeatIdentityOnEachRow
            $rows += @{
                $c.equipmentNumber = ''
                $c.model           = $(if ($id) { $r.Model } else { '' })
                $c.serial          = $(if ($id) { $r.Serial } else { '' })
                $c.source          = $(if ($id) { $Mapping.source } else { '' })
                $c.readingDate     = $(if ($id) { $when.ToString($dateFmt) } else { '' })
                $c.meterType       = $m.Type
                $c.reading         = $m.Value
                $c.credits         = ''
                $c.remarks         = Format-QuMeterRemarks -Template $Mapping.remarks -Reading $r -DateFormat $dateFmt
            }
            $first = $false
        }
    }
    return ,$rows
}

function Export-QuMeterGeneralCsv {
    param($Readings, [string]$Path)
    $rows = Convert-ReadingsToGeneralRows $Readings
    $headers = @('Date','Time','IP','Model','Serial','Total','Mono','Color','SysDescr','Status','Error','SerialSource','ModelSource','TotalSource')
    Write-QuCsv -Path $Path -Headers $headers -Rows $rows
}

function Export-QuMeterEaCsv {
    param($Readings, [string]$Path, $Mapping)
    if (-not $Mapping) { $Mapping = Get-DefaultEaMapping }
    if ($Mapping.format -eq 'advanced') {
        $rows = Convert-ReadingsToEaAdvancedRows $Readings $Mapping
        $c = $Mapping.advancedColumns
        $headers = @($c.equipmentNumber, $c.model, $c.serial, $c.source, $c.readingDate, $c.meterType, $c.reading, $c.credits, $c.remarks)
        Write-QuCsv -Path $Path -Headers $headers -Rows $rows
    } else {
        $rows = Convert-ReadingsToEaBasicRows $Readings $Mapping
        $c = $Mapping.columns
        $headers = @($c.equipmentNumber, $c.model, $c.serial, $c.mono, $c.color, $c.total, $c.remarks, $c.readingDate)
        Write-QuCsv -Path $Path -Headers $headers -Rows $rows
    }
}

function Export-QuMeterMpsCsv {
    param($Readings, [string]$Path)
    # Generic drop-folder layout. Not tied to a specific MPS monitor (unknown at build time).
    $rows = @()
    foreach ($r in $Readings) {
        if ($r.Status -ne 'OK') { continue }
        $when = $r.ReadAt
        if ($when -eq [datetime]::MinValue) { $when = Get-Date }
        $rows += @{
            'SerialNumber'   = $r.Serial
            'Model'          = $r.Model
            'IPAddress'      = $r.Ip
            'TotalCount'     = $r.Total
            'MonoCount'      = $r.Mono
            'ColorCount'     = $r.Color
            'ReadDate'       = $when.ToString('yyyy-MM-dd')
            'ReadDateTime'   = $when.ToString('yyyy-MM-dd HH:mm:ss')
            'SysDescr'       = $r.SysDescr
        }
    }
    $headers = @('SerialNumber','Model','IPAddress','TotalCount','MonoCount','ColorCount','ReadDate','ReadDateTime','SysDescr')
    Write-QuCsv -Path $Path -Headers $headers -Rows $rows
}

function New-QuSnmpClient {
    param(
        [string]$Community = 'public',
        [int]$Port = 161,
        [int]$TimeoutMs = 1500,
        [int]$Retries = 1,
        [ValidateSet('v1','v2c')][string]$Version = 'v2c'
    )
    Initialize-QuSnmp
    $c = New-Object QuMeterSnmp.SnmpClient
    $c.Community = $Community
    $c.Port = $Port
    $c.TimeoutMs = $TimeoutMs
    $c.Retries = $Retries
    $c.Version = $(if ($Version -eq 'v1') { [QuMeterSnmp.SnmpVersion]::V1 } else { [QuMeterSnmp.SnmpVersion]::V2c })
    return $c
}

function Invoke-QuMeterScan {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string[]]$Hosts,
        [int]$Concurrency = 32,
        [scriptblock]$Progress
    )
    Initialize-QuSnmp
    $cb = $null
    if ($Progress) {
        $cb = [Action[int,int,QuMeterSnmp.PrinterReading]]{ param($d,$t,$r) & $Progress $d $t $r }
    }
    return [QuMeterSnmp.PrinterQuery]::QueryMany($Client, $Hosts, $Concurrency, $cb)
}

# --- Manual export helpers (Excel / e-automate xlsx / MPS / IP list) ---

function Test-QuMeterHasSerial {
    param($Reading)
    if ($null -eq $Reading) { return $false }
    $s = ([string]$Reading.Serial).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    $key = $s.ToLowerInvariant()
    if ($key -eq 'n/a' -or $key -eq 'na' -or $key -eq 'unknown' -or $key -eq '0') { return $false }
    return $true
}

function Get-QuMeterVisibleReadings {
    param($Readings, [bool]$ExcludeTimedOut, [bool]$ExcludeNoSerial)
    $list = @($Readings)
    if ($ExcludeTimedOut) {
        $list = @($list | Where-Object { $_.Status -ne 'Timeout' })
    }
    if ($ExcludeNoSerial) {
        $list = @($list | Where-Object { Test-QuMeterHasSerial $_ })
    }
    return ,$list
}

function Get-QuMeterRespondedIpText {
    param($Readings, [bool]$ExcludeNoSerial)
    $ips = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($r in @($Readings)) {
        if ($null -eq $r) { continue }
        if ("$($r.Status)" -eq 'Timeout') { continue }
        if ($ExcludeNoSerial -and -not (Test-QuMeterHasSerial $r)) { continue }
        $ip = [string]$r.Ip
        if ([string]::IsNullOrWhiteSpace($ip)) { continue }
        if ($seen.ContainsKey($ip)) { continue }
        $seen[$ip] = $true
        $ips.Add($ip)
    }
    return ($ips -join "`r`n")
}

function Get-QuMeterManufacturer {
    param($Reading)
    foreach ($s in @($Reading.SysDescr, $Reading.Model)) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s -match '^(Hewlett-Packard|Konica\s*Minolta|HP|Canon|Xerox|Ricoh|Lexmark|Brother|Epson|Kyocera|Sharp|Toshiba|Samsung|Dell|OKI|Oki)') {
            return ($Matches[1] -replace '\s+', ' ')
        }
    }
    return ''
}

function Convert-ReadingsToMpsFmAuditRows {
    param($Readings)
    $rows = @()
    foreach ($r in $Readings) {
        if ($r.Status -ne 'OK') { continue }
        $rows += @{
            'IP Address'    = $r.Ip
            'Manufacturer'  = Get-QuMeterManufacturer $r
            'Model'         = $r.Model
            'Serial Number' = $r.Serial
            'Description'   = $r.SysDescr
            'Total Pages'   = $r.Total
            'Mono Pages'    = $r.Mono
            'Color Pages'   = $r.Color
        }
    }
    return ,$rows
}

function Export-QuMeterMpsFmAuditCsv {
    param($Readings, [string]$Path)
    $rows = Convert-ReadingsToMpsFmAuditRows $Readings
    $headers = @('IP Address','Manufacturer','Model','Serial Number','Description','Total Pages','Mono Pages','Color Pages')
    Write-QuCsv -Path $Path -Headers $headers -Rows $rows
}

function ConvertTo-QuXmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    $s = $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
    $s = $s.Replace("`r`n", '&#10;').Replace("`n", '&#10;').Replace("`r", '&#10;')
    return $s
}

function Get-QuXlsxColName {
    param([int]$Index)
    $n = $Index + 1
    $s = ''
    while ($n -gt 0) {
        $n--
        $s = [string][char]([int][char]'A' + ($n % 26)) + $s
        $n = [int][math]::Floor($n / 26)
    }
    return $s
}

function Test-QuXlsxNumber {
    param($Value)
    $s = [string]$Value
    if ($s -eq '0') { return $true }
    if ($s -match '^-?[1-9]\d*$') { return $true }
    if ($s -match '^-?(0|[1-9]\d*)\.\d+$') { return $true }
    return $false
}

function ConvertTo-QuXlsxCellXml {
    param($Value, [string]$Ref)
    if ($null -eq $Value -or "$Value" -eq '') { return "<c r=`"$Ref`"/>" }
    $s = [string]$Value
    if (Test-QuXlsxNumber $s) { return "<c r=`"$Ref`" t=`"n`"><v>$s</v></c>" }
    $esc = ConvertTo-QuXmlText $s
    return "<c r=`"$Ref`" t=`"inlineStr`"><is><t xml:space=`"preserve`">$esc</t></is></c>"
}

function ConvertTo-QuXlsxSheetName {
    param([string]$Name)
    $s = [string]$Name
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'Sheet' }
    $s = $s -replace '[\\/\?\*\[\]:]', '_'
    $s = $s.Trim("'")
    if ($s.Length -gt 31) { $s = $s.Substring(0, 31) }
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'Sheet' }
    return $s
}

function New-QuXlsxSheetXml {
    param(
        [object[]]$Rows,
        [int[]]$ColumnWidths,
        [int]$FreezeTopRows = 0
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
    if ($FreezeTopRows -gt 0) {
        $top = "A$($FreezeTopRows + 1)"
        [void]$sb.Append("<sheetViews><sheetView workbookViewId=`"0`"><pane ySplit=`"$FreezeTopRows`" topLeftCell=`"$top`" activePane=`"bottomLeft`" state=`"frozen`"/></sheetView></sheetViews>")
    }
    if ($ColumnWidths -and $ColumnWidths.Count -gt 0) {
        [void]$sb.Append('<cols>')
        for ($i = 0; $i -lt $ColumnWidths.Count; $i++) {
            $idx = $i + 1
            $w = $ColumnWidths[$i]
            [void]$sb.Append("<col min=`"$idx`" max=`"$idx`" width=`"$w`" customWidth=`"1`"/>")
        }
        [void]$sb.Append('</cols>')
    }
    [void]$sb.Append('<sheetData>')
    $rNum = 0
    foreach ($row in $Rows) {
        $rNum++
        [void]$sb.Append("<row r=`"$rNum`">")
        $c = 0
        $cells = @($row)
        foreach ($val in $cells) {
            $ref = (Get-QuXlsxColName $c) + "$rNum"
            [void]$sb.Append((ConvertTo-QuXlsxCellXml $val $ref))
            $c++
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function Write-QuXlsx {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable[]]$Sheets
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $usedNames = @{}
    $sheetMeta = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($sheet in $Sheets) {
        $i++
        $name = ConvertTo-QuXlsxSheetName $(if ($sheet.Name) { $sheet.Name } else { "Sheet$i" })
        $base = $name
        $n = 1
        while ($usedNames.ContainsKey($name)) {
            $n++
            $suffix = "_$n"
            $keep = 31 - $suffix.Length
            if ($keep -lt 1) { $keep = 1 }
            $name = ConvertTo-QuXlsxSheetName ($base.Substring(0, [math]::Min($base.Length, $keep)) + $suffix)
        }
        $usedNames[$name] = $true
        $widths = $null
        if ($sheet.ContainsKey('ColumnWidths') -and $sheet.ColumnWidths) { $widths = [int[]]$sheet.ColumnWidths }
        $freeze = 0
        if ($sheet.ContainsKey('FreezeTopRows') -and $sheet.FreezeTopRows) { $freeze = [int]$sheet.FreezeTopRows }
        $xml = New-QuXlsxSheetXml -Rows @($sheet.Rows) -ColumnWidths $widths -FreezeTopRows $freeze
        $sheetMeta.Add(@{ Name = $name; Id = $i; Xml = $xml })
    }

    $types = New-Object System.Text.StringBuilder
    [void]$types.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$types.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    [void]$types.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    [void]$types.Append('<Default Extension="xml" ContentType="application/xml"/>')
    [void]$types.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    foreach ($s in $sheetMeta) {
        [void]$types.Append("<Override PartName=`"/xl/worksheets/sheet$($s.Id).xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
    }
    [void]$types.Append('</Types>')

    $rootRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'

    $wb = New-Object System.Text.StringBuilder
    [void]$wb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$wb.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
    [void]$wb.Append('<sheets>')
    foreach ($s in $sheetMeta) {
        $escName = ConvertTo-QuXmlText $s.Name
        [void]$wb.Append("<sheet name=`"$escName`" sheetId=`"$($s.Id)`" r:id=`"rId$($s.Id)`"/>")
    }
    [void]$wb.Append('</sheets></workbook>')

    $wbRels = New-Object System.Text.StringBuilder
    [void]$wbRels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$wbRels.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
    foreach ($s in $sheetMeta) {
        [void]$wbRels.Append("<Relationship Id=`"rId$($s.Id)`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$($s.Id).xml`"/>")
    }
    [void]$wbRels.Append('</Relationships>')

    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        function Add-QuZipText($Zip, [string]$Name, [string]$Text) {
            $entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $stream = $entry.Open()
            try {
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        }
        Add-QuZipText $zip '[Content_Types].xml' $types.ToString()
        Add-QuZipText $zip '_rels/.rels' $rootRels
        Add-QuZipText $zip 'xl/workbook.xml' $wb.ToString()
        Add-QuZipText $zip 'xl/_rels/workbook.xml.rels' $wbRels.ToString()
        foreach ($s in $sheetMeta) {
            Add-QuZipText $zip "xl/worksheets/sheet$($s.Id).xml" $s.Xml
        }
    } finally { $zip.Dispose() }
}

function Add-QuXlsxRow {
    param($List, [object[]]$Cells)
    [void]$List.Add([object[]]$Cells)
}

function Convert-QuMeterRowsToXlsx {
    param($RowHashes, [string[]]$Headers)
    $list = New-Object System.Collections.Generic.List[object]
    Add-QuXlsxRow $list $Headers
    foreach ($r in @($RowHashes)) {
        $line = foreach ($h in $Headers) { $r[$h] }
        Add-QuXlsxRow $list @($line)
    }
    return ,$list.ToArray()
}

function Get-QuMeterEaGuideRows {
    param($Mapping)
    if (-not $Mapping) { $Mapping = Get-DefaultEaMapping }
    $list = New-Object System.Collections.Generic.List[object]
    Add-QuXlsxRow $list @('Meter Import / Meter Import Advanced - field guide')
    Add-QuXlsxRow $list @('Generated by QuMeter. Column names follow ECI e-automate webhelp: https://webhelp.e-automate.com/cloud/Spreadsheet_Utilities/Data_Import_Utility/Meter_Import.htm')
    Add-QuXlsxRow $list @('The official Import and Export Utility accepts .xlsx only. It is built around the official EA_MeterImport.xlsx template (header metadata in rows 1-7, column headers on row 8, data from row 9). QuMeter fills that same layout. If the utility rejects this generated file, open the official template, set Source, and paste the Import tab data rows under row 8.')
    Add-QuXlsxRow $list @('')
    Add-QuXlsxRow $list @('Field Name','Description','Required','Data Type','Notes')
    if ($Mapping.format -eq 'advanced') {
        $c = $Mapping.advancedColumns
        Add-QuXlsxRow $list @($c.equipmentNumber, 'Equipment number in e-automate', 'No*', 'Text', 'Required if you are not identifying by Model + Serial. Leave blank when identifying by Model + Serial.')
        Add-QuXlsxRow $list @($c.model, 'Model number', 'No*', 'Text', 'Required with Serial when Equipment Number is blank.')
        Add-QuXlsxRow $list @($c.serial, 'Serial number', 'No*', 'Text', 'Required with Model when Equipment Number is blank.')
        Add-QuXlsxRow $list @($c.source, 'Meter source', 'Yes', 'Text', 'Must exist in Lists and Codes. Do not use Contract, Service Call, or Web. Default in QuMeter is SNMP - change it in the mapping if your list uses another name.')
        Add-QuXlsxRow $list @($c.readingDate, 'Meter reading date', 'Yes', 'Date', "Format $($Mapping.dateFormat)")
        Add-QuXlsxRow $list @($c.meterType, 'Meter type name', 'Yes', 'Text', 'Must match a meter type on the equipment in Lists and Codes (default: B\W, Color, Total Count).')
        Add-QuXlsxRow $list @($c.reading, 'Meter reading', 'Yes', 'Number', 'One row per meter type.')
        Add-QuXlsxRow $list @($c.credits, 'Copy credits', 'No', 'Number', 'Left blank.')
        Add-QuXlsxRow $list @($c.remarks, 'Remarks', 'No', 'Text', $Mapping.remarks)
    } else {
        $c = $Mapping.columns
        Add-QuXlsxRow $list @($c.equipmentNumber, 'Equipment number in e-automate', 'No*', 'Text', 'Required if you are not identifying by Model + Serial. Leave blank when identifying by Model + Serial.')
        Add-QuXlsxRow $list @($c.model, 'Model number', 'No*', 'Text', 'Required with Serial when Equipment Number is blank.')
        Add-QuXlsxRow $list @($c.serial, 'Serial number', 'No*', 'Text', 'Required with Model when Equipment Number is blank.')
        Add-QuXlsxRow $list @($c.mono, 'Black-and-white / mono meter', 'If the equipment has this meter', 'Number', 'Left blank when the printer did not report it. QuMeter never estimates.')
        Add-QuXlsxRow $list @($c.color, 'Color meter', 'If the equipment has this meter', 'Number', 'Left blank when the printer did not report it.')
        Add-QuXlsxRow $list @($c.total, 'Total count meter', 'If the equipment has this meter', 'Number', 'Left blank when the printer did not report it.')
        Add-QuXlsxRow $list @($c.remarks, 'Remarks', 'No', 'Text', $Mapping.remarks)
        Add-QuXlsxRow $list @($c.readingDate, 'Meter reading date', 'Yes', 'Date', "Format $($Mapping.dateFormat)")
        Add-QuXlsxRow $list @('Source (header field, not a column)', 'Applies to every row in a basic import', 'Yes', 'Text', "Set on the Import tab header (row 3 in this file) to '$($Mapping.source)'. Must exist in Lists and Codes. Do not use Contract, Service Call, or Web.")
    }
    Add-QuXlsxRow $list @('')
    Add-QuXlsxRow $list @('e-automate will reject a row if you include a meter type the equipment does not have, or omit a meter type it does have (except virtual/calculated meters).')
    return ,$list.ToArray()
}

function New-QuMeterEaImportSheetRows {
    param($Readings, $Mapping)
    if (-not $Mapping) { $Mapping = Get-DefaultEaMapping }
    if ($Mapping.format -eq 'advanced') {
        $c = $Mapping.advancedColumns
        $headers = @($c.equipmentNumber, $c.model, $c.serial, $c.source, $c.readingDate, $c.meterType, $c.reading, $c.credits, $c.remarks)
        $data = Convert-ReadingsToEaAdvancedRows $Readings $Mapping
    } else {
        $c = $Mapping.columns
        $headers = @($c.equipmentNumber, $c.model, $c.serial, $c.mono, $c.color, $c.total, $c.remarks, $c.readingDate)
        $data = Convert-ReadingsToEaBasicRows $Readings $Mapping
    }
    $list = New-Object System.Collections.Generic.List[object]
    Add-QuXlsxRow $list @('Meter Import', 'QuMeter export for the ECI e-automate Import and Export Utility')
    Add-QuXlsxRow $list @('Description', 'Bulk import of meter readings. Official importer is .xlsx only.')
    Add-QuXlsxRow $list @('Source', $Mapping.source)
    Add-QuXlsxRow $list @('Note', 'Source must already exist in Lists and Codes. Do not use Contract, Service Call, or Web.')
    Add-QuXlsxRow $list @('Note', 'Equipment is identified by Model + Serial. Equipment Number is left blank.')
    Add-QuXlsxRow $list @('Note', 'QuMeter does not estimate missing meters. Blank Mono/Color means the printer did not report it.')
    Add-QuXlsxRow $list @('Note', 'Column headers are on row 8. Data starts on row 9. If this generated file is rejected, paste these data rows into the official EA_MeterImport.xlsx template under row 8.')
    Add-QuXlsxRow $list $headers
    foreach ($d in @($data)) {
        $line = foreach ($h in $headers) { $d[$h] }
        Add-QuXlsxRow $list @($line)
    }
    return ,$list.ToArray()
}

function Export-QuMeterEaXlsx {
    param($Readings, [string]$Path, $Mapping)
    if (-not $Mapping) { $Mapping = Get-DefaultEaMapping }
    $importRows = New-QuMeterEaImportSheetRows $Readings $Mapping
    $guideRows = Get-QuMeterEaGuideRows $Mapping
    $importWidths = if ($Mapping.format -eq 'advanced') { @(20,24,20,14,16,16,14,12,28) } else { @(22,24,20,14,14,16,28,16) }
    Write-QuXlsx -Path $Path -Sheets @(
        @{ Name = 'Guide';  Rows = $guideRows;  ColumnWidths = @(36, 70, 28, 14, 70) }
        @{ Name = 'Import'; Rows = $importRows; ColumnWidths = $importWidths; FreezeTopRows = 8 }
    )
}

function Export-QuMeterExcel {
    param($Readings, [string]$Path, $Mapping, [bool]$ExcludeTimedOut, [bool]$ExcludeNoSerial)
    if (-not $Mapping) { $Mapping = Get-DefaultEaMapping }
    $visible = Get-QuMeterVisibleReadings -Readings $Readings -ExcludeTimedOut $ExcludeTimedOut -ExcludeNoSerial $ExcludeNoSerial
    $genHeaders = @('Date','Time','IP','Model','Serial','Total','Mono','Color','SysDescr','Status','Error','SerialSource','ModelSource','TotalSource')
    $genRows = Convert-QuMeterRowsToXlsx -RowHashes (Convert-ReadingsToGeneralRows $visible) -Headers $genHeaders
    $eaRows = New-QuMeterEaImportSheetRows $visible $Mapping
    $mpsHeaders = @('SerialNumber','Model','IPAddress','TotalCount','MonoCount','ColorCount','ReadDate','ReadDateTime','SysDescr')
    $mpsHashes = @()
    foreach ($r in $visible) {
        if ($r.Status -ne 'OK') { continue }
        $when = $r.ReadAt
        if ($when -eq [datetime]::MinValue) { $when = Get-Date }
        $mpsHashes += @{
            'SerialNumber' = $r.Serial
            'Model'        = $r.Model
            'IPAddress'    = $r.Ip
            'TotalCount'   = $r.Total
            'MonoCount'    = $r.Mono
            'ColorCount'   = $r.Color
            'ReadDate'     = $when.ToString('yyyy-MM-dd')
            'ReadDateTime' = $when.ToString('yyyy-MM-dd HH:mm:ss')
            'SysDescr'     = $r.SysDescr
        }
    }
    $mpsRows = Convert-QuMeterRowsToXlsx -RowHashes $mpsHashes -Headers $mpsHeaders
    $fmaHeaders = @('IP Address','Manufacturer','Model','Serial Number','Description','Total Pages','Mono Pages','Color Pages')
    $fmaRows = Convert-QuMeterRowsToXlsx -RowHashes (Convert-ReadingsToMpsFmAuditRows $visible) -Headers $fmaHeaders
    $how = New-Object System.Collections.Generic.List[object]
    Add-QuXlsxRow $how @('How to use these sheets')
    Add-QuXlsxRow $how @('Results', 'Full scan record (opens in Excel). Timed-out addresses are omitted if that box is checked. IPs with no serial number (blank, N/A, unknown, or 0) are omitted if that box is checked.')
    Add-QuXlsxRow $how @('e-automate', 'Recommended import path: use the separate e-automate .xlsx (or this sheet) with the ECI Import and Export Utility. Official utility is .xlsx only. Column headers are on row 8; data starts on row 9. Set Source (row 3) to a meter source that already exists in Lists and Codes (not Contract, Service Call, or Web). If the utility rejects this generated workbook, download the official EA_MeterImport.xlsx template, set Source, and paste the data rows under row 8.')
    Add-QuXlsxRow $how @('MPS', 'Generic watch-folder CSV layout used by QuMeter Automate: SerialNumber, Model, IPAddress, TotalCount, MonoCount, ColorCount, ReadDate, ReadDateTime, SysDescr. Confirm your MPS tool accepts this layout, or map the columns, then let MPS sync to e-automate if that integration is already set up.')
    Add-QuXlsxRow $how @('FMAudit', 'Same meter fields with FMAudit audit-history column names (IP Address, Manufacturer, Model, Serial Number, Description, Total Pages, Mono Pages, Color Pages). Use this if your MPS tool expects FMAudit-style headers. A public, official "import this file into ECI MPS" template was not confirmed; map columns if your tool differs.')
    Add-QuXlsxRow $how @('Recommendation', 'For updating meters on many serial numbers at once, the most reliable documented path is a direct e-automate Meter Import (the e-automate sheet or .xlsx). Use MPS first only if you already have MPS reporting meters into e-automate and your MPS tool can import one of the MPS sheets.')
    Write-QuXlsx -Path $Path -Sheets @(
        @{ Name = 'Results';    Rows = $genRows; ColumnWidths = @(12,10,14,28,18,12,12,12,36,12,28,22,18,18); FreezeTopRows = 1 }
        @{ Name = 'e-automate'; Rows = $eaRows;  ColumnWidths = @(22,24,20,14,14,16,28,16); FreezeTopRows = 8 }
        @{ Name = 'MPS';        Rows = $mpsRows; ColumnWidths = @(18,24,14,14,14,14,14,20,36); FreezeTopRows = 1 }
        @{ Name = 'FMAudit';    Rows = $fmaRows; ColumnWidths = @(14,16,24,18,36,14,14,14); FreezeTopRows = 1 }
        @{ Name = 'How to import'; Rows = $how.ToArray(); ColumnWidths = @(20, 80) }
    )
}

Initialize-QuSnmp
