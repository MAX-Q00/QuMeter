# QuMeter - SNMP lifetime meter puller (PowerShell + WinForms, no install)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot 'QuSnmp.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

$settingsPath = Join-Path $PSScriptRoot 'settings.json'
$mappingPath  = Join-Path $PSScriptRoot 'e-automate.mapping.json'
$mapping = Read-EaMapping -Path $mappingPath

function Load-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
    try { return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Save-Settings($obj) {
    ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $settingsPath -Encoding UTF8
}

$saved = Load-Settings
$f = New-Object Windows.Forms.Form -Property @{
    Text = 'QuMeter'
    Size = '900,640'
    MinimumSize = '760,520'
    StartPosition = 'CenterScreen'
    Font = New-Object Drawing.Font('Segoe UI', 9)
}

function L($text,$x,$y,$w=80) {
    $l = New-Object Windows.Forms.Label -Property @{ Text=$text; Location="$x,$y"; AutoSize=$true }
    $f.Controls.Add($l); $l
}
function T($x,$y,$w,$text='') {
    $t = New-Object Windows.Forms.TextBox -Property @{ Location="$x,$y"; Width=$w; Text=$text }
    $f.Controls.Add($t); $t
}

L 'Community' 15 18 | Out-Null
$community = T 90 15 90 $(if ($saved.community) { $saved.community } else { 'public' })
L 'Version' 195 18 50 | Out-Null
$ver = New-Object Windows.Forms.ComboBox -Property @{ Location='250,15'; Width=60; DropDownStyle='DropDownList' }
[void]$ver.Items.AddRange(@('v2c','v1'))
$ver.SelectedItem = $(if ($saved.version) { $saved.version } else { 'v2c' })
if ($ver.SelectedIndex -lt 0) { $ver.SelectedIndex = 0 }
$f.Controls.Add($ver)
L 'Port' 325 18 30 | Out-Null
$port = New-Object Windows.Forms.NumericUpDown -Property @{ Location='360,15'; Width=60; Minimum=1; Maximum=65535; Value=161 }
if ($saved.port) { $port.Value = [decimal]$saved.port }
$f.Controls.Add($port)
L 'Timeout (ms)' 435 18 | Out-Null
$timeout = New-Object Windows.Forms.NumericUpDown -Property @{ Location='525,15'; Width=80; Minimum=100; Maximum=30000; Increment=100; Value=1500 }
if ($saved.timeoutMs) { $timeout.Value = [decimal]$saved.timeoutMs }
$f.Controls.Add($timeout)
L 'Retries' 620 18 | Out-Null
$retries = New-Object Windows.Forms.NumericUpDown -Property @{ Location='675,15'; Width=50; Minimum=0; Maximum=8; Value=1 }
if ($null -ne $saved.retries) { $retries.Value = [decimal]$saved.retries }
$f.Controls.Add($retries)

L 'Printer IPs, ranges, or CIDR (one per line or comma-separated). Example: 10.0.0.10  or  10.0.1.0/24  or  10.0.1.1-10.0.1.50' 15 48 | Out-Null
$targets = New-Object Windows.Forms.TextBox -Property @{
    Location='15,70'; Size='700,90'; Multiline=$true; ScrollBars='Vertical'; AcceptsReturn=$true; Font = New-Object Drawing.Font('Consolas', 9)
}
if ($saved.targets) { $targets.Text = $saved.targets }
$f.Controls.Add($targets)

$load = New-Object Windows.Forms.Button -Property @{ Text='Load list...'; Location='730,70'; Size='140,28' }
$scan = New-Object Windows.Forms.Button -Property @{ Text='Scan'; Location='730,102'; Size='140,28' }
$cancel = New-Object Windows.Forms.Button -Property @{ Text='Cancel'; Location='730,134'; Size='140,28'; Enabled=$false }
$f.Controls.AddRange(@($load,$scan,$cancel))

$grid = New-Object Windows.Forms.DataGridView -Property @{
    Location='15,175'; Size='855,360'; Anchor='Top,Bottom,Left,Right'
    AllowUserToAddRows=$false; AllowUserToDeleteRows=$false; ReadOnly=$true
    AutoSizeColumnsMode='Fill'; SelectionMode='FullRowSelect'; MultiSelect=$true
    RowHeadersVisible=$false; BackgroundColor='White'
}
foreach ($col in @('IP','Model','Serial','Total','Mono','Color','Status','SysDescr','Error')) {
    [void]$grid.Columns.Add($col, $col)
}
$grid.Columns['SysDescr'].FillWeight = 160
$grid.Columns['Error'].FillWeight = 140
$f.Controls.Add($grid)

$exportCsv = New-Object Windows.Forms.Button -Property @{ Text='Export CSV'; Location='15,548'; Size='140,32'; Anchor='Bottom,Left' }
$exportEa  = New-Object Windows.Forms.Button -Property @{ Text='Export e-automate CSV'; Location='165,548'; Size='180,32'; Anchor='Bottom,Left' }
$exportBoth= New-Object Windows.Forms.Button -Property @{ Text='Export both'; Location='355,548'; Size='120,32'; Anchor='Bottom,Left' }
$f.Controls.AddRange(@($exportCsv,$exportEa,$exportBoth))

$st = New-Object Windows.Forms.Label -Property @{ Text='Paste printer IPs and click Scan.'; Location='490,554'; AutoSize=$true; Anchor='Bottom,Left' }
$f.Controls.Add($st)

$script:busy = $false
$script:cancelFlag = $false
$script:readings = New-Object System.Collections.Generic.List[QuMeterSnmp.PrinterReading]

$load.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter='Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'; Title='Load printer list' }
    if ($d.ShowDialog() -eq 'OK') {
        $targets.Text = [System.IO.File]::ReadAllText($d.FileName)
    }
})

function Persist {
    Save-Settings @{
        community = $community.Text
        version   = $ver.SelectedItem.ToString()
        port      = [int]$port.Value
        timeoutMs = [int]$timeout.Value
        retries   = [int]$retries.Value
        targets   = $targets.Text
    }
}

function Get-CurrentReadings { @($script:readings) }

function Prompt-Save([string]$title, [string]$filter, [string]$defaultName) {
    $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Title=$title; Filter=$filter; FileName=$defaultName }
    if ($d.ShowDialog() -eq 'OK') { return $d.FileName }
    return $null
}

$exportCsv.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { [Windows.Forms.MessageBox]::Show('No results to export.','QuMeter') | Out-Null; return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Prompt-Save 'Export general CSV' 'CSV (*.csv)|*.csv' "QuMeter_$stamp.csv"
    if ($path) { Export-QuMeterGeneralCsv -Readings $list -Path $path; $st.Text = "Saved $path" }
})
$exportEa.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { [Windows.Forms.MessageBox]::Show('No results to export.','QuMeter') | Out-Null; return }
    $ok = @($list | Where-Object { $_.Status -eq 'OK' -and $_.Serial })
    if ($ok.Count -eq 0) { [Windows.Forms.MessageBox]::Show('No successful readings with a serial number. e-automate matching is by serial.','QuMeter') | Out-Null; return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path = Prompt-Save 'Export e-automate meter import CSV' 'CSV (*.csv)|*.csv' "QuMeter_eautomate_$stamp.csv"
    if ($path) {
        $mapping = Read-EaMapping -Path $mappingPath
        Export-QuMeterEaCsv -Readings $list -Path $path -Mapping $mapping
        $st.Text = "Saved $path  (paste into EA_MeterImport.xlsx under row 8)"
    }
})
$exportBoth.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { [Windows.Forms.MessageBox]::Show('No results to export.','QuMeter') | Out-Null; return }
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description='Choose a folder for both CSV files' }
    if ($d.ShowDialog() -ne 'OK') { return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $g = Join-Path $d.SelectedPath "QuMeter_$stamp.csv"
    $e = Join-Path $d.SelectedPath "QuMeter_eautomate_$stamp.csv"
    $mapping = Read-EaMapping -Path $mappingPath
    Export-QuMeterGeneralCsv -Readings $list -Path $g
    Export-QuMeterEaCsv -Readings $list -Path $e -Mapping $mapping
    $st.Text = "Saved both CSVs in $($d.SelectedPath)"
})

$scan.Add_Click({
    if ($script:busy) { return }
    Persist
    try {
        $hosts = [QuMeterSnmp.TargetParser]::Parse($targets.Text, 65536)
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'QuMeter') | Out-Null
        return
    }
    if ($hosts.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('Enter at least one IP, range, or CIDR.','QuMeter') | Out-Null
        return
    }
    if ($hosts.Count -gt 1024) {
        $ans = [Windows.Forms.MessageBox]::Show("This expands to $($hosts.Count) addresses. Scan anyway?", 'QuMeter', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
    } elseif ($hosts.Count -gt 256) {
        $ans = [Windows.Forms.MessageBox]::Show("This expands to $($hosts.Count) addresses. Continue?", 'QuMeter', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }

    $script:busy = $true
    $script:cancelFlag = $false
    $scan.Enabled = $false
    $cancel.Enabled = $true
    $grid.Rows.Clear()
    $script:readings = New-Object System.Collections.Generic.List[QuMeterSnmp.PrinterReading]
    $st.Text = "Scanning 0 / $($hosts.Count)..."
    $f.Refresh()

    $client = New-QuSnmpClient -Community $community.Text.Trim() -Port ([int]$port.Value) -TimeoutMs ([int]$timeout.Value) -Retries ([int]$retries.Value) -Version $ver.SelectedItem.ToString()
    $hostList = [string[]]$hosts
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($client, $hosts)
        [QuMeterSnmp.PrinterQuery]::QueryMany($client, $hosts, 32, $null)
    }).AddArgument($client).AddArgument($hostList)
    $script:scanPs = $ps
    $script:scanHandle = $ps.BeginInvoke()
    $script:scanTimer.Start()
})

function Complete-Scan {
    $script:scanTimer.Stop()
    $ps = $script:scanPs
    $handle = $script:scanHandle
    $script:scanPs = $null
    $script:scanHandle = $null
    try {
        if ($ps -and $handle) {
            $list = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
            $script:readings.Clear()
            $grid.Rows.Clear()
            foreach ($r in $list) {
                $script:readings.Add($r)
                [void]$grid.Rows.Add($r.Ip, $r.Model, $r.Serial, $r.Total, $r.Mono, $r.Color, $r.Status, $r.SysDescr, $r.ErrorMessage)
            }
            $ok = @($list | Where-Object { $_.Status -eq 'OK' }).Count
            $to = @($list | Where-Object { $_.Status -eq 'Timeout' }).Count
            $st.Text = "Done. $ok ok, $to timed out, $($list.Count) total."
        }
    } catch {
        $st.Text = "Scan failed: $($_.Exception.Message)"
    } finally {
        if ($ps) {
            try { $ps.Runspace.Dispose() } catch {}
            try { $ps.Dispose() } catch {}
        }
        $script:busy = $false
        $scan.Enabled = $true
        $cancel.Enabled = $false
    }
}

$script:scanTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 200 }
$script:scanTimer.Add_Tick({
    if ($script:scanHandle -and $script:scanHandle.IsCompleted) { Complete-Scan }
    elseif ($script:busy -and $script:scanPs) {
        $n = $script:readings.Count
        $st.Text = 'Scanning...'
    }
})

$cancel.Add_Click({
    $st.Text = 'Cancel requested. Waiting for in-flight queries to finish...'
    # UDP timeouts still have to end; closing the window also stops a new scan from starting.
})

$f.Add_FormClosing({
    Persist
    if ($script:scanTimer) { $script:scanTimer.Stop() }
    if ($script:scanPs) {
        try { $script:scanPs.Stop() } catch {}
        try { if ($script:scanPs.Runspace) { $script:scanPs.Runspace.Dispose() } } catch {}
        try { $script:scanPs.Dispose() } catch {}
    }
})
[void]$f.ShowDialog()
