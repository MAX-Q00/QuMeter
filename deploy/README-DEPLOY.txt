QuMeter Auto - deployment package
=================================

Use this when QuMeter's "Deploy" button can't reach the server (WinRM and the
admin share are blocked). Copy this folder to the target machine (for example
the PaperCut server) and:

  1. Right-click Install.bat > Run as administrator.
     - Copies the engine to C:\ProgramData\QuMeter (or the path chosen in QuMeter).
     - Registers the "QuMeter Auto" scheduled task to run whether anyone is logged on
       or not (SYSTEM by default; choose a service account in QuMeter or run
       Install.ps1 -RunAs Account to be prompted for one).
     - Runs it once and prints the result.
  2. If this package includes apikey.install, it is converted to a DPAPI-protected
     apikey.dat on install. DELETE this folder and the zip afterwards - they contain
     the API key in plain text.
  3. Uninstall.bat removes the task and program files (keeps output and logs).
  4. RunOnce.bat triggers a run on demand.

Output: C:\ProgramData\QuMeter\output (or the folder set in QuMeter; can be a UNC
share like \\fileserver\meters). If you use a UNC share and the task runs as
SYSTEM, the server's computer account (SERVER$) needs write access to that share.
A domain service account with write access is the simpler choice.

Each run writes: QuMeter_<stamp>.csv (general), QuMeter_eautomate_<stamp>.csv,
optional QuMeter_mps_<stamp>.csv, logs\QuMeter_<date>.log and logs\status.json
(the signed status that QuMeter's Automate tab reads).

Requirements on the server: Windows PowerShell 5.1 (built in), and UDP 161 (SNMP)
reachable from the server to every printer.
