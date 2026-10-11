# A piece of a screenshot, enlarged pixel for pixel (no smoothing): to look at how a glyph stands
# in its button. Coordinates are pixels of the source picture.
#
#   Source\Tools\dev-crop.ps1 -In shot.png -Out piece.png -X 830 -Y 450 -W 50 -H 460 -Zoom 4
param(
    [Parameter(Mandatory)][string]$In,
    [Parameter(Mandatory)][string]$Out,
    [int]$X = 0, [int]$Y = 0, [int]$W = 100, [int]$H = 100,
    [int]$Zoom = 4
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $In).Path)
try {
    $piece = New-Object System.Drawing.Bitmap ($W * $Zoom), ($H * $Zoom)
    $g = [System.Drawing.Graphics]::FromImage($piece)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.DrawImage($source, (New-Object System.Drawing.Rectangle 0, 0, ($W * $Zoom), ($H * $Zoom)), (New-Object System.Drawing.Rectangle $X, $Y, $W, $H), [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()
    $piece.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $piece.Dispose()
    "saved $Out"
} finally { $source.Dispose() }
