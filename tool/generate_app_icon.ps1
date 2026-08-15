# Generates the Windows app icon (windows/runner/resources/app_icon.ico) from a
# source PNG, packing multiple resolutions (16..256) as PNG-compressed ICO
# entries (Windows Vista+ format; used by the Flutter Windows runner).
#
# Usage:
#   pwsh -File tool/generate_app_icon.ps1 [-Source dshc_icon.png] [-Output windows/runner/resources/app_icon.ico]

param(
  [string]$Source = "dshc_icon.png",
  [string]$Output = "windows/runner/resources/app_icon.ico"
)

Add-Type -AssemblyName System.Drawing

$sourcePath = Join-Path (Get-Location) $Source
$outputPath = Join-Path (Get-Location) $Output

if (-not (Test-Path $sourcePath)) {
  Write-Error "Source PNG not found: $sourcePath"
  exit 1
}

$bitmap = [System.Drawing.Bitmap]::FromFile($sourcePath)
$sizes = @(16, 24, 32, 48, 64, 128, 256)
$pngs = @()

foreach ($s in $sizes) {
  $bmp = New-Object System.Drawing.Bitmap($s, $s)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($bitmap, 0, 0, $s, $s)
  $g.Dispose()
  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngs += , $ms.ToArray()
  $bmp.Dispose()
  $ms.Dispose()
}
$bitmap.Dispose()

$count = $pngs.Count
$headerSize = 6
$entrySize = 16
$offset = $headerSize + ($entrySize * $count)
$total = $offset
foreach ($p in $pngs) { $total += $p.Length }

$out = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter($out)
$writer.Write([UInt16]0)               # reserved
$writer.Write([UInt16]1)               # type: icon
$writer.Write([UInt16]$count)          # number of images
$curr = $offset
for ($i = 0; $i -lt $count; $i++) {
  $s = $sizes[$i]
  $b = [byte]($s -band 0xFF)
  if ($s -ge 256) { $b = 0 }           # 0 == 256 in ICO dimensions
  $writer.Write([byte]$b)              # width
  $writer.Write([byte]$b)              # height
  $writer.Write([byte]0)               # color count
  $writer.Write([byte]0)               # reserved
  $writer.Write([UInt16]1)             # color planes
  $writer.Write([UInt16]32)            # bits per pixel
  $writer.Write([UInt32]$pngs[$i].Length)  # bytes in resource
  $writer.Write([UInt32]$curr)         # image data offset
  $curr += $pngs[$i].Length
}
for ($i = 0; $i -lt $count; $i++) {
  $writer.Write($pngs[$i])
}
$writer.Flush()
[System.IO.File]::WriteAllBytes($outputPath, $out.ToArray())
$writer.Dispose()
$out.Dispose()

Write-Output "Wrote $outputPath ($total bytes, $count resolutions: $($sizes -join ','))"
