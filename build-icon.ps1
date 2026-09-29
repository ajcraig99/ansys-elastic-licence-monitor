# Copyright (c) 2026 Arron Craig
# SPDX-License-Identifier: GPL-3.0-or-later
# This file is part of Ansys Elastic Licence Monitor. See LICENSE for terms.
#
# build-icon.ps1 - regenerates assets\icon.ico from assets\icon.png.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build-icon.ps1
#
# The .ico is committed, so this only needs running after replacing icon.png.
# Sizes 16-64 are stored as 32-bit DIBs (the most widely supported entry
# format); 256 is stored as PNG, as Windows expects for that size.

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
# Resolved here, not as param defaults: WinPS 5.1 leaves $PSScriptRoot empty
# while evaluating the param block.
$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source) { $Source = Join-Path $scriptRoot 'assets\icon.png' }
if (-not $Output) { $Output = Join-Path $scriptRoot 'assets\icon.ico' }
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)

function New-ResizedBitmap([System.Drawing.Image]$Img, [int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.DrawImage($Img, 0, 0, $Size, $Size)
    } finally { $g.Dispose() }
    return $bmp
}

function Get-DibBytes([System.Drawing.Bitmap]$Bmp) {
    # BITMAPINFOHEADER + bottom-up BGRA pixels + 1-bit AND mask (all zero:
    # transparency comes from the alpha channel).
    $n = $Bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([int32]40); $w.Write([int32]$n); $w.Write([int32]($n * 2))
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int32]0)
    $maskStride = [int]([Math]::Ceiling($n / 32.0) * 4)
    $w.Write([int32]($n * $n * 4 + $maskStride * $n))
    $w.Write([int32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([int32]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) {
            $c = $Bmp.GetPixel($x, $y)
            $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A)
        }
    }
    $w.Write((New-Object byte[] ($maskStride * $n)))
    $w.Flush()
    # Leading comma: stop PowerShell unrolling the byte[] into loose objects,
    # which would then hit BinaryWriter.Write's wrong overload (one byte each).
    return ,$ms.ToArray()
}

$img = [System.Drawing.Image]::FromFile((Resolve-Path $Source).Path)
try {
    $entries = foreach ($s in $sizes) {
        $bmp = New-ResizedBitmap $img $s
        try {
            if ($s -ge 256) {
                $pm = New-Object System.IO.MemoryStream
                $bmp.Save($pm, [System.Drawing.Imaging.ImageFormat]::Png)
                $data = $pm.ToArray()
            } else {
                $data = Get-DibBytes $bmp
            }
        } finally { $bmp.Dispose() }
        [PSCustomObject]@{ Size = $s; Data = [byte[]]$data }
    }
} finally { $img.Dispose() }

# ICONDIR + ICONDIRENTRY[] + image data.
$fs = [System.IO.File]::Create($Output)
$w = New-Object System.IO.BinaryWriter($fs)
try {
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }   # 0 means 256
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([int16]1); $w.Write([int16]32)
        $w.Write([int32]$e.Data.Length); $w.Write([int32]$offset)
        $offset += $e.Data.Length
    }
    foreach ($e in $entries) { $w.Write([byte[]]$e.Data) }
} finally { $w.Dispose() }

Write-Host "Wrote $Output ($((Get-Item $Output).Length) bytes, sizes: $($sizes -join ', '))"
