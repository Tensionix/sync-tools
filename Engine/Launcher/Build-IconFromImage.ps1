<#
.SYNOPSIS
    Собирает значок приложения из готовой картинки.

.DESCRIPTION
    Прежний Build-Icon.ps1 рисовал знак кодом. Когда знак нарисован человеком,
    рисовать его заново незачем: этот сценарий берёт PNG и раскладывает его по
    размерам, которые Windows спрашивает у значка, - от 16 точек в списке файлов
    до 256 на плитке.

    Уменьшение идёт с высоким качеством и на прозрачном фоне: белая подложка,
    которую любит подставлять GDI+, испортила бы значок на тёмной панели задач.

    Файл .ico собирается вручную: внутри лежат обычные PNG, так делает Windows
    начиная с Vista, и это единственный способ получить кадр в 256 точек.

.PARAMETER Source
    Картинка-исходник. По умолчанию Assets\SyncTools.png.

.PARAMETER Target
    Куда положить .ico. По умолчанию рядом, с тем же именем.

.EXAMPLE
    .\Build-IconFromImage.ps1
    Собрать Assets\SyncTools.ico из Assets\SyncTools.png.
#>
[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$Target = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Source) { $Source = Join-Path $AppRoot 'Assets\SyncTools.png' }
if (-not $Target) { $Target = [System.IO.Path]::ChangeExtension($Source, '.ico') }

if (-not (Test-Path -LiteralPath $Source)) { throw "нет картинки: $Source" }

$origin = [System.Drawing.Bitmap]::FromFile($Source)
try {
    $sizes = @(256, 128, 64, 48, 32, 16)
    $frames = @()
    foreach ($side in $sizes) {
        $frame = [System.Drawing.Bitmap]::new($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $canvas = [System.Drawing.Graphics]::FromImage($frame)
        try {
            $canvas.Clear([System.Drawing.Color]::Transparent)
            $canvas.InterpolationMode = 'HighQualityBicubic'
            $canvas.SmoothingMode = 'HighQuality'
            $canvas.PixelOffsetMode = 'HighQuality'
            $canvas.CompositingQuality = 'HighQuality'
            $canvas.DrawImage($origin, [System.Drawing.Rectangle]::new(0, 0, $side, $side))
        } finally { $canvas.Dispose() }

        $stream = [System.IO.MemoryStream]::new()
        $frame.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames += [pscustomobject]@{ Side = $side; Data = $stream.ToArray() }
        $stream.Dispose()
        $frame.Dispose()
    }
} finally { $origin.Dispose() }

$out = [System.IO.MemoryStream]::new()
$writer = [System.IO.BinaryWriter]::new($out)
$writer.Write([uint16]0)              # reserved
$writer.Write([uint16]1)              # type: icon
$writer.Write([uint16]$frames.Count)

$offset = 6 + 16 * $frames.Count
foreach ($frame in $frames) {
    # 256 записывается нулём: в каталоге значка размер занимает один байт.
    $writer.Write([byte]$(if ($frame.Side -ge 256) { 0 } else { $frame.Side }))
    $writer.Write([byte]$(if ($frame.Side -ge 256) { 0 } else { $frame.Side }))
    $writer.Write([byte]0)            # палитра не используется
    $writer.Write([byte]0)            # reserved
    $writer.Write([uint16]1)          # плоскости
    $writer.Write([uint16]32)         # бит на пиксель
    $writer.Write([uint32]$frame.Data.Length)
    $writer.Write([uint32]$offset)
    $offset += $frame.Data.Length
}
foreach ($frame in $frames) { $writer.Write($frame.Data) }
$writer.Flush()
[System.IO.File]::WriteAllBytes($Target, $out.ToArray())
$writer.Dispose()
$out.Dispose()

Write-Output "исходник: $Source"
Write-Output "значок  : $Target ($($sizes -join ', '))"
