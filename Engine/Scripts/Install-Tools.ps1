# Audion Sync Tools - the archiver and the editors into Tools\.
#
# The installer of Audion Disk Tools (Engine\Install-Tools.ps1), taken as it is there. In this
# program it puts in only PeaZip, Edit and micro: rclone, the terminal and cloudflared are kept by
# Update-Tools.ps1, which calls this script for the three. The branches of rclone and the terminal
# below are the original's and are not reached here.
#
#   -Tool peazip   7-Zip and zstd from PeaZip portable -> Tools\PeaZip
#   -Tool rclone   rclone for BISYNC and the rclone engine -> Tools\rclone
#   -Tool edit     Microsoft Edit, the default editor of F4 (MIT) -> Tools\edit
#   -Tool micro    micro, the second editor of F4 (MIT), kept for the Linux port -> Tools\micro
#   -Tool terminal Windows Terminal (MIT), portable, for Ctrl+Enter and the editors -> Tools\terminal
#   -PruneOnly     tidy an existing copy without downloading
#   -IfNewer       download only when GitHub has a newer version or the tool is missing
#
# The latest version every time; the old copy is replaced whole and only once
# the new one is unpacked and checked, so a failed download never leaves a
# half-installed tool behind. GitHub without the API first (releases/latest
# redirect): the API allows 60 calls an hour and is only the fallback.
#
# Only what the program runs is kept: of PeaZip - res\bin\7z, res\bin\zstd and
# the licences (39 MB -> about 8 MB); of rclone - the executable and its
# README with the licence, not the man page and the HTML copy; of Edit - the
# executable, not its debug symbols (edit.pdb); of micro - the executable,
# README and licences, not the man page and the Linux desktop entry. Each tool
# gets a version.txt; the program reads it for the update dots of PeaZip and
# rclone - the editors and the terminal have no dots, [06] of the builder keeps
# them fresh. The terminal runs in portable mode (a .portable file beside it);
# the owner's config\terminal (.portable, settings\settings.json) is laid over
# every new copy - config\ survives the cleanup, Tools\terminal is replaced whole.

param(
    [Parameter(Mandatory)][ValidateSet("peazip", "edit", "micro")][string]$Tool,
    [string]$Root = "",
    [switch]$PruneOnly,
    [switch]$IfNewer
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }

$tools = Join-Path $Root "Tools"
$stage = Join-Path $Root "._runtime\tools_stage"
New-Item -ItemType Directory -Force -Path $tools, $stage | Out-Null
$headers = @{ "User-Agent" = "Audion-Sync-Tools" }
$folders = @{ peazip = "PeaZip"; rclone = "rclone"; edit = "edit"; micro = "micro"; terminal = "terminal" }
$repos = @{ peazip = "peazip/PeaZip"; rclone = "rclone/rclone"; edit = "microsoft/edit"; micro = "micro-editor/micro"; terminal = "microsoft/terminal" }
# The editors answer with their version and exit: "edit version 1.2.1", "Version: 2.0.14".
$versionArg = @{ edit = "--version"; micro = "-version" }

function Get-LatestTag([string]$Repo) {
    try {
        $request = [Net.HttpWebRequest]::Create("https://github.com/$Repo/releases/latest")
        $request.AllowAutoRedirect = $false
        $request.UserAgent = "Audion-Sync-Tools"
        $response = $request.GetResponse()
        $location = $response.Headers["Location"]
        $response.Close()
        if ($location -match '/tag/(?<tag>[^/]+)$') { return $Matches.tag }
    } catch { Write-Host "[WARN] releases/latest redirect failed, using the API: $($_.Exception.Message)" }
    $release = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/$Repo/releases/latest"
    return $release.tag_name
}

# micro and PeaZip are not signed by their makers, but both lay a file of SHA-256 sums beside the
# release: micro - <asset>.sha, PeaZip - SHA256.txt. The archive is compared with it before anything
# of it is unpacked or started, the way Update-Tools.ps1 compares the archive of rclone. A sum that
# differs refuses the archive, and what stood before stays. A file of sums that could not be
# fetched, or holds no line for the archive, is said and the install goes on: the first start of
# the program begins with these tools.
function Get-PublisherSums([string]$Url) {
    $file = Join-Path $stage ([guid]::NewGuid().ToString("N") + ".sums")
    try {
        Invoke-WebRequest -Headers $headers -Uri $Url -OutFile $file
        return [IO.File]::ReadAllText($file)
    } catch {
        return ""
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PublisherSum([string]$File, [string]$Sums, [string]$Name, [string]$What) {
    $line = @($Sums -split "`r?`n" | Where-Object { $_ -match ('^\s*[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($Name) + '\s*$') }) | Select-Object -First 1
    if (-not $line) {
        Write-Host "[WARN] ${What}: the checksum of the publisher was not found - the archive is not compared"
        return $false
    }
    $want = ([regex]::Match($line, '[0-9a-fA-F]{64}')).Value
    $have = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($have -ne $want) { throw "${What}: the archive does not match the checksum of its publisher - not installed." }
    Write-Host "[SUM] ${What}: the archive matches the checksum of its publisher"
    return $true
}

function Write-Version([string]$Dir, [string]$Version) {
    [IO.File]::WriteAllText((Join-Path $Dir "version.txt"), $Version.Trim().TrimStart("v"), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-PrunePeaZip([string]$Dir) {
    # Keep res\bin\7z, res\bin\zstd and res\share\copying; everything else is PeaZip's own window.
    $keep = @("res\bin\7z", "res\bin\zstd", "res\share\copying") | ForEach-Object { Join-Path $Dir $_ }
    Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -ne "version.txt" } | Remove-Item -Force
    foreach ($folder in Get-ChildItem -LiteralPath $Dir -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending) {
        $path = $folder.FullName
        $inside = $keep | Where-Object { $path -eq $_ -or $path.StartsWith("$_\") }
        $above = $keep | Where-Object { $_.StartsWith("$path\") }
        if ($inside) { continue }
        if ($above) { Get-ChildItem -LiteralPath $path -File | Remove-Item -Force; continue }
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

function Invoke-PruneRclone([string]$Dir) {
    foreach ($name in @("rclone.1", "README.html", "git-log.txt")) {
        $file = Join-Path $Dir $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}

function Invoke-PruneEdit([string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter "*.pdb" | Remove-Item -Force
}

function Invoke-PruneMicro([string]$Dir) {
    foreach ($name in @("micro.1", "micro.desktop", "micro.svg")) {
        $file = Join-Path $Dir $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
}

# Portable mode: with .portable beside it the terminal keeps its settings in settings\ next to itself.
function Invoke-PruneTerminal([string]$Dir) {
    [IO.File]::WriteAllText((Join-Path $Dir ".portable"), "")
}

# What an editor says about its own version: the digits of its first line.
function Get-EditorVersion([string]$Which, [string]$Dir) {
    $out = (& (Join-Path $Dir "$Which.exe") $versionArg[$Which] 2>&1 | Select-Object -First 1) -as [string]
    if ($out -match '(?<v>\d+(\.\d+)+)') { return $Matches.v }
    return ""
}

# A real x64 Windows program, read from its header: MZ, the PE signature where
# the header points, the x64 machine. The terminal is not started to prove it
# (it would open a window), so a version string alone must not pass (audit 5.4.1 N2).
function Test-Executable([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $head = New-Object byte[] 4096
        $read = $stream.Read($head, 0, $head.Length)
    } finally { $stream.Dispose() }
    if ($read -lt 64 -or $head[0] -ne 0x4D -or $head[1] -ne 0x5A) { return $false }
    $pe = [BitConverter]::ToInt32($head, 0x3C)
    if ($pe -lt 0 -or $pe + 6 -gt $read) { return $false }
    if ($head[$pe] -ne 0x50 -or $head[$pe + 1] -ne 0x45 -or $head[$pe + 2] -ne 0 -or $head[$pe + 3] -ne 0) { return $false }
    return [BitConverter]::ToUInt16($head, $pe + 4) -eq 0x8664
}

# A tool is complete and runs, or this throws. Called on the staged copy before
# the old one is touched, and again on the installed copy after the switch.
function Test-Tool([string]$Which, [string]$Dir) {
    if ($Which -eq "peazip") {
        foreach ($need in @("res\bin\7z\7z.exe", "res\bin\7z\7z.dll", "res\bin\zstd\zstd.exe", "version.txt")) {
            if (-not (Test-Path -LiteralPath (Join-Path $Dir $need))) { throw "PeaZip is incomplete: $need is missing." }
        }
        & (Join-Path $Dir "res\bin\7z\7z.exe") i *> $null
        if ($LASTEXITCODE -ne 0) { throw "7z.exe does not run (exit $LASTEXITCODE)." }
        & (Join-Path $Dir "res\bin\zstd\zstd.exe") --version *> $null
        if ($LASTEXITCODE -ne 0) { throw "zstd.exe does not run (exit $LASTEXITCODE)." }
    } elseif ($Which -eq "terminal") {
        # The parts it cannot start without; the settings editor and extras are not required.
        foreach ($need in @("WindowsTerminal.exe", "wt.exe", "OpenConsole.exe", "TerminalApp.dll", "TerminalConnection.dll",
                            "Microsoft.Terminal.Control.dll", "Microsoft.UI.Xaml.dll", ".portable", "version.txt")) {
            if (-not (Test-Path -LiteralPath (Join-Path $Dir $need))) { throw "Windows Terminal is incomplete: $need is missing." }
        }
        # Every program and library of the package: an x64 Windows file, signed by
        # Microsoft with a valid signature - a damaged or foreign file is refused
        # before the old copy goes. It is still not started: that would open a window.
        foreach ($binary in Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Extension -in @(".exe", ".dll") }) {
            if (-not (Test-Executable $binary.FullName)) { throw "Windows Terminal is damaged: $($binary.Name) is not an x64 Windows file." }
            $signature = Get-AuthenticodeSignature -LiteralPath $binary.FullName
            if ($signature.Status -ne "Valid" -or $signature.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
                throw "Windows Terminal is not genuine: $($binary.Name) - signature $($signature.Status)."
            }
        }
        if (-not (Get-Item -LiteralPath (Join-Path $Dir "WindowsTerminal.exe")).VersionInfo.ProductVersion) { throw "WindowsTerminal.exe has no version - a damaged copy." }
    } elseif ($Which -in @("edit", "micro")) {
        $exe = Join-Path $Dir "$Which.exe"
        if (-not (Test-Path -LiteralPath $exe)) { throw "$Which is incomplete: $Which.exe is missing." }
        # Microsoft Edit is signed by Microsoft: that is checked before the file is started for the
        # first time. micro is not signed by its makers: its archive was compared with their checksum.
        if ($Which -eq "edit") {
            $signature = Get-AuthenticodeSignature -LiteralPath $exe
            if ($signature.Status -ne "Valid" -or "$($signature.SignerCertificate.Subject)" -notmatch '^CN=Microsoft Corporation,') {
                throw "Microsoft Edit is not genuine: edit.exe - signature $($signature.Status)."
            }
        }
        & $exe $versionArg[$Which] *> $null
        if ($LASTEXITCODE -ne 0) { throw "$Which.exe does not run (exit $LASTEXITCODE)." }
    } else {
        $exe = Join-Path $Dir "rclone.exe"
        if (-not (Test-Path -LiteralPath $exe)) { throw "rclone is incomplete: rclone.exe is missing." }
        & $exe version *> $null
        if ($LASTEXITCODE -ne 0) { throw "rclone.exe does not run (exit $LASTEXITCODE)." }
    }
}

# What runs from a folder: a program started from it holds its files, and Windows
# refuses to rename or delete the folder while any file in it is open.
function Get-Holders([string]$Folder) {
    $prefix = $Folder.TrimEnd('\') + '\'
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { $false } } |
        ForEach-Object { "$($_.ProcessName) (PID $($_.Id))" }
}

# A tool folder is renamed or removed only when nothing holds a file in it. Windows says
# "Access to the path is denied" for an open file inside - a terminal started from the copy,
# the antivirus or the search indexer reading a fresh file. Those last a moment: try again
# for ten seconds; then say plainly what holds the folder, into the output the journal keeps
# (03.10.2026: [06] failed on Tools\terminal with no reason in the journal, a retry a minute
# later went through).
function Invoke-Retrying([string]$Folder, [string]$What, [scriptblock]$Step, [int]$Tries = 10) {
    for ($try = 1; ; $try++) {
        try { & $Step; return }
        catch {
            if ($try -ge $Tries) {
                $holders = @(Get-Holders $Folder)
                $who = if ($holders.Count -gt 0) { "held by " + ($holders -join ", ") + " - close it and run again" }
                       else { "a file in it is open (a program started from it, the antivirus or the indexer) - run again in a minute" }
                $message = "$What failed: $(Split-Path $Folder -Leaf) is in use, $who. ($($_.Exception.Message))"
                Write-Host "[ERROR] $message"
                throw $message
            }
            Start-Sleep -Seconds 1
        }
    }
}

# An earlier run stopped between "old aside" and "new in place": put the old one back.
function Repair-Interrupted([string]$Target) {
    $old = "$Target.old"
    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $Target)) {
        Rename-Item -LiteralPath $old -NewName (Split-Path $Target -Leaf)
        Write-Host "[REPAIR] restored $(Split-Path $Target -Leaf) from an interrupted update"
    }
}

function Install-Folder([string]$Zip, [string]$Marker, [string]$Target, [scriptblock]$Prune, [string]$Version, [string]$Which) {
    $unpacked = Join-Path $stage ([IO.Path]::GetFileNameWithoutExtension($Zip))
    if (Test-Path -LiteralPath $unpacked) { Remove-Item -LiteralPath $unpacked -Recurse -Force }
    # By .NET, not Expand-Archive: the PowerShell that rides inside the program has no Archive module.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $unpacked)
    $found = Get-ChildItem -LiteralPath $unpacked -Recurse -Filter $Marker -File | Select-Object -First 1
    if (-not $found) { throw "$Marker was not found in $Zip" }
    $source = $found.Directory.FullName
    & $Prune $source
    Write-Version $source $Version
    # The owner's terminal config goes over the fresh copy, before it is checked.
    $config = Join-Path $Root "config\terminal"
    if ($Which -eq "terminal" -and (Test-Path -LiteralPath $config)) {
        Get-ChildItem -LiteralPath $config -Force | Copy-Item -Destination $source -Recurse -Force
    }
    if ($Which -eq "rclone") {
        $line = (& (Join-Path $source "rclone.exe") version | Select-Object -First 1)
        if ($line -match 'v(?<v>[\d.]+)') { Write-Version $source $Matches.v }
    }
    # The new copy proves itself before the old one moves an inch.
    Test-Tool $Which $source

    Repair-Interrupted $Target
    $old = "$Target.old"
    if (Test-Path -LiteralPath $old) {
        Invoke-Retrying $old "Removing the copy left by an earlier update" { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop }
    }
    # Nothing is touched until the old copy can move aside whole: on failure it stays as it was, working.
    if (Test-Path -LiteralPath $Target) {
        Invoke-Retrying $Target "The update" { Rename-Item -LiteralPath $Target -NewName (Split-Path $old -Leaf) -ErrorAction Stop }
    }
    try {
        Move-Item -LiteralPath $source -Destination $Target
        Test-Tool $Which $Target
    } catch {
        # Anything wrong after the switch: the new one goes, the old one comes back.
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $old) { Rename-Item -LiteralPath $old -NewName (Split-Path $Target -Leaf) }
        throw
    }
    # Only now, with the new copy installed and checked, the old one is removed. The new one is in
    # place already: an old copy still held is only a leftover, the next run removes it.
    if (Test-Path -LiteralPath $old) {
        try { Invoke-Retrying $old "Removing the old copy" { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction Stop } -Tries 5 }
        catch { Write-Host "[WARN] $(Split-Path $old -Leaf) is left behind - the next update removes it." }
    }
    Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
}

Repair-Interrupted (Join-Path $tools $folders[$Tool])
# -IfNewer: the version in version.txt against the latest GitHub tag; equal - nothing to do.
if ($IfNewer -and -not $PruneOnly) {
    $folder = Join-Path $tools $folders[$Tool]
    $stamp = Join-Path $folder "version.txt"
    $installed = if (Test-Path -LiteralPath $stamp) { (Get-Content -LiteralPath $stamp -Raw).Trim() } else { "" }
    # An editor put in by hand has no version.txt yet: it tells its version itself.
    if (-not $installed -and $Tool -in @("edit", "micro") -and (Test-Path -LiteralPath (Join-Path $folder "$Tool.exe"))) { $installed = Get-EditorVersion $Tool $folder }
    $latest = (Get-LatestTag $repos[$Tool]).TrimStart("v")
    $current = $false
    try { $current = $installed -and ([version]$installed -ge [version]$latest) } catch { $current = ($installed -eq $latest) }
    # A terminal put together by hand has no version.txt, and its exe counts its
    # own way (1.24.260710001 against the tag 1.24.11911.0): only the release line compares.
    $exe = Join-Path $folder "WindowsTerminal.exe"
    if ($Tool -eq "terminal" -and -not (Test-Path -LiteralPath $stamp) -and (Test-Path -LiteralPath $exe)) {
        $own = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        $line = { param($v) [version]((($v -split '\.')[0..1]) -join '.') }
        $installed = $own
        $current = (& $line $own) -ge (& $line $latest)
    }
    if ($current) {
        Write-Host "[OK] $Tool $installed is the latest - nothing to download."
        exit 0
    }
    Write-Host "[UPDATE] $Tool $(if ($installed) { $installed } else { 'missing' }) -> $latest"
}

switch ($Tool) {
    "peazip" {
        $target = Join-Path $tools "PeaZip"
        if ($PruneOnly) {
            $exe = Join-Path $target "peazip.exe"
            if ((Test-Path -LiteralPath $exe) -and -not (Test-Path -LiteralPath (Join-Path $target "version.txt"))) {
                Write-Version $target ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)
            }
            Invoke-PrunePeaZip $target
        } else {
            $tag = Get-LatestTag "peazip/PeaZip"
            $version = $tag.TrimStart("v")
            $url = "https://github.com/peazip/PeaZip/releases/download/$tag/peazip_portable-$version.WIN64.zip"
            $zip = Join-Path $stage "peazip_portable-$version.WIN64.zip"
            Write-Host "[PEAZIP] $version"
            Write-Host "[URL] $url"
            # The line of SHA256.txt is found by the name the publisher gave the file. By the straight
            # address that is the name it is saved under; by the fallback one it is whatever the release holds.
            $published = Split-Path $zip -Leaf
            try {
                Invoke-WebRequest -Headers $headers -Uri $url -OutFile $zip
            } catch {
                Write-Host "[WARN] direct asset failed, asking the API: $($_.Exception.Message)"
                $release = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/peazip/PeaZip/releases/latest"
                $asset = $release.assets | Where-Object { $_.name -like "peazip_portable-*.WIN64.zip" } | Select-Object -First 1
                if (-not $asset) { throw "No peazip_portable-*.WIN64.zip in the latest release." }
                Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $zip
                $published = [string]$asset.name
            }
            [void](Assert-PublisherSum -File $zip -Sums (Get-PublisherSums "https://github.com/peazip/PeaZip/releases/download/$tag/SHA256.txt") -Name $published -What "PeaZip")
            Install-Folder -Zip $zip -Marker "peazip.exe" -Target $target -Prune ${function:Invoke-PrunePeaZip} -Version $version -Which peazip
        }
        foreach ($need in @("res\bin\7z\7z.exe", "res\bin\zstd\zstd.exe", "version.txt")) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $need))) { throw "Tools\PeaZip\$need is missing." }
        }
        Write-Host ("[OK] PeaZip {0} -> Tools\PeaZip ({1:N1} MB)" -f (Get-Content (Join-Path $target "version.txt")), ((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    }
    "rclone" {
        $target = Join-Path $tools "rclone"
        if (-not $PruneOnly) {
            # rclone keeps a stable address for the current build: no GitHub needed.
            $url = "https://downloads.rclone.org/rclone-current-windows-amd64.zip"
            $zip = Join-Path $stage "rclone-current-windows-amd64.zip"
            Write-Host "[URL] $url"
            Invoke-WebRequest -Headers $headers -Uri $url -OutFile $zip
            Install-Folder -Zip $zip -Marker "rclone.exe" -Target $target -Prune ${function:Invoke-PruneRclone} -Version "0" -Which rclone
        } else {
            Invoke-PruneRclone $target
        }
        $line = (& (Join-Path $target "rclone.exe") version | Select-Object -First 1)
        if ($line -match 'v(?<v>[\d.]+)') { Write-Version $target $Matches.v }
        Write-Host ("[OK] {0} -> Tools\rclone ({1:N1} MB)" -f $line, ((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    }
    "terminal" {
        $target = Join-Path $tools "terminal"
        if (-not $PruneOnly) {
            $tag = Get-LatestTag $repos.terminal
            $version = $tag.TrimStart("v")
            $asset = "Microsoft.WindowsTerminal_$($version)_x64.zip"
            $url = "https://github.com/$($repos.terminal)/releases/download/$tag/$asset"
            $zip = Join-Path $stage $asset
            Write-Host "[TERMINAL] $version"
            Write-Host "[URL] $url"
            Invoke-WebRequest -Headers $headers -Uri $url -OutFile $zip
            Install-Folder -Zip $zip -Marker "WindowsTerminal.exe" -Target $target -Prune ${function:Invoke-PruneTerminal} -Version $version -Which terminal
        } else {
            Invoke-PruneTerminal $target
        }
        Write-Host ("[OK] Windows Terminal {0} -> Tools\terminal ({1:N1} MB)" -f (Get-Content (Join-Path $target "version.txt")), ((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    }
    { $_ -in @("edit", "micro") } {
        $target = Join-Path $tools $folders[$Tool]
        $prune = if ($Tool -eq "edit") { ${function:Invoke-PruneEdit} } else { ${function:Invoke-PruneMicro} }
        if (-not $PruneOnly) {
            $tag = Get-LatestTag $repos[$Tool]
            $version = $tag.TrimStart("v")
            $asset = if ($Tool -eq "edit") { "edit-$version-x86_64-windows.zip" } else { "micro-$version-win64.zip" }
            $url = "https://github.com/$($repos[$Tool])/releases/download/$tag/$asset"
            $zip = Join-Path $stage $asset
            Write-Host "[$($Tool.ToUpper())] $version"
            Write-Host "[URL] $url"
            Invoke-WebRequest -Headers $headers -Uri $url -OutFile $zip
            # micro: the sum its publisher lays beside the asset. Microsoft Edit is signed - Test-Tool checks that.
            if ($Tool -eq "micro") { [void](Assert-PublisherSum -File $zip -Sums (Get-PublisherSums "$url.sha") -Name $asset -What "micro") }
            Install-Folder -Zip $zip -Marker "$Tool.exe" -Target $target -Prune $prune -Version $version -Which $Tool
        } else {
            & $prune $target
            if (-not (Test-Path -LiteralPath (Join-Path $target "version.txt"))) { Write-Version $target (Get-EditorVersion $Tool $target) }
        }
        Write-Host ("[OK] {0} {1} -> Tools\{2} ({3:N1} MB)" -f $Tool, (Get-Content (Join-Path $target "version.txt")), $folders[$Tool], ((Get-ChildItem $target -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    }
}
