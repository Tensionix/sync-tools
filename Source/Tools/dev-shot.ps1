# A screenshot of a window of ONE copy of the program: the process is picked by the full path of
# its exe, never by its name - the owner's own copy may be open beside it.
#
# PrintWindow gives an empty frame for Avalonia, so the window is put on top for a moment and
# copied from the screen. No mouse is moved. -Popup takes the dialog the window has open
# (its last active popup) instead of the window itself.
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Out,
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$Popup
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Shot -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetLastActivePopup(System.IntPtr h);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
'@
[void][Shot.Win]::SetProcessDPIAware()
$full = (Resolve-Path -LiteralPath $Exe).Path
$process = Get-Process | Where-Object { $_.Path -eq $full -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $process) { throw "no window of $full" }
$h = $process.MainWindowHandle
if ($Popup) { $h = [Shot.Win]::GetLastActivePopup($h) }
$top = [IntPtr](-1); $notop = [IntPtr](-2)
if (-not $Popup) { [void][Shot.Win]::ShowWindow($h, 9) }
if ($Width -gt 0 -and $Height -gt 0) { [void][Shot.Win]::SetWindowPos($h, $top, 40, 40, $Width, $Height, 0x0040) }
else { [void][Shot.Win]::SetWindowPos($h, $top, 0, 0, 0, 0, 0x0043) }
Start-Sleep -Milliseconds 900
$r = New-Object Shot.Win+RECT
[void][Shot.Win]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L; $hh = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $hh
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $hh))
$g.Dispose()
[void][Shot.Win]::SetWindowPos($h, $notop, 0, 0, 0, 0, 0x0003)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
"saved $Out ${w}x${hh}"
