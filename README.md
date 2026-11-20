# QuMeter

**Published by QuSpace Studios LLC**  
© 2026 QuSpace Studios LLC

Windows app that reads lifetime meters from networked printers over SNMP (v1/v2c) and writes Excel, CSV, e-automate meter-import, and MPS meter-import files. PowerShell 5.1 + WinForms, nothing to install. Built for HP fleets, but it uses the standard Printer-MIB OIDs, so other brands usually return at least serial + total.

QuMeter now includes **QuMeter Auto** (the old [QuMeterAuto](https://github.com/MAX-Q00/QuMeterAuto) repo is archived).

Double-click `QuMeter.bat`. The window has two tabs.

## Manual tab

Paste IPs, ranges (`10.0.1.1-10.0.1.50` or `10.0.1.1-50`) or CIDR (`10.0.1.0/24`), set the community (default `public`), click **Scan**. A progress bar shows the scan. Click **Stop scan** to cancel a running scan: remaining probes stop, results already collected are kept, and addresses not yet probed are marked **Cancelled**. While a scan is running, the pointer uses the Windows busy cursor. Exports warn you that a cancelled scan is incomplete before writing a file. Check **Don't show printers that timed out** to hide timeouts in the grid and in every export. Check **Don't show printers with no serial number** to hide printers with a blank or placeholder serial (`N/A`, `unknown`, or `0`) from the grid, every export, and the Responding IPs list; the same checkbox is on the Automate Settings tab and is saved in `config.json` (`excludeNoSerial`) for scheduled Auto runs. **Hide tips** collapses the right-hand Tips pane (the choice is remembered). **About** in the status bar shows the publisher and copyright. Export buttons stay off while a scan is running, and e-automate / MPS exports need at least one printer that answered with a serial number. After a scan, the **Responding IPs** box lists every address that did not time out (one per line, the same format as the IP input); **Copy** puts that list on the clipboard so you can paste it back and rescan only those printers. The window, tabs, results grid, and text boxes have horizontal and vertical scroll bars.

Then export (e-automate is listed first, as recommended):

- **Export e-automate** (recommended for updating many serials at once): a `.xlsx` workbook laid out like ECI's Meter Import utility (Guide + Import tabs, **Source** on row 3, column headers on row 8, data from row 9). Only printers that answered and reported a serial are included. Matching is by Model + Serial. You can also save a CSV from the same dialog if you want to paste into the official template. The official Import and Export Utility is `.xlsx` only; if it rejects the generated workbook, download official `EA_MeterImport.xlsx`, set **Source** to a meter source in Lists and Codes (not Contract, Service Call or Web), paste our data rows under row 8, and import that file.
- **Export Excel**: a `.xlsx` workbook with Results, e-automate, MPS, FMAudit, and import-instruction sheets. No Excel install is required to write the file.
- **Export MPS**: a CSV for an MPS watch folder or manual import. The default layout is `SerialNumber, Model, IPAddress, TotalCount, MonoCount, ColorCount, ReadDate, ReadDateTime, SysDescr` (same as the Automate tab). Choose **FMAudit-style CSV** in the save dialog for published FMAudit audit-history headers (`IP Address, Manufacturer, Model, Serial Number, Description, Total Pages, Mono Pages, Color Pages`). Confirm your MPS tool accepts the columns, or map them, then let MPS sync to e-automate if that integration is already set up. A single official public "import this file into ECI MPS" template was not confirmed.
- **Export all...** writes the Excel workbook, e-automate `.xlsx` and CSV, both MPS CSVs, and the general CSV into one folder.
- **Remarks**: an editable box on the Manual tab and the Automate Settings tab (default Imported by QuMeter). It is written to the e-automate Remarks column. Leave it empty for a blank field. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. Saved in settings.json and config.json (eaRemarks), so scheduled QuMeter Auto runs use the same text.
- **Export results CSV**: the general scan record (date, time, IP, model, serial, meters, status, errors). Save dialogs open in the last export folder.
- **Edit mapping...** opens `e-automate.mapping.json` for custom column or meter-type names, or `"format": "advanced"`.

The **Tips** panel on the right explains which file to use and how. It can be hidden and resized.

## Automate tab

This tab is still in development. A beta banner at the top says **Beta: this tab is still in development. Feedback is welcome.** **Send feedback** opens a pre-filled email to dylan@quspace.studio with the subject `QuMeter feedback (vX.Y.Z)`. **Report on GitHub** opens a new issue at [MAX-Q00/QuMeter](https://github.com/MAX-Q00/QuMeter/issues/new).

**Run once now** (big button at the top) runs the full automated method one time with the saved settings, the same as a scheduled run. It stays disabled until at least one printer is saved on the Settings tab. It does the SNMP pull, writes the dated general, e-automate and optional MPS CSVs, and logs the run. It shows progress, the current step and a live log, plus links to the output folder, MPS folder, last log and last-run details. Settings show the resolved **Saves to:** path for each folder, and **Save settings** marks unsaved changes with an asterisk.

Sub-tabs:

| Sub-tab | What it does |
| --- | --- |
| **Settings** | Printer list, community/version/port/timeout/retries/parallelism, output folder, MPS drop folder, log folder, retention days, e-automate format + meter Source + mapping file. Save settings validates and writes `config.json`. |
| **Schedule (this PC)** | Task name, Daily/Weekly/Monthly, time (this PC, 24-hour), weekday or day of month (1-28 or Last), and run as (current user / SYSTEM / service account). Install/Update, Remove (only when a task exists), and status. **Restart as administrator** appears only when the task would run as SYSTEM or a service account. |
| **Tips** | How to use the output, UNC shares, and the Schedule tab. |

### Engine

`QuMeterEngine.ps1` is the headless run (what QuMeter Auto used to be). It runs from the scheduled task and from Run once now:

```
powershell -NoProfile -ExecutionPolicy Bypass -File QuMeterEngine.ps1 -ConfigPath config.json
```

Each run writes `QuMeter_<stamp>.csv`, `QuMeter_eautomate_<stamp>.csv`, optional `QuMeter_mps_<stamp>.csv`, `logs\QuMeter_<date>.log`, and `logs\status.json` (last-run details the Automate tab reads). Exit codes: 0 ok, 1 failed, 2 completed with errors. Retention deletes old `QuMeter_*` files in the output and log folders, never in the MPS folder.

A service-account password is given to Windows Task Scheduler only; it is never written to disk. Output can be a UNC share. A task running as SYSTEM writes to shares as the computer account (`SERVER$`), so use a service account for UNC output unless that account has rights.

## What it reads

| Field | OID | Source | Notes |
| --- | --- | --- | --- |
| sysDescr | `1.3.6.1.2.1.1.1.0` | SNMPv2-MIB | Always requested |
| Model (primary) | `1.3.6.1.2.1.25.3.2.1.3.1` | HOST-RESOURCES-MIB `hrDeviceDescr` | Walks the table if index `.1` is empty |
| Model (HP fallback) | `1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.2.0` | HP-LASERJET-COMMON-MIB `model-name` | Verified in the published MIB |
| Model (alt) | `1.3.6.1.2.1.43.5.1.1.16.1` | Printer-MIB `prtGeneralPrinterName` | Used only if the others are empty |
| Serial (primary) | `1.3.6.1.2.1.43.5.1.1.17.1` | Printer-MIB `prtGeneralSerialNumber` | Walks the table if index `.1` is empty |
| Serial (HP fallback) | `1.3.6.1.4.1.11.2.3.9.4.2.1.1.3.3.0` | HP-LASERJET-COMMON-MIB `serial-number` | Verified in the published MIB. Leading 2-byte HP symbol-set prefix (Roman-8 `0x0115`) is stripped |
| Lifetime total | `1.3.6.1.2.1.43.10.2.1.4.1.1` | Printer-MIB `prtMarkerLifeCount` | Walks the table if index `1.1` is empty |
| HP mono | `1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.6.0` | HP-LASERJET-COMMON-MIB `total-mono-page-count` | Verified in the published MIB. Left **blank** if the device does not return it — never computed as Total − Color |
| HP color | `1.3.6.1.4.1.11.2.3.9.4.2.1.4.1.2.7.0` | HP-LASERJET-COMMON-MIB `total-color-page-count` | Verified in the published MIB. Left **blank** if unavailable |

SNMP is implemented in `QuSnmp.cs` over UDP. There are no third-party DLLs and no net-snmp dependency.

## e-automate and MPS exports

Default layout is the official **Meter Import** (basic) columns, taken from ECI's webhelp:

[Meter Import](https://webhelp.e-automate.com/cloud/Spreadsheet_Utilities/Data_Import_Utility/Meter_Import.htm)

`Equipment Number, Model, Serial, B\W, Color, Total Count, Remarks, Reading Date`

Equipment Number is left blank; the machine is identified by **Model + Serial**, which the official utility allows.

**Important:** the official ECI Import and Export Utility accepts the official `EA_MeterImport.xlsx` template (**.xlsx only**), with column headers on row 8 and data starting on row 9. There is also a header **Source** field on that template (not a column) that must be a meter source already defined in Lists and Codes. Do not use the system-controlled sources Contract, Service Call, or Web.

QuMeter writes a `.xlsx` workbook with that layout (and still writes a CSV you can paste into the official template). Column names, date format, remarks, and meter-type labels are configurable in `e-automate.mapping.json`. Set `"format": "advanced"` to use the official Meter Import Advanced columns (`Equipment Number, Model, Serial, Source, Reading Date, Meter Type, Reading, Credits, Remarks`).

The exact official `.xlsx` template (rows 1-7 of header metadata, named ranges, hyperlinks, etc.) is not reproduced here, so the official utility may still require you to paste into `EA_MeterImport.xlsx` if it rejects the generated file. If your shop's template uses different meter-type names than `B\W`, `Color`, and `Total Count`, edit the mapping file to match Lists and Codes.

e-automate will reject a row if the equipment is missing a meter type you supplied, or if you omit a meter type the equipment has. Unavailable SNMP values are left blank on purpose; you may need to drop blank columns or fill missing types before import.

This app never writes to the e-automate database and never calls an e-automate or MPS API.

## Files

- `QuMeter.ps1` GUI · `QuMeterEngine.ps1` headless run · `QuMeterCore.ps1` config/schedule/status/version · `QuMeterUpdate.ps1` GitHub Releases updater · `QuSnmp.cs`/`QuSnmp.ps1` SNMP + CSV/Excel exports
- `config.json` Automate settings (no secrets) · `settings.json` Manual tab · `e-automate.mapping.json` column mapping
- `scripts/New-QuMeterReleasePackage.ps1` builds the release zip the updater expects · `scripts/Install-QuMeterShortcut.ps1` creates or refreshes the Desktop shortcut
- `tests\` box tests (`Test-QuSnmp.ps1`, `Test-QuMeterCore.ps1`, `Test-QuMeterUpdate.ps1`, SNMP simulator)

On first start, if there's no `config.json` and an old `..\QuMeterAuto\config.json` exists, its settings and `devices.txt` are imported.

This app never writes to the e-automate database and never calls an e-automate or MPS API.

## Updates

The app version lives in one place: `$script:QmVersion` in `QuMeterCore.ps1` (`Get-QmVersion` reads it). Keep that in sync before you tag a release.

On startup, QuMeter checks the latest GitHub Release for [MAX-Q00/QuMeter](https://github.com/MAX-Q00/QuMeter/releases/latest) over HTTPS, unauthenticated, with a short timeout. If the machine is offline or no release exists yet, the check fails silently. If a newer version is published, you are asked whether to install it. **Check for updates** on the status bar runs the same check on demand and tells you when you are already current.

If you choose to update, QuMeter downloads the release asset named `QuMeter-X.Y.Z.zip`, checks the size, and checks the SHA256 when the release provides one (GitHub's asset digest, or a `SHA256:` line in the release notes). It then starts a short helper, closes the window (so files are not in use), copies the previous app files into `backup/QuMeter-<old-version>/`, replaces the program files, and relaunches. `settings.json`, `config.json`, `devices.txt`, output, and logs are left alone. An existing `e-automate.mapping.json` is not overwritten.

Until you publish a GitHub Release, startup will not offer an update.

## Publishing a release

Do not publish from this script; it only builds the zip the updater looks for.

1. Bump `$script:QmVersion` in `QuMeterCore.ps1` and commit (this is the only version source of truth).
2. Merge to `main`.
3. Create and push an annotated tag that matches that version, for example `v2.2.0`.
4. On GitHub, draft a new release from that tag.
5. Run `pwsh -NoProfile -File scripts/New-QuMeterReleasePackage.ps1` and attach the zip it prints, whose name must be `QuMeter-<version>.zip` (files at the zip root, not in a wrapper folder).
6. Optional: attach the `.sha256` file or paste `SHA256: <hex>` in the release notes. GitHub also publishes an asset digest the updater will use when present.
7. Publish the release (not as a draft or prerelease). The app reads `/releases/latest`.

## Publisher on Windows

QuMeter is published by **QuSpace Studios LLC**. The window title, status bar, README, source headers, scheduled-task author, and Desktop shortcut description already say so. Windows **Verified publisher** on UAC and SmartScreen only appears on a digitally signed application, which needs a code-signing certificate after Microsoft finishes publisher verification. That is not available yet.

Save dialogs use ordinary file-type filters, for example `CSV (*.csv)`, `Excel workbook (*.xlsx)`, `e-automate workbook (*.xlsx)`, `e-automate CSV (*.csv)`, `MPS CSV (*.csv)`, and `FMAudit-style CSV (*.csv)`.

---

Published by QuSpace Studios LLC. © 2026 QuSpace Studios LLC.
