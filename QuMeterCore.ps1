# QuMeterCore.ps1 - shared automation logic for QuMeter (GUI Automate tab, headless engine, deploy installer).
# Windows PowerShell 5.1 compatible. No third-party modules.
$script:QmCoreRoot = $PSScriptRoot
if (-not $script:QmCoreRoot) { $script:QmCoreRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:QmVersion = '2.1.0'
$script:QmEntropy = [System.Text.Encoding]::UTF8.GetBytes('QuMeter-apikey-v1')
$script:QmEngineFiles = @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1')

function Get-QmVersion { $script:QmVersion }
function Join-QmWinPath {
    # Join for Windows paths that may not exist on this machine (remote drive letters); Join-Path would fail.
    param([Parameter(Mandatory)][string]$Base, [Parameter(Mandatory)][string]$Child)
    return ($Base.TrimEnd('\','/') + '\' + $Child.TrimStart('\','/'))
}
function Test-QmIsWindows { return ([System.Environment]::OSVersion.Platform -eq 'Win32NT') }

# ---------------------------------------------------------------- config
function Get-QmDefaultConfig {
    [ordered]@{
        community     = 'public'
        version       = 'v2c'
        port          = 161
        timeoutMs     = 1500
        retries       = 1
        concurrency   = 32
        targets       = @()
        targetFile    = ''
        outputFolder  = 'output'
        mpsDropFolder = ''
        logFolder     = 'logs'
        mappingFile   = 'e-automate.mapping.json'
        eaFormat      = 'basic'
        eaSource      = 'SNMP'
        retentionDays = 90
        schedule      = [ordered]@{
            taskName   = 'QuMeter Auto'
            frequency  = 'Daily'
            time       = '06:00'
            dayOfWeek  = 'Monday'
            dayOfMonth = '1'
            runAs      = 'CurrentUser'   # CurrentUser | SYSTEM | Account
            runAsUser  = ''
        }
        deploy        = [ordered]@{
            target          = ''
            installPath     = 'C:\ProgramData\QuMeter'
            adminShare      = ''          # blank = drive letter + $ (C$)
            method          = 'Auto'      # Auto | WinRM | AdminShare
            runAs           = 'SYSTEM'    # SYSTEM | Account
            runAsUser       = ''
            outputFolder    = 'output'
            mpsDropFolder   = ''
            useCurrentLogin = $true
            runAfterDeploy  = $true
            runTimeoutMin   = 15
        }
    }
}

function ConvertTo-QmHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-QmHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-QmHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($i in $InputObject) { $list += ,(ConvertTo-QmHashtable $i) }
        return ,$list
    }
    return $InputObject
}

function Merge-QmConfig {
    param($Defaults, $Overrides)
    $out = [ordered]@{}
    foreach ($k in $Defaults.Keys) { $out[$k] = $Defaults[$k] }
    if ($null -eq $Overrides) { return $out }
    foreach ($k in $Overrides.Keys) {
        $d = $out[$k]; $v = $Overrides[$k]
        if ($d -is [System.Collections.IDictionary] -and $v -is [System.Collections.IDictionary]) { $out[$k] = Merge-QmConfig $d $v }
        elseif ($null -ne $v) { $out[$k] = $v }
    }
    return $out
}

function ConvertTo-QmTargetList {
    param($Value)
    $list = @()
    if ($null -eq $Value) { return ,$list }
    $items = @()
    if ($Value -is [string]) { $items = $Value -split '\r\n|\n|\r' } else { $items = @($Value) }
    foreach ($i in $items) {
        $s = "$i".Trim()
        if ($s) { $list += $s }
    }
    return ,$list
}

function Read-QmConfig {
    param([string]$Path)
    $cfg = Get-QmDefaultConfig
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $obj = ConvertTo-QmHashtable ($raw | ConvertFrom-Json)
            $cfg = Merge-QmConfig $cfg $obj
        }
    }
    $cfg.targets = ConvertTo-QmTargetList $cfg.targets
    foreach ($k in @('port','timeoutMs','retries','concurrency','retentionDays')) { $cfg[$k] = [int]$cfg[$k] }
    $cfg.deploy.useCurrentLogin = [bool]$cfg.deploy.useCurrentLogin
    $cfg.deploy.runAfterDeploy  = [bool]$cfg.deploy.runAfterDeploy
    $cfg.deploy.runTimeoutMin   = [int]$cfg.deploy.runTimeoutMin
    $cfg.schedule.dayOfMonth    = "$($cfg.schedule.dayOfMonth)"
    # never keep a secret in config.json even if someone typed one in
    foreach ($bad in @('apiKey','password','apikey')) { if ($cfg.Contains($bad)) { $cfg.Remove($bad) } }
    return $cfg
}

function Save-QmConfig {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Path)
    $copy = Merge-QmConfig ([ordered]@{}) $Config
    foreach ($bad in @('apiKey','password','apikey')) { if ($copy.Contains($bad)) { $copy.Remove($bad) } }
    $copy.targets = [string[]](ConvertTo-QmTargetList $copy.targets)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = $copy | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Import-QmLegacyConfig {
    # Pull settings from an old QuMeter Auto folder (config.json + devices.txt).
    param([Parameter(Mandatory)][string]$LegacyDir)
    $cfgPath = Join-Path $LegacyDir 'config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    $cfg = Read-QmConfig $cfgPath
    $devPath = $null
    if ($cfg.targetFile) {
        $devPath = $cfg.targetFile
        if (-not [System.IO.Path]::IsPathRooted($devPath)) { $devPath = Join-Path $LegacyDir $devPath }
    }
    if ($devPath -and (Test-Path -LiteralPath $devPath)) {
        $lines = Get-Content -LiteralPath $devPath | ForEach-Object { ($_ -replace '#.*$','').Trim() } | Where-Object { $_ }
        $cfg.targets = ConvertTo-QmTargetList (@($cfg.targets) + @($lines))
    }
    $cfg.targetFile = ''
    foreach ($k in @('outputFolder','logFolder','mpsDropFolder')) {
        $v = "$($cfg[$k])"
        if ($v -and -not [System.IO.Path]::IsPathRooted($v)) { $cfg[$k] = Join-Path $LegacyDir $v }
    }
    $cfg.mappingFile = 'e-automate.mapping.json'
    return $cfg
}

function Test-QmTimeString { param([string]$Time) return ($Time -match '^([01]?\d|2[0-3]):[0-5]\d$') }

function Test-QmConfig {
    # Returns a list of human-readable problems (empty = OK).
    param([Parameter(Mandatory)]$Config, [string]$Root)
    $errs = New-Object System.Collections.Generic.List[string]
    $hasTargets = (@($Config.targets).Count -gt 0)
    if (-not $hasTargets -and $Config.targetFile) {
        $tf = $Config.targetFile
        if ($Root -and -not [System.IO.Path]::IsPathRooted($tf)) { $tf = Join-Path $Root $tf }
        $hasTargets = Test-Path -LiteralPath $tf
    }
    if (-not $hasTargets) { $errs.Add('No printers listed. Add IPs, ranges, or CIDR blocks.') }
    if (@('v1','v2c') -notcontains "$($Config.version)") { $errs.Add("SNMP version must be v1 or v2c (got '$($Config.version)').") }
    if (-not "$($Config.community)") { $errs.Add('SNMP community is empty.') }
    if ([int]$Config.port -lt 1 -or [int]$Config.port -gt 65535) { $errs.Add('Port must be 1-65535.') }
    if ([int]$Config.timeoutMs -lt 100) { $errs.Add('Timeout must be at least 100 ms.') }
    if ([int]$Config.retentionDays -lt 0) { $errs.Add('Retention days cannot be negative (0 = keep forever).') }
    if (-not "$($Config.outputFolder)") { $errs.Add('Output folder is empty.') }
    if (@('basic','advanced') -notcontains "$($Config.eaFormat)") { $errs.Add('e-automate format must be basic or advanced.') }
    $s = $Config.schedule
    if (-not (Test-QmTimeString $s.time)) { $errs.Add("Schedule time must be HH:mm (got '$($s.time)').") }
    if (@('Daily','Weekly','Monthly') -notcontains "$($s.frequency)") { $errs.Add('Frequency must be Daily, Weekly, or Monthly.') }
    if ($s.frequency -eq 'Weekly' -and @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') -notcontains "$($s.dayOfWeek)") { $errs.Add('Pick a day of the week.') }
    if ($s.frequency -eq 'Monthly') {
        $d = "$($s.dayOfMonth)"
        if ($d -ne 'Last' -and -not ($d -match '^\d+$' -and [int]$d -ge 1 -and [int]$d -le 28)) { $errs.Add('Day of month must be 1-28 or Last.') }
    }
    if (-not "$($s.taskName)") { $errs.Add('Task name is empty.') }
    return ,$errs
}

function Resolve-QmPath {
    param([string]$Path, [string]$Root)
    if (-not $Path) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $Root $Path)
}

# ---------------------------------------------------------------- API key, HMAC, DPAPI
function New-QmApiKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes); $rng.Dispose()
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) { [void]$sb.Append($alphabet[$b % $alphabet.Length]) }
    return 'qm_' + $sb.ToString()
}

function Get-QmHmac {
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $h = New-Object System.Security.Cryptography.HMACSHA256 (,[System.Text.Encoding]::UTF8.GetBytes($Key))
    try { $hash = $h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) } finally { $h.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-QmEqualConstantTime {
    param([string]$A, [string]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ([int][char]$A[$i] -bxor [int][char]$B[$i]) }
    return ($diff -eq 0)
}

function New-QmSignedEnvelope {
    # Wraps an object as {payload:"<json>", hmac:"hex"|null, signed:bool}
    param([Parameter(Mandatory)]$Object, [string]$Key)
    $payload = $Object | ConvertTo-Json -Depth 8 -Compress
    $env = [ordered]@{ format = 'QuMeter-signed-v1'; signed = $false; alg = $null; hmac = $null; payload = $payload }
    if ($Key) { $env.signed = $true; $env.alg = 'HMAC-SHA256'; $env.hmac = Get-QmHmac -Key $Key -Text $payload }
    return ($env | ConvertTo-Json -Depth 3)
}

function Read-QmSignedEnvelope {
    # Returns @{ Data; Signed; Verified; Problem }. Verified=$true only when the HMAC matches $Key.
    param([Parameter(Mandatory)][string]$Json, [string]$Key)
    $r = [ordered]@{ Data = $null; Signed = $false; Verified = $false; Problem = $null }
    try { $env = $Json | ConvertFrom-Json } catch { $r.Problem = "Unreadable status/request file: $($_.Exception.Message)"; return $r }
    if (-not $env.payload) { $r.Problem = 'File has no payload (not a QuMeter signed file).'; return $r }
    try { $r.Data = $env.payload | ConvertFrom-Json } catch { $r.Problem = "Payload is not valid JSON: $($_.Exception.Message)"; return $r }
    $r.Signed = [bool]$env.signed
    if ($r.Signed) {
        if (-not $Key) { $r.Problem = 'File is signed but no API key is set here, so it cannot be verified.' }
        elseif (Test-QmEqualConstantTime (Get-QmHmac -Key $Key -Text $env.payload) "$($env.hmac)") { $r.Verified = $true }
        else { $r.Problem = 'API key mismatch: the signature does not match this API key (wrong key, or the file was altered).' }
    } else {
        if ($Key) { $r.Problem = 'File is NOT signed: the deployed instance has no API key installed.' }
    }
    return $r
}

function Initialize-QmDpapi { if (Test-QmIsWindows) { Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue } }

function Protect-QmSecret {
    param([Parameter(Mandatory)][string]$Secret, [ValidateSet('CurrentUser','LocalMachine')][string]$Scope = 'CurrentUser')
    if (-not (Test-QmIsWindows)) { throw 'DPAPI is only available on Windows.' }
    Initialize-QmDpapi
    $s = [System.Security.Cryptography.DataProtectionScope]::$Scope
    $enc = [System.Security.Cryptography.ProtectedData]::Protect([System.Text.Encoding]::UTF8.GetBytes($Secret), $script:QmEntropy, $s)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-QmSecret {
    param([Parameter(Mandatory)][string]$Blob, [ValidateSet('CurrentUser','LocalMachine')][string]$Scope = 'CurrentUser')
    if (-not (Test-QmIsWindows)) { throw 'DPAPI is only available on Windows.' }
    Initialize-QmDpapi
    $s = [System.Security.Cryptography.DataProtectionScope]::$Scope
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Blob.Trim()), $script:QmEntropy, $s)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}

function Set-QmSecretFileAcl {
    # Locks a key file to SYSTEM + Administrators (+ optional run-as / current user). Best effort.
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExtraAccounts)
    if (-not (Test-QmIsWindows)) { return }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $ids = @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators') + @($ExtraAccounts | Where-Object { $_ })
    foreach ($id in $ids) {
        try {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
        } catch { }
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Save-QmUserApiKey {
    # GUI copy of the key: DPAPI CurrentUser, so only this Windows user on this PC can read it.
    param([string]$Key, [Parameter(Mandatory)][string]$Path)
    if (-not $Key) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }; return }
    [System.IO.File]::WriteAllText($Path, (Protect-QmSecret -Secret $Key -Scope CurrentUser))
}

function Read-QmUserApiKey {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { return Unprotect-QmSecret -Blob ([System.IO.File]::ReadAllText($Path)) -Scope CurrentUser } catch { return '' }
}

function Install-QmMachineApiKey {
    # Instance copy of the key: DPAPI LocalMachine in apikey.dat, ACL-locked. Empty key removes it.
    param([string]$Key, [Parameter(Mandatory)][string]$Dir, [string[]]$ExtraAccounts)
    $dat = Join-Path $Dir 'apikey.dat'
    if (-not $Key) { if (Test-Path -LiteralPath $dat) { Remove-Item -LiteralPath $dat -Force }; return }
    [System.IO.File]::WriteAllText($dat, (Protect-QmSecret -Secret $Key -Scope LocalMachine))
    try { Set-QmSecretFileAcl -Path $dat -ExtraAccounts $ExtraAccounts } catch { }
}

function Get-QmInstanceApiKey {
    # Used by the engine. Converts a one-time apikey.install (plain, from admin-share deploy or package) to apikey.dat.
    param([Parameter(Mandatory)][string]$Dir, [ref]$Note)
    $inst = Join-Path $Dir 'apikey.install'
    $dat  = Join-Path $Dir 'apikey.dat'
    if (Test-Path -LiteralPath $inst) {
        $plain = ([System.IO.File]::ReadAllText($inst)).Trim()
        if (Test-QmIsWindows) {
            try {
                Install-QmMachineApiKey -Key $plain -Dir $Dir -ExtraAccounts @([Security.Principal.WindowsIdentity]::GetCurrent().Name)
                Remove-Item -LiteralPath $inst -Force
                if ($Note) { $Note.Value = 'Converted apikey.install to DPAPI-protected apikey.dat.' }
            } catch { if ($Note) { $Note.Value = "Could not protect apikey.install: $($_.Exception.Message)" } }
        }
        return $plain
    }
    if (Test-Path -LiteralPath $dat) {
        try { return Unprotect-QmSecret -Blob ([System.IO.File]::ReadAllText($dat)) -Scope LocalMachine }
        catch { if ($Note) { $Note.Value = "apikey.dat could not be decrypted on this machine: $($_.Exception.Message)" }; return '' }
    }
    return ''
}

# ---------------------------------------------------------------- run requests (GUI -> instance)
function New-QmRunRequest {
    param([string]$Key, [string]$Target)
    $id = [guid]::NewGuid().ToString()
    $payload = [ordered]@{ action = 'run'; requestId = $id; issuedAtUtc = [DateTime]::UtcNow.ToString('o'); target = $Target; from = "$env:COMPUTERNAME" }
    return @{ RequestId = $id; Json = (New-QmSignedEnvelope -Object $payload -Key $Key) }
}

function Test-QmRunRequest {
    # Returns @{ Accepted; RequestId; Reason }
    param([Parameter(Mandatory)][string]$Json, [string]$InstanceKey, [int]$MaxAgeMinutes = 60)
    $res = @{ Accepted = $false; RequestId = $null; Reason = $null }
    $env = Read-QmSignedEnvelope -Json $Json -Key $InstanceKey
    if ($env.Data) { $res.RequestId = "$($env.Data.requestId)" }
    if (-not $env.Data) { $res.Reason = $env.Problem; return $res }
    if ($env.Data.action -ne 'run') { $res.Reason = "Unknown request action '$($env.Data.action)'."; return $res }
    if ($InstanceKey) {
        if (-not $env.Signed) { $res.Reason = 'Run request rejected: it is not signed, but this instance requires the API key.'; return $res }
        if (-not $env.Verified) { $res.Reason = 'Run request rejected: API key mismatch. Update the API key in QuMeter or redeploy.'; return $res }
    }
    try {
        $iv = $env.Data.issuedAtUtc
        if ($iv -is [datetime]) { $issued = $iv.ToUniversalTime() }
        else { $issued = [DateTime]::Parse("$iv", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
        $age = ([DateTime]::UtcNow - $issued).TotalMinutes
        if ($age -gt $MaxAgeMinutes -or $age -lt -10) { $res.Reason = "Run request rejected: it is stale ($([int]$age) min old)."; return $res }
    } catch { $res.Reason = 'Run request rejected: bad timestamp.'; return $res }
    $res.Accepted = $true
    return $res
}

# ---------------------------------------------------------------- status (instance -> GUI)
function ConvertTo-QmStatusText {
    # One-paragraph human summary of a status payload object.
    param($Status, $Envelope)
    if (-not $Status) { return 'No status available.' }
    $run = $Status.run
    $lines = @()
    $state = if ($run.success) { 'SUCCESS' } elseif ($run.partial) { 'COMPLETED WITH ERRORS' } else { 'FAILED' }
    $lines += "Last run: $state  ($($run.trigger))"
    $lines += "Started: $($run.startedAt)   Finished: $($run.finishedAt)   ($($run.durationSec)s)"
    $lines += "Instance: $($Status.instance.computer)  $($Status.instance.installDir)  as $($Status.instance.user)  v$($Status.instance.version)"
    if ($Status.counts) { $lines += "Printers: $($Status.counts.hosts) queried, $($Status.counts.ok) OK ($($Status.counts.withSerial) with serial), $($Status.counts.timeout) timed out, $($Status.counts.error) errors" }
    if ($run.error) { $lines += "ERROR [$($run.errorStage)]: $($run.error)" }
    foreach ($w in @($Status.writeErrors)) { if ($w) { $lines += "WRITE ERROR: $w" } }
    foreach ($w in @($Status.warnings)) { if ($w) { $lines += "Warning: $w" } }
    if ($Status.files) {
        foreach ($p in @('general','eautomate','mps')) { if ($Status.files.$p) { $lines += "File: $($Status.files.$p)" } }
    }
    if ($Envelope) {
        if ($Envelope.Verified) { $lines += 'Authenticity: verified with your API key.' }
        elseif ($Envelope.Problem) { $lines += "Authenticity: $($Envelope.Problem)" }
        else { $lines += 'Authenticity: unsigned (no API key set on either side).' }
    }
    return ($lines -join "`r`n")
}

# ---------------------------------------------------------------- scheduled task XML
function ConvertTo-QmXmlText { param([string]$s) return [System.Security.SecurityElement]::Escape("$s") }

function Get-QmEngineArguments {
    param([Parameter(Mandatory)][string]$InstallDir)
    $engine = Join-QmWinPath $InstallDir 'QuMeterEngine.ps1'
    $cfg = Join-QmWinPath $InstallDir 'config.json'
    return "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$engine`" -ConfigPath `"$cfg`""
}

function New-QmTaskXml {
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][string]$InstallDir,
        [ValidateSet('CurrentUser','SYSTEM','Account')][string]$RunAs = 'SYSTEM',
        [string]$UserId,
        [datetime]$StartDate = [datetime]::Today
    )
    $t = [TimeSpan]::Parse("$($Schedule.time)")
    $start = $StartDate.Date.Add($t).ToString('yyyy-MM-ddTHH:mm:ss')
    switch ("$($Schedule.frequency)") {
        'Weekly'  { $sched = "<ScheduleByWeek><DaysOfWeek><$($Schedule.dayOfWeek) /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek>" }
        'Monthly' {
            $months = (@('January','February','March','April','May','June','July','August','September','October','November','December') | ForEach-Object { "<$_ />" }) -join ''
            $sched = "<ScheduleByMonth><DaysOfMonth><Day>$(ConvertTo-QmXmlText $Schedule.dayOfMonth)</Day></DaysOfMonth><Months>$months</Months></ScheduleByMonth>"
        }
        default   { $sched = '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay>' }
    }
    switch ($RunAs) {
        'SYSTEM'  { $principal = '<UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel>' }
        'Account' {
            if (-not $UserId) { throw 'A run-as account name is required.' }
            $principal = "<UserId>$(ConvertTo-QmXmlText $UserId)</UserId><LogonType>Password</LogonType><RunLevel>HighestAvailable</RunLevel>"
        }
        default {
            if (-not $UserId) { $UserId = "$env:USERDOMAIN\$env:USERNAME" }
            $principal = "<UserId>$(ConvertTo-QmXmlText $UserId)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel>"
        }
    }
    $desc = "QuMeter Auto $script:QmVersion - reads printer lifetime meters over SNMP and writes dated general / e-automate / MPS CSV files. Installed in $InstallDir."
    $psExe = '%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe'
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>QuMeter</Author>
    <Description>$(ConvertTo-QmXmlText $desc)</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
      $sched
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">$principal</Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-QmXmlText $psExe)</Command>
      <Arguments>$(ConvertTo-QmXmlText (Get-QmEngineArguments -InstallDir $InstallDir))</Arguments>
      <WorkingDirectory>$(ConvertTo-QmXmlText $InstallDir)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
}

function Get-QmScheduleText {
    param($Schedule)
    switch ("$($Schedule.frequency)") {
        'Weekly'  { "every $($Schedule.dayOfWeek) at $($Schedule.time)" }
        'Monthly' { if ("$($Schedule.dayOfMonth)" -eq 'Last') { "on the last day of each month at $($Schedule.time)" } else { "on day $($Schedule.dayOfMonth) of each month at $($Schedule.time)" } }
        default   { "daily at $($Schedule.time)" }
    }
}

# ---------------------------------------------------------------- local task (this PC)
function Install-QmLocalTask {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppDir, [pscredential]$RunAsCredential, [string]$ApiKey)
    $s = $Config.schedule
    $user = $null
    if ($s.runAs -eq 'Account') {
        if (-not $RunAsCredential) { throw 'Run-as account credentials are required.' }
        $user = $RunAsCredential.UserName
    } elseif ($s.runAs -eq 'CurrentUser') { $user = "$env:USERDOMAIN\$env:USERNAME" }
    $xml = New-QmTaskXml -Schedule $s -InstallDir $AppDir -RunAs $s.runAs -UserId $user
    if ($s.runAs -eq 'Account') {
        Register-ScheduledTask -Xml $xml -TaskName $s.taskName -User $user -Password $RunAsCredential.GetNetworkCredential().Password -Force | Out-Null
    } else {
        Register-ScheduledTask -Xml $xml -TaskName $s.taskName -Force | Out-Null
    }
    $extra = @("$env:USERDOMAIN\$env:USERNAME"); if ($user) { $extra += $user }
    if ($ApiKey) { Install-QmMachineApiKey -Key $ApiKey -Dir $AppDir -ExtraAccounts $extra }
    return Get-QmLocalTaskStatus -TaskName $s.taskName
}

function Remove-QmLocalTask {
    param([Parameter(Mandatory)][string]$TaskName)
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        return $true
    }
    return $false
}

function Format-QmTaskResult {
    param($Code)
    if ($null -eq $Code -or "$Code" -eq '') { return '' }
    $n = [int64]0
    if (-not [int64]::TryParse("$Code", [ref]$n)) { return "$Code" }
    $u = [uint32]($n -band 0xFFFFFFFF)
    $known = @{ 0 = 'success'; 1 = 'engine error (see status/log)'; 2 = 'completed with errors (see status)'; 3 = 'run request rejected (API key)'; 267009 = 'currently running'; 267011 = 'has not run yet'; 267014 = 'terminated by user'; 2147750687 = 'already running'; 2147942402 = 'file not found' }
    $txt = $known[[int64]$u]
    return ('0x{0:X} {1}' -f $u, $txt).Trim()
}

function Get-QmLocalTaskStatus {
    param([Parameter(Mandatory)][string]$TaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return [pscustomobject]@{ Exists = $false; State = 'Not installed'; LastRunTime = $null; LastResult = ''; NextRunTime = $null; RunAs = '' } }
    $i = $t | Get-ScheduledTaskInfo
    return [pscustomobject]@{ Exists = $true; State = "$($t.State)"; LastRunTime = $i.LastRunTime; LastResult = (Format-QmTaskResult $i.LastTaskResult); NextRunTime = $i.NextRunTime; RunAs = "$($t.Principal.UserId)" }
}

# ---------------------------------------------------------------- deploy staging / package
function Get-QmUncPath {
    # C:\ProgramData\QuMeter on TARGET -> \\TARGET\C$\ProgramData\QuMeter (share overridable)
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$LocalPath, [string]$Share)
    if ($LocalPath -notmatch '^([A-Za-z]):\\?(.*)$') { throw "Install path must be a local drive path like C:\ProgramData\QuMeter (got '$LocalPath')." }
    $drive = $Matches[1]; $rest = $Matches[2].TrimEnd('\')
    if (-not $Share) { $Share = "$($drive.ToUpper())`$" }
    $root = "\\$Target\$Share"
    return @{ ShareRoot = $root; Path = $(if ($rest) { "$root\$rest" } else { $root }); Rest = $rest }
}

function New-QmTargetConfig {
    # The config that gets copied to the deployed instance (no deploy block, target-specific folders, logs inside install dir).
    param([Parameter(Mandatory)]$Config, [string]$AppDir)
    $c = Merge-QmConfig (Get-QmDefaultConfig) $Config
    $targets = @(ConvertTo-QmTargetList $c.targets)
    if ($c.targetFile -and $AppDir) {
        $tf = Resolve-QmPath $c.targetFile $AppDir
        if (Test-Path -LiteralPath $tf) {
            $targets += @(Get-Content -LiteralPath $tf | ForEach-Object { ($_ -replace '#.*$','').Trim() } | Where-Object { $_ })
        }
    }
    $c.targets = [string[]](ConvertTo-QmTargetList $targets)
    $c.targetFile = ''
    $c.outputFolder = $(if ($c.deploy.outputFolder) { $c.deploy.outputFolder } else { 'output' })
    $c.mpsDropFolder = "$($c.deploy.mpsDropFolder)"
    $c.logFolder = 'logs'
    $c.mappingFile = 'e-automate.mapping.json'
    $c.schedule.runAs = $c.deploy.runAs
    $c.schedule.runAsUser = $c.deploy.runAsUser
    $c.Remove('deploy')
    return $c
}

function New-QmStaging {
    # Copies engine files + mapping + target config into a fresh temp folder. Returns the folder path.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppDir, [string]$ApiKey, [switch]$IncludeInstaller)
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ('QuMeterDeploy_' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($f in $script:QmEngineFiles) {
        $src = Join-Path $AppDir $f
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing engine file: $src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f)
    }
    $map = Resolve-QmPath $(if ($Config.mappingFile) { $Config.mappingFile } else { 'e-automate.mapping.json' }) $AppDir
    if (Test-Path -LiteralPath $map) { Copy-Item -LiteralPath $map -Destination (Join-Path $stage 'e-automate.mapping.json') }
    $tc = New-QmTargetConfig -Config $Config -AppDir $AppDir
    Save-QmConfig -Config $tc -Path (Join-Path $stage 'config.json')
    if ($IncludeInstaller) {
        foreach ($f in @('Install.ps1','Install.bat','Uninstall.bat','RunOnce.bat','README-DEPLOY.txt')) {
            $src = Join-Path (Join-Path $AppDir 'deploy') $f
            if (-not (Test-Path -LiteralPath $src)) { throw "Missing installer file: $src" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $stage $f)
        }
        $meta = [ordered]@{ version = $script:QmVersion; installPath = $Config.deploy.installPath; createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); createdOn = "$env:COMPUTERNAME"; hasApiKey = [bool]$ApiKey }
        ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $stage 'package.json') -Encoding UTF8
    }
    if ($ApiKey) { [System.IO.File]::WriteAllText((Join-Path $stage 'apikey.install'), $ApiKey) }
    return $stage
}

function New-QmDeployPackage {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppDir, [Parameter(Mandatory)][string]$OutZip, [string]$ApiKey)
    $stage = New-QmStaging -Config $Config -AppDir $AppDir -ApiKey $ApiKey -IncludeInstaller
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }
        $dir = Split-Path -Parent $OutZip
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $OutZip)
    } finally { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    return $OutZip
}

# ---------------------------------------------------------------- remote connection (GUI -> deployed instance)
function Write-QmOpLog { param([scriptblock]$Log, [string]$Message) if ($Log) { & $Log $Message } else { Write-Verbose $Message } }

function New-QmRemoteContext {
    # Opens the channel to TARGET: WinRM (preferred) or admin share + schtasks.exe. Throws with a clear message on failure.
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$InstallPath,
        [string]$AdminShare,
        [ValidateSet('Auto','WinRM','AdminShare')][string]$Method = 'Auto',
        [pscredential]$Credential,
        [scriptblock]$Log
    )
    $ctx = [ordered]@{ Target = $Target; InstallPath = $InstallPath; Method = $null; Session = $null; Credential = $Credential; Drive = $null; RemoteDir = $null; Problems = @() }
    if ($Method -ne 'AdminShare') {
        Write-QmOpLog $Log "Connecting to $Target over WinRM..."
        try {
            $opt = New-PSSessionOption -OpenTimeout 20000 -OperationTimeout 600000
            $p = @{ ComputerName = $Target; SessionOption = $opt; ErrorAction = 'Stop' }
            if ($Credential) { $p.Credential = $Credential }
            $ctx.Session = New-PSSession @p
            $ctx.Method = 'WinRM'
            Write-QmOpLog $Log 'WinRM connected.'
            return $ctx
        } catch {
            $msg = "WinRM to $Target failed: $($_.Exception.Message)"
            $ctx.Problems += $msg
            Write-QmOpLog $Log $msg
            if ($Method -eq 'WinRM') { throw "$msg`nFix: run 'Enable-PSRemoting -Force' on $Target (admin), allow TCP 5985 in its firewall, use the computer name (not IP) on a domain, or add the IP to TrustedHosts on this PC. Or switch the method to Admin share." }
        }
    }
    Write-QmOpLog $Log "Connecting to $Target admin share..."
    $unc = Get-QmUncPath -Target $Target -LocalPath $InstallPath -Share $AdminShare
    $name = 'QmT' + [guid]::NewGuid().ToString('N').Substring(0,6)
    try {
        $p = @{ Name = $name; PSProvider = 'FileSystem'; Root = $unc.ShareRoot; Scope = 'Script'; ErrorAction = 'Stop' }
        if ($Credential) { $p.Credential = $Credential }
        New-PSDrive @p | Out-Null
    } catch {
        $msg = "Admin share $($unc.ShareRoot) failed: $($_.Exception.Message)"
        $ctx.Problems += $msg
        throw (($ctx.Problems -join "`n") + "`nFix: the account must be a local admin on $Target, File and Printer Sharing (TCP 445) must be allowed, and the admin share must exist. Or use Export deployment package and run Install.bat on $Target.")
    }
    $ctx.Drive = $name
    $ctx.RemoteDir = $(if ($unc.Rest) { "${name}:\$($unc.Rest)" } else { "${name}:\" })
    $ctx.Method = 'AdminShare'
    Write-QmOpLog $Log "Admin share connected ($($unc.Path)). Task commands will use schtasks.exe /S $Target."
    return $ctx
}

function Close-QmRemoteContext {
    param($Ctx)
    if (-not $Ctx) { return }
    if ($Ctx.Session) { try { Remove-PSSession $Ctx.Session } catch { } }
    if ($Ctx.Drive) { try { Remove-PSDrive -Name $Ctx.Drive -Scope Script -Force } catch { } }
}

function Invoke-QmSchtasks {
    param($Ctx, [string[]]$Arguments, [pscredential]$RunAsCredential, [switch]$AllowFail)
    $a = @('/S', $Ctx.Target)
    if ($Ctx.Credential) { $a += @('/U', $Ctx.Credential.UserName, '/P', $Ctx.Credential.GetNetworkCredential().Password) }
    $a += $Arguments
    if ($RunAsCredential) { $a += @('/RU', $RunAsCredential.UserName, '/RP', $RunAsCredential.GetNetworkCredential().Password) }
    $out = & schtasks.exe @a 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) { throw "schtasks failed (exit $code): $($out.Trim())" }
    return @{ Code = $code; Output = $out }
}

function Copy-QmToTarget {
    param($Ctx, [Parameter(Mandatory)][string]$StageDir, [scriptblock]$Log)
    $files = Get-ChildItem -LiteralPath $StageDir -File
    if ($Ctx.Method -eq 'WinRM') {
        Invoke-Command -Session $Ctx.Session -ScriptBlock { param($d) New-Item -ItemType Directory -Path $d -Force | Out-Null; foreach ($s in @('logs','output')) { New-Item -ItemType Directory -Path (Join-Path $d $s) -Force | Out-Null } } -ArgumentList $Ctx.InstallPath -ErrorAction Stop
        foreach ($f in $files) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-QmWinPath $Ctx.InstallPath $f.Name) -ToSession $Ctx.Session -Force -ErrorAction Stop
            Write-QmOpLog $Log "  copied $($f.Name)"
        }
    } else {
        New-Item -ItemType Directory -Path $Ctx.RemoteDir -Force -ErrorAction Stop | Out-Null
        foreach ($s in @('logs','output')) { New-Item -ItemType Directory -Path (Join-Path $Ctx.RemoteDir $s) -Force | Out-Null }
        foreach ($f in $files) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Ctx.RemoteDir $f.Name) -Force -ErrorAction Stop
            Write-QmOpLog $Log "  copied $($f.Name)"
        }
    }
}

function Read-QmRemoteFile {
    param($Ctx, [Parameter(Mandatory)][string]$RelativePath, [int]$Tail = 0)
    if ($Ctx.Method -eq 'WinRM') {
        return Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($p, $t)
            if (-not (Test-Path -LiteralPath $p)) { return $null }
            if ($t -gt 0) { return ((Get-Content -LiteralPath $p -Tail $t) -join "`r`n") }
            return [System.IO.File]::ReadAllText($p)
        } -ArgumentList (Join-QmWinPath $Ctx.InstallPath $RelativePath), $Tail -ErrorAction Stop
    }
    $path = Join-Path $Ctx.RemoteDir $RelativePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if ($Tail -gt 0) { return ((Get-Content -LiteralPath $path -Tail $Tail) -join "`r`n") }
    return (Get-Content -LiteralPath $path -Raw)
}

function Write-QmRemoteFile {
    param($Ctx, [Parameter(Mandatory)][string]$RelativePath, [Parameter(Mandatory)][string]$Content)
    if ($Ctx.Method -eq 'WinRM') {
        Invoke-Command -Session $Ctx.Session -ScriptBlock { param($p, $c) [System.IO.File]::WriteAllText($p, $c) } -ArgumentList (Join-QmWinPath $Ctx.InstallPath $RelativePath), $Content -ErrorAction Stop
    } else {
        Set-Content -LiteralPath (Join-Path $Ctx.RemoteDir $RelativePath) -Value $Content -Encoding UTF8 -NoNewline -ErrorAction Stop
    }
}

function Get-QmRemoteLatestLogName {
    param($Ctx)
    if ($Ctx.Method -eq 'WinRM') {
        return Invoke-Command -Session $Ctx.Session -ScriptBlock { param($d) $l = Get-ChildItem -LiteralPath (Join-Path $d 'logs') -Filter 'QuMeter*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($l) { $l.Name } } -ArgumentList $Ctx.InstallPath
    }
    $l = Get-ChildItem -LiteralPath (Join-Path $Ctx.RemoteDir 'logs') -Filter 'QuMeter*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($l) { return $l.Name }
    return $null
}

function Register-QmRemoteTask {
    param($Ctx, [Parameter(Mandatory)]$Schedule, [string]$RunAs = 'SYSTEM', [pscredential]$RunAsCredential, [scriptblock]$Log)
    $user = $null
    if ($RunAs -eq 'Account') { if (-not $RunAsCredential) { throw 'Run-as account credentials are required.' }; $user = $RunAsCredential.UserName }
    $xml = New-QmTaskXml -Schedule $Schedule -InstallDir $Ctx.InstallPath -RunAs $RunAs -UserId $user
    if ($Ctx.Method -eq 'WinRM') {
        Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($xml, $name, $cred)
            if ($cred) { Register-ScheduledTask -Xml $xml -TaskName $name -User $cred.UserName -Password $cred.GetNetworkCredential().Password -Force | Out-Null }
            else { Register-ScheduledTask -Xml $xml -TaskName $name -Force | Out-Null }
        } -ArgumentList $xml, $Schedule.taskName, $RunAsCredential -ErrorAction Stop
    } else {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('qmtask_' + [guid]::NewGuid().ToString('N') + '.xml')
        [System.IO.File]::WriteAllText($tmp, $xml, [System.Text.Encoding]::Unicode)
        try { Invoke-QmSchtasks -Ctx $Ctx -Arguments @('/Create','/TN',$Schedule.taskName,'/XML',$tmp,'/F') -RunAsCredential $RunAsCredential | Out-Null }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    Write-QmOpLog $Log "Registered task '$($Schedule.taskName)' on $($Ctx.Target) ($(Get-QmScheduleText $Schedule), run as $(if ($user) { $user } else { $RunAs }))."
}

function Install-QmRemoteApiKey {
    param($Ctx, [string]$ApiKey, [string]$RunAsUser, [scriptblock]$Log)
    if ($Ctx.Method -eq 'WinRM') {
        Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($dir, $key, $extra)
            Add-Type -AssemblyName System.Security
            $dat = Join-Path $dir 'apikey.dat'; $inst = Join-Path $dir 'apikey.install'
            if (Test-Path -LiteralPath $inst) { Remove-Item -LiteralPath $inst -Force }
            if (-not $key) { if (Test-Path -LiteralPath $dat) { Remove-Item -LiteralPath $dat -Force }; return }
            $enc = [System.Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($key), [Text.Encoding]::UTF8.GetBytes('QuMeter-apikey-v1'), 'LocalMachine')
            [System.IO.File]::WriteAllText($dat, [Convert]::ToBase64String($enc))
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($id in @('NT AUTHORITY\SYSTEM','BUILTIN\Administrators', $extra)) { if ($id) { try { $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id,'FullControl','Allow'))) } catch {} } }
            Set-Acl -LiteralPath $dat -AclObject $acl
        } -ArgumentList $Ctx.InstallPath, $ApiKey, $RunAsUser -ErrorAction Stop
        if ($ApiKey) { Write-QmOpLog $Log 'API key installed on target (DPAPI LocalMachine, apikey.dat locked to SYSTEM/Administrators/run-as).' }
    } else {
        $inst = Join-Path $Ctx.RemoteDir 'apikey.install'
        $dat = Join-Path $Ctx.RemoteDir 'apikey.dat'
        if (-not $ApiKey) { foreach ($p in @($inst,$dat)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }; return }
        if (Test-Path -LiteralPath $dat) { Remove-Item -LiteralPath $dat -Force }
        Set-Content -LiteralPath $inst -Value $ApiKey -Encoding ASCII -NoNewline
        try { Set-QmSecretFileAcl -Path $inst -ExtraAccounts @($RunAsUser) } catch { Write-QmOpLog $Log "Warning: could not lock apikey.install ACL: $($_.Exception.Message)" }
        Write-QmOpLog $Log 'API key copied as apikey.install (ACL-locked); the engine converts it to DPAPI apikey.dat and deletes it on its first run.'
    }
}

function Get-QmRemoteTaskInfo {
    param($Ctx, [Parameter(Mandatory)][string]$TaskName)
    if ($Ctx.Method -eq 'WinRM') {
        $r = Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($n)
            $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
            if (-not $t) { return @{ Exists = $false } }
            $i = $t | Get-ScheduledTaskInfo
            return @{ Exists = $true; State = "$($t.State)"; LastRunTime = $i.LastRunTime; LastTaskResult = $i.LastTaskResult; NextRunTime = $i.NextRunTime; RunAs = "$($t.Principal.UserId)" }
        } -ArgumentList $TaskName -ErrorAction Stop
        if (-not $r.Exists) { return [pscustomobject]@{ Exists = $false; State = 'Not installed'; LastRunTime = $null; LastResult = ''; NextRunTime = $null; RunAs = ''; Raw = '' } }
        return [pscustomobject]@{ Exists = $true; State = $r.State; LastRunTime = $r.LastRunTime; LastResult = (Format-QmTaskResult $r.LastTaskResult); NextRunTime = $r.NextRunTime; RunAs = $r.RunAs; Raw = '' }
    }
    $q = Invoke-QmSchtasks -Ctx $Ctx -Arguments @('/Query','/TN',$TaskName,'/V','/FO','CSV') -AllowFail
    if ($q.Code -ne 0) { return [pscustomobject]@{ Exists = $false; State = 'Not installed'; LastRunTime = $null; LastResult = ''; NextRunTime = $null; RunAs = ''; Raw = $q.Output.Trim() } }
    $row = @($q.Output | ConvertFrom-Csv | Where-Object { $_.TaskName })[0]
    return [pscustomobject]@{ Exists = $true; State = "$($row.Status)"; LastRunTime = "$($row.'Last Run Time')"; LastResult = (Format-QmTaskResult $row.'Last Result'); NextRunTime = "$($row.'Next Run Time')"; RunAs = "$($row.'Run As User')"; Raw = '' }
}

function Start-QmRemoteTask {
    param($Ctx, [Parameter(Mandatory)][string]$TaskName)
    if ($Ctx.Method -eq 'WinRM') { Invoke-Command -Session $Ctx.Session -ScriptBlock { param($n) Start-ScheduledTask -TaskName $n } -ArgumentList $TaskName -ErrorAction Stop }
    else { Invoke-QmSchtasks -Ctx $Ctx -Arguments @('/Run','/TN',$TaskName) | Out-Null }
}

function Get-QmRemoteStatus {
    # Collects task info + signed status.json + log tail from the target. Never throws for missing files.
    param($Ctx, [Parameter(Mandatory)][string]$TaskName, [string]$ApiKey, [int]$LogTail = 200)
    $res = [ordered]@{ Target = $Ctx.Target; Method = $Ctx.Method; Task = $null; Envelope = $null; Status = $null; StatusText = ''; LogName = $null; LogTail = ''; Errors = @() }
    try { $res.Task = Get-QmRemoteTaskInfo -Ctx $Ctx -TaskName $TaskName } catch { $res.Errors += "Could not query task: $($_.Exception.Message)" }
    try {
        $json = Read-QmRemoteFile -Ctx $Ctx -RelativePath 'logs\status.json'
        if ($json) {
            $res.Envelope = Read-QmSignedEnvelope -Json $json -Key $ApiKey
            $res.Status = $res.Envelope.Data
            if ($res.Envelope.Problem) { $res.Errors += $res.Envelope.Problem }
            $res.StatusText = ConvertTo-QmStatusText $res.Status $res.Envelope
        } else { $res.StatusText = 'The deployed instance has not written a status yet (it has not run).' }
    } catch { $res.Errors += "Could not read status.json: $($_.Exception.Message)" }
    try {
        $res.LogName = Get-QmRemoteLatestLogName -Ctx $Ctx
        if ($res.LogName) { $res.LogTail = Read-QmRemoteFile -Ctx $Ctx -RelativePath ("logs\" + $res.LogName) -Tail $LogTail }
    } catch { $res.Errors += "Could not read log: $($_.Exception.Message)" }
    return $res
}

function Invoke-QmRemoteRunOnce {
    # Drops a signed run request, starts the task, waits for status.json carrying our requestId.
    param($Ctx, [Parameter(Mandatory)][string]$TaskName, [string]$ApiKey, [int]$TimeoutMinutes = 15, [scriptblock]$Log)
    $req = New-QmRunRequest -Key $ApiKey -Target $Ctx.Target
    Write-QmRemoteFile -Ctx $Ctx -RelativePath 'request.json' -Content $req.Json
    Write-QmOpLog $Log "Run request $($req.RequestId) written$(if ($ApiKey) { ' (signed with API key)' } else { ' (unsigned: no API key set)' }). Starting task..."
    Start-QmRemoteTask -Ctx $Ctx -TaskName $TaskName
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sawRunning = $false; $idleChecks = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $json = $null
        try { $json = Read-QmRemoteFile -Ctx $Ctx -RelativePath 'logs\status.json' } catch { }
        if ($json) {
            $env = Read-QmSignedEnvelope -Json $json -Key $ApiKey
            if ($env.Data -and "$($env.Data.run.requestId)" -eq $req.RequestId) {
                Write-QmOpLog $Log 'Target finished the run.'
                $st = Get-QmRemoteStatus -Ctx $Ctx -TaskName $TaskName -ApiKey $ApiKey
                $st.RequestId = $req.RequestId
                return $st
            }
        }
        $info = $null
        try { $info = Get-QmRemoteTaskInfo -Ctx $Ctx -TaskName $TaskName } catch { }
        if ($info) {
            if ($info.State -eq 'Running') { $sawRunning = $true; $idleChecks = 0 }
            elseif ($sawRunning -or $idleChecks -gt 0) { $idleChecks++ }
            else { $idleChecks++ }
            if ($idleChecks -ge 10) {
                $st = Get-QmRemoteStatus -Ctx $Ctx -TaskName $TaskName -ApiKey $ApiKey
                $st.RequestId = $req.RequestId
                $st.Errors += "The task is no longer running but the instance did not report a result for this request (task last result: $($info.LastResult)). The engine may have failed to start: check that $($Ctx.InstallPath) exists and the run-as account can run PowerShell."
                return $st
            }
        }
    }
    $st = Get-QmRemoteStatus -Ctx $Ctx -TaskName $TaskName -ApiKey $ApiKey
    $st.RequestId = $req.RequestId
    $st.Errors += "Timed out after $TimeoutMinutes min waiting for the target to finish."
    return $st
}

function Remove-QmRemote {
    param($Ctx, [Parameter(Mandatory)][string]$TaskName, [switch]$DeleteFiles, [scriptblock]$Log)
    if ($Ctx.Method -eq 'WinRM') {
        Invoke-Command -Session $Ctx.Session -ScriptBlock {
            param($n, $dir, $del)
            if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $n -Confirm:$false }
            if ($del -and (Test-Path -LiteralPath $dir)) {
                foreach ($f in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','config.json','e-automate.mapping.json','apikey.dat','apikey.install','request.json')) {
                    $p = Join-Path $dir $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
                }
            }
        } -ArgumentList $TaskName, $Ctx.InstallPath, ([bool]$DeleteFiles) -ErrorAction Stop
    } else {
        $q = Invoke-QmSchtasks -Ctx $Ctx -Arguments @('/Delete','/TN',$TaskName,'/F') -AllowFail
        if ($q.Code -ne 0) { Write-QmOpLog $Log "schtasks delete: $($q.Output.Trim())" }
        if ($DeleteFiles) {
            foreach ($f in @('QuSnmp.cs','QuSnmp.ps1','QuMeterCore.ps1','QuMeterEngine.ps1','config.json','e-automate.mapping.json','apikey.dat','apikey.install','request.json')) {
                $p = Join-Path $Ctx.RemoteDir $f; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
            }
        }
    }
    Write-QmOpLog $Log "Removed task '$TaskName' from $($Ctx.Target)$(if ($DeleteFiles) { ' and deleted program files (output and logs kept)' })."
}

function Invoke-QmDeploy {
    # Full deploy: stage, copy, API key, register task, verify, optional test run. Returns a status object.
    param(
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$AppDir,
        [pscredential]$Credential, [pscredential]$RunAsCredential, [string]$ApiKey, [scriptblock]$Log
    )
    $d = $Config.deploy
    if (-not $d.target) { throw 'Enter the target computer name or IP.' }
    $errs = Test-QmConfig -Config $Config -Root $AppDir
    if ($errs.Count) { throw ("Fix these settings first:`n - " + ($errs -join "`n - ")) }
    $stage = New-QmStaging -Config $Config -AppDir $AppDir
    $ctx = $null
    try {
        $ctx = New-QmRemoteContext -Target $d.target -InstallPath $d.installPath -AdminShare $d.adminShare -Method $d.method -Credential $Credential -Log $Log
        Write-QmOpLog $Log "Copying QuMeter engine to $($d.target):$($d.installPath)..."
        Copy-QmToTarget -Ctx $ctx -StageDir $stage -Log $Log
        Install-QmRemoteApiKey -Ctx $ctx -ApiKey $ApiKey -RunAsUser $(if ($RunAsCredential) { $RunAsCredential.UserName }) -Log $Log
        $tc = New-QmTargetConfig -Config $Config -AppDir $AppDir
        Register-QmRemoteTask -Ctx $ctx -Schedule $tc.schedule -RunAs $d.runAs -RunAsCredential $RunAsCredential -Log $Log
        $info = Get-QmRemoteTaskInfo -Ctx $ctx -TaskName $tc.schedule.taskName
        if (-not $info.Exists) { throw "The task was registered but could not be read back from $($d.target)." }
        Write-QmOpLog $Log "Verified: task state=$($info.State), next run=$($info.NextRunTime), run as=$($info.RunAs)."
        if ($d.runAfterDeploy) {
            Write-QmOpLog $Log 'Running once on the target to verify...'
            $st = Invoke-QmRemoteRunOnce -Ctx $ctx -TaskName $tc.schedule.taskName -ApiKey $ApiKey -TimeoutMinutes $d.runTimeoutMin -Log $Log
        } else {
            $st = Get-QmRemoteStatus -Ctx $ctx -TaskName $tc.schedule.taskName -ApiKey $ApiKey
        }
        $st.Deployed = $true
        return $st
    } finally {
        Close-QmRemoteContext $ctx
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
