# QuMeter

A Windows app that reads lifetime meters from networked printers over SNMP (v1/v2c) and exports a general CSV plus an e-automate meter-import CSV. PowerShell + WinForms, no installer. Mostly written for HP fleets, but it uses standard Printer-MIB OIDs so other brands usually return at least serial + total count.

Matching in the e-automate file is by **serial number**.

## Run

Double-click `QuMeter.bat`, or:

```
powershell -NoProfile -ExecutionPolicy Bypass -File QuMeter.ps1
```

Paste IPs, ranges (`10.0.1.1-10.0.1.50` or `10.0.1.1-50`), or CIDR (`10.0.1.0/24`), set the community (default `public`), and click Scan.

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

## e-automate CSV

Default layout is the official **Meter Import** (basic) columns, taken from ECI's webhelp:

[Meter Import](https://webhelp.e-automate.com/cloud/Spreadsheet_Utilities/Data_Import_Utility/Meter_Import.htm)

`Equipment Number, Model, Serial, B\W, Color, Total Count, Remarks, Reading Date`

Equipment Number is left blank; the machine is identified by **Model + Serial**, which the official utility allows.

**Important:** the official ECI Import and Export Utility accepts the official `EA_MeterImport.xlsx` template (**.xlsx only**), with column headers on row 8 and data starting on row 9. There is also a header **Source** field on that template (not a column) that must be a meter source already defined in Lists and Codes. Do not use the system-controlled sources Contract, Service Call, or Web.

QuMeter writes a CSV with the confirmed column names so you can paste it into that template. Column names, date format, remarks, and meter-type labels are configurable in `e-automate.mapping.json`. Set `"format": "advanced"` to use the official Meter Import Advanced columns (`Equipment Number, Model, Serial, Source, Reading Date, Meter Type, Reading, Credits, Remarks`).

The exact official `.xlsx` template (rows 1–7 of header metadata, named ranges, etc.) is not reproduced here. If your shop's template uses different meter-type names than `B\W`, `Color`, and `Total Count`, edit the mapping file to match Lists and Codes.

e-automate will reject a row if the equipment is missing a meter type you supplied, or if you omit a meter type the equipment has. Unavailable SNMP values are left blank on purpose; you may need to drop blank columns or fill missing types before import.

This app never writes to the e-automate database and never calls an e-automate or MPS API.

## Settings

- `e-automate.mapping.json` — column mapping (edit this if your template differs)
- `settings.json` — last community, timeout, and target list (created after you run the app)

## Related

[QuMeter Auto](https://github.com/MAX-Q00/QuMeterAuto) is the scheduled, unattended version of the same meter puller.
