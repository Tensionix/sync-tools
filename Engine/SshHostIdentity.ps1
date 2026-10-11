# sshd identity belongs to the selected DATA folder, not to the Windows profile.
# Tunnel\SSHD is intentionally separate from client golden copies and Export.
function Protect-AbkHostIdentityFile {
    param([string]$Path, [switch]$Archive, [switch]$Directory)
    $owner = if ($Archive) { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } else { 'S-1-5-32-544' }
    $allowed = @($owner, 'S-1-5-18', 'S-1-5-32-544') | Select-Object -Unique
    # Set-Acl with a fresh descriptor requests SeSecurityPrivilege on some hosts.
    # icacls applies only the owner/DACL we need, including removal of explicit ACEs.
    & icacls.exe $Path /setowner ('*' + $owner) /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot set SSHD key owner' }
    $rights = if ($Directory) { ':(OI)(CI)(F)' } else { ':(F)' }
    $grants = @($allowed | ForEach-Object { '*' + $_ + $rights })
    & icacls.exe $Path /inheritance:r /grant:r @grants /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restrict SSHD key permissions' }
    foreach ($rule in (Get-Acl -LiteralPath $Path).Access) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($rule.AccessControlType -eq 'Deny' -or $sid -notin $allowed) {
            $remove = if ($rule.AccessControlType -eq 'Deny') { '/remove:d' } else { '/remove:g' }
            & icacls.exe $Path $remove ('*' + $sid) /Q 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Cannot remove foreign SSHD key permissions' }
        }
    }
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $owner -or
        @($acl.Access | Where-Object { $_.AccessControlType -ne 'Allow' -or $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed }).Count) { throw 'SSHD key ACL verification failed' }
}

function Read-AbkHostIdentityManifest {
    param([string]$Store)
    $manifestPath = Join-Path $Store 'identity.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'SSHD identity archive is incomplete: identity.json is missing' }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    $files = @($manifest.Files)
    if ($manifest.Version -ne 1 -or $files.Count -lt 2) { throw 'Invalid SSHD identity manifest' }
    $seen = @{}
    foreach ($entry in $files) {
        if ($entry.Name -notmatch '^ssh_host_[a-z0-9]+_key(?:\.pub)?$' -or $seen.ContainsKey($entry.Name)) { throw 'Invalid SSHD identity filename' }
        $seen[$entry.Name] = $true
        $file = Join-Path $Store $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0 -or
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Sha256) { throw ('SSHD identity archive is damaged: ' + $entry.Name) }
    }
    foreach ($entry in $files) {
        $peer = if ($entry.Name.EndsWith('.pub')) { $entry.Name.Substring(0, $entry.Name.Length - 4) } else { $entry.Name + '.pub' }
        if (-not $seen.ContainsKey($peer)) { throw ('Incomplete SSHD host key pair: ' + $entry.Name) }
    }
    return $manifest
}

function Restore-AbkSshHostIdentity {
    param([Parameter(Mandatory)][string]$DataRoot, [string]$SshDirectory = (Join-Path $env:ProgramData 'ssh'),
        # RESTORE MIRROR: the saved identity wins. Differing and extra live host
        # keys are moved into Backup first instead of stopping the restore.
        [switch]$Replace, [string]$Backup)
    $store = Join-Path $DataRoot 'Tunnel\SSHD'
    if (-not (Test-Path -LiteralPath $store)) { return 'not-saved' }
    # A reinstall changes the user's SID; the elevated SSHD step reclaims only
    # this machine's retained identity so subsequent non-elevated steps can read it.
    Protect-AbkHostIdentityFile -Path $store -Archive -Directory
    foreach ($file in @(Get-ChildItem -LiteralPath $store -File)) { Protect-AbkHostIdentityFile -Path $file.FullName -Archive }
    $manifest = Read-AbkHostIdentityManifest -Store $store
    # Validate the entire archive and every existing target before writing anything.
    $conflicts = @()
    foreach ($entry in $manifest.Files) {
        $target = Join-Path $SshDirectory $entry.Name
        if ((Test-Path -LiteralPath $target) -and
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.Sha256) {
            if (-not $Replace) { throw ('SSHD identity conflict; existing and saved keys preserved: ' + $entry.Name) }
            $conflicts += $target
        }
    }
    $savedNames = @($manifest.Files | ForEach-Object { $_.Name })
    foreach ($file in @(Get-ChildItem -LiteralPath $SshDirectory -Filter 'ssh_host_*_key*' -File -ErrorAction SilentlyContinue)) {
        if ($file.Name -match '^ssh_host_[a-z0-9]+_key(?:\.pub)?$' -and $file.Name -notin $savedNames) {
            if (-not $Replace) { throw ('SSHD identity conflict: live key absent from archive: ' + $file.Name) }
            $conflicts += $file.FullName
        }
    }
    if ($conflicts.Count) {
        if (-not $Backup) { throw 'SSHD identity replace needs a backup folder' }
        $kept = Join-Path $Backup 'ProgramData-ssh'
        New-Item -ItemType Directory -Path $kept -Force | Out-Null
        foreach ($path in $conflicts) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $kept ([IO.Path]::GetFileName($path))) -Force
            Remove-Item -LiteralPath $path -Force
        }
    }
    New-Item -ItemType Directory -Path $SshDirectory -Force | Out-Null
    $copied = $false
    foreach ($entry in $manifest.Files) {
        $target = Join-Path $SshDirectory $entry.Name
        if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath (Join-Path $store $entry.Name) -Destination $target; $copied = $true }
        Protect-AbkHostIdentityFile -Path $target
    }
    if ($conflicts.Count) { return 'replaced' }
    if ($copied) { return 'restored' }
    return 'verified'
}

function Save-AbkSshHostIdentity {
    param([Parameter(Mandatory)][string]$DataRoot, [string]$SshDirectory = (Join-Path $env:ProgramData 'ssh'))
    $store = Join-Path $DataRoot 'Tunnel\SSHD'
    if (Test-Path -LiteralPath $store) {
        # An existing archive is immutable. This also verifies live identity matches.
        $null = Restore-AbkSshHostIdentity -DataRoot $DataRoot -SshDirectory $SshDirectory
        return 'verified'
    }
    $privateFiles = @(Get-ChildItem -LiteralPath $SshDirectory -File -ErrorAction Stop | Where-Object { $_.Name -match '^ssh_host_[a-z0-9]+_key$' })
    if (-not $privateFiles.Count) { throw 'SSHD produced no host keys; identity was not saved' }
    $files = @()
    foreach ($key in $privateFiles) {
        foreach ($path in @($key.FullName, ($key.FullName + '.pub'))) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) { throw ('Missing or empty SSHD host key: ' + [IO.Path]::GetFileName($path)) }
            $files += Get-Item -LiteralPath $path
        }
        # ssh-keygen derives the public half without prompting or logging key data.
        $keygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if (-not $keygen) {
            # An MSI may have just installed the service without refreshing PATH
            # in this already running PowerShell process.
            $service = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
            $match = [regex]::Match([string]$service.PathName, '^"?(.+?sshd\.exe)"?(?:\s|$)')
            if ($match.Success) {
                $sibling = Join-Path (Split-Path -Parent $match.Groups[1].Value) 'ssh-keygen.exe'
                if (Test-Path -LiteralPath $sibling -PathType Leaf) { $keygen = [pscustomobject]@{ Source=$sibling } }
            }
        }
        if (-not $keygen) { throw 'ssh-keygen.exe is required to validate the SSHD backup' }
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $keygen.Source
        $psi.Arguments = '-y -P "" -f "' + $key.FullName + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($psi)
        try {
            $output = $process.StandardOutput.ReadToEndAsync(); $errorOutput = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(15000)) { $process.Kill(); $process.WaitForExit(); throw 'SSHD host key validation timed out' }
            $derived = $output.Result.Trim() -split '\s+'
            $public = [IO.File]::ReadAllText($key.FullName + '.pub').Trim() -split '\s+'
            if ($process.ExitCode -ne 0 -or $derived.Count -lt 2 -or $public.Count -lt 2 -or
                $derived[0] -cne $public[0] -or $derived[1] -cne $public[1]) { throw ('Invalid SSHD host key pair: ' + $key.Name) }
        } finally { $process.Dispose() }
    }
    # Publish only a complete snapshot; an interrupted write never becomes trusted.
    $stage = Join-Path $DataRoot ('Tunnel\SSHD.pending-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Protect-AbkHostIdentityFile -Path $stage -Archive -Directory
    $entries = @()
    foreach ($file in $files) {
        $target = Join-Path $stage $file.Name
        Copy-Item -LiteralPath $file.FullName -Destination $target
        Protect-AbkHostIdentityFile -Path $target -Archive
        $entries += @{ Name = $file.Name; Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash }
    }
    $manifest = @{ Version = 1; SavedComputer = $env:COMPUTERNAME; Files = $entries } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText((Join-Path $stage 'identity.json'), $manifest, [Text.UTF8Encoding]::new($false))
    $null = Read-AbkHostIdentityManifest -Store $stage
    [IO.Directory]::Move($stage, $store)
    return 'saved'
}
