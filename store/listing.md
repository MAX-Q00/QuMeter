# QuMeter — Microsoft Store Listing Draft

**App Name:** QuMeter  
**Publisher:** QuSpace Studios (`QuSpace Studios LLC`)  
**Store ID:** `9PDKLRNTBFZ7`  
**Package Family Name:** `QuSpaceStudios.QuMeter_60dym0mcr3xcp`  
**Version:** `2.2.5.0` (x64)  

---

## Category

- **Primary category:** Utilities & tools  
- **Secondary category:** Productivity  

---

## Short Description

Read lifetime meter counts from networked printers over SNMP and export ready-to-import Excel, CSV, e-automate, and MPS reports—manually or on an automated schedule.

---

## Full Description

QuMeter is a fast, lightweight Windows desktop utility for managed print providers, copier technicians, and IT teams who need accurate lifetime meter counts from networked printers without deploying heavy cloud agents.

Enter individual IP addresses, IP ranges (such as 10.0.1.1-50), or CIDR subnets, or import an existing MPS fleet list (.xlsx or .csv) and filter by customer. QuMeter queries devices over SNMPv1 or SNMPv2c using standard Printer-MIB and Host-Resources-MIB OIDs—with built-in HP private MIB fallbacks—to pull serial numbers, device models, sysDescr, total lifetime impressions, and monochrome/color page counts.

Export clean, ready-to-use files with one click:
- e-automate Meter Import workbooks (.xlsx) and CSVs (Basic and Advanced layouts, with customizable column mapping and token-based remarks)
- Multi-sheet Excel workbooks (.xlsx) with Results, e-automate, MPS, FMAudit, and import instructions—no Excel installation required
- Standard MPS CSVs and FMAudit-style CSVs

Need hands-off collection? Use the built-in Automate tab (formerly QuMeter Auto) to save your printer list and schedule unattended Daily, Weekly, or Monthly meter pulls through Windows Task Scheduler, writing dated CSVs, logs, and optional MPS drop-folder outputs—including to shared network folders.

All scanning and data stay completely on your local computer and local network.

---

## Features (5)

*(Each under Partner Center's 200-character feature limit)*

1. Bulk SNMPv1/v2c meter discovery across IP lists, ranges, and CIDR subnets with live progress, cancellation, and timeout/no-serial filtering.
2. One-click exports to e-automate (.xlsx and CSV, Basic or Advanced), multi-sheet Excel (.xlsx), standard MPS CSV, and FMAudit-style CSV.
3. Import MPS fleet lists (.xlsx or .csv), filter scans by customer, and merge live SNMP meter readings with customer, asset, and serial details.
4. Customizable e-automate export mappings and dynamic meter remarks with {date}, {time}, {ip}, {serial}, and {model} tokens.
5. Built-in Automate tab to run scheduled Daily, Weekly, or Monthly unattended meter pulls to local folders or network shares.

---

## Search Keywords (7)

*(Partner Center allows up to 7 search terms, up to 30 characters each)*

1. `printer meter`
2. `SNMP`
3. `e-automate`
4. `print fleet`
5. `MPS`
6. `page counter`
7. `copier meters`

---

## Privacy Policy — Is One Needed?

**Yes — Required for Microsoft Store submission.**

Under **Microsoft Store Policy 10.5.1** and Microsoft's MSIX submission rules:
1. All packaged Win32 / Desktop Bridge (`runFullTrust`) desktop apps must provide a privacy policy, even when they do not collect personal information.
2. Because QuMeter declares `internetClientServer` and `privateNetworkClientServer` capabilities for network SNMP scanning, Partner Center automatically flags the submission as capable of transmitting/accessing network data and requires either a **Privacy Policy URL** or **pasted privacy policy text** on the Properties page.

### Ready-to-Use Privacy Policy Text (can be hosted at quspace.studio or pasted into Partner Center)

> **Privacy Policy for QuMeter**  
> *Published by QuSpace Studios LLC*  
> *Effective Date: November 25, 2026*  
>
> **Information We Collect and Process**  
> QuMeter does not collect, sell, or transmit personal information, telemetry, analytics, or advertising data to QuSpace Studios LLC or any third party.  
>
> **Local Data and Network Access**  
> QuMeter uses your local network and internet permissions solely to send SNMP queries to the printer IP addresses you configure and to export meter reports to folders you select. Configuration files, imported fleet lists, logs, and exported reports are stored locally on your device (in `%LOCALAPPDATA%\QuMeter` or your chosen output folders).  
>
> **Third-Party Sharing**  
> QuMeter does not share your data with third parties. If you choose to click "Send feedback" or "Report on GitHub" from the About window, your default email client or browser will open so you can voluntarily contact `dylan@quspace.studio` or submit an issue on GitHub.  
>
> **Your Controls**  
> You can view, edit, or delete locally stored settings, imported lists, logs, and exported files at any time, or uninstall QuMeter through Windows Settings.  
>
> **Contact**  
> For privacy questions, contact QuSpace Studios LLC at `dylan@quspace.studio`.
