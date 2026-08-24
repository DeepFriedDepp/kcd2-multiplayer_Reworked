# Builds KCDMP_launcher/app.ico from the branding PNG.
#
# A single upscaled/renamed PNG is not a real .ico -- Windows picks a
# resolution per context (taskbar, desktop, shortcut properties, Alt-Tab)
# and a one-size file just gets blurrily rescaled everywhere. This writes a
# real multi-resolution .ico: each size is its own properly downsampled
# image, PNG-compressed inside the icon container (the Vista+ ICO format,
# which every version of Windows this project targets supports).
#
# No new dependency: System.Drawing is already pulled into
# KCDMP_launcher.csproj via <UseWindowsForms>true</UseWindowsForms>, and
# this repo has neither ImageMagick nor Python installed (see
# docs/WO-50-findings.md Phase 3). Re-run this any time the source artwork
# changes; it always overwrites the output.

param(
    [string]$SourcePng = (Join-Path $PSScriptRoot "..\docs\branding\kcd2-mp-logo.png"),
    [string]$OutputIco = (Join-Path $PSScriptRoot "..\KCDMP_launcher\app.ico"),
    [int[]]$Sizes = @(16, 32, 48, 64, 128, 256)
)

Add-Type -AssemblyName System.Drawing

$SourcePng = (Resolve-Path $SourcePng).Path
Write-Host "Source: $SourcePng"
Write-Host "Output: $OutputIco"

$src = [System.Drawing.Image]::FromFile($SourcePng)
try {
    $entries = foreach ($size in $Sizes) {
        $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($src, 0, 0, $size, $size)
        } finally { $g.Dispose() }

        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose()
        $bmp.Dispose()

        [PSCustomObject]@{ Size = $size; Bytes = $bytes }
    }
} finally {
    $src.Dispose()
}

# ICO container: ICONDIR (6 bytes) + one ICONDIRENTRY (16 bytes) per image,
# then the raw PNG-encoded image data back to back. A width/height byte of
# 0 in a directory entry means 256, per the file format.
$headerSize   = 6
$dirEntrySize = 16
$dataOffset   = $headerSize + ($dirEntrySize * $entries.Count)

$outDir = Split-Path -Parent $OutputIco
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

$fs = New-Object System.IO.FileStream($OutputIco, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)
try {
    $bw.Write([UInt16]0)              # reserved
    $bw.Write([UInt16]1)              # type = icon
    $bw.Write([UInt16]$entries.Count)

    $offset = $dataOffset
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
        $bw.Write([byte]$dim)             # width
        $bw.Write([byte]$dim)             # height
        $bw.Write([byte]0)                # color palette count (0 = n/a)
        $bw.Write([byte]0)                # reserved
        $bw.Write([UInt16]1)              # color planes
        $bw.Write([UInt16]32)             # bits per pixel
        $bw.Write([UInt32]$e.Bytes.Length)
        $bw.Write([UInt32]$offset)
        $offset += $e.Bytes.Length
    }

    foreach ($e in $entries) {
        $bw.Write($e.Bytes)
    }
    $bw.Flush()
} finally {
    $bw.Close()
    $fs.Close()
}

Write-Host "Wrote $OutputIco (sizes: $($Sizes -join ', '))"
