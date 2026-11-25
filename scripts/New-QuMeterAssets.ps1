# Generates QuMeter.ico and Microsoft Store logo PNG assets (printer/meter gauge theme).
# Published by QuSpace Studios LLC
# (c) 2026 QuSpace Studios LLC
#   powershell -NoProfile -File scripts/New-QuMeterAssets.ps1
param(
    [string]$OutRoot
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }
if (-not $OutRoot) { $OutRoot = $root }
$assets = Join-Path $OutRoot 'packaging\msix\Assets'
if (-not (Test-Path -LiteralPath $assets)) {
    New-Item -ItemType Directory -Path $assets -Force | Out-Null
}

$green = [Drawing.Color]::FromArgb(25, 135, 84)
$greenDark = [Drawing.Color]::FromArgb(18, 100, 62)
$paper = [Drawing.Color]::FromArgb(248, 250, 252)
$ink = [Drawing.Color]::FromArgb(33, 37, 41)
$accent = [Drawing.Color]::FromArgb(13, 110, 253)

function New-QmBitmap {
    param([int]$W, [int]$H)
    $bmp = New-Object Drawing.Bitmap $W, $H
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([Drawing.Color]::Transparent)
    return @{ Bmp = $bmp; G = $g }
}

function Draw-QmMark {
    param($G, [int]$W, [int]$H, [bool]$Wide = $false)
    $pad = [math]::Max(1, [int]($W * 0.08))
    if ($Wide) { $cx = [int]($W * 0.38) } else { $cx = [int]($W / 2) }
    $cy = [int]($H / 2)
    $r = [int]([math]::Min($W, $H) * 0.36)
    if ($r -lt 4) { $r = [math]::Max(2, [int]([math]::Min($W, $H) / 2) - 1) }

    $bg = New-Object Drawing.Drawing2D.LinearGradientBrush(
        (New-Object Drawing.Point(0, 0)),
        (New-Object Drawing.Point(0, $H)),
        $green,
        $greenDark
    )
    $G.FillRectangle($bg, 0, 0, $W, $H)
    $bg.Dispose()

    $disk = New-Object Drawing.SolidBrush $paper
    $G.FillEllipse($disk, $cx - $r, $cy - $r, $r * 2, $r * 2)
    $disk.Dispose()

    $ringWidth = [math]::Max(1, [int]($r * 0.08))
    $ring = New-Object Drawing.Pen($ink, $ringWidth)
    $G.DrawEllipse($ring, $cx - $r, $cy - $r, $r * 2, $r * 2)
    $ring.Dispose()

    $arcWidth = [math]::Max(2, [int]($r * 0.14))
    $arcPen = New-Object Drawing.Pen($green, $arcWidth)
    $arcPen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $arcPen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $inset = [int]($r * 0.22)
    $G.DrawArc($arcPen, ($cx - $r + $inset), ($cy - $r + $inset), (($r - $inset) * 2), (($r - $inset) * 2), 135, 270)
    $arcPen.Dispose()

    $needleWidth = [math]::Max(1, [int]($r * 0.1))
    $needle = New-Object Drawing.Pen($accent, $needleWidth)
    $needle.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $needle.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $angle = -40 * [math]::PI / 180
    $nx = $cx + [int]([math]::Cos($angle) * $r * 0.62)
    $ny = $cy + [int]([math]::Sin($angle) * $r * 0.62)
    $G.DrawLine($needle, $cx, $cy, $nx, $ny)
    $needle.Dispose()

    $hub = New-Object Drawing.SolidBrush $ink
    $hr = [math]::Max(1, [int]($r * 0.12))
    $G.FillEllipse($hub, $cx - $hr, $cy - $hr, $hr * 2, $hr * 2)
    $hub.Dispose()

    if ($Wide) {
        $fontSize = [math]::Max(8, [int]($H * 0.28))
        $font = New-Object Drawing.Font('Segoe UI Semibold', $fontSize, [Drawing.FontStyle]::Bold)
        $brush = New-Object Drawing.SolidBrush $paper
        $fmt = New-Object Drawing.StringFormat
        $fmt.LineAlignment = [Drawing.StringAlignment]::Center
        $fmt.Alignment = [Drawing.StringAlignment]::Near
        $rect = New-Object Drawing.RectangleF(($cx + $r + $pad), 0, ($W - $cx - $r - $pad * 2), $H)
        $G.DrawString('QuMeter', $font, $brush, $rect, $fmt)
        $font.Dispose()
        $brush.Dispose()
        $fmt.Dispose()
    }
}

function Save-QmPng {
    param($Bmp, [string]$Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
}

function New-QmScaledPng {
    param([string]$BaseName, [int]$BaseW, [int]$BaseH, [int[]]$Scales, [bool]$Wide = $false)
    foreach ($scale in $Scales) {
        $w = [int][math]::Round($BaseW * $scale / 100.0)
        $h = [int][math]::Round($BaseH * $scale / 100.0)
        $o = New-QmBitmap -W $w -H $h
        Draw-QmMark -G $o.G -W $w -H $h -Wide:$Wide
        $o.G.Dispose()
        if ($scale -eq 100) { $name = "$BaseName.png" } else { $name = "$BaseName.scale-$scale.png" }
        Save-QmPng -Bmp $o.Bmp -Path (Join-Path $assets $name)
        $o.Bmp.Dispose()
    }
}

function Write-QmIco {
    param([string]$Path, [int[]]$Sizes)
    $images = New-Object 'System.Collections.Generic.List[System.Drawing.Bitmap]'
    foreach ($s in $Sizes) {
        $o = New-QmBitmap -W $s -H $s
        Draw-QmMark -G $o.G -W $s -H $s
        $o.G.Dispose()
        [void]$images.Add($o.Bmp)
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([uint16]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]$images.Count)
    $offset = 6 + (16 * $images.Count)
    $pngBlobs = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($bmp in $images) {
        $pms = New-Object System.IO.MemoryStream
        $bmp.Save($pms, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $pms.ToArray()
        $pms.Dispose()
        [void]$pngBlobs.Add($bytes)
        if ($bmp.Width -ge 256) { $wb = [byte]0 } else { $wb = [byte]$bmp.Width }
        if ($bmp.Height -ge 256) { $hb = [byte]0 } else { $hb = [byte]$bmp.Height }
        $bw.Write($wb)
        $bw.Write($hb)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$bytes.Length)
        $bw.Write([uint32]$offset)
        $offset += $bytes.Length
    }
    foreach ($blob in $pngBlobs) { $bw.Write($blob) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
    foreach ($bmp in $images) { $bmp.Dispose() }
}

$scales = @(100, 125, 150, 200, 400)
New-QmScaledPng -BaseName 'StoreLogo' -BaseW 50 -BaseH 50 -Scales $scales
New-QmScaledPng -BaseName 'Square44x44Logo' -BaseW 44 -BaseH 44 -Scales $scales
New-QmScaledPng -BaseName 'Square71x71Logo' -BaseW 71 -BaseH 71 -Scales $scales
New-QmScaledPng -BaseName 'Square150x150Logo' -BaseW 150 -BaseH 150 -Scales $scales
New-QmScaledPng -BaseName 'Square310x310Logo' -BaseW 310 -BaseH 310 -Scales $scales
New-QmScaledPng -BaseName 'Wide310x150Logo' -BaseW 310 -BaseH 150 -Scales $scales -Wide $true
# SplashScreen scale-100 must be 620x300 (not the 150x150 tile logo).
New-QmScaledPng -BaseName 'SplashScreen' -BaseW 620 -BaseH 300 -Scales $scales -Wide $true

foreach ($ts in @(16, 24, 32, 48, 256)) {
    $o = New-QmBitmap -W $ts -H $ts
    Draw-QmMark -G $o.G -W $ts -H $ts
    $o.G.Dispose()
    Save-QmPng -Bmp $o.Bmp -Path (Join-Path $assets ("Square44x44Logo.targetsize-{0}.png" -f $ts))
    Save-QmPng -Bmp $o.Bmp -Path (Join-Path $assets ("Square44x44Logo.targetsize-{0}_altform-unplated.png" -f $ts))
    $o.Bmp.Dispose()
}

$icoPath = Join-Path $OutRoot 'QuMeter.ico'
Write-QmIco -Path $icoPath -Sizes @(16, 24, 32, 48, 256)
Write-Host "Wrote assets under $assets"
Write-Host "Wrote $icoPath"
