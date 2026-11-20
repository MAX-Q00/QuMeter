# QuMeter - SNMP lifetime meter puller with Manual and Automate tabs (PowerShell 5.1 + WinForms, no install).
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$app = $PSScriptRoot
. (Join-Path $app 'QuSnmp.ps1')
. (Join-Path $app 'QuMeterCore.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()

$settingsPath = Join-Path $app 'settings.json'
$mappingPath  = Join-Path $app 'e-automate.mapping.json'
$configPath   = Join-Path $app 'config.json'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Load-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
    try { return Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Save-Settings($obj) { ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $settingsPath -Encoding UTF8 }

$saved = Load-Settings
$script:importNote = ''
if (Test-Path -LiteralPath $configPath) { $script:cfg = Read-QmConfig -Path $configPath }
else {
    $legacy = Join-Path (Split-Path -Parent $app) 'QuMeterAuto'
    $imp = $null
    try { $imp = Import-QmLegacyConfig -LegacyDir $legacy } catch { }
    if ($imp) { $script:cfg = $imp; $script:importNote = "Imported settings from $legacy. Click Save settings to keep them." }
    else { $script:cfg = Get-QmDefaultConfig }
}
# ------------------------------------------------------------------ UI helpers
$fontBold = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$fontMono = New-Object Drawing.Font('Consolas', 9)
function Add-C($parent, $ctl) { $parent.Controls.Add($ctl); return $ctl }
function New-L($p, $text, $x, $y) { Add-C $p (New-Object Windows.Forms.Label -Property @{ Text = $text; Location = "$x,$y"; AutoSize = $true }) }
function New-T($p, $x, $y, $w, $text = '') { Add-C $p (New-Object Windows.Forms.TextBox -Property @{ Location = "$x,$y"; Width = $w; Text = "$text" }) }
function New-B($p, $text, $x, $y, $w = 120, $h = 28) { Add-C $p (New-Object Windows.Forms.Button -Property @{ Text = $text; Location = "$x,$y"; Size = "$w,$h" }) }
function New-N($p, $x, $y, $w, $min, $max, $val, $inc = 1) {
    $n = New-Object Windows.Forms.NumericUpDown -Property @{ Location = "$x,$y"; Width = $w; Minimum = $min; Maximum = $max; Increment = $inc }
    $n.Value = [decimal][math]::Min([math]::Max([double]$val, [double]$min), [double]$max)
    Add-C $p $n
}
function New-Cb($p, $x, $y, $w, [string[]]$items, $sel) {
    $c = New-Object Windows.Forms.ComboBox -Property @{ Location = "$x,$y"; Width = $w; DropDownStyle = 'DropDownList' }
    [void]$c.Items.AddRange($items)
    $c.SelectedItem = "$sel"; if ($c.SelectedIndex -lt 0) { $c.SelectedIndex = 0 }
    Add-C $p $c
}
function New-Tips($p, $text, $x, $y, $w, $h, $anchor) {
    # Windows TextBox needs CRLF line breaks; scripts may be saved with LF only.
    $text = [string]$text -replace "`r`n", "`n" -replace "`n", "`r`n"
    $t = New-Object Windows.Forms.TextBox -Property @{ Location = "$x,$y"; Size = "$w,$h"; Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $true; BackColor = [Drawing.Color]::FromArgb(255, 252, 235); Text = $text; Anchor = $anchor }
    Add-C $p $t
}
function Msg($text, $icon = 'Information') { [void][Windows.Forms.MessageBox]::Show($text, 'QuMeter', 'OK', $icon) }
function Ask($text) { return ([Windows.Forms.MessageBox]::Show($text, 'QuMeter', 'YesNo', 'Question') -eq 'Yes') }
function Browse-Folder($box) {
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Choose a folder (you can also type a UNC path like \\server\share\meters)' }
    if ($d.ShowDialog() -eq 'OK') { $box.Text = $d.SelectedPath }
}
function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

$f = New-Object Windows.Forms.Form -Property @{ Text = "QuMeter $(Get-QmVersion) - $(Get-QmPublisher)"; Size = '1100,820'; MinimumSize = '900,640'; StartPosition = 'CenterScreen'; Font = New-Object Drawing.Font('Segoe UI', 9) }
$tabs = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$tabManual = New-Object Windows.Forms.TabPage -Property @{ Text = 'Manual'; Padding = '6,6,6,6'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(1040, 720) }
$tabAuto   = New-Object Windows.Forms.TabPage -Property @{ Text = 'Automate'; Padding = '6,6,6,6'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(1040, 640) }
[void]$tabs.TabPages.Add($tabManual); [void]$tabs.TabPages.Add($tabAuto)
$f.Controls.Add($tabs)
$pubBar = New-Object Windows.Forms.StatusStrip
$pubLeft = New-Object Windows.Forms.ToolStripStatusLabel
$pubLeft.Text = ('Published by {0}' -f (Get-QmPublisher))
$pubLeft.Spring = $true
$pubLeft.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$pubUpdate = New-Object Windows.Forms.ToolStripStatusLabel
$pubUpdate.Text = 'Check for updates'
$pubUpdate.IsLink = $true
$pubUpdate.Margin = New-Object Windows.Forms.Padding(12, 3, 12, 3)
$pubRight = New-Object Windows.Forms.ToolStripStatusLabel
$pubRight.Text = (Get-QmCopyrightText)
[void]$pubBar.Items.Add($pubLeft)
[void]$pubBar.Items.Add($pubUpdate)
[void]$pubBar.Items.Add($pubRight)
$f.Controls.Add($pubBar)

# ================================================================== MANUAL TAB
$scrollHost = Add-C $tabManual (New-Object Windows.Forms.Panel -Property @{ Dock = 'Fill'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(1040, 720) })
$Mhost = $scrollHost
$left = Add-C $Mhost (New-Object Windows.Forms.Panel -Property @{ Dock = 'None' })
$grid = Add-C $left (New-Object Windows.Forms.DataGridView -Property @{
    Dock = 'Fill'
    AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; ReadOnly = $true
    AutoSizeColumnsMode = 'None'; ScrollBars = 'Both'; SelectionMode = 'FullRowSelect'
    MultiSelect = $true; RowHeadersVisible = $false; BackgroundColor = 'White'
    AllowUserToResizeColumns = $true; AllowUserToOrderColumns = $true
})
$top = Add-C $left (New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 312 })
$bottom = Add-C $left (New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 78 })
$M = $top

New-L $M 'Community' 10 13 | Out-Null
$community = New-T $M 80 10 90 $(if ($saved.community) { $saved.community } else { 'public' })
New-L $M 'Version' 180 13 | Out-Null
$ver = New-Cb $M 230 10 60 @('v2c','v1') $(if ($saved.version) { $saved.version } else { 'v2c' })
New-L $M 'Port' 300 13 | Out-Null
$port = New-N $M 333 10 65 1 65535 $(if ($saved.port) { $saved.port } else { 161 })
New-L $M 'Timeout (ms)' 408 13 | Out-Null
$timeout = New-N $M 488 10 70 100 30000 $(if ($saved.timeoutMs) { $saved.timeoutMs } else { 1500 }) 100
New-L $M 'Retries' 568 13 | Out-Null
$retries = New-N $M 615 10 45 0 8 $(if ($null -ne $saved.retries) { $saved.retries } else { 1 })

New-L $M 'Printer IPs, ranges, or CIDR (one per line or comma-separated), e.g. 10.0.0.10   10.0.1.1-50   10.0.1.0/24' 10 42 | Out-Null
$targets = Add-C $M (New-Object Windows.Forms.TextBox -Property @{ Location = '10,62'; Size = '520,90'; Multiline = $true; ScrollBars = 'Both'; WordWrap = $false; AcceptsReturn = $true; Font = $fontMono })
if ($saved.targets) { $targets.Text = $saved.targets }
$load = New-B $M 'Load list...' 540 62 130 28
$scan = New-B $M 'Scan' 540 94 130 32
$scan.Font = $fontBold
$scanCancel = New-B $M 'Stop scan' 540 94 130 32
$scanCancel.Visible = $false
$scanBar = Add-C $M (New-Object Windows.Forms.ProgressBar -Property @{ Location = '540,132'; Size = '130,18' })

$initialRemarks = 'Imported by QuMeter'
if ($script:cfg -and $null -ne $script:cfg.eaRemarks) { $initialRemarks = [string]$script:cfg.eaRemarks }
if ($saved -and ($saved.PSObject.Properties.Name -contains 'remarks')) { $initialRemarks = [string]$saved.remarks }
New-L $M 'Remarks' 10 159 | Out-Null
$remarks = New-T $M 70 156 460 $initialRemarks
$remarks.Anchor = 'Top,Left,Right'

$excludeTo = Add-C $M (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Exclude IPs that timed out from the list and from exports'; Location = '10,184'; AutoSize = $true })
if ($saved.PSObject.Properties.Name -contains 'excludeTimedOut' -and $saved.excludeTimedOut) { $excludeTo.Checked = $true }

$excludeNoSerial = Add-C $M (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Exclude IPs that have no serial number from the list and from exports'; Location = '10,206'; AutoSize = $true })
if ($script:cfg -and $script:cfg.excludeNoSerial) { $excludeNoSerial.Checked = $true }
if ($saved -and ($saved.PSObject.Properties.Name -contains 'excludeNoSerial') -and $saved.excludeNoSerial) { $excludeNoSerial.Checked = $true }

New-L $M 'Responding IPs (did not time out) - copy this list to rescan only those printers:' 10 228 | Out-Null
$responded = Add-C $M (New-Object Windows.Forms.TextBox -Property @{ Location = '10,246'; Size = '520,54'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false; Font = $fontMono; BackColor = 'White' })
$copyIps = New-B $M 'Copy' 540 246 130 28

foreach ($col in @('IP','Model','Serial','Total','Mono','Color','Status','SysDescr','Error')) {
    [void]$grid.Columns.Add($col, $col)
}
$grid.Columns['IP'].Width = 110
$grid.Columns['Model'].Width = 170
$grid.Columns['Serial'].Width = 120
$grid.Columns['Total'].Width = 80
$grid.Columns['Mono'].Width = 80
$grid.Columns['Color'].Width = 80
$grid.Columns['Status'].Width = 80
$grid.Columns['SysDescr'].Width = 220
$grid.Columns['Error'].Width = 220

$exportXlsx = New-B $bottom 'Export Excel' 10 6 110 30
$exportEa   = New-B $bottom 'Export e-automate' 125 6 130 30
$exportMps  = New-B $bottom 'Export MPS' 260 6 100 30
$exportAll  = New-B $bottom 'Export all...' 365 6 110 30
$exportCsv  = New-B $bottom 'Export CSV' 480 6 100 30
$editMap    = New-B $bottom 'Edit mapping...' 585 6 110 30
$st = New-L $bottom 'Paste printer IPs and click Scan.' 10 44
$st.AutoSize = $true

$manualTips = @"
TIPS - USING THE MANUAL OUTPUT

RECOMMENDED: e-automate workbook  (Export e-automate)
Best path for updating meters on many serial numbers at once. Only printers that answered AND reported a serial are included. Matching is by Model + Serial (Equipment Number is left blank).
Columns (ECI Meter Import): Equipment Number, Model, Serial, B\W, Color, Total Count, Remarks, Reading Date.

How to import it into e-automate:
 a. The official Import and Export Utility accepts .xlsx only.
 b. Try dropping the QuMeter e-automate .xlsx onto "Drop a file here" and click Import.
 c. In the file, Source is on the Import sheet in row 3. It must already exist in Lists and Codes (not Contract, Service Call or Web). Change it in Edit mapping... if your list uses a name other than SNMP.
 d. Column headers are on row 8; data starts on row 9.
 e. If the utility rejects this generated workbook, download the official EA_MeterImport.xlsx template, set Source in the header, paste our data rows (not our header) under row 8, save, and import that official file.
 e-automate rejects a row if you send a meter type the equipment doesn't have, or leave out one it does have. Blank Mono/Color means the printer didn't report it; QuMeter never estimates.

ALTERNATIVE: MPS file, then MPS to e-automate  (Export MPS)
Use this if you already have an MPS tool (for example FMAudit / Printanista) reporting meters into e-automate.
 - Default MPS CSV: SerialNumber, Model, IPAddress, TotalCount, MonoCount, ColorCount, ReadDate, ReadDateTime, SysDescr (same layout the Automate tab drops in a watch folder). Confirm your MPS tool accepts that layout, or map the columns.
 - FMAudit-style CSV / Excel sheet: IP Address, Manufacturer, Model, Serial Number, Description, Total Pages, Mono Pages, Color Pages (published FMAudit audit-history names). Use this if your tool expects those headers.
A single official "import this file into ECI MPS" template was not published in the public docs, so confirm the columns in your MPS tool before a live import.

Excel workbook  (Export Excel)
Opens in Excel with sheets for Results, e-automate, MPS, FMAudit, and import instructions. Timed-out IPs and IPs with no serial number are omitted if those boxes are checked. This is the record/spreadsheet export, not a substitute for the official e-automate template if the utility requires it.

General CSV  (Export CSV)
Your record of the scan: date, time, IP, model, serial, total, mono, color, status and any error. Timeouts and IPs with no serial are included unless those boxes are checked.

Responding IP list
After a scan, the box above the grid lists every address that did not time out, one per line, in the same format as the IP input. If "Exclude IPs that have no serial number" is checked, addresses with a blank or placeholder serial (N/A, unknown, 0) are omitted too. Click Copy and paste it back into the input to rescan only those printers.
Click Stop scan to cancel a scan that is still running. Addresses already read are kept; addresses not yet probed are marked Cancelled. Exports warn you if the scan was cancelled, because those results are incomplete.

Exclude IPs that timed out
When checked, timed-out addresses disappear from the grid and from every export. Printers that answered with an error still appear.

Exclude IPs that have no serial number
When checked, printers with no serial number (blank, whitespace, N/A, unknown, or 0) disappear from the grid, from every export (Excel, e-automate, MPS, FMAudit, Export all, and general CSV), and from the Responding IPs list. The same checkbox on the Automate Settings tab is used by scheduled QuMeter Auto runs after it is saved.

Remarks
The Remarks box is written into the e-automate Remarks column (and the e-automate sheet in the Excel workbook). The default is Imported by QuMeter. Leave it empty for a blank remarks field. Commas and quotes are escaped in the CSV. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. The same remarks text is used by Automate / QuMeter Auto (including scheduled runs) after it is saved.

Custom column names / Advanced format
If your template or meter types use different names than B\W, Color and Total Count, click Edit mapping... (e-automate.mapping.json). Set "format": "advanced" for the Meter Import Advanced layout (one row per meter: Meter Type + Reading, with Source).

Scan tips
- Community is usually "public". Use v1 if old printers time out on v2c.
- Big ranges (/24) take a few seconds; non-printers just time out.
- Run from a PC on the printer network: SNMP is UDP 161.
"@
$manualTipsBox = New-Tips $Mhost $manualTips 0 0 370 100 'None'
$left.Dock = 'None'
$manualTipsBox.Dock = 'None'
function Layout-ManualTab {
    $min = $scrollHost.AutoScrollMinSize
    $w = [math]::Max($min.Width, $scrollHost.ClientSize.Width)
    $h = [math]::Max($min.Height, $scrollHost.ClientSize.Height)
    $tipsW = 370
    $manualTipsBox.Location = New-Object Drawing.Point(($w - $tipsW), 0)
    $manualTipsBox.Size = New-Object Drawing.Size($tipsW, $h)
    $left.Location = New-Object Drawing.Point(0, 0)
    $left.Size = New-Object Drawing.Size(($w - $tipsW), $h)
}
$tabManual.Add_Resize({ Layout-ManualTab })
$scrollHost.Add_Resize({ Layout-ManualTab })
Layout-ManualTab

$script:scanJob = $null
$load.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'; Title = 'Load printer list' }
    if ($d.ShowDialog() -eq 'OK') { $targets.Text = [System.IO.File]::ReadAllText($d.FileName) }
})
function Persist {
    Save-Settings @{ community = $community.Text; version = $ver.SelectedItem.ToString(); port = [int]$port.Value; timeoutMs = [int]$timeout.Value; retries = [int]$retries.Value; targets = $targets.Text; excludeTimedOut = [bool]$excludeTo.Checked; excludeNoSerial = [bool]$excludeNoSerial.Checked; remarks = $remarks.Text }
    if ($script:cfg) { $script:cfg.eaRemarks = $remarks.Text; $script:cfg.excludeNoSerial = [bool]$excludeNoSerial.Checked }
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfgFile = Read-QmConfig -Path $configPath
            $cfgFile.eaRemarks = $remarks.Text
            $cfgFile.excludeNoSerial = [bool]$excludeNoSerial.Checked
            Save-QmConfig -Config $cfgFile -Path $configPath
        } catch { }
    }
}
function Get-ExportMapping {
    $map = Read-EaMapping -Path $mappingPath
    $map.remarks = $remarks.Text
    return $map
}
$script:readings = New-Object System.Collections.Generic.List[QuMeterSnmp.PrinterReading]
$script:scanWasCancelled = $false
function Get-CurrentReadings { Get-QuMeterVisibleReadings -Readings @($script:readings) -ExcludeTimedOut $excludeTo.Checked -ExcludeNoSerial $excludeNoSerial.Checked }
function Prompt-Save([string]$title, [string]$filter, [string]$defaultName) {
    $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Title = $title; Filter = $filter; FileName = $defaultName }
    if ($d.ShowDialog() -eq 'OK') { return $d.FileName }
    return $null
}
function Confirm-ExportPartialScan {
    if (-not $script:scanWasCancelled) { return $true }
    $cancelled = @($script:readings | Where-Object { $_.Status -eq 'Cancelled' }).Count
    $finished = $script:readings.Count - $cancelled
    $total = $script:readings.Count
    return (Ask "This scan was cancelled after $finished of $total addresses. These results are incomplete. Export them anyway?")
}
function Show-ManualResults {
    $grid.Rows.Clear()
    $responded.Text = Get-QuMeterRespondedIpText -Readings @($script:readings) -ExcludeNoSerial $excludeNoSerial.Checked
    $visible = Get-CurrentReadings
    foreach ($r in $visible) {
        $i = $grid.Rows.Add($r.Ip, $r.Model, $r.Serial, $r.Total, $r.Mono, $r.Color, $r.Status, $r.SysDescr, $r.ErrorMessage)
        if ($r.Status -eq 'Cancelled') { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(150, 90, 0) }
        elseif ($r.Status -ne 'OK') { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::Firebrick }
    }
    try { $grid.AutoResizeColumns([Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells) } catch { }
    $ok = @($script:readings | Where-Object { $_.Status -eq 'OK' }).Count
    $to = @($script:readings | Where-Object { $_.Status -eq 'Timeout' }).Count
    $cancelled = @($script:readings | Where-Object { $_.Status -eq 'Cancelled' }).Count
    $finished = $script:readings.Count - $cancelled
    $shown = @($visible).Count
    if ($script:scanWasCancelled) {
        $st.ForeColor = [Drawing.Color]::FromArgb(150, 90, 0)
        $st.Text = "Scan cancelled. $ok ok, $to timed out, $finished of $($script:readings.Count) addresses finished, $shown shown."
    } else {
        $st.ForeColor = [Drawing.SystemColors]::ControlText
        $st.Text = "Done. $ok ok, $to timed out, $($script:readings.Count) total, $shown shown."
    }
}
function Set-ScanControlsRunning([bool]$running) {
    $scan.Visible = -not $running
    $scan.Enabled = -not $running
    $scanCancel.Visible = $running
    $scanCancel.Enabled = $running
    $load.Enabled = -not $running
}
function Complete-ManualScan($j) {
    $script:scanTimer.Stop()
    $script:scanJob = $null
    Set-ScanControlsRunning $false
    if ($j.Error) {
        $script:scanWasCancelled = $false
        $st.ForeColor = [Drawing.Color]::Firebrick
        $st.Text = "Scan failed: $($j.Error.Message)"
        return
    }
    $script:readings.Clear()
    if ($j.Results) { foreach ($r in $j.Results) { [void]$script:readings.Add($r) } }
    $script:scanWasCancelled = [bool]$j.IsCancelled
    Show-ManualResults
}
$excludeTo.Add_CheckedChanged({
    if ($script:readings -and $script:readings.Count -gt 0) { Show-ManualResults }
    Persist
})
$excludeNoSerial.Add_CheckedChanged({
    if ($aExcludeNoSerial.Checked -ne $excludeNoSerial.Checked) { $aExcludeNoSerial.Checked = $excludeNoSerial.Checked }
    if ($script:readings -and $script:readings.Count -gt 0) { Show-ManualResults }
    Persist
})
$copyIps.Add_Click({
    $text = $responded.Text
    if ([string]::IsNullOrWhiteSpace($text)) { Msg 'No responding IPs yet. Run a scan first.'; return }
    [Windows.Forms.Clipboard]::SetText($text)
    $n = @($text -split '\r?\n' | Where-Object { $_.Trim() }).Count
    $st.Text = "Copied $n responding IP(s)."
})
$editMap.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$mappingPath`"" })
$exportCsv.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { Msg 'No results to export.'; return }
    if (-not (Confirm-ExportPartialScan)) { return }
    $path = Prompt-Save 'Export general CSV' 'CSV (*.csv)|*.csv' ("QuMeter_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($path) { Export-QuMeterGeneralCsv -Readings $list -Path $path; $st.Text = "Saved $path" }
})
$exportXlsx.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { Msg 'No results to export.'; return }
    if (-not (Confirm-ExportPartialScan)) { return }
    $path = Prompt-Save 'Export Excel workbook' 'Excel workbook (*.xlsx)|*.xlsx' ("QuMeter_{0}.xlsx" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($path) {
        Export-QuMeterExcel -Readings $script:readings -Path $path -Mapping (Get-ExportMapping) -ExcludeTimedOut $excludeTo.Checked -ExcludeNoSerial $excludeNoSerial.Checked
        $st.Text = "Saved $path"
    }
})
$exportEa.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { Msg 'No results to export.'; return }
    if (-not (Confirm-ExportPartialScan)) { return }
    $ok = @($list | Where-Object { $_.Status -eq 'OK' -and $_.Serial })
    if ($ok.Count -eq 0) { Msg 'No successful readings with a serial number. e-automate matching is by serial.'; return }
    $path = Prompt-Save 'Export e-automate meter import' 'e-automate workbook (*.xlsx)|*.xlsx|e-automate CSV (*.csv)|*.csv' ("QuMeter_eautomate_{0}.xlsx" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if (-not $path) { return }
    $map = Get-ExportMapping
    if ([IO.Path]::GetExtension($path) -ieq '.csv') {
        Export-QuMeterEaCsv -Readings $list -Path $path -Mapping $map
        $st.Text = "Saved $path (paste into EA_MeterImport.xlsx under row 8 if needed)"
    } else {
        Export-QuMeterEaXlsx -Readings $list -Path $path -Mapping $map
        $st.Text = "Saved $path (recommended: import in e-automate, or paste into the official template if the utility rejects this file)"
    }
})
$exportMps.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { Msg 'No results to export.'; return }
    if (-not (Confirm-ExportPartialScan)) { return }
    $ok = @($list | Where-Object { $_.Status -eq 'OK' })
    if ($ok.Count -eq 0) { Msg 'No successful readings to put in an MPS file.'; return }
    $d = New-Object Windows.Forms.SaveFileDialog -Property @{
        Title = 'Export MPS meter import'
        Filter = 'MPS CSV (*.csv)|*.csv|FMAudit-style CSV (*.csv)|*.csv'
        FileName = ("QuMeter_mps_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if ($d.ShowDialog() -ne 'OK') { return }
    if ($d.FilterIndex -eq 2) {
        Export-QuMeterMpsFmAuditCsv -Readings $list -Path $d.FileName
        $st.Text = "Saved FMAudit-style MPS CSV $($d.FileName)"
    } else {
        Export-QuMeterMpsCsv -Readings $list -Path $d.FileName
        $st.Text = "Saved MPS CSV $($d.FileName)"
    }
})
$exportAll.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) { Msg 'No results to export.'; return }
    if (-not (Confirm-ExportPartialScan)) { return }
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Choose a folder for the Excel, e-automate, and MPS export files' }
    if ($d.ShowDialog() -ne 'OK') { return }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $map = Get-ExportMapping
    Export-QuMeterGeneralCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_$stamp.csv")
    Export-QuMeterExcel -Readings $script:readings -Path (Join-Path $d.SelectedPath "QuMeter_$stamp.xlsx") -Mapping $map -ExcludeTimedOut $excludeTo.Checked -ExcludeNoSerial $excludeNoSerial.Checked
    Export-QuMeterEaCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_eautomate_$stamp.csv") -Mapping $map
    Export-QuMeterEaXlsx -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_eautomate_$stamp.xlsx") -Mapping $map
    Export-QuMeterMpsCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_mps_$stamp.csv")
    Export-QuMeterMpsFmAuditCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_mps_fmaudit_$stamp.csv")
    $st.Text = "Saved Excel, e-automate, and MPS files in $($d.SelectedPath). Recommended: import the e-automate .xlsx in e-automate (or paste into the official template)."
})
$scan.Add_Click({
    if ($script:scanJob) { return }
    Persist
    try { $hosts = [QuMeterSnmp.TargetParser]::Parse($targets.Text, 65536) } catch { Msg $_.Exception.Message 'Warning'; return }
    if ($hosts.Count -eq 0) { Msg 'Enter at least one IP, range, or CIDR.'; return }
    if ($hosts.Count -gt 256 -and -not (Ask "This expands to $($hosts.Count) addresses. Scan anyway?")) { return }
    $grid.Rows.Clear(); $script:readings.Clear(); $responded.Text = ''
    $script:scanWasCancelled = $false
    $st.ForeColor = [Drawing.SystemColors]::ControlText
    $client = New-QuSnmpClient -Community $community.Text.Trim() -Port ([int]$port.Value) -TimeoutMs ([int]$timeout.Value) -Retries ([int]$retries.Value) -Version $ver.SelectedItem.ToString()
    $scanBar.Maximum = [math]::Max(1, $hosts.Count); $scanBar.Value = 0
    $script:scanJob = [QuMeterSnmp.ScanJob]::Start($client, [string[]]$hosts, 32)
    Set-ScanControlsRunning $true
    $st.Text = "Scanning 0 / $($hosts.Count)..."
    $script:scanTimer.Start()
})
$scanCancel.Add_Click({
    $j = $script:scanJob
    if (-not $j -or $j.IsCompleted) { return }
    $scanCancel.Enabled = $false
    $st.ForeColor = [Drawing.Color]::FromArgb(150, 90, 0)
    $st.Text = 'Stopping scan...'
    $j.Cancel()
})
$script:scanTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 200 }
$script:scanTimer.Add_Tick({
    $j = $script:scanJob
    if (-not $j) { $script:scanTimer.Stop(); return }
    $scanBar.Value = [math]::Min($j.Done, $scanBar.Maximum)
    if (-not $j.IsCompleted) {
        if ($j.IsCancelled) { $st.Text = "Stopping scan... $($j.Done) / $($j.Total) finished." }
        else { $st.Text = "Scanning $($j.Done) / $($j.Total)..." }
        return
    }
    Complete-ManualScan $j
})

# ================================================================== AUTOMATE TAB
$A = $tabAuto
$sub = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$pSet = New-Object Windows.Forms.TabPage -Property @{ Text = 'Settings'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(900, 620) }
$pSch = New-Object Windows.Forms.TabPage -Property @{ Text = 'Schedule (this PC)'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(900, 560) }
$pTip = New-Object Windows.Forms.TabPage -Property @{ Text = 'Tips'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(900, 500) }
foreach ($pg in @($pSet,$pSch,$pTip)) { [void]$sub.TabPages.Add($pg) }
$A.Controls.Add($sub)

# --- Run once now bar (top)
$top = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 140; BorderStyle = 'FixedSingle'; BackColor = [Drawing.Color]::FromArgb(240, 247, 255) }
$A.Controls.Add($top)
$autoBanner = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 28; BackColor = [Drawing.Color]::FromArgb(255, 248, 230) }
$autoBannerFlow = New-Object Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Fill'; WrapContents = $false; Padding = '6,4,6,0' }
[void]$autoBannerFlow.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = 'Beta: this tab is still in development. Feedback is welcome.'; AutoSize = $true; Margin = '0,2,12,0'; ForeColor = [Drawing.Color]::FromArgb(90, 70, 20) }))
$lnkFeedback = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Send feedback'; AutoSize = $true; Margin = '0,2,12,0'; LinkColor = [Drawing.Color]::FromArgb(0, 102, 184) }
$lnkGithubIssue = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Report on GitHub'; AutoSize = $true; Margin = '0,2,0,0'; LinkColor = [Drawing.Color]::FromArgb(0, 102, 184) }
$lnkFeedback.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackMailto) } catch { Msg $_.Exception.Message 'Error' } })
$lnkGithubIssue.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackIssuesUrl) } catch { Msg $_.Exception.Message 'Error' } })
[void]$autoBannerFlow.Controls.Add($lnkFeedback)
[void]$autoBannerFlow.Controls.Add($lnkGithubIssue)
$autoBanner.Controls.Add($autoBannerFlow)
$A.Controls.Add($autoBanner)
$sub.BringToFront()
$runOnce = New-B $top 'Run once now' 10 10 180 56
$runOnce.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$runOnce.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $runOnce.ForeColor = 'White'; $runOnce.FlatStyle = 'Flat'
(New-L $top "Runs the full automated meter`nreport one time with the saved`nsettings (same as a scheduled run)." 10 70).ForeColor = 'DimGray'
$runBar = Add-C $top (New-Object Windows.Forms.ProgressBar -Property @{ Location = '205,10'; Size = '600,22'; Anchor = 'Top,Left,Right' })
$runStatus = New-L $top 'Ready. Save your settings, then click Run once now to test.' 205 38
$runStatus.Font = $fontBold
$lnkOut = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open output folder'; Location = '820,12'; AutoSize = $true; Anchor = 'Top,Right' })
$lnkLog = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open last log'; Location = '820,32'; AutoSize = $true; Anchor = 'Top,Right' })
$lnkSt  = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Last run details'; Location = '930,12'; AutoSize = $true; Anchor = 'Top,Right' })
$lnkMps = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open MPS folder'; Location = '930,32'; AutoSize = $true; Anchor = 'Top,Right' })
$runLog = Add-C $top (New-Object Windows.Forms.TextBox -Property @{ Location = '205,58'; Size = '835,74'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; Font = $fontMono; Anchor = 'Top,Left,Right' })

# --- Settings sub-tab
$S = $pSet
New-L $S 'Printers to read (IPs, ranges, CIDR; one per line):' 10 10 | Out-Null
$aTargets = Add-C $S (New-Object Windows.Forms.TextBox -Property @{ Location = '10,30'; Size = '400,170'; Multiline = $true; ScrollBars = 'Both'; WordWrap = $false; AcceptsReturn = $true; Font = $fontMono })
$aCopy = New-B $S 'Copy list from Manual tab' 10 205 180 26
$aLoad = New-B $S 'Load list...' 195 205 100 26
$x2 = 440
New-L $S 'Community' $x2 33 | Out-Null;   $aComm = New-T $S ($x2 + 90) 30 110
New-L $S 'SNMP version' $x2 63 | Out-Null; $aVer = New-Cb $S ($x2 + 90) 60 70 @('v2c','v1') 'v2c'
New-L $S 'Port' $x2 93 | Out-Null;        $aPort = New-N $S ($x2 + 90) 90 70 1 65535 161
New-L $S 'Timeout (ms)' $x2 123 | Out-Null; $aTimeout = New-N $S ($x2 + 90) 120 80 100 30000 1500 100
New-L $S 'Retries' $x2 153 | Out-Null;     $aRetries = New-N $S ($x2 + 90) 150 50 0 8 1
New-L $S 'Parallel queries' $x2 183 | Out-Null; $aConc = New-N $S ($x2 + 90) 180 60 1 64 32

$y = 245
New-L $S 'Output folder' 10 ($y + 3) | Out-Null;   $aOut = New-T $S 150 $y 520;  $bOut = New-B $S 'Browse...' 675 ($y - 1) 80 24
$y += 30; New-L $S 'MPS drop folder (optional)' 10 ($y + 3) | Out-Null; $aMps = New-T $S 150 $y 520; $bMps = New-B $S 'Browse...' 675 ($y - 1) 80 24
$y += 30; New-L $S 'Log folder' 10 ($y + 3) | Out-Null; $aLogF = New-T $S 150 $y 520; $bLog = New-B $S 'Browse...' 675 ($y - 1) 80 24
$y += 30; New-L $S 'Keep files (days, 0 = forever)' 10 ($y + 3) | Out-Null; $aRet = New-N $S 190 $y 70 0 3650 90
$y += 30; New-L $S 'e-automate format' 10 ($y + 3) | Out-Null; $aFmt = New-Cb $S 150 $y 100 @('basic','advanced') 'basic'
New-L $S 'Meter source (Lists and Codes)' 265 ($y + 3) | Out-Null; $aSrc = New-T $S 445 $y 120
$y += 30; New-L $S 'Meter remarks' 10 ($y + 3) | Out-Null; $aRemarks = New-T $S 150 $y 605 $initialRemarks
$y += 30; $aExcludeNoSerial = Add-C $S (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Exclude IPs that have no serial number from exports'; Location = "10,$y"; AutoSize = $true })
if ($excludeNoSerial.Checked) { $aExcludeNoSerial.Checked = $true }
$y += 30; New-L $S 'Mapping file' 10 ($y + 3) | Out-Null; $aMap = New-T $S 150 $y 440; $bMap = New-B $S 'Browse...' 595 ($y - 1) 75 24; $bMapEdit = New-B $S 'Edit' 675 ($y - 1) 80 24
$y += 40
$aSave = New-B $S 'Save settings' 10 $y 130 32
$aSave.Font = $fontBold
$aReload = New-B $S 'Reload' 145 $y 90 32
$aValid = New-L $S $script:importNote 245 ($y + 8)

# --- Schedule sub-tab
$H = $pSch
New-L $H 'Task name' 10 18 | Out-Null;  $sName = New-T $H 130 15 220
New-L $H 'Frequency' 10 50 | Out-Null;  $sFreq = New-Cb $H 130 47 100 @('Daily','Weekly','Monthly') 'Daily'
New-L $H 'Time' 245 50 | Out-Null
$sTime = Add-C $H (New-Object Windows.Forms.DateTimePicker -Property @{ Location = '285,47'; Width = 80; Format = 'Custom'; CustomFormat = 'HH:mm'; ShowUpDown = $true })
New-L $H 'Day of week' 10 82 | Out-Null; $sDow = New-Cb $H 130 79 110 @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') 'Monday'
New-L $H 'Day of month' 245 82 | Out-Null; $sDom = New-Cb $H 335 79 60 (@(1..28 | ForEach-Object { "$_" }) + 'Last') '1'
New-L $H 'Run as' 10 114 | Out-Null
$runAsItems = @('Current user (only when logged on)','SYSTEM (always; needs admin)','Service account (always)')
$sRunAs = New-Cb $H 130 111 260 $runAsItems $runAsItems[0]
New-L $H 'Account (DOMAIN\user)' 10 146 | Out-Null; $sUser = New-T $H 150 143 240
$sInstall = New-B $H 'Install / Update task' 10 185 160 32
$sInstall.Font = $fontBold
$sRemove = New-B $H 'Remove task' 175 185 110 32
$sRefresh = New-B $H 'Refresh status' 290 185 110 32
$sAdmin = New-B $H 'Restart QuMeter as administrator' 405 185 220 32
$sStatus = Add-C $H (New-Object Windows.Forms.TextBox -Property @{ Location = '10,230'; Size = '1010,200'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Font = $fontMono; Anchor = 'Top,Left,Right' })
(New-L $H "The service account password is handed to Windows Task Scheduler only; QuMeter never saves it.`n'Current user' needs no admin rights but only runs while you're logged on. Use SYSTEM or a service account to run with nobody logged on." 10 440).ForeColor = 'DimGray'

# --- Tips sub-tab
$autoTips = @"
TIPS - AUTOMATE

WHAT IT DOES
Each run (scheduled, or Run once now) reads every printer over SNMP and writes, with a date/time stamp:
  - QuMeter_<stamp>.csv            general results for every address (records / Excel)
  - QuMeter_eautomate_<stamp>.csv  e-automate meter import rows (OK + serial only)
  - QuMeter_mps_<stamp>.csv        optional, into the MPS drop folder
  - logs\QuMeter_<date>.log        what happened, per printer
  - logs\status.json               run status the GUI reads (success, per-printer errors, files, write errors)
Files older than "Keep files" days are deleted from the output and log folders (never from the MPS folder).

GETTING METERS INTO E-AUTOMATE
Same as the Manual tab: open EA_MeterImport.xlsx, set Source (must exist in Lists and Codes), paste the e-automate CSV rows under the headers on row 8, and run the import. Matching is by Serial.
Meter remarks come from the Meter remarks box on this Settings tab (default Imported by QuMeter). Leave it empty for a blank remarks field. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. Check "Exclude IPs that have no serial number from exports" to leave printers with a blank or placeholder serial (N/A, unknown, 0) out of the general, e-automate, and MPS files. Click Save settings so scheduled QuMeter Auto runs use the remarks and this checkbox (they are stored in config.json).

OUTPUT TO A NETWORK SHARE
Output and MPS folders can be UNC paths like \\fileserver\meters so files land where you and e-automate can reach them.
If the task runs as SYSTEM it uses the computer account (e.g. SERVER$) on the network. SYSTEM can't write to a share unless that computer account has write rights on the share and folder. For UNC output, a domain service account with write access is recommended (Run as > Service account).

THIS PC (Schedule tab)
Install / Update creates the Windows task "QuMeter Auto". Current user = no admin needed but only while logged on. SYSTEM / service account = runs with nobody logged on (admin needed to install).

ERRORS
Anything that goes wrong is shown on Run once now and in Last run details: printers timing out, files that couldn't be written, or bad settings. The Schedule tab also shows the task's last/next run and result.
"@
New-Tips $pTip $autoTips 6 6 1020 470 'Top,Bottom,Left,Right' | Out-Null
$pTip.Add_Resize({ $pTip.Controls[0].Size = "$($pTip.ClientSize.Width - 12),$($pTip.ClientSize.Height - 12)" })


$remarks.Add_TextChanged({ if ($aRemarks.Text -ne $remarks.Text) { $aRemarks.Text = $remarks.Text } })
$aRemarks.Add_TextChanged({ if ($remarks.Text -ne $aRemarks.Text) { $remarks.Text = $aRemarks.Text } })
$aExcludeNoSerial.Add_CheckedChanged({
    if ($excludeNoSerial.Checked -ne $aExcludeNoSerial.Checked) { $excludeNoSerial.Checked = $aExcludeNoSerial.Checked }
})
# ------------------------------------------------------------------ config <-> GUI
function Set-GuiFromConfig($c) {
    $aTargets.Text = (@($c.targets) -join "`r`n")
    $aComm.Text = $c.community; $aVer.SelectedItem = "$($c.version)"
    $aPort.Value = [decimal]$c.port; $aTimeout.Value = [decimal][math]::Max(100, $c.timeoutMs); $aRetries.Value = [decimal]$c.retries; $aConc.Value = [decimal][math]::Min(64, [math]::Max(1, $c.concurrency))
    $aOut.Text = $c.outputFolder; $aMps.Text = $c.mpsDropFolder; $aLogF.Text = $c.logFolder; $aRet.Value = [decimal]$c.retentionDays
    $aFmt.SelectedItem = "$($c.eaFormat)"; $aSrc.Text = $c.eaSource; $aRemarks.Text = [string]$c.eaRemarks; $remarks.Text = [string]$c.eaRemarks; $aExcludeNoSerial.Checked = [bool]$c.excludeNoSerial; $excludeNoSerial.Checked = [bool]$c.excludeNoSerial; $aMap.Text = $c.mappingFile
    $s = $c.schedule
    $sName.Text = $s.taskName; $sFreq.SelectedItem = "$($s.frequency)"
    try { $sTime.Value = [datetime]::Today.Add([TimeSpan]::Parse("$($s.time)")) } catch { }
    $sDow.SelectedItem = "$($s.dayOfWeek)"; $sDom.SelectedItem = "$($s.dayOfMonth)"
    $sRunAs.SelectedIndex = @{ CurrentUser = 0; SYSTEM = 1; Account = 2 }["$($s.runAs)"]
    if ($sRunAs.SelectedIndex -lt 0) { $sRunAs.SelectedIndex = 0 }
    $sUser.Text = $s.runAsUser
    Update-Enables
}
function Get-ConfigFromGui {
    $c = Get-QmDefaultConfig
    $c.targets = [string[]](ConvertTo-QmTargetList $aTargets.Text)
    $c.targetFile = "$($script:cfg.targetFile)"
    $c.community = $aComm.Text.Trim(); $c.version = "$($aVer.SelectedItem)"; $c.port = [int]$aPort.Value
    $c.timeoutMs = [int]$aTimeout.Value; $c.retries = [int]$aRetries.Value; $c.concurrency = [int]$aConc.Value
    $c.outputFolder = $aOut.Text.Trim(); $c.mpsDropFolder = $aMps.Text.Trim(); $c.logFolder = $(if ($aLogF.Text.Trim()) { $aLogF.Text.Trim() } else { 'logs' })
    $c.retentionDays = [int]$aRet.Value; $c.eaFormat = "$($aFmt.SelectedItem)"; $c.eaSource = $aSrc.Text.Trim(); $c.eaRemarks = $aRemarks.Text; $c.excludeNoSerial = [bool]$aExcludeNoSerial.Checked
    $c.mappingFile = $(if ($aMap.Text.Trim()) { $aMap.Text.Trim() } else { 'e-automate.mapping.json' })
    $c.schedule.taskName = $sName.Text.Trim(); $c.schedule.frequency = "$($sFreq.SelectedItem)"; $c.schedule.time = $sTime.Value.ToString('HH:mm')
    $c.schedule.dayOfWeek = "$($sDow.SelectedItem)"; $c.schedule.dayOfMonth = "$($sDom.SelectedItem)"
    $c.schedule.runAs = @('CurrentUser','SYSTEM','Account')[$sRunAs.SelectedIndex]; $c.schedule.runAsUser = $sUser.Text.Trim()
    return $c
}
function Update-Enables {
    $sDow.Enabled = ($sFreq.SelectedItem -eq 'Weekly'); $sDom.Enabled = ($sFreq.SelectedItem -eq 'Monthly')
    $sUser.Enabled = ($sRunAs.SelectedIndex -eq 2)
    $sAdmin.Visible = -not (Test-IsAdmin)
}
function Save-All([switch]$Quiet) {
    $c = Get-ConfigFromGui
    $errs = Test-QmConfig -Config $c -Root $app
    if ($errs.Count) {
        $aValid.ForeColor = 'Firebrick'; $aValid.Text = ($errs -join '  ')
        Msg ("Please fix:`n - " + ($errs -join "`n - ")) 'Warning'
        return $null
    }
    Save-QmConfig -Config $c -Path $configPath
    $script:cfg = Read-QmConfig -Path $configPath
    $remarks.Text = $aRemarks.Text
    Persist
    $aValid.ForeColor = 'DarkGreen'; $aValid.Text = "Saved $(Get-Date -Format 'HH:mm:ss'). Schedule: $(Get-QmScheduleText $script:cfg.schedule)."
    return $script:cfg
}

foreach ($ctl in @($sFreq,$sRunAs)) { $ctl.Add_SelectedIndexChanged({ Update-Enables }) }
$aCopy.Add_Click({ $aTargets.Text = $targets.Text; $aComm.Text = $community.Text; $aVer.SelectedItem = $ver.SelectedItem; $aPort.Value = $port.Value; $aTimeout.Value = $timeout.Value; $aRetries.Value = $retries.Value })
$aLoad.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*' }
    if ($d.ShowDialog() -eq 'OK') { $aTargets.Text = [System.IO.File]::ReadAllText($d.FileName) }
})
$bOut.Add_Click({ Browse-Folder $aOut }); $bMps.Add_Click({ Browse-Folder $aMps }); $bLog.Add_Click({ Browse-Folder $aLogF })
$bMap.Add_Click({ $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'JSON (*.json)|*.json' }; if ($d.ShowDialog() -eq 'OK') { $aMap.Text = $d.FileName } })
$bMapEdit.Add_Click({ $p = Resolve-QmPath $(if ($aMap.Text) { $aMap.Text } else { 'e-automate.mapping.json' }) $app; Start-Process notepad.exe -ArgumentList "`"$p`"" })
$aSave.Add_Click({ [void](Save-All) })
$aReload.Add_Click({ $script:cfg = Read-QmConfig -Path $configPath; Set-GuiFromConfig $script:cfg })

# ------------------------------------------------------------------ Run once now (local)
$script:runProc = $null; $script:runProgFile = $null; $script:runPos = 0
function Get-LocalFolder([string]$which) { $v = $script:cfg[$which]; if (-not $v) { return $null }; return Resolve-QmPath $v $app }
function Read-LocalStatus {
    $lf = Get-LocalFolder 'logFolder'; if (-not $lf) { $lf = Join-Path $app 'logs' }
    $p = Join-Path $lf 'status.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Read-QmStatus -Json ([System.IO.File]::ReadAllText($p)) } catch { return $null }
}
function Show-LocalResult {
    $s = Read-LocalStatus
    if (-not $s) { $runStatus.ForeColor = 'Firebrick'; $runStatus.Text = 'The run did not produce a status. See the log below.'; return }
    if ($s.run.success) { $runStatus.ForeColor = 'DarkGreen'; $runStatus.Text = "Success: $($s.counts.ok) of $($s.counts.hosts) printers read, files written ($($s.run.finishedAt))." }
    elseif ($s.run.partial) { $runStatus.ForeColor = 'DarkOrange'; $runStatus.Text = "Completed with errors: $($s.run.error)" }
    else { $runStatus.ForeColor = 'Firebrick'; $runStatus.Text = "FAILED [$($s.run.errorStage)]: $($s.run.error)" }
    if ($s.counts.timeout + $s.counts.error -gt 0 -and $s.run.success) { $runStatus.Text += "  ($($s.counts.timeout + $s.counts.error) printer(s) didn't answer - see Last run details)" }
}
$runOnce.Add_Click({
    if ($script:runProc) { return }
    if (-not (Save-All)) { return }
    $script:runProgFile = Join-Path ([System.IO.Path]::GetTempPath()) ('QuMeterRun_' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($script:runProgFile, '')
    $script:runPos = 0
    $runLog.Clear(); $runBar.Value = 0; $runBar.Maximum = 100
    $runStatus.ForeColor = 'Black'; $runStatus.Text = 'Starting...'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $app 'QuMeterEngine.ps1')`" -ConfigPath `"$configPath`" -ProgressFile `"$($script:runProgFile)`" -Trigger manual"
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $app
    try { $script:runProc = [System.Diagnostics.Process]::Start($psi) } catch { $runStatus.ForeColor = 'Firebrick'; $runStatus.Text = "Could not start the engine: $($_.Exception.Message)"; return }
    $runOnce.Enabled = $false
    $script:runTimer.Start()
})
function Read-ProgressLines {
    if (-not $script:runProgFile -or -not (Test-Path -LiteralPath $script:runProgFile)) { return }
    $fs = New-Object System.IO.FileStream($script:runProgFile, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -le $script:runPos) { return }
        [void]$fs.Seek($script:runPos, 'Begin')
        $sr = New-Object System.IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
        $cut = $text.LastIndexOf("`n")
        if ($cut -lt 0) { return }
        $script:runPos += [System.Text.Encoding]::UTF8.GetByteCount($text.Substring(0, $cut + 1))
        foreach ($line in ($text.Substring(0, $cut) -split "`r?`n")) {
            if ($line -match '^PROGRESS (\d+)/(\d+)') { $runBar.Maximum = [math]::Max(1, [int]$Matches[2]); $runBar.Value = [math]::Min([int]$Matches[1], $runBar.Maximum); $runStatus.Text = "Reading printers: $($Matches[1]) of $($Matches[2])" }
            elseif ($line -match '^STEP (.*)') { $runStatus.Text = $Matches[1] }
            elseif ($line -match '^LOG (.*)') { $runLog.AppendText($Matches[1] + "`r`n") }
        }
    } finally { $fs.Dispose() }
}
$script:runTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 300 }
$script:runTimer.Add_Tick({
    try { Read-ProgressLines } catch { }
    if ($script:runProc -and $script:runProc.HasExited) {
        $script:runTimer.Stop()
        try { Read-ProgressLines } catch { }
        $code = $script:runProc.ExitCode
        $script:runProc = $null; $runOnce.Enabled = $true
        if ($runBar.Value -lt $runBar.Maximum -and $code -eq 0) { $runBar.Value = $runBar.Maximum }
        Show-LocalResult
        Remove-Item -LiteralPath $script:runProgFile -Force -ErrorAction SilentlyContinue
    }
})
$lnkOut.Add_LinkClicked({ $p = Get-LocalFolder 'outputFolder'; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList "`"$p`"" } else { Msg "Output folder doesn't exist yet: $p" } })
$lnkMps.Add_LinkClicked({ $p = Get-LocalFolder 'mpsDropFolder'; if ($p -and (Test-Path -LiteralPath $p)) { Start-Process explorer.exe -ArgumentList "`"$p`"" } else { Msg 'No MPS drop folder set, or it does not exist yet.' } })
$lnkLog.Add_LinkClicked({
    $lf = Get-LocalFolder 'logFolder'
    $l = Get-ChildItem -LiteralPath $lf -Filter 'QuMeter*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) { Start-Process notepad.exe -ArgumentList "`"$($l.FullName)`"" } else { Msg "No log yet in $lf" }
})
$lnkSt.Add_LinkClicked({
    $s = Read-LocalStatus
    if (-not $s) { Msg 'No run on this PC yet.'; return }
    $txt = ConvertTo-QmStatusText $s
    $bad = @($s.devices | Where-Object { $_.status -ne 'OK' -or $_.error })
    if ($bad.Count) { $txt += "`r`n`r`nPrinters with problems:`r`n" + (($bad | ForEach-Object { "  $($_.ip)  $($_.status)  $($_.error)" }) -join "`r`n") }
    Msg $txt
})

# ------------------------------------------------------------------ Schedule (this PC)
function Show-LocalTask {
    try {
        $t = Get-QmLocalTaskStatus -TaskName $sName.Text.Trim()
        $sStatus.Text = "Task '$($sName.Text)': $($t.State)`r`nRun as: $($t.RunAs)`r`nLast run: $($t.LastRunTime)   Result: $($t.LastResult)`r`nNext run: $($t.NextRunTime)"
        $st = Read-LocalStatus
        if ($st) { $sStatus.Text += "`r`n`r`n" + (ConvertTo-QmStatusText $st) }
    } catch { $sStatus.Text = "Could not read task: $($_.Exception.Message)" }
}
$sRefresh.Add_Click({ Show-LocalTask })
$sInstall.Add_Click({
    $c = Save-All; if (-not $c) { return }
    if ($c.schedule.runAs -ne 'CurrentUser' -and -not (Test-IsAdmin)) { Msg 'Running as SYSTEM or a service account needs admin rights. Click "Restart QuMeter as administrator" first.' 'Warning'; return }
    $cred = $null
    if ($c.schedule.runAs -eq 'Account') {
        $cred = Get-Credential -UserName $c.schedule.runAsUser -Message 'Service account the QuMeter Auto task runs as. The password goes to Task Scheduler only.'
        if (-not $cred) { return }
    }
    try {
        $t = Install-QmLocalTask -Config $c -AppDir $app -RunAsCredential $cred
        Show-LocalTask
        Msg "Scheduled '$($c.schedule.taskName)' $(Get-QmScheduleText $c.schedule). Next run: $($t.NextRunTime)"
    } catch { $sStatus.Text = "Install failed: $($_.Exception.Message)"; Msg "Install failed: $($_.Exception.Message)" 'Error' }
})
$sRemove.Add_Click({
    if (-not (Ask "Remove the scheduled task '$($sName.Text)' from this PC?")) { return }
    try { if (Remove-QmLocalTask -TaskName $sName.Text.Trim()) { $sStatus.Text = 'Task removed.' } else { $sStatus.Text = 'Task was not installed.' } }
    catch { $sStatus.Text = "Remove failed: $($_.Exception.Message)" }
})
$sAdmin.Add_Click({
    try { Start-Process $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $app 'QuMeter.ps1')`""; $f.Close() } catch { }
})

# ------------------------------------------------------------------ start
Set-GuiFromConfig $script:cfg
if ($script:importNote) { $aValid.ForeColor = 'DarkOrange' }
if (Test-Path -LiteralPath $configPath) { try { Show-LocalResult; if (-not (Read-LocalStatus)) { $runStatus.ForeColor = 'Black'; $runStatus.Text = 'Ready. Save your settings, then click Run once now to test.' } } catch { } }
Show-LocalTask
function Stop-QmBackgroundUpdateCheck {
    foreach ($tm in @($script:updateTimer, $script:updatePoll)) { if ($tm) { try { $tm.Stop() } catch { } } }
    if ($script:updatePs) {
        try { $script:updatePs.Stop() } catch { }
        try { $script:updatePs.Dispose() } catch { }
        $script:updatePs = $null
    }
    if ($script:updateRs) {
        try { $script:updateRs.Dispose() } catch { }
        $script:updateRs = $null
    }
}
function Invoke-QmUpdateInstall($rel) {
    $pubUpdate.Text = ("Downloading QuMeter {0}..." -f $rel.Version)
    $f.Cursor = 'WaitCursor'
    try {
        $null = Install-QmUpdateFromRelease -Release $rel -AppDir $app -WaitPid $PID -Relaunch
        $pubUpdate.Text = 'Restarting to finish the update...'
        $f.Close()
    } catch {
        $f.Cursor = 'Default'
        $pubUpdate.Text = 'Check for updates'
        Msg ("Update failed: {0}" -f $_.Exception.Message) 'Error'
    }
}
function Show-QmUpdatePrompt($rel) {
    $msg = "QuMeter $($rel.Version) is available (you have $(Get-QmVersion)). Download and install the update from GitHub Releases now?"
    if (Ask $msg) { Invoke-QmUpdateInstall $rel }
}
function Show-QmUpdateCheck {
    param([switch]$QuietIfCurrent)
    $pubUpdate.Text = 'Checking for updates...'
    $cur = Get-QmVersion
    $rel = $null
    try { $rel = Get-QmLatestRelease } catch { $rel = $null }
    $pubUpdate.Text = 'Check for updates'
    if (-not $rel) {
        if (-not $QuietIfCurrent) { Msg 'Could not check for updates. Check your internet connection and try again, or confirm a GitHub Release exists.' 'Warning' }
        return
    }
    $cmp = Compare-QmVersion $cur $rel.Version
    if ($cmp -eq 0) {
        if (-not $QuietIfCurrent) { Msg "You're on the latest version ($cur)." }
        return
    }
    if ($cmp -gt 0) {
        if (-not $QuietIfCurrent) { Msg "This build ($cur) is newer than the latest published release ($($rel.Version))." }
        return
    }
    Show-QmUpdatePrompt $rel
}
function Start-QmBackgroundUpdateCheck {
    Stop-QmBackgroundUpdateCheck
    $script:updateRs = [runspacefactory]::CreateRunspace()
    $script:updateRs.Open()
    $script:updatePs = [powershell]::Create()
    $script:updatePs.Runspace = $script:updateRs
    [void]$script:updatePs.AddScript('param($Core,$Upd) . $Core; Get-QmLatestRelease').AddArgument((Join-Path $app 'QuMeterCore.ps1')).AddArgument((Join-Path $app 'QuMeterUpdate.ps1'))
    $script:updateHandle = $script:updatePs.BeginInvoke()
    $script:updatePoll = New-Object Windows.Forms.Timer -Property @{ Interval = 250 }
    $script:updatePoll.Add_Tick({
        if (-not $script:updateHandle -or -not $script:updateHandle.IsCompleted) { return }
        $script:updatePoll.Stop()
        $rel = $null
        try {
            $out = $script:updatePs.EndInvoke($script:updateHandle)
            if ($out) { $rel = @($out)[-1] }
        } catch { $rel = $null }
        Stop-QmBackgroundUpdateCheck
        if ($rel -and $rel.Version) {
            try {
                if ((Compare-QmVersion (Get-QmVersion) $rel.Version) -lt 0) { Show-QmUpdatePrompt $rel }
            } catch { }
        }
    })
    $script:updatePoll.Start()
}
$pubUpdate.Add_Click({ Show-QmUpdateCheck })
$f.Add_Shown({
    $script:updateTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 800 }
    $script:updateTimer.Add_Tick({
        $script:updateTimer.Stop()
        Start-QmBackgroundUpdateCheck
    })
    $script:updateTimer.Start()
})
$f.Add_FormClosing({
    Persist
    if ($script:scanJob -and -not $script:scanJob.IsCompleted) {
        try { $script:scanJob.Cancel(); [void]$script:scanJob.Wait(3000) } catch { }
    }
    foreach ($tm in @($script:scanTimer, $script:runTimer, $script:updateTimer, $script:updatePoll)) { if ($tm) { try { $tm.Stop() } catch { } } }
    Stop-QmBackgroundUpdateCheck
})
[void]$f.ShowDialog()
