# QuMeter

Windows app that reads lifetime meters from networked printers over SNMP (v1/v2c) and writes Excel, CSV, e-automate meter-import, and MPS meter-import files. PowerShell 5.1 + WinForms, nothing to install. Built for HP fleets, but it uses the standard Printer-MIB OIDs, so other brands usually return at least serial + total.

QuMeter now includes **QuMeter Auto** (the old [QuMeterAuto](https://github.com/MAX-Q00/QuMeterAuto) repo is archived).

Double-click `QuMeter.bat`. The window has two tabs.

## Manual tab

Paste IPs, ranges (`10.0.1.1-10.0.1.50` or `10.0.1.1-50`) or CIDR (`10.0.1.0/24`), set the community (default `public`), click **Scan**. A progress bar shows the scan. Check **Exclude IPs that timed out** to hide timeouts in the grid and in every export. Check **Exclude IPs that have no serial number** to hide printers with a blank or placeholder serial (`N/A`, `unknown`, or `0`) from the grid, every export, and the Responding IPs list; the same checkbox is on the Automate Settings tab and is saved in `config.json` (`excludeNoSerial`) for scheduled Auto runs. After a scan, the **Responding IPs** box lists every address that did not time out (one per line, the same format as the IP input); **Copy** puts that list on the clipboard so you can paste it back and rescan only those printers. The window, tabs, results grid, and text boxes have horizontal and vertical scroll bars.

Then export:

- **Export Excel**: a `.xlsx` workbook with Results, e-automate, MPS, FMAudit, and import-instruction sheets. No Excel install is required to write the file.
- **Export e-automate** (recommended for updating many serials at once): a `.xlsx` workbook laid out like ECI's Meter Import utility (Guide + Import tabs, **Source** on row 3, column headers on row 8, data from row 9). Only printers that answered and reported a serial are included. Matching is by Model + Serial. You can also save a CSV from the same dialog if you want to paste into the official template. The official Import and Export Utility is `.xlsx` only; if it rejects the generated workbook, download official `EA_MeterImport.xlsx`, set **Source** to a meter source in Lists and Codes (not Contract, Service Call or Web), paste our data rows under row 8, and import that file.
- **Export MPS**: a CSV for an MPS watch folder or manual import. The default layout is `SerialNumber, Model, IPAddress, TotalCount, MonoCount, ColorCount, ReadDate, ReadDateTime, SysDescr` (same as the Automate tab). Choose **FMAudit-style CSV** in the save dialog for published FMAudit audit-history headers (`IP Address, Manufacturer, Model, Serial Number, Description, Total Pages, Mono Pages, Color Pages`). Confirm your MPS tool accepts the columns, or map them, then let MPS sync to e-automate if that integration is already set up. A single official public "import this file into ECI MPS" template was not confirmed.
- **Export all...** writes the Excel workbook, e-automate `.xlsx` and CSV, both MPS CSVs, and the general CSV into one folder.
- **Remarks**: an editable box on the Manual tab and the Automate Settings tab (default Imported by QuMeter). It is written to the e-automate Remarks column. Leave it empty for a blank field. Optional tokens, replaced per printer: {date} {time} {ip} {serial} {model}. Saved in settings.json and config.json (eaRemarks), so scheduled QuMeter Auto runs use the same text.
- **Export CSV**: the general scan record (date, time, IP, model, serial, meters, status, errors).
- **Edit mapping...** opens `e-automate.mapping.json` for custom column or meter-type names, or `"format": "advanced"`.

The **Tips** panel on the right explains which file to use and how.

## Automate tab

**Run once now** (big button at the top) runs the full automated method one time with the saved settings, the same as a scheduled run. It does the SNMP pull, writes the dated general, e-automate and optional MPS CSVs, and logs the run. It shows progress, the current step and a live log, plus links to the output folder, MPS folder, last log and last-run details.

Sub-tabs:

| Sub-tab | What it does |
| --- | --- |
| **Settings** | Printer list, community/version/port/timeout/retries/parallelism, output folder, MPS drop folder, log folder, retention days, e-automate format + meter Source + mapping file. Save settings validates and writes `config.json`. |
| **Schedule (this PC)** | Task name, Daily/Weekly/Monthly, time, weekday or day of month (1-28 or Last), and run as (current user / SYSTEM / service account). Install/Update, Remove, and status (state, last run, result, next run). |
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

- `QuMeter.ps1` GUI · `QuMeterEngine.ps1` headless run · `QuMeterCore.ps1` config/schedule/status · `QuSnmp.cs`/`QuSnmp.ps1` SNMP + CSV/Excel exports
- `config.json` Automate settings (no secrets) · `settings.json` Manual tab · `e-automate.mapping.json` column mapping
- `tests\` box tests (`Test-QuSnmp.ps1`, `Test-QuMeterCore.ps1`, SNMP simulator)

On first start, if there's no `config.json` and an old `..\QuMeterAuto\config.json` exists, its settings and `devices.txt` are imported.

This app never writes to the e-automate database and never calls an e-automate or MPS API.
