# QuMeter - SNMP lifetime meter puller with Manual and Automate tabs (PowerShell 5.1 + WinForms, no install).
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$app = $PSScriptRoot
. (Join-Path $app 'QuSnmp.ps1')
. (Join-Path $app 'QuMeterCore.ps1')
[System.Windows.Forms.Application]::EnableVisualStyles()
$wm = @'
using System;
using System.Runtime.InteropServices;
public class QmNative {
  public const int PBM_SETSTATE = 0x0410;
  public const int PBST_NORMAL = 1;
  public const int PBST_ERROR = 2;
  public const int PBST_PAUSED = 3;
  public const int EM_SETCUEBANNER = 0x1501;
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageStr(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
}
'@
Add-Type -TypeDefinition $wm -ErrorAction SilentlyContinue
function Set-Acc($ctl, [string]$name, [string]$desc = '') {
    if (-not $ctl) { return }
    $ctl.AccessibleName = $name
    if ($desc) { $ctl.AccessibleDescription = $desc }
}
function Set-ProgressBarState($bar, [string]$state) {
    if (-not $bar) { return }
    $inner = $bar
    try {
        if ($bar -is [Windows.Forms.ToolStripProgressBar]) { $inner = $bar.ProgressBar }
    } catch { }
    if (-not $inner -or $inner.IsDisposed) { return }
    try {
        $code = switch ($state) {
            'paused' { [QmNative]::PBST_PAUSED }
            'error'  { [QmNative]::PBST_ERROR }
            default  { [QmNative]::PBST_NORMAL }
        }
        [void][QmNative]::SendMessage($inner.Handle, [QmNative]::PBM_SETSTATE, [IntPtr]$code, [IntPtr]::Zero)
    } catch { }
}
function Set-ScanProgressVisible([bool]$show) {
    if ($scanBarItem) {
        $scanBarItem.Visible = [bool]$show
        if ($pubBar) { try { $pubBar.PerformLayout() } catch { } }
    }
}
function Set-AppStatus([string]$text, $color = $null, [string]$ForTab = '') {
    if (-not $color) { $color = [Drawing.SystemColors]::ControlText }
    if (-not $ForTab) {
        if ($tabs -and $tabAuto -and $tabs.SelectedTab -eq $tabAuto) { $ForTab = 'auto' } else { $ForTab = 'manual' }
    }
    if ($ForTab -eq 'auto') { $script:autoStatusText = $text; $script:autoStatusColor = $color }
    else { $script:manualStatusText = $text; $script:manualStatusColor = $color }
    $active = 'manual'
    if ($tabs -and $tabAuto -and $tabs.SelectedTab -eq $tabAuto) { $active = 'auto' }
    if ($ForTab -ne $active) { return }
    Show-StatusStripText $text $color
}
function Show-StatusStripText([string]$text, $color = $null) {
    if (-not $pubStatus) { return }
    if (-not $color) { $color = [Drawing.SystemColors]::ControlText }
    $pubStatus.ForeColor = $color
    $pubStatus.Text = $text
    $pubStatus.ToolTipText = $text
    $pubStatus.AutoToolTip = $true
}
function Show-ActiveTabStatus {
    $for = 'manual'
    if ($tabs -and $tabAuto -and $tabs.SelectedTab -eq $tabAuto) { $for = 'auto' }
    if ($for -eq 'auto') { $text = $script:autoStatusText; $color = $script:autoStatusColor }
    else { $text = $script:manualStatusText; $color = $script:manualStatusColor }
    if (-not $text) {
        $text = $(if ($for -eq 'auto') { Get-QmRunOnceEmptyCaption } else { 'Paste printer IPs and click Scan.' })
    }
    if (-not $color) { $color = [Drawing.SystemColors]::ControlText }
    Show-StatusStripText $text $color
}


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
function Get-TipsHeadingFont($base) {
    try { return New-Object Drawing.Font('Segoe UI Semibold', $base.Size) } catch { return New-Object Drawing.Font($base, [Drawing.FontStyle]::Bold) }
}
function Format-TipsBox($box) {
    if (-not $box) { return }
    $text = [string]$box.Text
    $heads = @(
        'Tips - using the Manual tab','Scan','Import list (MPS)','Customer drop-down',
        'Recommended: e-automate workbook (Export e-automate)',
        'Alternative: MPS file, then MPS to e-automate (Export MPS)',
        'Excel workbook (Export Excel)','General CSV (Export results CSV)',
        'Responding IP list','Exclude IPs that are timing out',
        'Only show/include devices that are reporting serial numbers(Usually Only Printers)',
        'Meter remarks','Custom column names / Advanced format','Scan tips','Tips',
        'Tips - Automate','This tab is experimental','What it does','Getting meters into e-automate',
        'Output to a network share','This PC (Schedule tab)','Errors'
    )
    $headFont = Get-TipsHeadingFont $box.Font
    $pos = 0
    foreach ($line in ($text -split "`r`n")) {
        $isHead = $heads -contains $line
        if ($isHead) {
            $box.Select($pos, $line.Length)
            $box.SelectionFont = $headFont
        } elseif ($line -match '^\s+(QuMeter_|logs\\)') {
            $box.Select($pos, $line.Length)
            $box.SelectionFont = $fontMono
        }
        $pos += $line.Length + 2
    }
    $box.SelectionLength = 0
    $box.SelectionStart = 0
}
function New-Tips($p, $text, $x, $y, $w, $h, $anchor) {
    # Windows RichTextBox needs CRLF line breaks; scripts may be saved with LF only.
    $text = [string]$text -replace "`r`n", "`n" -replace "`n", "`r`n"
    $t = New-Object Windows.Forms.RichTextBox -Property @{
        Location = "$x,$y"; Size = "$w,$h"; Multiline = $true; ReadOnly = $true
        ScrollBars = 'Both'; WordWrap = $true; BorderStyle = 'None'
        BackColor = [Drawing.Color]::FromArgb(255, 252, 235); Text = $text; Anchor = $anchor
        DetectUrls = $false; TabStop = $false
    }
    try { $t.SelectionTabs = [int[]]@(240, 520) } catch { }
    Add-C $p $t | Out-Null
    Format-TipsBox $t
    return $t
}
function Msg($text, $icon = 'Information', $title = 'QuMeter') { [void][Windows.Forms.MessageBox]::Show($text, $title, 'OK', $icon) }
function Ask($text) { return ([Windows.Forms.MessageBox]::Show($text, 'QuMeter', 'YesNo', 'Question') -eq 'Yes') }
function Browse-Folder($box) {
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Choose a folder (you can also type a UNC path like \\server\share\meters)' }
    if ($d.ShowDialog() -eq 'OK') { $box.Text = $d.SelectedPath }
}
function Test-IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

$f = New-Object Windows.Forms.Form -Property @{ Text = "QuMeter $(Get-QmVersion)"; Size = '1100,820'; MinimumSize = '900,640'; StartPosition = 'CenterScreen'; Font = New-Object Drawing.Font('Segoe UI', 9); AutoScaleMode = 'Dpi'; AutoScaleDimensions = New-Object Drawing.SizeF(96, 96) }
$tabs = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$tabManual = New-Object Windows.Forms.TabPage -Property @{ Text = 'Manual'; Padding = '6,6,6,6'; AutoScroll = $false }
$tabAuto   = New-Object Windows.Forms.TabPage -Property @{ Text = (Get-QmAutomateTabText); Padding = '6,6,6,6'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(860, 600) }
[void]$tabs.TabPages.Add($tabManual); [void]$tabs.TabPages.Add($tabAuto)
$f.Controls.Add($tabs)
$pubBar = New-Object Windows.Forms.StatusStrip
$pubStatus = New-Object Windows.Forms.ToolStripStatusLabel
$pubStatus.Text = 'Paste printer IPs and click Scan.'
$pubStatus.Spring = $true
$pubStatus.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$pubStatus.AutoToolTip = $true
$pubStatus.ToolTipText = $pubStatus.Text
$script:manualStatusText = $pubStatus.Text
$script:manualStatusColor = [Drawing.SystemColors]::ControlText
$script:autoStatusText = (Get-QmRunOnceEmptyCaption)
$script:autoStatusColor = [Drawing.SystemColors]::ControlText
$pubBrand = New-Object Windows.Forms.ToolStripStatusLabel
$pubBrand.Text = (Get-QmPublisher)
$pubBrand.IsLink = $true
$pubBrand.Margin = New-Object Windows.Forms.Padding(8, 3, 8, 3)
$pubVer = New-Object Windows.Forms.ToolStripStatusLabel
$pubVer.Text = ('v{0}' -f (Get-QmVersion))
$pubUpdate = New-Object Windows.Forms.ToolStripStatusLabel
$pubUpdate.Text = 'Check for updates'
$pubUpdate.IsLink = $true
$pubUpdate.Margin = New-Object Windows.Forms.Padding(12, 3, 12, 3)
$pubAbout = New-Object Windows.Forms.ToolStripStatusLabel
$pubAbout.Text = 'About'
$pubAbout.IsLink = $true
$scanBarItem = New-Object Windows.Forms.ToolStripProgressBar
$scanBarItem.Name = 'ScanProgress'
$scanBarItem.AutoSize = $false
$scanBarItem.Width = 120
$scanBarItem.Visible = $false
$scanBarItem.Margin = New-Object Windows.Forms.Padding(6, 3, 6, 3)
$scanBar = $scanBarItem
Set-Acc $scanBarItem.ProgressBar 'Scan progress'
[void]$pubBar.Items.Add($pubStatus)
[void]$pubBar.Items.Add($scanBarItem)
[void]$pubBar.Items.Add($pubBrand)
[void]$pubBar.Items.Add($pubVer)
[void]$pubBar.Items.Add($pubUpdate)
[void]$pubBar.Items.Add($pubAbout)
$f.Controls.Add($pubBar)
$uiTip = New-Object Windows.Forms.ToolTip
$uiTip.ShowAlways = $true
function Show-About {
    $d = New-Object Windows.Forms.Form -Property @{ Text = 'About QuMeter'; Size = '420,280'; StartPosition = 'CenterParent'; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; Font = $f.Font }
    $txt = "QuMeter $(Get-QmVersion)`r`n$(Get-QmCopyrightText)`r`n`r`n$(Get-QmAboutDescription)"
    [void]$d.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = $txt; Location = '16,16'; AutoSize = $true; MaximumSize = New-Object Drawing.Size(380, 0) }))
    $lnk = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Send feedback'; Location = '16,120'; AutoSize = $true }
    $lnk.LinkBehavior = 'AlwaysUnderline'
    $lnk.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackMailto) } catch { } })
    $lnk2 = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Report on GitHub'; Location = '16,142'; AutoSize = $true }
    $lnk2.LinkBehavior = 'AlwaysUnderline'
    $lnk2.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackIssuesUrl) } catch { } })
    $lnk3 = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Check for updates'; Location = '16,164'; AutoSize = $true }
    $lnk3.LinkBehavior = 'AlwaysUnderline'
    $lnk3.Add_LinkClicked({ $d.Close(); Show-QmUpdateCheck })
    $ok = New-Object Windows.Forms.Button -Property @{ Text = 'OK'; Location = '310,200'; Size = '80,28'; DialogResult = 'OK' }
    $d.Controls.AddRange(@($lnk, $lnk2, $lnk3, $ok))
    $d.AcceptButton = $ok
    [void]$d.ShowDialog($f)
    $d.Dispose()
}
$pubBrand.Add_Click({ Show-About })
$pubAbout.Add_Click({ Show-About })

# ================================================================== MANUAL TAB
$script:tipsSeen = [bool]($saved -and ($saved.PSObject.Properties.Name -contains 'tipsSeen') -and $saved.tipsSeen)
$script:hideTipsPref = Get-QmDefaultHideTips $saved
$script:userSetTips = $false
$script:tipsPinnedOpen = $false
$script:lastExportFolder = $null
if ($saved -and ($saved.PSObject.Properties.Name -contains 'lastExportFolder') -and $saved.lastExportFolder) { $script:lastExportFolder = [string]$saved.lastExportFolder }
$script:lastMpsImportFolder = $null
if ($saved -and ($saved.PSObject.Properties.Name -contains 'lastMpsImportFolder') -and $saved.lastMpsImportFolder) { $script:lastMpsImportFolder = [string]$saved.lastMpsImportFolder }
$script:mpsImportPath = Get-QmMpsImportPath $app
$script:mpsImport = $null
$script:mpsSelectedCustomer = Get-QmMpsIpSearchLabel
$script:listSource = ''
$script:updatingCustomerFilter = $false
$script:updatingTargets = $false
$script:lastScanReadings = @()
$split = New-Object Windows.Forms.SplitContainer
$split.Width = 1000
$split.Height = 700
$split.Dock = 'Fill'
$split.Orientation = 'Vertical'
$split.SplitterWidth = 6
# Min sizes must be set after the control is wide enough (default Width is 150).
$split.Panel1MinSize = 200
$split.Panel2MinSize = 160
[void]$tabManual.Controls.Add($split)
$leftTable = Add-C $split.Panel1 (New-Object Windows.Forms.TableLayoutPanel -Property @{
    Dock = 'Fill'; ColumnCount = 1; RowCount = 3; Padding = '0,0,0,0'
})
[void]$leftTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$leftTable.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$leftTable.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$leftTable.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))

$settingsHost = New-Object Windows.Forms.TableLayoutPanel -Property @{
    Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
    ColumnCount = 1; RowCount = 2; Padding = '0,0,0,0'
}
[void]$settingsHost.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$settingsHost.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
[void]$settingsHost.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
$leftTable.Controls.Add($settingsHost, 0, 0)

$grid = New-Object Windows.Forms.DataGridView -Property @{
    Dock = 'Fill'
    AllowUserToAddRows = $false; AllowUserToDeleteRows = $false; ReadOnly = $true
    AutoSizeColumnsMode = 'None'; ScrollBars = 'Both'; SelectionMode = 'FullRowSelect'
    MultiSelect = $true; RowHeadersVisible = $false; BackgroundColor = 'White'
    AllowUserToResizeColumns = $true; AllowUserToOrderColumns = $true
    ShowCellToolTips = $true
}
$leftTable.Controls.Add($grid, 0, 1)

$bottom = New-Object Windows.Forms.FlowLayoutPanel -Property @{
    Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
    WrapContents = $true; Padding = '4,6,4,4'; FlowDirection = 'LeftToRight'
}
$leftTable.Controls.Add($bottom, 0, 2)

$settingsFlow = New-Object Windows.Forms.FlowLayoutPanel -Property @{
    Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'
    WrapContents = $true; FlowDirection = 'LeftToRight'; Padding = '6,4,6,4'
}
function New-FlowField($labelText, $ctl, [int]$ctlWidth) {
    $wrap = New-Object Windows.Forms.FlowLayoutPanel
    $wrap.AutoSize = $true
    $wrap.WrapContents = $false
    $wrap.Margin = New-Object Windows.Forms.Padding(0, 1, 10, 1)
    $wrap.Padding = New-Object Windows.Forms.Padding(0)
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = $labelText
    $lbl.AutoSize = $true
    $lbl.Anchor = 'Left'
    $lbl.TextAlign = 'MiddleLeft'
    $lbl.Margin = New-Object Windows.Forms.Padding(0, 6, 6, 0)
    $ctl.Width = $ctlWidth
    $ctl.Margin = New-Object Windows.Forms.Padding(0, 2, 0, 2)
    $ctl.Anchor = 'Left'
    [void]$wrap.Controls.Add($lbl)
    [void]$wrap.Controls.Add($ctl)
    return $wrap
}
$community = New-Object Windows.Forms.TextBox
$community.Text = $(if ($saved.community) { $saved.community } else { 'public' })
Set-Acc $community 'Community'
$ver = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 70 }
[void]$ver.Items.AddRange(@('v2c','v1'))
$ver.SelectedItem = $(if ($saved.version) { $saved.version } else { 'v2c' })
if ($ver.SelectedIndex -lt 0) { $ver.SelectedIndex = 0 }
Set-Acc $ver 'SNMP version'
$port = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 1; Maximum = 65535 }
$port.Value = [decimal]$(if ($saved.port) { $saved.port } else { 161 })
Set-Acc $port 'Port'
$timeout = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 100; Maximum = 30000; Increment = 100 }
$timeout.Value = [decimal]$(if ($saved.timeoutMs) { $saved.timeoutMs } else { 1500 })
Set-Acc $timeout 'Timeout (ms)'
$retries = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 0; Maximum = 8 }
$retries.Value = [decimal]$(if ($null -ne $saved.retries) { $saved.retries } else { 1 })
Set-Acc $retries 'Retries'
$savedConc = 32
if ($saved -and ($saved.PSObject.Properties.Name -contains 'concurrency') -and $saved.concurrency) { $savedConc = $saved.concurrency }
$concurrency = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 1; Maximum = 64 }
$concurrency.Value = [decimal]$savedConc
Set-Acc $concurrency 'Parallel queries'
[void]$settingsFlow.Controls.Add((New-FlowField '&Community' $community 70))
[void]$settingsFlow.Controls.Add((New-FlowField '&SNMP version' $ver 70))
[void]$settingsFlow.Controls.Add((New-FlowField '&Port' $port 60))
[void]$settingsFlow.Controls.Add((New-FlowField '&Timeout (ms)' $timeout 70))
[void]$settingsFlow.Controls.Add((New-FlowField '&Retries' $retries 50))
[void]$settingsFlow.Controls.Add((New-FlowField 'P&arallel queries' $concurrency 60))

$M = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 300 }
$settingsHost.Controls.Add($M, 0, 0)
$settingsHost.Controls.Add($settingsFlow, 0, 1)
$scanCol = Add-C $M (New-Object Windows.Forms.Panel -Property @{ Dock = 'Right'; Width = 150 })
New-L $M 'Printer &IPs, ranges, or CIDR (one per line or comma-separated)' 10 6 | Out-Null
$targets = Add-C $M (New-Object Windows.Forms.TextBox -Property @{ Location = '10,24'; Size = '520,72'; Multiline = $true; ScrollBars = 'Vertical'; WordWrap = $false; AcceptsReturn = $true; Font = $fontMono })
Set-Acc $targets 'Printer IPs, ranges, or CIDR'
if ($saved.targets) {
    $script:updatingTargets = $true
    try { $targets.Text = Repair-QmTargetText $saved.targets } finally { $script:updatingTargets = $false }
}
$load = New-B $scanCol '&Load list...' 10 4 130 28
Set-Acc $load 'Load list'
$importMps = New-B $scanCol (Get-QmImportMpsButtonText) 10 36 130 28
Set-Acc $importMps (Get-QmImportMpsButtonText)
$scan = New-B $scanCol '&Scan' 10 76 130 36
$scan.Font = $fontBold
$pri = Get-QmPrimaryButtonArgb
$scan.BackColor = [Drawing.Color]::FromArgb([int]$pri[0], [int]$pri[1], [int]$pri[2])
$scan.ForeColor = [Drawing.Color]::White
$scan.FlatStyle = 'Flat'
$scan.FlatAppearance.BorderSize = 0
$scan.UseVisualStyleBackColor = $false
Set-Acc $scan 'Scan'
$scanCancel = New-B $scanCol 'S&top scan' 10 76 130 36
$scanCancel.Font = $fontBold
$scanCancel.BackColor = [Drawing.Color]::FromArgb(146, 64, 14)
$scanCancel.ForeColor = [Drawing.Color]::White
$scanCancel.FlatStyle = 'Flat'
$scanCancel.FlatAppearance.BorderSize = 0
$scanCancel.UseVisualStyleBackColor = $false
$scanCancel.Visible = $false
Set-Acc $scanCancel 'Stop scan'
$tipsBtn = New-B $scanCol '&Tips' 10 118 130 28
Set-Acc $tipsBtn 'Tips'
$editMap = New-B $scanCol '&Edit mapping...' 10 158 130 28
Set-Acc $editMap 'Edit mapping'
$f.AcceptButton = $scan
$scanCount = $null

$initialRemarks = 'Imported by QuMeter'
if ($script:cfg -and $null -ne $script:cfg.eaRemarks) { $initialRemarks = [string]$script:cfg.eaRemarks }
if ($saved -and ($saved.PSObject.Properties.Name -contains 'remarks')) { $initialRemarks = [string]$saved.remarks }
$lblRemarks = New-L $M '&Meter remarks' 10 102
$remarks = New-T $M 110 99 420 $initialRemarks
Set-Acc $remarks 'Meter remarks'
$lblCustomer = New-L $M '&Customer' 10 130
$customerFilter = Add-C $M (New-Object Windows.Forms.ComboBox -Property @{ Location = '78,127'; Width = 452; DropDownStyle = 'DropDownList' })
Set-Acc $customerFilter 'Customer'
[void]$customerFilter.Items.Add((Get-QmMpsIpSearchLabel))
$customerFilter.SelectedIndex = 0
$customerFilter.Enabled = $true

$excludeTo = Add-C $M (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Exclude IPs that are timing out'; Location = '10,156'; AutoSize = $false })
Set-Acc $excludeTo 'Exclude IPs that are timing out'
$excludeTo.Checked = $true
if ($saved -and ($saved.PSObject.Properties.Name -contains 'excludeTimedOut')) { $excludeTo.Checked = [bool]$saved.excludeTimedOut }

$excludeNoSerial = Add-C $M (New-Object Windows.Forms.CheckBox -Property @{ Text = 'Only show/include devices that are reporting serial numbers(Usually Only Printers)'; Location = '10,178'; AutoSize = $false })
Set-Acc $excludeNoSerial 'Only show/include devices that are reporting serial numbers(Usually Only Printers)'
$excludeNoSerial.Checked = $true
if ($saved -and ($saved.PSObject.Properties.Name -contains 'excludeNoSerial')) { $excludeNoSerial.Checked = [bool]$saved.excludeNoSerial }
elseif ($script:cfg -and ($script:cfg.PSObject.Properties.Name -contains 'excludeNoSerial')) { $excludeNoSerial.Checked = [bool]$script:cfg.excludeNoSerial }

$lblResponded = New-L $M 'Responding IPs (did not time out) - copy this list to rescan only those printers:' 10 202
$copyIps = New-B $M '&Copy' 450 198 80 24
Set-Acc $copyIps 'Copy responding IPs'
$copyIps.Enabled = $false
$responded = Add-C $M (New-Object Windows.Forms.TextBox -Property @{ Location = '10,222'; Size = '520,48'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; WordWrap = $false; Font = $fontMono; BackColor = 'White' })
Set-Acc $responded 'Responding IPs'

foreach ($col in (Get-QmManualGridColumnOrder)) {
    [void]$grid.Columns.Add($col, $col)
}
$grid.Columns['IP'].Width = 110
$grid.Columns['Status'].Width = 80
$grid.Columns['Serial'].Width = 110
$grid.Columns['Model'].Width = 140
$grid.Columns['Total'].Width = 60
$grid.Columns['Mono'].Width = 60
$grid.Columns['Color'].Width = 60
$grid.Columns['Customer'].Width = 130
$grid.Columns['Brand'].Width = 80
$grid.Columns['Asset'].Width = 80
$grid.Columns['System'].Width = 110
$grid.Columns['SysDescr'].Width = 160
$grid.Columns['Error'].MinimumWidth = 80
$grid.Columns['Error'].AutoSizeMode = 'Fill'
foreach ($short in @('IP','Status','Serial','Model','Total','Mono','Color','Brand','Asset')) {
    $grid.Columns[$short].AutoSizeMode = 'AllCells'
}
$grid.Add_CellToolTipTextNeeded({
    if ($_.RowIndex -ge 0 -and $_.ColumnIndex -ge 0) {
        $_.ToolTipText = [string]$grid.Rows[$_.RowIndex].Cells[$_.ColumnIndex].Value
    }
})
Set-Acc $grid 'Scan results'

$exportEa   = New-B $bottom 'Export e-automate' 0 0 130 30
$exportMps  = New-B $bottom 'Export MPS' 0 0 100 30
$exportXlsx = New-B $bottom 'Export Excel' 0 0 110 30
$exportCsv  = New-B $bottom 'Export results CSV' 0 0 140 30
$exportAll  = New-B $bottom 'Export all...' 0 0 110 30
foreach ($eb in @($exportEa,$exportMps,$exportXlsx,$exportCsv,$exportAll)) { $eb.Margin = New-Object Windows.Forms.Padding(0, 0, 6, 4) }
Set-Acc $exportEa 'Export e-automate'
Set-Acc $exportMps 'Export MPS'
Set-Acc $exportXlsx 'Export Excel'
Set-Acc $exportCsv 'Export results CSV'
Set-Acc $exportAll 'Export all'

function Fit-FilterCheckboxes {
    if (-not $M) { return }
    $fieldW = [math]::Max(220, $M.ClientSize.Width - $scanCol.Width - 20)
    foreach ($cb in @($excludeTo, $excludeNoSerial)) {
        $cb.AutoSize = $false
        $cb.Width = $fieldW
        $pref = $cb.GetPreferredSize((New-Object Drawing.Size($fieldW, 0)))
        $cb.Height = [math]::Max(20, [int]$pref.Height)
    }
    $excludeTo.Location = New-Object Drawing.Point(10, 156)
    $excludeNoSerial.Location = New-Object Drawing.Point(10, ($excludeTo.Bottom + 2))
    if ($lblResponded) { $lblResponded.Location = New-Object Drawing.Point(10, ($excludeNoSerial.Bottom + 4)) }
    if ($copyIps -and $lblResponded) {
        $copyIps.Location = New-Object Drawing.Point([math]::Max($lblResponded.Right + 8, $fieldW - 80), $lblResponded.Top)
    }
    if ($responded -and $lblResponded) {
        $responded.Location = New-Object Drawing.Point(10, ($lblResponded.Bottom + 2))
        $responded.Size = New-Object Drawing.Size($fieldW, 48)
    }
    $need = 8
    if ($responded) { $need = $responded.Bottom + 8 }
    if ($M.Height -ne $need) { $M.Height = [math]::Max(220, $need) }
}
function Layout-ManualFields {
    $fieldW = [math]::Max(220, $M.ClientSize.Width - $scanCol.Width - 20)
    $targets.Width = $fieldW
    $responded.Width = $fieldW
    $remarks.Width = [math]::Max(160, $fieldW - 100)
    if ($customerFilter) { $customerFilter.Width = [math]::Max(160, $fieldW - 68) }
    Fit-FilterCheckboxes
}
$M.Add_Resize({ Layout-ManualFields })
$settingsHost.Add_Resize({ Layout-ManualFields })

$manualTips = @"
Tips - using the Manual tab

Scan
Paste IPs, ranges (10.0.1.1-10.0.1.50 or 10.0.1.1-50) or CIDR (10.0.1.0/24), set the community (usually public), and click Scan. If the IP box is empty and an MPS list is imported, Scan queries the imported IPs for the selected customer (or every imported IP when All customers is selected) and merges the meters with the imported customer details. Click Stop scan to cancel a running scan: results already collected are kept, and addresses not yet probed are marked Cancelled. Exports warn you if the scan was stopped, because those results are incomplete.

Import list (MPS)
Click Import list (MPS)... under Scan to load an MPS fleet report (.xlsx or .csv). QuMeter reads the IP, customer, brand, model, serial, asset, and other columns, fills the results list, and stores that list until you import again. Older .xls files need to be saved as .xlsx first. Rows with no usable IP stay in the list (status No IP) and are not scanned. Blank rows are skipped. The imported list is saved in mps-import.json and comes back after you restart the app.

Customer drop-down
IP Search/No Customer is always the first item. It is the default (and the only item) when no list is imported. After an import, All customers and each customer in the file appear under it. Picking a customer shows only that customer's rows in the list. Clicking or tabbing into the Printer IPs box, or typing an IP or range, switches the drop-down to IP Search/No Customer. In that mode Scan uses the addresses in the box as a normal scan, with no customer filter.

Recommended: e-automate workbook (Export e-automate)
Best path for updating meters on many serial numbers at once. Only printers that answered AND reported a serial are included.
e-automate matches each row to equipment by Model + Serial. Equipment Number is left blank.
The official Import and Export Utility accepts .xlsx only.
Columns (ECI Meter Import): Equipment Number, Model, Serial, B\W, Color, Total Count, Remarks, Reading Date.

How to import it into e-automate:
 a. Try dropping the QuMeter e-automate .xlsx onto "Drop a file here" and click Import.
 b. In the file, Source is on the Import sheet in row 3. It must already exist in Lists and Codes (not Contract, Service Call or Web). Change it in Edit mapping... if your list uses a name other than SNMP.
 c. Column headers are on row 8; data starts on row 9.
 d. If the utility rejects this generated workbook, download the official EA_MeterImport.xlsx template, set Source in the header, paste our data rows (not our header) under row 8, save, and import that official file.
 e-automate rejects a row if you send a meter type the equipment doesn't have, or leave out one it does have. Blank Mono/Color means the printer didn't report it; QuMeter never estimates.

Alternative: MPS file, then MPS to e-automate (Export MPS)
Use this if you already have an MPS tool (for example FMAudit / Printanista) reporting meters into e-automate.
 - Default MPS CSV: SerialNumber, Model, IPAddress, TotalCount, MonoCount, ColorCount, ReadDate, ReadDateTime, SysDescr (same layout the Automate tab drops in a watch folder). Confirm your MPS tool accepts that layout, or map the columns.
 - FMAudit-style CSV is the second "Save as type" in the Export MPS dialog: IP Address, Manufacturer, Model, Serial Number, Description, Total Pages, Mono Pages, Color Pages (published FMAudit audit-history names). Use this if your tool expects those headers.
A single official "import this file into ECI MPS" template was not published in the public docs, so confirm the columns in your MPS tool before a live import.

Excel workbook (Export Excel)
Opens in Excel with sheets for Results, e-automate, MPS, FMAudit, and import instructions. Timed-out IPs and devices with no serial number are omitted when those boxes are checked (they are checked by default). This is the record/spreadsheet export, not a substitute for the official e-automate template if the utility requires it.

General CSV (Export results CSV)
Your record of the scan: date, time, IP, model, serial, total, mono, color, status and any error. Timeouts and devices with no serial are left out when those boxes are checked (they are checked by default).

Responding IP list
After a scan, the box above the grid lists every address that did not time out, one per line, in the same format as the IP input. When "Only show/include devices that are reporting serial numbers(Usually Only Printers)" is checked, addresses with a blank or placeholder serial (N/A, unknown, 0) are omitted too. Click Copy and paste it back into the input to rescan only those printers.

Exclude IPs that are timing out
This box is checked by default. When checked, timed-out addresses disappear from the grid and from every export. Printers that answered with an error still appear. Uncheck it if you want timeouts included.

Only show/include devices that are reporting serial numbers(Usually Only Printers)
This box is checked by default. When checked, devices with no serial number (blank, whitespace, N/A, unknown, or 0) disappear from the grid, from every export (Excel, e-automate, MPS, FMAudit, Export all, and results CSV), and from the Responding IPs list. The same checkbox on the Automate Settings tab is used by scheduled QuMeter Auto runs after it is saved.

Meter remarks
The Meter remarks box is written into the e-automate Remarks column (and the e-automate sheet in the Excel workbook). The default is Imported by QuMeter. Leave it empty for a blank remarks field. Commas and quotes are escaped in the CSV. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. The same remarks text is used by Automate / QuMeter Auto (including scheduled runs) after it is saved.

Custom column names / Advanced format
If your template or meter types use different names than B\W, Color and Total Count, click Edit mapping... (e-automate.mapping.json). Set "format": "advanced" for the Meter Import Advanced layout (one row per meter: Meter Type + Reading, with Source).

Scan tips
- Community is usually "public". Use v1 if old printers time out on v2c.
- Big ranges (/24) take a few seconds; non-printers just time out.
- Parallel queries is how many printers are asked at once (1-64).
- Run from a PC on the printer network: SNMP is UDP 161.

Tips
After the first run, this pane stays hidden unless you click Tips next to Scan. On a narrow window it collapses automatically so the results grid stays readable; click Tips to show it again. Hide tips is in the header of this pane.
"@
$tipsPanel = $split.Panel2
$tipsPanel.BackColor = [Drawing.Color]::FromArgb(255, 252, 235)
$tipsHeader = Add-C $tipsPanel (New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 28; BackColor = [Drawing.Color]::FromArgb(255, 252, 235) })
$tipsHeaderLabel = Add-C $tipsHeader (New-Object Windows.Forms.Label -Property @{ Text = 'Tips'; Location = '6,5'; AutoSize = $true; Font = (Get-TipsHeadingFont (New-Object Drawing.Font('Segoe UI', 9))) })
$hideTipsLink = Add-C $tipsHeader (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Hide tips'; AutoSize = $true; Location = '80,6'; LinkBehavior = 'AlwaysUnderline' })
Set-Acc $hideTipsLink 'Hide tips'
$manualTipsBox = New-Tips $tipsPanel $manualTips 6 34 100 100 'Top,Bottom,Left,Right'
function Layout-TipsPane {
    if ($hideTipsLink -and $tipsHeader) {
        $hideTipsLink.Left = [math]::Max(80, $tipsHeader.ClientSize.Width - $hideTipsLink.Width - 8)
    }
    if ($manualTipsBox -and -not $split.Panel2Collapsed) {
        $manualTipsBox.Location = New-Object Drawing.Point(6, 34)
        $manualTipsBox.Size = New-Object Drawing.Size([math]::Max(20, $split.Panel2.ClientSize.Width - 12), [math]::Max(20, $split.Panel2.ClientSize.Height - 40))
    }
}
$split.Panel2.Add_Resize({ Layout-TipsPane })
$tipsHeader.Add_Resize({ Layout-TipsPane })
function Apply-TipsVisibility {
    $width = 1100
    try { $width = [int]$f.Width } catch { }
    $collapse = Test-QmTipsShouldCollapse -Width $width -HidePref ([bool]$script:hideTipsPref) -PinnedOpen ([bool]$script:tipsPinnedOpen) -Threshold (Get-QmTipsAutoCollapseWidth)
    $split.Panel2Collapsed = [bool]$collapse
    if ($tipsBtn) { $tipsBtn.Visible = $true }
    Layout-TipsPane
}
function Show-TipsPane {
    $script:userSetTips = $true
    $script:hideTipsPref = $false
    $script:tipsPinnedOpen = $true
    Apply-TipsVisibility
    Persist
}
function Hide-TipsPane {
    $script:userSetTips = $true
    $script:hideTipsPref = $true
    $script:tipsPinnedOpen = $false
    Apply-TipsVisibility
    Persist
}
$tipsBtn.Add_Click({ Show-TipsPane })
$hideTipsLink.Add_LinkClicked({ Hide-TipsPane })
$f.Add_Resize({ Apply-TipsVisibility })
$f.Add_Shown({
    try {
        if (-not $split.Panel2Collapsed -and $split.Width -gt 700) {
            $avail = $split.Width - $split.SplitterWidth
            $want = [math]::Max($split.Panel1MinSize, [int]($split.Width * 0.68))
            $max = $avail - $split.Panel2MinSize
            if ($want -gt $max) { $want = $max }
            if ($want -ge $split.Panel1MinSize) { $split.SplitterDistance = $want }
        }
    } catch { }
    Apply-TipsVisibility
    try { Layout-TipsPane } catch { }
    try { Layout-ManualFields } catch { }
    Start-QmGridSelectionClear
})

$script:scanJob = $null
function Set-TargetText([string]$Text) {
    $script:updatingTargets = $true
    try { $targets.Text = [string]$Text } finally { $script:updatingTargets = $false }
}
function Get-MpsFilterRows {
    if (-not $script:mpsImport) { return (New-Object System.Collections.Generic.List[object]) }
    return (Get-QmMpsRowsForCustomer -Rows $script:mpsImport.Rows -Customer $script:mpsSelectedCustomer)
}
function Set-MpsCustomerFilterItems([string]$Selected) {
    $script:updatingCustomerFilter = $true
    try {
        $customerFilter.Items.Clear()
        $rowSource = $null
        if ($script:mpsImport) { $rowSource = $script:mpsImport.Rows }
        foreach ($name in (ConvertTo-QmFlatList (Get-QmMpsCustomerFilterItems $rowSource))) {
            [void]$customerFilter.Items.Add([string]$name)
        }
        $pick = $Selected
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = Get-QmMpsDefaultCustomer -HasImport ([bool]$script:mpsImport) }
        $idx = $customerFilter.Items.IndexOf($pick)
        if ($idx -lt 0) {
            $pick = Get-QmMpsDefaultCustomer -HasImport ([bool]$script:mpsImport)
            $idx = $customerFilter.Items.IndexOf($pick)
            if ($idx -lt 0) { $idx = 0; $pick = [string]$customerFilter.Items[0] }
        }
        $customerFilter.SelectedIndex = $idx
        $script:mpsSelectedCustomer = $pick
        $customerFilter.Enabled = $true
    } finally { $script:updatingCustomerFilter = $false }
}
function Show-MpsImportedList {
    if (Test-QmMpsIpSearchMode $script:mpsSelectedCustomer) { return }
    $rows = Get-MpsFilterRows
    Set-TargetText (Get-QmMpsIpText $rows)
    $script:readings.Clear()
    Add-QmReadingsToList -List $script:readings -Items @($rows | ForEach-Object { ConvertTo-QmImportedReading $_ })
    $script:listSource = 'import'
    $script:scanWasCancelled = $false
    Show-ManualResults
}
function Apply-MpsImport($Import, [string]$Selected = 'All customers') {
    $script:mpsImport = $Import
    Set-MpsCustomerFilterItems $Selected
    if ($Import) {
        Save-QmMpsImport -Import $Import -Path $script:mpsImportPath -SelectedCustomer $script:mpsSelectedCustomer
    }
    Show-MpsImportedList
    Persist
}
function Restore-MpsImport {
    $imp = Read-QmMpsImport -Path $script:mpsImportPath
    if (-not $imp -or -not $imp.Rows -or $imp.Rows.Count -eq 0) { return }
    $sel = [string]$imp.SelectedCustomer
    if ($saved -and ($saved.PSObject.Properties.Name -contains 'mpsSelectedCustomer') -and $saved.mpsSelectedCustomer) {
        $sel = [string]$saved.mpsSelectedCustomer
    }
    $script:mpsImport = $imp
    Set-MpsCustomerFilterItems $sel
    Show-MpsImportedList
}

$load.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'; Title = 'Load printer list' }
    if ($d.ShowDialog() -eq 'OK') { $targets.Text = [System.IO.File]::ReadAllText($d.FileName) }
})
$importMps.Add_Click({
    if ($script:scanJob) { return }
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{
        Title = 'Import list (MPS)'
        Filter = 'MPS list (*.xlsx;*.csv)|*.xlsx;*.csv|Excel workbook (*.xlsx)|*.xlsx|CSV (*.csv)|*.csv|All files (*.*)|*.*'
    }
    if ($script:lastMpsImportFolder -and (Test-Path -LiteralPath $script:lastMpsImportFolder)) {
        $d.InitialDirectory = $script:lastMpsImportFolder
    }
    if ($d.ShowDialog() -ne 'OK') { return }
    $script:lastMpsImportFolder = Split-Path -Parent $d.FileName
    try {
        $imp = Import-QmMpsList -Path $d.FileName
    } catch {
        Msg $_.Exception.Message 'Warning'
        return
    }
    if (-not $imp -or $imp.TotalRows -eq 0) {
        Msg 'No printer rows were found in that file.'
        return
    }
    Apply-MpsImport $imp 'All customers'
})
$customerFilter.Add_SelectedIndexChanged({
    if ($script:updatingCustomerFilter) { return }
    $sel = [string]$customerFilter.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $script:mpsSelectedCustomer = $sel
    if ($script:mpsImport -and (Test-Path -LiteralPath $script:mpsImportPath)) {
        try { Save-QmMpsImport -Import $script:mpsImport -Path $script:mpsImportPath -SelectedCustomer $sel } catch { }
    }
    if (Test-QmMpsIpSearchMode $sel) {
        # Leave the IP box as-is so focusing or typing there cannot loop or wipe typed addresses.
        Persist
        return
    }
    if (-not $script:mpsImport) { Persist; return }
    if ($script:listSource -eq 'scan') {
        $importRows = Get-MpsFilterRows
        $ipSet = @{}
        foreach ($ip in (ConvertTo-QmFlatList (Get-QmMpsIpList $importRows))) { $ipSet[[string]$ip] = $true }
        $scanRows = New-Object System.Collections.Generic.List[object]
        foreach ($r in (ConvertTo-QmFlatList $script:lastScanReadings)) {
            if ($r.Ip -and $ipSet.ContainsKey([string]$r.Ip)) { [void]$scanRows.Add($r) }
        }
        $script:readings.Clear()
        $merged = Merge-QmImportedReadings -ScanReadings $scanRows -ImportRows $importRows
        Add-QmReadingsToList -List $script:readings -Items $merged
        Set-TargetText (Get-QmMpsIpText $importRows)
        Persist
        Show-ManualResults
        return
    }
    Show-MpsImportedList
    Persist
})
function Switch-ToIpSearchMode([bool]$OnFocus = $false) {
    if ($script:updatingTargets) { return }
    if ($script:scanJob) { return }
    if (-not (Test-QmMpsShouldSwitchToIpSearch -CurrentCustomer $script:mpsSelectedCustomer -TargetText $targets.Text -HasImport ([bool]$script:mpsImport) -Programmatic $false -OnFocus $OnFocus)) { return }
    $script:updatingCustomerFilter = $true
    try {
        $script:mpsSelectedCustomer = Get-QmMpsIpSearchLabel
        $idx = $customerFilter.Items.IndexOf((Get-QmMpsIpSearchLabel))
        if ($idx -ge 0 -and $customerFilter.SelectedIndex -ne $idx) { $customerFilter.SelectedIndex = $idx }
    } finally { $script:updatingCustomerFilter = $false }
    if ($script:mpsImport -and (Test-Path -LiteralPath $script:mpsImportPath)) {
        try { Save-QmMpsImport -Import $script:mpsImport -Path $script:mpsImportPath -SelectedCustomer $script:mpsSelectedCustomer } catch { }
    }
    Persist
}
$targets.Add_Enter({ Switch-ToIpSearchMode -OnFocus $true })
$targets.Add_GotFocus({ Switch-ToIpSearchMode -OnFocus $true })
$targets.Add_TextChanged({ Switch-ToIpSearchMode -OnFocus $false })
function Persist {
    if (-not $script:userSetTips -and -not $script:tipsSeen) { $script:hideTipsPref = $true }
    $script:tipsSeen = $true
    Save-Settings @{ community = $community.Text; version = $ver.SelectedItem.ToString(); port = [int]$port.Value; timeoutMs = [int]$timeout.Value; retries = [int]$retries.Value; concurrency = [int]$concurrency.Value; targets = (Repair-QmTargetText $targets.Text); excludeTimedOut = [bool]$excludeTo.Checked; excludeNoSerial = [bool]$excludeNoSerial.Checked; remarks = $remarks.Text; hideTips = [bool]$script:hideTipsPref; tipsSeen = $true; lastExportFolder = [string]$script:lastExportFolder; lastMpsImportFolder = [string]$script:lastMpsImportFolder; mpsSelectedCustomer = [string]$script:mpsSelectedCustomer }
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
function Get-LastExportDir {
    if ($script:lastExportFolder -and (Test-Path -LiteralPath $script:lastExportFolder)) { return $script:lastExportFolder }
    try {
        $folder = 'output'
        if ($script:cfg -and $script:cfg.outputFolder) { $folder = $script:cfg.outputFolder }
        $p = Resolve-QmPath $folder $app
        if (Test-Path -LiteralPath $p) { return $p }
    } catch { }
    return $app
}
function Remember-ExportPath([string]$path) {
    if (-not $path) { return }
    $dir = Split-Path -Parent $path
    if ($dir) { $script:lastExportFolder = $dir; Persist }
}
function Prompt-Save([string]$title, [string]$filter, [string]$defaultName) {
    $d = New-Object Windows.Forms.SaveFileDialog -Property @{ Title = $title; Filter = $filter; FileName = $defaultName; InitialDirectory = (Get-LastExportDir) }
    if ($d.ShowDialog() -eq 'OK') { Remember-ExportPath $d.FileName; return $d.FileName }
    return $null
}
function Get-ScanCounts {
    $all = @($script:readings)
    return [pscustomobject]@{
        Total = $all.Count
        Ok = @($all | Where-Object { $_.Status -eq 'OK' }).Count
        Timeout = @($all | Where-Object { $_.Status -eq 'Timeout' }).Count
        Cancelled = @($all | Where-Object { $_.Status -eq 'Cancelled' }).Count
        Responded = @($all | Where-Object { Test-QmRespondedStatus $_.Status }).Count
        OkSerial = @($all | Where-Object { $_.Status -eq 'OK' -and -not [string]::IsNullOrWhiteSpace($_.Serial) }).Count
    }
}
function Confirm-ExportPartialScan {
    if (-not $script:scanWasCancelled) { return $true }
    $c = Get-ScanCounts
    if ($c.Responded -eq 0) {
        Msg "No printers responded, so there's nothing to export." 'Information'
        return $false
    }
    $checked = $c.Total - $c.Cancelled
    $msg = "This scan was stopped after $checked of $($c.Total) addresses. These results are incomplete.`n`nExport them anyway?"
    return ([Windows.Forms.MessageBox]::Show($msg, 'Export incomplete scan?', 'YesNo', 'Warning') -eq 'Yes')
}
function Update-ExportButtons {
    $scanning = [bool]$script:scanJob
    $c = Get-ScanCounts
    $any = Test-QmExportButtonsShouldEnable -Scanning $scanning -Total $c.Total -Responded $c.Responded -OkSerial $c.OkSerial -Kind 'general'
    $ea = Test-QmExportButtonsShouldEnable -Scanning $scanning -Total $c.Total -Responded $c.Responded -OkSerial $c.OkSerial -Kind 'ea'
    foreach ($b in @($exportCsv, $exportXlsx, $exportAll)) {
        $b.Enabled = $any
        $uiTip.SetToolTip($b, $(if ($scanning) { 'Wait for the scan to finish.' } elseif (-not $any) { "No printers responded, so there's nothing to export." } else { '' }))
    }
    $exportEa.Enabled = $ea
    $uiTip.SetToolTip($exportEa, $(if ($scanning) { 'Wait for the scan to finish.' } elseif ($c.Responded -eq 0) { "No printers responded, so there's nothing to export." } elseif (-not $ea) { 'e-automate needs at least one printer that responded with a serial number.' } else { '' }))
    $exportMps.Enabled = $ea
    $uiTip.SetToolTip($exportMps, $(if ($scanning) { 'Wait for the scan to finish.' } elseif ($c.Responded -eq 0) { "No printers responded, so there's nothing to export." } elseif (-not $ea) { 'MPS export needs at least one printer that responded with a serial number.' } else { '' }))
}
function Update-CopyButton {
    if ($copyIps) { $copyIps.Enabled = -not [string]::IsNullOrWhiteSpace($responded.Text) }
}
function Clear-QmGridSelection {
    if (-not $grid -or $grid.IsDisposed) { return }
    try {
        $grid.ClearSelection()
        foreach ($row in @($grid.Rows)) { $row.Selected = $false }
        $grid.CurrentCell = $null
    } catch { }
}
function Start-QmGridSelectionClear {
    Clear-QmGridSelection
    if ($grid -and -not $grid.IsDisposed -and $grid.IsHandleCreated) {
        [void]$grid.BeginInvoke([Windows.Forms.MethodInvoker]{ Clear-QmGridSelection })
    }
    try { if ($script:gridSelTimer) { $script:gridSelTimer.Stop() } } catch { }
    $script:gridSelTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 50 }
    $script:gridSelTimer.Add_Tick({
        try { $script:gridSelTimer.Stop(); Clear-QmGridSelection } catch { }
    })
    $script:gridSelTimer.Start()
}
function Show-ManualResults {
    $grid.Rows.Clear()
    $responded.Text = Get-QuMeterRespondedIpText -Readings @($script:readings) -ExcludeNoSerial $excludeNoSerial.Checked
    $visible = Get-CurrentReadings
    foreach ($r in $visible) {
        $ipText = $(if ([string]::IsNullOrWhiteSpace($r.Ip)) { 'no IP' } else { $r.Ip })
        $i = $grid.Rows.Add($ipText, $r.Status, $r.Serial, $r.Model, $r.Total, $r.Mono, $r.Color, $r.Customer, $r.Brand, $r.AssetNumber, $r.SystemName, $r.SysDescr, $r.ErrorMessage)
        if ($r.Status -eq 'Cancelled') { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(150, 90, 0) }
        elseif ($r.Status -eq 'No IP' -or [string]::IsNullOrWhiteSpace($r.Ip)) {
            $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.SystemColors]::ControlText
            $grid.Rows[$i].DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(245, 245, 245)
            $grid.Rows[$i].Cells['IP'].Style.Font = New-Object Drawing.Font($grid.Font, [Drawing.FontStyle]::Italic)
        }
        elseif ($r.Status -eq 'Imported') { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.SystemColors]::ControlText }
        elseif ($r.Status -ne 'OK') { $grid.Rows[$i].DefaultCellStyle.ForeColor = [Drawing.Color]::Firebrick }
    }
    Start-QmGridSelectionClear
    Update-CopyButton
    Set-ScanProgressVisible $false
    $c = Get-ScanCounts
    $shown = @($visible).Count
    if ($script:listSource -eq 'import') {
        $ipCount = @($visible | Where-Object { $_.Status -eq 'Imported' }).Count
        $noIpCount = @($visible | Where-Object { $_.Status -eq 'No IP' }).Count
        $who = $script:mpsSelectedCustomer
        if (Test-QmMpsAllCustomersMode $who) { $who = 'all customers' }
        $src = ''
        if ($script:mpsImport -and $script:mpsImport.SourceName) { $src = " from $($script:mpsImport.SourceName)" }
        Set-ProgressBarState $scanBar 'normal'
        Set-AppStatus "Imported list$src ($who): $shown row(s), $ipCount with an IP, $noIpCount with no IP. Click Scan to read meters for the IPs shown."
        if ($scanCount) { $scanCount.Text = '' }
        Update-ExportButtons
        return
    }
    $checked = $c.Total - $c.Cancelled
    if ($script:scanWasCancelled) {
        Set-ProgressBarState $scanBar 'paused'
        Set-AppStatus "Scan stopped. $checked of $($c.Total) addresses checked: $($c.Responded) responded, $($c.Timeout) timed out, $($c.Cancelled) not checked. $shown shown." ([Drawing.Color]::FromArgb(150, 90, 0))
        if ($scanCount) { $scanCount.Text = "$checked / $($c.Total)" }
    } else {
        Set-ProgressBarState $scanBar 'normal'
        Set-AppStatus "Scan finished. $($c.Total) addresses checked: $($c.Responded) responded, $($c.Timeout) timed out. $shown shown."
        if ($scanCount) { $scanCount.Text = "$($c.Total) / $($c.Total)" }
    }
    Update-ExportButtons
}
function Set-ScanControlsRunning([bool]$running) {
    $scan.Visible = -not $running
    $scan.Enabled = -not $running
    $scanCancel.Visible = $running
    $scanCancel.Enabled = $running
    $load.Enabled = -not $running
    $importMps.Enabled = -not $running
    $customerFilter.Enabled = -not $running
    $f.UseWaitCursor = [bool]$running
    $f.AcceptButton = $(if ($running) { $scanCancel } else { $scan })
    Update-ExportButtons
}
function Complete-ManualScan($j) {
    $script:scanTimer.Stop()
    $script:scanJob = $null
    Set-ScanControlsRunning $false
    if ($j.Error) {
        $script:scanWasCancelled = $false
        Set-ProgressBarState $scanBar 'error'
        Set-AppStatus "Scan failed: $($j.Error.Message)" ([Drawing.Color]::Firebrick)
        Set-ScanProgressVisible $false
        Update-ExportButtons
        return
    }
    $script:readings.Clear()
    $results = ConvertTo-QmFlatList $j.Results
    $script:lastScanReadings = ConvertTo-QmFlatList $results
    if (Test-QmMpsShouldMergeScan -Customer $script:mpsSelectedCustomer -Import $script:mpsImport) {
        $importRows = Get-QmMpsRowsForCustomer -Rows $script:mpsImport.Rows -Customer $script:mpsSelectedCustomer
        $results = Merge-QmImportedReadings -ScanReadings $results -ImportRows $importRows
    }
    Add-QmReadingsToList -List $script:readings -Items $results
    $script:scanWasCancelled = [bool]$j.IsCancelled
    $script:listSource = 'scan'
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
    Set-AppStatus "Copied $n responding IP(s)."
})
$responded.Add_TextChanged({ Update-CopyButton })
Update-CopyButton
$editMap.Add_Click({ Start-Process notepad.exe -ArgumentList "`"$mappingPath`"" })
$exportCsv.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) {
        $c = Get-ScanCounts
        if ($c.Responded -eq 0) { Msg "No printers responded, so there's nothing to export." } else { Msg 'Nothing to export with the current filters.' }
        return
    }
    if (-not (Confirm-ExportPartialScan)) { return }
    $path = Prompt-Save 'Export results CSV' 'CSV (*.csv)|*.csv' ("QuMeter_results_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($path) { Export-QuMeterGeneralCsv -Readings $list -Path $path; Set-AppStatus "Saved $path" }
})
$exportXlsx.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) {
        $c = Get-ScanCounts
        if ($c.Responded -eq 0) { Msg "No printers responded, so there's nothing to export." } else { Msg 'Nothing to export with the current filters.' }
        return
    }
    if (-not (Confirm-ExportPartialScan)) { return }
    $path = Prompt-Save 'Export Excel workbook' 'Excel workbook (*.xlsx)|*.xlsx' ("QuMeter_results_{0}.xlsx" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($path) {
        Export-QuMeterExcel -Readings $script:readings -Path $path -Mapping (Get-ExportMapping) -ExcludeTimedOut $excludeTo.Checked -ExcludeNoSerial $excludeNoSerial.Checked
        Set-AppStatus "Saved $path"
    }
})
$exportEa.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) {
        $c = Get-ScanCounts
        if ($c.Responded -eq 0) { Msg "No printers responded, so there's nothing to export." } else { Msg 'Nothing to export with the current filters.' }
        return
    }
    if (-not (Confirm-ExportPartialScan)) { return }
    $ok = @($list | Where-Object { $_.Status -eq 'OK' -and $_.Serial })
    if ($ok.Count -eq 0) { Msg 'No successful readings with a serial number. e-automate matching is by serial.'; return }
    $path = Prompt-Save 'Export e-automate meter import' 'e-automate workbook (*.xlsx)|*.xlsx|e-automate CSV (*.csv)|*.csv' ("QuMeter_eautomate_{0}.xlsx" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if (-not $path) { return }
    $map = Get-ExportMapping
    if ([IO.Path]::GetExtension($path) -ieq '.csv') {
        Export-QuMeterEaCsv -Readings $list -Path $path -Mapping $map
        Set-AppStatus "Saved $path (paste into EA_MeterImport.xlsx under row 8 if needed)"
    } else {
        Export-QuMeterEaXlsx -Readings $list -Path $path -Mapping $map
        Set-AppStatus "Saved $path (recommended: import in e-automate, or paste into the official template if the utility rejects this file)"
    }
})
$exportMps.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) {
        $c = Get-ScanCounts
        if ($c.Responded -eq 0) { Msg "No printers responded, so there's nothing to export." } else { Msg 'Nothing to export with the current filters.' }
        return
    }
    if (-not (Confirm-ExportPartialScan)) { return }
    $ok = @($list | Where-Object { $_.Status -eq 'OK' })
    if ($ok.Count -eq 0) { Msg 'No successful readings to put in an MPS file.'; return }
    $d = New-Object Windows.Forms.SaveFileDialog -Property @{
        Title = 'Export MPS meter import'
        Filter = 'MPS CSV (*.csv)|*.csv|FMAudit-style CSV (*.csv)|*.csv'
        FileName = ("QuMeter_mps_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        InitialDirectory = (Get-LastExportDir)
    }
    if ($d.ShowDialog() -ne 'OK') { return }
    Remember-ExportPath $d.FileName
    if ($d.FilterIndex -eq 2) {
        Export-QuMeterMpsFmAuditCsv -Readings $list -Path $d.FileName
        Set-AppStatus "Saved FMAudit-style MPS CSV $($d.FileName)"
    } else {
        Export-QuMeterMpsCsv -Readings $list -Path $d.FileName
        Set-AppStatus "Saved MPS CSV $($d.FileName)"
    }
})
$exportAll.Add_Click({
    $list = Get-CurrentReadings
    if (-not $list -or $list.Count -eq 0) {
        $c = Get-ScanCounts
        if ($c.Responded -eq 0) { Msg "No printers responded, so there's nothing to export." } else { Msg 'Nothing to export with the current filters.' }
        return
    }
    if (-not (Confirm-ExportPartialScan)) { return }
    $d = New-Object Windows.Forms.FolderBrowserDialog -Property @{ Description = 'Choose a folder for the Excel, e-automate, and MPS export files'; SelectedPath = (Get-LastExportDir) }
    if ($d.ShowDialog() -ne 'OK') { return }
    $script:lastExportFolder = $d.SelectedPath; Persist
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $map = Get-ExportMapping
    Export-QuMeterGeneralCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_$stamp.csv")
    Export-QuMeterExcel -Readings $script:readings -Path (Join-Path $d.SelectedPath "QuMeter_$stamp.xlsx") -Mapping $map -ExcludeTimedOut $excludeTo.Checked -ExcludeNoSerial $excludeNoSerial.Checked
    Export-QuMeterEaCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_eautomate_$stamp.csv") -Mapping $map
    Export-QuMeterEaXlsx -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_eautomate_$stamp.xlsx") -Mapping $map
    Export-QuMeterMpsCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_mps_$stamp.csv")
    Export-QuMeterMpsFmAuditCsv -Readings $list -Path (Join-Path $d.SelectedPath "QuMeter_mps_fmaudit_$stamp.csv")
    Set-AppStatus "Saved Excel, e-automate, and MPS files in $($d.SelectedPath). Recommended: import the e-automate .xlsx in e-automate (or paste into the official template)."
})
$scan.Add_Click({
    if ($script:scanJob) { return }
    Persist
    $scanText = Get-QmManualScanTargetText -TargetText $targets.Text -Import $script:mpsImport -Customer $script:mpsSelectedCustomer
    if ([string]::IsNullOrWhiteSpace($scanText)) {
        if ($script:mpsImport -and -not (Test-QmMpsIpSearchMode $script:mpsSelectedCustomer)) {
            Msg 'The imported list has no usable IPs for the selected customer.'
        } else {
            Msg 'Enter at least one IP, range, or CIDR.'
        }
        return
    }
    if ((Repair-QmTargetText $targets.Text) -ne $scanText -and -not (Test-QmMpsIpSearchMode $script:mpsSelectedCustomer)) {
        Set-TargetText $scanText
    }
    try { $hosts = [QuMeterSnmp.TargetParser]::Parse($scanText, 65536) } catch { Msg $_.Exception.Message 'Warning'; return }
    if ($hosts.Count -eq 0) {
        if ($script:mpsImport -and -not (Test-QmMpsIpSearchMode $script:mpsSelectedCustomer)) {
            Msg 'The imported list has no usable IPs for the selected customer.'
        } else {
            Msg 'Enter at least one IP, range, or CIDR.'
        }
        return
    }
    if ($hosts.Count -gt 256 -and -not (Ask "This expands to $($hosts.Count) addresses. Scan anyway?")) { return }
    $grid.Rows.Clear(); $script:readings.Clear(); $responded.Text = ''
    $script:scanWasCancelled = $false
    $script:listSource = 'scan'
    $client = New-QuSnmpClient -Community $community.Text.Trim() -Port ([int]$port.Value) -TimeoutMs ([int]$timeout.Value) -Retries ([int]$retries.Value) -Version $ver.SelectedItem.ToString()
    $scanBar.Maximum = [math]::Max(1, $hosts.Count); $scanBar.Value = 0
    Set-ProgressBarState $scanBar 'normal'
    Set-ScanProgressVisible $true
    Update-ExportButtons
    if ($scanCount) { $scanCount.Text = "0 / $($hosts.Count)" }
    $script:scanJob = [QuMeterSnmp.ScanJob]::Start($client, [string[]]$hosts, [int]$concurrency.Value)
    Set-ScanControlsRunning $true
    Set-AppStatus "Scanning 0 of $($hosts.Count)..."
    $script:scanTimer.Start()
})
$scanCancel.Add_Click({
    $j = $script:scanJob
    if (-not $j -or $j.IsCompleted) { return }
    $scanCancel.Enabled = $false
    Set-AppStatus 'Stopping scan...' ([Drawing.Color]::FromArgb(150, 90, 0))
    $j.Cancel()
})
$script:scanTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 200 }
$script:scanTimer.Add_Tick({
    try {
        $j = $script:scanJob
        if (-not $j) { $script:scanTimer.Stop(); return }
        $scanBar.Value = [math]::Min($j.Done, $scanBar.Maximum)
        if (-not $j.IsCompleted) {
            if ($scanCount) { $scanCount.Text = "$($j.Done) / $($j.Total)" }
            if ($j.IsCancelled) { Set-AppStatus "Stopping scan... $($j.Done) of $($j.Total) checked." ([Drawing.Color]::FromArgb(150, 90, 0)) }
            else { Set-AppStatus "Scanning $($j.Done) of $($j.Total)..." }
            return
        }
        Complete-ManualScan $j
    } catch {
        try { $script:scanTimer.Stop() } catch { }
        $script:scanJob = $null
        try { Set-ScanControlsRunning $false } catch { }
        $msg = $_.Exception.Message
        try { Set-AppStatus "Scan failed: $msg" ([Drawing.Color]::Firebrick) } catch { }
        try { Msg $msg 'Error' } catch { }
    }
})

# ================================================================== AUTOMATE TAB
$A = $tabAuto
$sub = New-Object Windows.Forms.TabControl -Property @{ Dock = 'Fill' }
$pSet = New-Object Windows.Forms.TabPage -Property @{ Text = 'Settings'; AutoScroll = $false }
$pSch = New-Object Windows.Forms.TabPage -Property @{ Text = 'Schedule (this PC)'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(900, 560) }
$pTip = New-Object Windows.Forms.TabPage -Property @{ Text = 'Tips'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(900, 500) }
foreach ($pg in @($pSet,$pSch,$pTip)) { [void]$sub.TabPages.Add($pg) }
$A.Controls.Add($sub)

# --- Run once now bar (top)
$top = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 118; BorderStyle = 'FixedSingle'; BackColor = [Drawing.Color]::FromArgb(240, 247, 255) }
$A.Controls.Add($top)
$autoBanner = New-Object Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 36; BackColor = [Drawing.Color]::White }
$autoBannerFlow = New-Object Windows.Forms.FlowLayoutPanel -Property @{ Dock = 'Fill'; WrapContents = $true; Padding = '6,4,6,0' }
$expArgb = Get-QmAutomateExperimentalArgb
$autoExpLabel = New-Object Windows.Forms.Label -Property @{
    Text = (Get-QmAutomateExperimentalBanner)
    AutoSize = $true
    Margin = '0,2,16,0'
    ForeColor = [Drawing.Color]::FromArgb([int]$expArgb[0], [int]$expArgb[1], [int]$expArgb[2])
    BackColor = [Drawing.Color]::White
    Font = $fontBold
}
Set-Acc $autoExpLabel (Get-QmAutomateExperimentalBanner)
[void]$autoBannerFlow.Controls.Add($autoExpLabel)
$lnkFeedback = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Send feedback'; AutoSize = $true; Margin = '0,2,12,0'; LinkColor = [Drawing.Color]::FromArgb(0, 102, 184); LinkBehavior = 'AlwaysUnderline' }
$lnkGithubIssue = New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Report on GitHub'; AutoSize = $true; Margin = '0,2,0,0'; LinkColor = [Drawing.Color]::FromArgb(0, 102, 184); LinkBehavior = 'AlwaysUnderline' }
$lnkFeedback.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackMailto) } catch { Msg $_.Exception.Message 'Error' } })
$lnkGithubIssue.Add_LinkClicked({ try { Start-Process (Get-QmFeedbackIssuesUrl) } catch { Msg $_.Exception.Message 'Error' } })
[void]$autoBannerFlow.Controls.Add($lnkFeedback)
[void]$autoBannerFlow.Controls.Add($lnkGithubIssue)
$autoBanner.Controls.Add($autoBannerFlow)
$A.Controls.Add($autoBanner)
$sub.BringToFront()
$runOnce = New-B $top 'Run once now' 10 10 180 56
$runOnce.Font = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$pri = Get-QmPrimaryButtonArgb
$runOnce.BackColor = [Drawing.Color]::FromArgb([int]$pri[0], [int]$pri[1], [int]$pri[2])
$runOnce.ForeColor = [Drawing.Color]::White
$runOnce.FlatStyle = 'Flat'
$runOnce.FlatAppearance.BorderSize = 0
$runOnce.UseVisualStyleBackColor = $false
(New-L $top "Runs the full automated meter report one time with the saved settings (same as a scheduled run)." 10 70).AutoSize = $true
$runOnceHelp = $top.Controls[$top.Controls.Count - 1]
$runOnceHelp.ForeColor = 'DimGray'
$runOnceHelp.MaximumSize = New-Object Drawing.Size(190, 40)
$runBar = Add-C $top (New-Object Windows.Forms.ProgressBar -Property @{ Location = '205,8'; Size = '430,18'; Anchor = 'Top,Left,Right' })
$runStatus = New-L $top (Get-QmRunOnceEmptyCaption) 205 28
$runStatus.Font = $fontBold
$runStatus.Anchor = 'Top,Left,Right'
$lnkOut = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open output folder'; Location = '650,8'; AutoSize = $true; Anchor = 'Top,Right'; LinkBehavior = 'AlwaysUnderline' })
$lnkLog = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open last log'; Location = '650,26'; AutoSize = $true; Anchor = 'Top,Right'; LinkBehavior = 'AlwaysUnderline' })
$lnkSt  = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Last run details'; Location = '780,8'; AutoSize = $true; Anchor = 'Top,Right'; LinkBehavior = 'AlwaysUnderline' })
$lnkMps = Add-C $top (New-Object Windows.Forms.LinkLabel -Property @{ Text = 'Open MPS folder'; Location = '780,26'; AutoSize = $true; Anchor = 'Top,Right'; LinkBehavior = 'AlwaysUnderline' })
$runLog = Add-C $top (New-Object Windows.Forms.TextBox -Property @{ Location = '205,52'; Size = '720,54'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Font = $fontMono; Anchor = 'Top,Left,Right'; Text = 'No runs yet.' })
Set-Acc $runOnce 'Run once now'
Set-Acc $runBar 'Run once progress'
Set-Acc $runStatus 'Run once status'
Set-Acc $runLog 'Run log'
Set-Acc $lnkOut 'Open output folder'
Set-Acc $lnkLog 'Open last log'
Set-Acc $lnkSt 'Last run details'
Set-Acc $lnkMps 'Open MPS folder'

# --- Settings sub-tab
$setBottom = Add-C $pSet (New-Object Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 48 })
$S = Add-C $pSet (New-Object Windows.Forms.Panel -Property @{ Dock = 'Fill'; AutoScroll = $true; AutoScrollMinSize = New-Object Drawing.Size(840, 520) })
function Add-TlpRow($tlp, $row, $label, $ctl) {
    $ctl.Dock = 'Fill'
    [void]$tlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 30)))
    $tlp.Controls.Add($label, 0, $row)
    $tlp.Controls.Add($ctl, 1, $row)
    $label.Anchor = 'Left'
    $label.TextAlign = 'MiddleLeft'
    $label.AutoSize = $true
}

$settingsGrid = Add-C $S (New-Object Windows.Forms.TableLayoutPanel -Property @{ Location = '10,10'; ColumnCount = 2; RowCount = 2; Width = 980; AutoSize = $true })
[void]$settingsGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 55)))
[void]$settingsGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 45)))
[void]$settingsGrid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 250)))
[void]$settingsGrid.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))

$printersBox = New-Object Windows.Forms.GroupBox -Property @{ Text = 'Printers'; Dock = 'Fill'; Padding = '8,8,8,8' }
$aTargets = Add-C $printersBox (New-Object Windows.Forms.TextBox -Property @{ Location = '10,32'; Size = '400,150'; Multiline = $true; ScrollBars = 'Vertical'; WordWrap = $false; AcceptsReturn = $true; Font = $fontMono; Anchor = 'Top,Left,Right,Bottom' })
Set-Acc $aTargets 'Printers to read'
(New-L $printersBox 'Printers to read (IPs, ranges, CIDR; one per line):' 10 16) | Out-Null
$aCopy = New-B $printersBox 'Copy list from Manual tab' 10 188 180 26
$aCopy.Anchor = 'Bottom,Left'
Set-Acc $aCopy 'Copy list from Manual tab'
$aUseManual = New-B $printersBox 'Use Manual tab settings' 195 188 165 26
$aUseManual.Anchor = 'Bottom,Left'
Set-Acc $aUseManual 'Use Manual tab settings'
$aLoad = New-B $printersBox 'Load list...' 365 188 100 26
$aLoad.Anchor = 'Bottom,Left'
Set-Acc $aLoad 'Load printer list'
$settingsGrid.Controls.Add($printersBox, 0, 0)

$connBox = New-Object Windows.Forms.GroupBox -Property @{ Text = 'Connection'; Dock = 'Fill'; Padding = '8,8,8,8' }
$snmpTlp = Add-C $connBox (New-Object Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 6; Padding = '6,16,6,6' })
[void]$snmpTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 140)))
[void]$snmpTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
$aComm = New-Object Windows.Forms.TextBox
$aVer = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList' }
[void]$aVer.Items.AddRange(@('v2c','v1')); $aVer.SelectedItem = 'v2c'
$aPort = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 1; Maximum = 65535; Value = 161 }
$aTimeout = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 100; Maximum = 30000; Increment = 100; Value = 1500 }
$aRetries = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 0; Maximum = 8; Value = 1 }
$aConc = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 1; Maximum = 64; Value = 32 }
Add-TlpRow $snmpTlp 0 (New-Object Windows.Forms.Label -Property @{ Text = '&Community'; AutoSize = $true }) $aComm
Add-TlpRow $snmpTlp 1 (New-Object Windows.Forms.Label -Property @{ Text = '&SNMP version'; AutoSize = $true }) $aVer
Add-TlpRow $snmpTlp 2 (New-Object Windows.Forms.Label -Property @{ Text = '&Port'; AutoSize = $true }) $aPort
Add-TlpRow $snmpTlp 3 (New-Object Windows.Forms.Label -Property @{ Text = '&Timeout (ms)'; AutoSize = $true }) $aTimeout
Add-TlpRow $snmpTlp 4 (New-Object Windows.Forms.Label -Property @{ Text = '&Retries'; AutoSize = $true }) $aRetries
Add-TlpRow $snmpTlp 5 (New-Object Windows.Forms.Label -Property @{ Text = 'P&arallel queries'; AutoSize = $true }) $aConc
Set-Acc $aComm 'Community'; Set-Acc $aVer 'SNMP version'; Set-Acc $aPort 'Port'; Set-Acc $aTimeout 'Timeout (ms)'; Set-Acc $aRetries 'Retries'; Set-Acc $aConc 'Parallel queries'
$settingsGrid.Controls.Add($connBox, 1, 0)

$filesBox = New-Object Windows.Forms.GroupBox -Property @{ Text = 'Files'; Dock = 'Fill'; AutoSize = $true; Padding = '8,8,8,8' }
$pathTlp = Add-C $filesBox (New-Object Windows.Forms.TableLayoutPanel -Property @{ Dock = 'Top'; AutoSize = $true; ColumnCount = 4; Padding = '6,16,6,6' })
[void]$pathTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 200)))
[void]$pathTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$pathTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 80)))
[void]$pathTlp.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 120)))
function Add-PathStyle($tlp) { [void]$tlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28))) }
function Add-HintStyle($tlp) { [void]$tlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 20))) }
$aOut = New-Object Windows.Forms.TextBox; $bOut = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...' }
$aOutPath = New-Object Windows.Forms.Label -Property @{ AutoSize = $true; ForeColor = 'DimGray'; Text = 'Saves to:' }
$aMps = New-Object Windows.Forms.TextBox; $bMps = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...' }
$aMpsPath = New-Object Windows.Forms.Label -Property @{ AutoSize = $true; ForeColor = 'DimGray'; Text = 'Saves to:' }
$aLogF = New-Object Windows.Forms.TextBox; $bLog = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...' }
$aLogPath = New-Object Windows.Forms.Label -Property @{ AutoSize = $true; ForeColor = 'DimGray'; Text = 'Saves to:' }
$aRet = New-Object Windows.Forms.NumericUpDown -Property @{ Minimum = 0; Maximum = 3650; Value = 90; Width = 70 }
$aFmt = New-Object Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Width = 100 }
[void]$aFmt.Items.AddRange(@('basic','advanced')); $aFmt.SelectedItem = 'basic'
$aSrc = New-Object Windows.Forms.TextBox
$aRemarks = New-Object Windows.Forms.TextBox
$aRemarks.Text = $initialRemarks
$aExcludeNoSerial = New-Object Windows.Forms.CheckBox -Property @{ Text = 'Only show/include devices that are reporting serial numbers(Usually Only Printers)'; AutoSize = $false }
$aExcludeNoSerial.Checked = [bool]$excludeNoSerial.Checked
$aMap = New-Object Windows.Forms.TextBox
$bMap = New-Object Windows.Forms.Button -Property @{ Text = 'Browse...' }
$bMapEdit = New-Object Windows.Forms.Button -Property @{ Text = 'Edit mapping...' }

$r = 0
Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&Meter remarks'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aRemarks, 1, $r); $aRemarks.Dock = 'Fill'; $pathTlp.SetColumnSpan($aRemarks, 3)
$r++; [void]$pathTlp.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 44)))
$pathTlp.Controls.Add($aExcludeNoSerial, 0, $r); $pathTlp.SetColumnSpan($aExcludeNoSerial, 4)
$aExcludeNoSerial.Dock = 'Fill'
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&Output folder'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aOut, 1, $r); $aOut.Dock = 'Fill'
$pathTlp.Controls.Add($bOut, 2, $r)
$r++; Add-HintStyle $pathTlp
$pathTlp.Controls.Add($aOutPath, 1, $r); $pathTlp.SetColumnSpan($aOutPath, 3)
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&MPS drop folder (optional)'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aMps, 1, $r); $aMps.Dock = 'Fill'
$pathTlp.Controls.Add($bMps, 2, $r)
$r++; Add-HintStyle $pathTlp
$pathTlp.Controls.Add($aMpsPath, 1, $r); $pathTlp.SetColumnSpan($aMpsPath, 3)
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&Log folder'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aLogF, 1, $r); $aLogF.Dock = 'Fill'
$pathTlp.Controls.Add($bLog, 2, $r)
$r++; Add-HintStyle $pathTlp
$pathTlp.Controls.Add($aLogPath, 1, $r); $pathTlp.SetColumnSpan($aLogPath, 3)
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&Keep files (days, 0 = forever)'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aRet, 1, $r)
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = '&e-automate format'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aFmt, 1, $r)
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = 'Meter source (Lists and Codes)'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aSrc, 1, $r); $aSrc.Dock = 'Fill'
$r++; Add-PathStyle $pathTlp
$pathTlp.Controls.Add((New-Object Windows.Forms.Label -Property @{ Text = 'Mappin&g file'; AutoSize = $true; Anchor = 'Left' }), 0, $r)
$pathTlp.Controls.Add($aMap, 1, $r); $aMap.Dock = 'Fill'
$pathTlp.Controls.Add($bMap, 2, $r)
$pathTlp.Controls.Add($bMapEdit, 3, $r)
Set-Acc $aOut 'Output folder'; Set-Acc $aMps 'MPS drop folder'; Set-Acc $aLogF 'Log folder'
Set-Acc $aRet 'Keep files (days)'; Set-Acc $aFmt 'e-automate format'; Set-Acc $aSrc 'Meter source'
Set-Acc $aRemarks 'Meter remarks'; Set-Acc $aExcludeNoSerial 'Only show/include devices that are reporting serial numbers(Usually Only Printers)'
Set-Acc $aMap 'Mapping file'; Set-Acc $bMapEdit 'Edit mapping'
Set-Acc $aOutPath 'Resolved output folder'; Set-Acc $aMpsPath 'Resolved MPS drop folder'; Set-Acc $aLogPath 'Resolved log folder'
$settingsGrid.Controls.Add($filesBox, 0, 1)
$settingsGrid.SetColumnSpan($filesBox, 2)
$S.Add_Resize({
    try { $settingsGrid.Width = [math]::Max(700, $S.ClientSize.Width - 24) } catch { }
})

$aSave = New-B $setBottom 'Save settings' 10 8 140 32
$aSave.Font = $fontBold
$aReload = New-B $setBottom 'Reload' 155 8 90 32
$aValid = New-L $setBottom $script:importNote 255 16
Set-Acc $aSave 'Save settings'; Set-Acc $aReload 'Reload settings'

# --- Schedule sub-tab
$H = $pSch
$sNameLbl = New-L $H '&Task name' 10 18;  $sName = New-T $H 130 15 220
Set-Acc $sName 'Task name'
$sFreqLbl = New-L $H '&Frequency' 10 50;  $sFreq = New-Cb $H 130 47 100 @('Daily','Weekly','Monthly') 'Daily'
Set-Acc $sFreq 'Frequency'
New-L $H '&Time' 245 50 | Out-Null
$sTime = Add-C $H (New-Object Windows.Forms.DateTimePicker -Property @{ Location = '285,47'; Width = 80; Format = 'Custom'; CustomFormat = 'HH:mm'; ShowUpDown = $true })
Set-Acc $sTime 'Time'
(New-L $H "(this PC's time, 24-hour)" 375 50).ForeColor = 'DimGray'
$sDowLbl = New-L $H '&Day of week' 10 82; $sDow = New-Cb $H 130 79 110 @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') 'Monday'
Set-Acc $sDow 'Day of week'
$sDomLbl = New-L $H 'Day of &month' 245 82; $sDom = New-Cb $H 335 79 60 (@(1..28 | ForEach-Object { "$_" }) + 'Last') '1'
Set-Acc $sDom 'Day of month'
New-L $H '&Run as' 10 114 | Out-Null
$runAsItems = @('Current user (only when logged on)','SYSTEM (always; needs admin)','Service account (always)')
$sRunAs = New-Cb $H 130 111 320 $runAsItems $runAsItems[0]
Set-Acc $sRunAs 'Run as'
($sRunAsHelp = New-L $H "'Current user' needs no admin and only runs while you're logged on. SYSTEM or a service account can run with nobody logged on (admin is needed to install)." 10 144).ForeColor = 'DimGray'
$sRunAsHelp.MaximumSize = New-Object Drawing.Size(800, 36)
$sUserLbl = New-L $H '&Account (DOMAIN\user)' 10 186; $sUser = New-T $H 160 183 240
Set-Acc $sUser 'Account'
($sPassNote = New-L $H 'The service account password is handed to Windows Task Scheduler only; QuMeter never saves it.' 10 212).ForeColor = 'DimGray'
$sInstall = New-B $H '&Install / Update task' 10 242 170 32
$sInstall.Font = $fontBold
$sRemove = New-B $H '&Remove task' 185 242 120 32
$sRemove.Enabled = $false
$sRefresh = New-B $H 'Refresh status' 310 242 110 32
$sAdmin = New-B $H 'Restart QuMeter as administrator' 425 242 230 32
$sAdmin.Visible = $false
Set-Acc $sInstall 'Install or update task'; Set-Acc $sRemove 'Remove task'; Set-Acc $sRefresh 'Refresh status'; Set-Acc $sAdmin 'Restart QuMeter as administrator'
$sStatus = Add-C $H (New-Object Windows.Forms.TextBox -Property @{ Location = '10,286'; Size = '1010,72'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'; Font = $f.Font; Anchor = 'Top,Left,Right' })
Set-Acc $sStatus 'Task status'

# --- Tips sub-tab
$autoTips = @"
Tips - Automate

This tab is experimental
The Automate (Experimental) tab is experimental and requires further testing. A red notice at the top of this tab says so. Confirm scheduled output before you rely on it.

What it does
Each run (scheduled, or Run once now) reads every printer over SNMP and writes, with a date/time stamp:
  QuMeter_<stamp>.csv	general results for every address (records)
  QuMeter_eautomate_<stamp>.csv	e-automate meter import rows (OK + serial only)
  QuMeter_mps_<stamp>.csv	optional, into the MPS drop folder
  logs\QuMeter_<date>.log	what happened, per printer
  logs\status.json	run status the GUI reads (success, per-printer errors, files, write errors)
Files older than "Keep files" days are deleted from the output and log folders (never from the MPS folder).

Getting meters into e-automate
e-automate matches each row to equipment by Model + Serial. Equipment Number is left blank.
Scheduled runs write a CSV. To import it, paste its rows into the official EA_MeterImport.xlsx template (the utility accepts .xlsx only). Open the template, set Source (must already exist in Lists and Codes; not Contract, Service Call or Web), paste the e-automate CSV rows under the headers on row 8, and run the import.
Meter remarks come from the Meter remarks box on this Settings tab (default Imported by QuMeter). Leave it empty for a blank remarks field. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. The "Only show/include devices that are reporting serial numbers(Usually Only Printers)" box is checked by default and is the same setting as on the Manual tab. When it is checked, devices with a blank or placeholder serial (N/A, unknown, 0) are left out of the general, e-automate, and MPS files. Click Save settings so scheduled QuMeter Auto runs use the remarks and this checkbox (they are stored in config.json).

Output to a network share
Output and MPS folders can be UNC paths like \\fileserver\meters so files land where you and e-automate can reach them.
If the task runs as SYSTEM it uses the computer account (e.g. SERVER$) on the network. SYSTEM can't write to a share unless that computer account has write rights on the share and folder. For UNC output, a domain service account with write access is recommended (Run as > Service account). Relative folders are resolved from the QuMeter app folder (Saves to: shows the full path). If the task runs as SYSTEM, confirm that account can write there.

This PC (Schedule tab)
Install / Update creates the Windows task "QuMeter Auto". Current user = no admin needed but only while logged on. SYSTEM / service account = runs with nobody logged on (admin needed to install).

Errors
Anything that goes wrong is shown on Run once now and in Last run details: printers timing out, files that couldn't be written, or bad settings. The Schedule tab also shows the task's last/next run and result.
"@

New-Tips $pTip $autoTips 6 6 1020 470 'Top,Bottom,Left,Right' | Out-Null
$pTip.Add_Resize({ $pTip.Controls[0].Size = "$($pTip.ClientSize.Width - 12),$($pTip.ClientSize.Height - 12)" })


# ------------------------------------------------------------------ config <-> GUI
$script:cfgDirty = $false
$script:cfgLoading = $false
function Get-QmResolvedDisplay([string]$raw, [string]$fallback) {
    $v = if ([string]::IsNullOrWhiteSpace($raw)) { $fallback } else { $raw }
    try { return (Resolve-QmPath $v $app) } catch { return $v }
}
function Update-PathLabels {
    $aOutPath.Text = "Saves to: $(Get-QmResolvedDisplay $aOut.Text 'output')"
    if ([string]::IsNullOrWhiteSpace($aMps.Text)) { $aMpsPath.Text = 'Saves to: (not set)' }
    else { $aMpsPath.Text = "Saves to: $(Get-QmResolvedDisplay $aMps.Text '')" }
    $aLogPath.Text = "Saves to: $(Get-QmResolvedDisplay $aLogF.Text 'logs')"
}
function Update-RunOnceEnabled {
    if ($script:runProc) { $runOnce.Enabled = $false; return }
    $savedTargets = @()
    if ($script:cfg -and $script:cfg.targets) { $savedTargets = @($script:cfg.targets) }
    $can = Test-QmRunOnceCanRun -SavedTargets $savedTargets -Running:$false
    $runOnce.Enabled = $can
    $emptyCaption = Get-QmRunOnceEmptyCaption
    if (-not $can) {
        $runStatus.Text = $emptyCaption
        $runStatus.ForeColor = [Drawing.SystemColors]::ControlText
        $uiTip.SetToolTip($runOnce, $emptyCaption)
        Set-AppStatus $emptyCaption $null 'auto'
    } else {
        $uiTip.SetToolTip($runOnce, 'Runs the full automated meter report one time with the saved settings (same as a scheduled run).')
        if ([string]::IsNullOrWhiteSpace($runStatus.Text) -or $runStatus.Text -eq $emptyCaption) {
            $runStatus.Text = 'Ready. Save your settings, then click Run once now to test.'
        }
        Set-AppStatus $runStatus.Text $null 'auto'
    }
}
function Set-CfgDirty([bool]$dirty) {
    if ($script:cfgLoading) { return }
    $script:cfgDirty = $dirty
    if ($aSave) { $aSave.Text = $(if ($dirty) { 'Save settings *' } else { 'Save settings' }) }
    if ($dirty -and $aValid -and $aValid.ForeColor -ne [Drawing.Color]::Firebrick) {
        $aValid.ForeColor = [Drawing.Color]::FromArgb(140, 90, 0)
        if ($aValid.Text -notmatch 'Unsaved') { $aValid.Text = 'Unsaved changes' }
    }
}

function Set-GuiFromConfig($c) {
    $script:cfgLoading = $true
    try {
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
        Update-PathLabels
    } finally {
        $script:cfgLoading = $false
        Set-CfgDirty $false
        if ($script:importNote) { $aValid.ForeColor = 'DarkOrange'; $aValid.Text = $script:importNote }
        elseif ($aValid.Text -eq 'Unsaved changes') { $aValid.ForeColor = [Drawing.SystemColors]::ControlText; $aValid.Text = '' }
        Update-RunOnceEnabled
    }
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
    $sDowLbl.Enabled = $sDow.Enabled
    $sDomLbl.Enabled = $sDom.Enabled
    $sUserLbl.Enabled = $sUser.Enabled
    $sAdmin.Visible = (($sRunAs.SelectedIndex -ge 1) -and -not (Test-IsAdmin))
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
    Set-CfgDirty $false
    Update-PathLabels
    Update-RunOnceEnabled
    return $script:cfg
}

foreach ($ctl in @($sFreq,$sRunAs)) { $ctl.Add_SelectedIndexChanged({ Update-Enables }) }
$aCopy.Add_Click({ $aTargets.Text = $targets.Text })
$aUseManual.Add_Click({
    $aTargets.Text = $targets.Text
    $aComm.Text = $community.Text
    $aVer.SelectedItem = $ver.SelectedItem
    $aPort.Value = $port.Value
    $aTimeout.Value = $timeout.Value
    $aRetries.Value = $retries.Value
    $aConc.Value = $concurrency.Value
    $aRemarks.Text = $remarks.Text
    $aExcludeNoSerial.Checked = $excludeNoSerial.Checked
})
$aLoad.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*' }
    if ($d.ShowDialog() -eq 'OK') { $aTargets.Text = [System.IO.File]::ReadAllText($d.FileName) }
})
$bOut.Add_Click({ Browse-Folder $aOut }); $bMps.Add_Click({ Browse-Folder $aMps }); $bLog.Add_Click({ Browse-Folder $aLogF })
$bMap.Add_Click({ $d = New-Object Windows.Forms.OpenFileDialog -Property @{ Filter = 'JSON (*.json)|*.json' }; if ($d.ShowDialog() -eq 'OK') { $aMap.Text = $d.FileName } })
$bMapEdit.Add_Click({ $p = Resolve-QmPath $(if ($aMap.Text) { $aMap.Text } else { 'e-automate.mapping.json' }) $app; Start-Process notepad.exe -ArgumentList "`"$p`"" })
$aSave.Add_Click({ [void](Save-All) })
$aReload.Add_Click({ $script:cfg = Read-QmConfig -Path $configPath; Set-GuiFromConfig $script:cfg })
$remarks.Add_TextChanged({ if ($aRemarks.Text -ne $remarks.Text) { $aRemarks.Text = $remarks.Text } })
$aRemarks.Add_TextChanged({
    if ($remarks.Text -ne $aRemarks.Text) { $remarks.Text = $aRemarks.Text }
    Set-CfgDirty $true
})
$aExcludeNoSerial.Add_CheckedChanged({
    if ($excludeNoSerial.Checked -ne $aExcludeNoSerial.Checked) { $excludeNoSerial.Checked = $aExcludeNoSerial.Checked }
    Set-CfgDirty $true
})
$pathDirty = { Update-PathLabels; Set-CfgDirty $true }
foreach ($tb in @($aTargets,$aComm,$aOut,$aMps,$aLogF,$aSrc,$aMap,$sName,$sUser)) { $tb.Add_TextChanged($pathDirty) }
foreach ($n in @($aPort,$aTimeout,$aRetries,$aConc,$aRet)) { $n.Add_ValueChanged({ Set-CfgDirty $true }) }
foreach ($cb in @($aVer,$aFmt,$sFreq,$sDow,$sDom,$sRunAs)) { $cb.Add_SelectedIndexChanged({ Set-CfgDirty $true }) }
$sTime.Add_ValueChanged({ Set-CfgDirty $true })

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
    try {
        try { Read-ProgressLines } catch { }
        if ($script:runProc -and $script:runProc.HasExited) {
            $script:runTimer.Stop()
            try { Read-ProgressLines } catch { }
            $code = $script:runProc.ExitCode
            $script:runProc = $null
            Update-RunOnceEnabled
            if ($runBar.Value -lt $runBar.Maximum -and $code -eq 0) { $runBar.Value = $runBar.Maximum }
            Show-LocalResult
            Update-LastRunLinks
            Remove-Item -LiteralPath $script:runProgFile -Force -ErrorAction SilentlyContinue
        }
    } catch {
        try { $script:runTimer.Stop() } catch { }
        try { Set-AppStatus "Run failed: $($_.Exception.Message)" ([Drawing.Color]::Firebrick) } catch { }
        try { Msg $_.Exception.Message 'Error' } catch { }
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
function Update-LastRunLinks {
    $s = $null
    try { $s = Read-LocalStatus } catch { }
    $lnkSt.Enabled = [bool]$s
    $l = $null
    try {
        $lf = Get-LocalFolder 'logFolder'
        if ($lf) { $l = Get-ChildItem -LiteralPath $lf -Filter 'QuMeter*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    } catch { }
    $lnkLog.Enabled = [bool]$l
    $mps = $null
    try { $mps = Get-LocalFolder 'mpsDropFolder' } catch { }
    $lnkMps.Enabled = -not [string]::IsNullOrWhiteSpace($mps)
    if (-not $s -and ($runLog.Lines.Count -le 1)) { $runLog.Text = 'No runs yet.' }
}
function Show-LocalTask {
    try {
        $t = Get-QmLocalTaskStatus -TaskName $sName.Text.Trim()
        $sRemove.Enabled = [bool]$t.Exists
        if (-not $t.Exists) {
            $sStatus.Text = "No task installed on this PC. Choose a time and click Install / Update task."
            return
        }
        $sStatus.Text = "Task '$($sName.Text)': $($t.State)`r`nRun as: $($t.RunAs)`r`nLast run: $($t.LastRunTime)   Result: $($t.LastResult)`r`nNext run: $($t.NextRunTime)"
        $lastRun = Read-LocalStatus
        if ($lastRun) { $sStatus.Text += "`r`n`r`n" + (ConvertTo-QmStatusText $lastRun) }
    } catch { $sStatus.Text = "Could not read task: $($_.Exception.Message)"; $sRemove.Enabled = $false }
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
    try { if (Remove-QmLocalTask -TaskName $sName.Text.Trim()) { $sStatus.Text = 'Task removed.'; $sRemove.Enabled = $false } else { $sStatus.Text = 'Task was not installed.'; $sRemove.Enabled = $false } }
    catch { $sStatus.Text = "Remove failed: $($_.Exception.Message)" }
})
$sAdmin.Add_Click({
    try { Start-Process $psExe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $app 'QuMeter.ps1')`""; $f.Close() } catch { }
})

# ------------------------------------------------------------------ start
Set-GuiFromConfig $script:cfg
if ($script:importNote) { $aValid.ForeColor = 'DarkOrange' }
if (Test-Path -LiteralPath $configPath) {
    try {
        if (Read-LocalStatus) { Show-LocalResult }
        else { $runStatus.ForeColor = 'Black'; $runStatus.Text = (Get-QmRunOnceEmptyCaption); $runLog.Text = 'No runs yet.'; Update-RunOnceEnabled }
    } catch { }
} else {
    $runLog.Text = 'No runs yet.'
}
Show-LocalTask
Update-LastRunLinks
Update-ExportButtons
Update-RunOnceEnabled
$tabs.Add_SelectedIndexChanged({ Show-ActiveTabStatus })
Show-ActiveTabStatus
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
    Set-AppStatus 'Checking for updates...'
    $cur = Get-QmVersion
    $rel = $null
    try { $rel = Get-QmLatestRelease } catch { $rel = $null }
    $pubUpdate.Text = 'Check for updates'
    if (-not $rel) {
        if (-not $QuietIfCurrent) { Msg 'Could not check for updates. Check your internet connection and try again, or confirm a GitHub Release exists.' 'Warning' 'Check for updates' }
        else { Set-AppStatus 'Could not check for updates.' }
        return
    }
    $cmp = Compare-QmVersion $cur $rel.Version
    if ($cmp -eq 0) {
        if (-not $QuietIfCurrent) { Msg "You're on the latest version ($cur)." 'Information' 'Check for updates' }
        else { Set-AppStatus "You're on the latest version ($cur)." }
        return
    }
    if ($cmp -gt 0) {
        if (-not $QuietIfCurrent) { Msg "This build ($cur) is newer than the latest published release ($($rel.Version))." 'Information' 'Check for updates' }
        else { Set-AppStatus "This build ($cur) is newer than the latest published release ($($rel.Version))." }
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
        try {
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
        } catch {
            try { $script:updatePoll.Stop() } catch { }
        }
    })
    $script:updatePoll.Start()
}
$pubUpdate.Add_Click({ Show-QmUpdateCheck })
$f.Add_Shown({
    $script:updateTimer = New-Object Windows.Forms.Timer -Property @{ Interval = 800 }
    $script:updateTimer.Add_Tick({
        try {
            $script:updateTimer.Stop()
            Start-QmBackgroundUpdateCheck
        } catch {
            try { $script:updateTimer.Stop() } catch { }
        }
    })
    $script:updateTimer.Start()
})
$f.Add_FormClosing({
    Persist
    if ($script:scanJob -and -not $script:scanJob.IsCompleted) {
        try { $script:scanJob.Cancel(); [void]$script:scanJob.Wait(3000) } catch { }
    }
    foreach ($tm in @($script:scanTimer, $script:runTimer, $script:updateTimer, $script:updatePoll, $script:gridSelTimer)) { if ($tm) { try { $tm.Stop() } catch { } } }
    Stop-QmBackgroundUpdateCheck
    if (-not $_.Cancel) {
        try {
            Set-AppStatus 'Thank you for using QuMeter by QuSpace Studios'
            if ($pubBar) { $pubBar.Refresh() }
            $f.Update()
        } catch { }
    }
})
try { Restore-MpsImport } catch { }
[void]$f.ShowDialog()
