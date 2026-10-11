# How every glyph sits inside its button, measured on the real screen, in pixels.
#
# The window (a Debug copy, started with the dev step "audit=<list>") writes where its icon buttons
# stand on the screen. This script puts the window on top for a moment, copies it from the screen
# and finds the drawing inside every button: the pixels that differ from the ground of the button.
# For each it prints the empty pixels on the left, right, top and bottom of the drawing; a glyph
# is in the middle when left = right and top = bottom (a difference of one is half a pixel).
#
#   Source\Tools\dev-audit.ps1 -Exe <...\AudionSyncTools.exe> -List C:\Temp\audit.txt
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$List,
    [string]$Only = '',
    [int]$Inset = 4,
    [int]$Contrast = 40
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Audit -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@
[void][Audit.Win]::SetProcessDPIAware()
$full = (Resolve-Path -LiteralPath $Exe).Path
$process = Get-Process | Where-Object { $_.Path -eq $full -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $process) { throw "no window of $full" }
$h = $process.MainWindowHandle
[void][Audit.Win]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0043)
Start-Sleep -Milliseconds 700

try {
    foreach ($line in Get-Content -LiteralPath $List) {
        $kind, $name, $x, $y, $w, $hh = $line -split "`t"
        if ($Only -and $kind -ne $Only) { continue }
        $x = [int]$x; $y = [int]$y; $w = [int]$w; $hh = [int]$hh
        if ($w -le 2 * $Inset -or $hh -le 2 * $Inset) { continue }
        $bmp = New-Object System.Drawing.Bitmap $w, $hh
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $hh))
        $g.Dispose()
        # The ground: the colour met most often inside the button.
        $seen = @{}
        for ($py = $Inset; $py -lt $hh - $Inset; $py++) { for ($px = $Inset; $px -lt $w - $Inset; $px++) { $k = $bmp.GetPixel($px, $py).ToArgb(); $seen[$k] = 1 + [int]$seen[$k] } }
        $ground = [System.Drawing.Color]::FromArgb([int](($seen.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key))
        $l = $w; $r = -1; $t = $hh; $b = -1
        for ($py = $Inset; $py -lt $hh - $Inset; $py++) {
            for ($px = $Inset; $px -lt $w - $Inset; $px++) {
                $c = $bmp.GetPixel($px, $py)
                $d = [Math]::Max([Math]::Abs($c.R - $ground.R), [Math]::Max([Math]::Abs($c.G - $ground.G), [Math]::Abs($c.B - $ground.B)))
                if ($d -lt $Contrast) { continue }
                if ($px -lt $l) { $l = $px }; if ($px -gt $r) { $r = $px }; if ($py -lt $t) { $t = $py }; if ($py -gt $b) { $b = $py }
            }
        }
        $bmp.Dispose()
        if ($r -lt 0) { '{0,-6} {1,-22} {2,3}x{3,-3}  nothing drawn' -f $kind, $name, $w, $hh; continue }
        $right = $w - 1 - $r; $bottom = $hh - 1 - $b
        '{0,-6} {1,-22} {2,3}x{3,-3}  left {4,2} right {5,2} ({6,2})   top {7,2} bottom {8,2} ({9,2})' -f $kind, $name, $w, $hh, $l, $right, ($l - $right), $t, $bottom, ($t - $bottom)
    }
} finally {
    [void][Audit.Win]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0003)
}
