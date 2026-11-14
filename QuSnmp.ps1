# QuSnmp.ps1 — shared SNMP helpers for QuMeter / QuMeter Auto.
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
            $c.remarks         = $Mapping.remarks
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
                $c.remarks         = $Mapping.remarks
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

Initialize-QuSnmp
