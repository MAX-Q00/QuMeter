# QuMeterUpdate.ps1 - GitHub Releases update check, download, verify, and install.
# Dotted from QuMeterCore.ps1. Windows PowerShell 5.1 compatible. No third-party modules.
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC

$script:QmGitHubRepo = 'MAX-Q00/QuMeter'
$script:QmUpdateApiTimeoutMs = 5000
$script:QmUpdateDownloadTimeoutMs = 60000

function Get-QmAppPayloadFiles {
    # Files the updater replaces. User data (settings.json, config.json, devices.txt, mps-import.json, output, logs) is left alone.
    # e-automate.mapping.json is only copied when the install does not already have one.
    @('QuMeter.bat', 'QuMeter.ps1', 'QuMeterCore.ps1', 'QuMeterEngine.ps1', 'QuMeterUpdate.ps1', 'QuSnmp.cs', 'QuSnmp.ps1', 'README.md')
}

function Get-QmUserDataFileNames {
    @('settings.json', 'config.json', 'devices.txt', 'mps-import.json')
}

function ConvertTo-QmVersion {
    param([Parameter(Mandatory)][string]$Text)
    $t = "$Text".Trim()
    if ($t.Length -eq 0) { return $null }
    if ($t[0] -eq 'v' -or $t[0] -eq 'V') { $t = $t.Substring(1) }
    if ($t -match '^(\d+(\.\d+){0,3})') {
        $p = $Matches[1]
        if (@($p.Split('.')).Count -eq 1) { $p = "$p.0" }
        return [version]$p
    }
    return $null
}

function ConvertTo-QmVersionString {
    param($Version)
    $v = $Version
    if ($v -isnot [version]) { $v = ConvertTo-QmVersion "$Version" }
    if ($null -eq $v) { return $null }
    if ($v.Build -lt 0) { return '{0}.{1}' -f $v.Major, $v.Minor }
    if ($v.Revision -lt 0) { return '{0}.{1}.{2}' -f $v.Major, $v.Minor, $v.Build }
    return $v.ToString()
}

function Compare-QmVersion {
    param($Current, $Other)
    $a = ConvertTo-QmVersion "$Current"
    $b = ConvertTo-QmVersion "$Other"
    if ($null -eq $a) { throw "Invalid version: $Current" }
    if ($null -eq $b) { throw "Invalid version: $Other" }
    return $a.CompareTo($b)
}

function Get-QmReleaseZipName {
    param($Version)
    $s = ConvertTo-QmVersionString $Version
    if (-not $s) { throw "Invalid version: $Version" }
    return "QuMeter-$s.zip"
}

function Get-QmSha256FromText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = "$Text".Trim()
    if ($t -match '^(?i)sha256:') { $t = $t.Substring(7).Trim() }
    if ($t -match '([A-Fa-f0-9]{64})') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Get-QmReleaseAssetSha256 {
    param($Release, $Asset, [string]$ZipName)
    if ($Asset -and $Asset.digest) {
        $d = Get-QmSha256FromText "$($Asset.digest)"
        if ($d) { return $d }
    }
    if ($Release -and $Release.body) {
        $body = [string]$Release.body
        if ($ZipName) {
            $escaped = [regex]::Escape($ZipName)
            if ($body -match "(?im)(?:sha256|SHA-256)[^\n]*$escaped[^\n]*([A-Fa-f0-9]{64})") { return $Matches[1].ToLowerInvariant() }
            if ($body -match "(?im)$escaped[^\n]*(?:sha256|SHA-256)[^\n]*([A-Fa-f0-9]{64})") { return $Matches[1].ToLowerInvariant() }
        }
        if ($body -match "(?im)(?:sha256|SHA-256)\s*[:=]\s*([A-Fa-f0-9]{64})") { return $Matches[1].ToLowerInvariant() }
    }
    return $null
}

function ConvertFrom-QmGithubRelease {
    param($Json)
    if ($null -eq $Json) { return $null }
    $obj = $Json
    if ($Json -is [string]) {
        $text = $Json.Trim()
        if ($text.Length -eq 0) { return $null }
        $obj = $text | ConvertFrom-Json
    }
    if ($null -eq $obj -or -not $obj.tag_name) { return $null }
    $ver = ConvertTo-QmVersion "$($obj.tag_name)"
    if ($null -eq $ver) { $ver = ConvertTo-QmVersion "$($obj.name)" }
    if ($null -eq $ver) { return $null }
    $verStr = ConvertTo-QmVersionString $ver
    $zipName = Get-QmReleaseZipName $verStr
    $assets = @()
    if ($obj.assets) { $assets = @($obj.assets) }
    $asset = $null
    foreach ($a in $assets) { if ("$($a.name)" -eq $zipName) { $asset = $a; break } }
    if (-not $asset) {
        $zips = @()
        foreach ($a in $assets) {
            $n = "$($a.name)"
            if ($n -like 'QuMeter-*.zip' -and $n -notlike '*.sha256') { $zips += ,$a }
        }
        if ($zips.Count -eq 1) { $asset = $zips[0]; $zipName = "$($asset.name)" }
    }
    $size = $null
    $url = $null
    $assetName = $null
    if ($asset) {
        $assetName = "$($asset.name)"
        $url = "$($asset.browser_download_url)"
        if ($asset.PSObject.Properties.Name -contains 'size') { $size = [int64]$asset.size }
    }
    $sha = Get-QmReleaseAssetSha256 -Release $obj -Asset $asset -ZipName $zipName
    return [pscustomobject]@{
        Tag             = "$($obj.tag_name)"
        Version         = $verStr
        Name            = "$($obj.name)"
        Body            = $(if ($obj.body) { [string]$obj.body } else { '' })
        HtmlUrl         = "$($obj.html_url)"
        AssetName       = $assetName
        AssetUrl        = $url
        AssetSize       = $size
        Sha256          = $sha
        ExpectedZipName = $zipName
    }
}

function Get-QmLatestRelease {
    param(
        [string]$Repo = $script:QmGitHubRepo,
        [int]$TimeoutMs = $script:QmUpdateApiTimeoutMs,
        [string]$ApiUrl
    )
    $url = $ApiUrl
    if (-not $url) { $url = "https://api.github.com/repos/$Repo/releases/latest" }
    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = 'GET'
        $req.UserAgent = "QuMeter/$(Get-QmVersion) (+https://github.com/$Repo)"
        $req.Accept = 'application/vnd.github+json'
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            try { $json = $sr.ReadToEnd() } finally { $sr.Close() }
        } finally {
            if ($resp) { $resp.Close() }
        }
        return ConvertFrom-QmGithubRelease $json
    } catch {
        return $null
    }
}

function Get-QmFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Test-QmDownload {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$ExpectedSize = 0,
        [string]$ExpectedSha256
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Download is missing: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($ExpectedSize -gt 0 -and $item.Length -ne $ExpectedSize) {
        throw "Download size mismatch: got $($item.Length) bytes, expected $ExpectedSize."
    }
    if ($ExpectedSha256) {
        $got = Get-QmFileSha256 $Path
        $exp = Get-QmSha256FromText $ExpectedSha256
        if (-not $exp) { throw "Invalid expected SHA256: $ExpectedSha256" }
        if ($got -ne $exp) { throw "Download SHA256 mismatch: got $got, expected $exp." }
    }
    return $true
}

function Resolve-QmExtractedRoot {
    param([Parameter(Mandatory)][string]$Directory)
    $payload = Get-QmAppPayloadFiles
    $hit = $false
    foreach ($f in $payload) {
        if (Test-Path -LiteralPath (Join-Path $Directory $f)) { $hit = $true; break }
    }
    if ($hit) { return $Directory }
    $subs = @(Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction SilentlyContinue)
    if ($subs.Count -eq 1) {
        $cand = $subs[0].FullName
        foreach ($f in $payload) {
            if (Test-Path -LiteralPath (Join-Path $cand $f)) { return $cand }
        }
    }
    throw 'The update zip does not look like a QuMeter release (QuMeter.ps1 was not found).'
}

function Install-QmUpdateFiles {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$AppDir,
        [string]$BackupDir
    )
    $root = Resolve-QmExtractedRoot $SourceDir
    $payload = Get-QmAppPayloadFiles
    if ($BackupDir) {
        if (-not (Test-Path -LiteralPath $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        }
        foreach ($f in $payload) {
            $src = Join-Path $AppDir $f
            if (Test-Path -LiteralPath $src) {
                Copy-Item -LiteralPath $src -Destination (Join-Path $BackupDir $f) -Force
            }
        }
    }
    foreach ($f in $payload) {
        $from = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $to = Join-Path $AppDir $f
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
    $mapFrom = Join-Path $root 'e-automate.mapping.json'
    $mapTo = Join-Path $AppDir 'e-automate.mapping.json'
    if ((Test-Path -LiteralPath $mapFrom) -and -not (Test-Path -LiteralPath $mapTo)) {
        Copy-Item -LiteralPath $mapFrom -Destination $mapTo -Force
    }
    return $root
}

function Get-QmWebBytes {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutMs = $script:QmUpdateDownloadTimeoutMs
    )
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.UserAgent = "QuMeter/$(Get-QmVersion) (+https://github.com/$($script:QmGitHubRepo))"
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $true
    $resp = $null
    try {
        $resp = $req.GetResponse()
        $dir = Split-Path -Parent $OutFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $fs = [System.IO.File]::Create($OutFile)
        try {
            $stream = $resp.GetResponseStream()
            $buffer = New-Object byte[] 81920
            while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $fs.Write($buffer, 0, $n) }
        } finally { $fs.Dispose() }
    } finally {
        if ($resp) { $resp.Close() }
    }
}

function Expand-QmZip {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Destination)
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

function ConvertTo-QmSingleQuoted {
    param([string]$Text)
    return ("'" + (("$Text") -replace "'", "''") + "'")
}

function New-QmUpdateApplyScript {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$BackupDir,
        [Parameter(Mandatory)][string]$LibraryDir,
        [int]$WaitPid,
        [switch]$Relaunch
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('QuMeter-apply-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $LibraryDir 'QuMeterCore.ps1') -Destination (Join-Path $tempRoot 'QuMeterCore.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $LibraryDir 'QuMeterUpdate.ps1') -Destination (Join-Path $tempRoot 'QuMeterUpdate.ps1') -Force
    $apply = Join-Path $tempRoot 'Apply-QuMeterUpdate.ps1'
    $wait = 0
    if ($WaitPid) { $wait = [int]$WaitPid }
    $rel = '$false'
    if ($Relaunch) { $rel = '$true' }
    $content = @"
`$ErrorActionPreference = 'Stop'
`$SourceDir = $(ConvertTo-QmSingleQuoted $SourceDir)
`$AppDir = $(ConvertTo-QmSingleQuoted $AppDir)
`$BackupDir = $(ConvertTo-QmSingleQuoted $BackupDir)
`$LibraryDir = $(ConvertTo-QmSingleQuoted $tempRoot)
`$WaitPid = $wait
`$Relaunch = $rel
. (Join-Path `$LibraryDir 'QuMeterCore.ps1')
. (Join-Path `$LibraryDir 'QuMeterUpdate.ps1')
if (`$WaitPid -gt 0) {
    `$proc = Get-Process -Id `$WaitPid -ErrorAction SilentlyContinue
    if (`$proc) { `$null = `$proc.WaitForExit(120000) }
    Start-Sleep -Milliseconds 500
}
`$copied = `$false
`$lastErr = `$null
for (`$i = 0; `$i -lt 8 -and -not `$copied; `$i++) {
    try {
        `$null = Install-QmUpdateFiles -SourceDir `$SourceDir -AppDir `$AppDir -BackupDir `$BackupDir
        `$copied = `$true
    } catch {
        `$lastErr = `$_
        Start-Sleep -Milliseconds 750
    }
}
if (-not `$copied) { throw "Could not replace QuMeter files (they may still be in use): `$(`$lastErr.Exception.Message)" }
if (`$Relaunch) {
    `$bat = Join-Path `$AppDir 'QuMeter.bat'
    if (Test-Path -LiteralPath `$bat) {
        Start-Process -FilePath `$bat -WorkingDirectory `$AppDir
    } else {
        `$ps = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath `$ps -WorkingDirectory `$AppDir -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path `$AppDir 'QuMeter.ps1'))
    }
}
"@
    Set-Content -LiteralPath $apply -Value $content -Encoding ASCII
    return $apply
}

function Start-QmUpdateApply {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$AppDir,
        [Parameter(Mandatory)][string]$BackupDir,
        [int]$WaitPid,
        [switch]$Relaunch
    )
    $apply = New-QmUpdateApplyScript -SourceDir $SourceDir -AppDir $AppDir -BackupDir $BackupDir -LibraryDir $AppDir -WaitPid $WaitPid -Relaunch:$Relaunch
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($cmd) { $psExe = $cmd.Source } else { throw 'Windows PowerShell was not found to finish the update.' }
    }
    Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $apply) | Out-Null
}

function Install-QmUpdateFromRelease {
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$AppDir,
        [int]$WaitPid,
        [switch]$Relaunch
    )
    if (-not $Release.AssetUrl) {
        throw "The GitHub release for QuMeter $($Release.Version) does not include $( $Release.ExpectedZipName ). Attach that zip when you publish the release."
    }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('QuMeter-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work $Release.ExpectedZipName
    Get-QmWebBytes -Url $Release.AssetUrl -OutFile $zip
    $size = 0
    if ($Release.AssetSize) { $size = [int64]$Release.AssetSize }
    Test-QmDownload -Path $zip -ExpectedSize $size -ExpectedSha256 $Release.Sha256 | Out-Null
    $extract = Join-Path $work 'extract'
    Expand-QmZip -ZipPath $zip -Destination $extract
    $null = Resolve-QmExtractedRoot $extract
    $backup = Join-Path $AppDir (Join-Path 'backup' ("QuMeter-" + (Get-QmVersion)))
    Start-QmUpdateApply -SourceDir $extract -AppDir $AppDir -BackupDir $backup -WaitPid $WaitPid -Relaunch:$Relaunch
    return $backup
}
