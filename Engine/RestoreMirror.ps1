# RESTORE MIRROR: after a Windows reinstall C: keeps exactly what the selected
# DATA describes. Whatever the profile, Startup or old versions left behind is
# moved into DATA\._runtime\mirror-<time>: off the system disk, restorable by
# hand, never silently deleted. Human steps (UAC, Access login, router
# passwords) wait as long as the person needs; there are no timeouts on them.

function Protect-AbkMirrorFolder {
    param([Parameter(Mandatory)][string]$Path)
    # Removed private keys land here: this user, SYSTEM and Administrators only.
    # Native tools write to stderr; under Stop Windows PowerShell 5.1 would throw.
    $ErrorActionPreference = 'Continue'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r ('*' + $me + ':(OI)(CI)(F)') '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('Cannot restrict MIRROR backup: ' + $Path) }
}

function New-AbkMirrorBackup {
    param([Parameter(Mandatory)][string]$DataRoot)
    $path = Join-Path $DataRoot ('._runtime\mirror-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    Protect-AbkMirrorFolder -Path $path
    return $path
}

function Move-AbkMirrorItem {
    <# Moves a file or folder into the backup under Name; returns the new path. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Backup,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $target = Join-Path $Backup $Name
    if (Test-Path -LiteralPath $target) { throw ('MIRROR backup already holds ' + $Name) }
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    # Copy, then remove: DATA usually sits on another volume, and a failed
    # cross-volume move leaves half a folder on each side.
    Copy-Item -LiteralPath $Path -Destination $target -Recurse -Force
    Remove-Item -LiteralPath $Path -Recurse -Force
    return $target
}

function Get-AbkMirrorLeftovers {
    <# Files earlier versions put on C: that DATA does not describe. #>
    param([string]$StartupFolder = [Environment]::GetFolderPath('Startup'))
    $items = @()
    # The program always passes DATA\config\rclone\rclone.conf explicitly; a
    # default rclone.conf is a leftover of older versions, with old secrets.
    foreach ($pair in @(@((Join-Path $env:APPDATA 'rclone\rclone.conf'), 'leftovers\AppData-rclone.conf'),
                        @((Join-Path $HOME '.config\rclone\rclone.conf'), 'leftovers\dot-config-rclone.conf'))) {
        if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
            $items += [pscustomobject]@{ Path = $pair[0]; Name = $pair[1]; What = 'rclone.conf outside DATA' }
        }
    }
    # RESTORE recreates only the enabled channel of this machine afterwards.
    foreach ($link in @(Get-ChildItem -LiteralPath $StartupFolder -Filter 'Audion SSH Beacon *.lnk' -File -ErrorAction SilentlyContinue)) {
        $items += [pscustomobject]@{ Path = $link.FullName; Name = ('Startup\' + $link.Name); What = 'REVERSE SSH TUN Startup' }
    }
    $items
}

function Read-AbkMirrorRetry {
    <# $true - try again, $false - skip. Waits for the answer as long as needed. #>
    param([Parameter(Mandatory)][string]$Text)
    $answer = Read-Host ('  ' + $Text + ' [Enter - ещё раз, S - пропустить]')
    return -not ("$answer".Trim() -match '^[sSыЫ]')
}

function Invoke-AbkElevatedStep {
    <#
        Runs a script as administrator and returns its exit code, or $null when
        the person chose to skip. A declined UAC prompt is asked again instead
        of failing the whole RESTORE.
    #>
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @(), [switch]$NoPrompt)
    $hostExe = (Get-Process -Id $PID).Path
    $line = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + ($Arguments -join ' ')
    while ($true) {
        try {
            $process = Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $line -Wait -PassThru
            return $process.ExitCode
        } catch {
            Write-Host '  UAC не подтверждён.' -ForegroundColor Yellow
            if ($NoPrompt -or -not (Read-AbkMirrorRetry 'Запросить UAC снова?')) { return $null }
        }
    }
}

function Get-AbkAccessHosts {
    <# HostName of every ssh route that goes through cloudflared access. #>
    param([Parameter(Mandatory)][string]$SshConfig)
    if (-not (Test-Path -LiteralPath $SshConfig)) { return @() }
    $found = @()
    $name = ''
    $viaAccess = $false
    foreach ($line in @([IO.File]::ReadAllLines($SshConfig)) + @('Host __end__')) {
        if ($line -match '^\s*(Host|Match)\s') {
            if ($viaAccess -and $name -and $name -notmatch '[%*?]') { $found += $name }
            $name = ''; $viaAccess = $false
            continue
        }
        if ($line -match '^\s*HostName\s+(\S+)') { $name = $Matches[1] }
        elseif ($line -match '^\s*ProxyCommand\s.*cloudflared') { $viaAccess = $true }
    }
    @($found | Sort-Object -Unique)
}

function Test-AbkAccessToken {
    param([Parameter(Mandatory)][string]$Cloudflared, [Parameter(Mandatory)][string]$HostName)
    # Exit code only: on success the command prints the JWT itself.
    $ErrorActionPreference = 'Continue'
    $null = & $Cloudflared access token ('-app=https://' + $HostName) 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-AbkAccessLogins {
    <# Cloudflare Access sign-in for every cloudflared route; waits for the person. #>
    param([Parameter(Mandatory)][string]$Cloudflared, [Parameter(Mandatory)][string]$SshConfig, [switch]$NoPrompt)
    $ErrorActionPreference = 'Continue'
    $result = @()
    foreach ($name in @(Get-AbkAccessHosts -SshConfig $SshConfig)) {
        if (Test-AbkAccessToken -Cloudflared $Cloudflared -HostName $name) {
            Write-Host ('  ' + $name + ': вход в Access уже есть') -ForegroundColor Green
            $result += [pscustomobject]@{ Name = $name; State = 'ok' }
            continue
        }
        if ($NoPrompt) {
            Write-Host ('  ' + $name + ': входа в Access нет (NoPrompt)') -ForegroundColor Yellow
            $result += [pscustomobject]@{ Name = $name; State = 'missing' }
            continue
        }
        $state = 'skipped'
        while ($true) {
            Write-Host ('  ' + $name + ': откроется браузер - войдите в Cloudflare Access') -ForegroundColor Cyan
            # --quiet keeps the JWT out of the console and the RESTORE log.
            & $Cloudflared access login --quiet --auto-close ('https://' + $name) 2>&1 | ForEach-Object {
                Write-Host ('    ' + ("$_" -replace 'eyJ[\w-]+\.[\w-]+\.[\w-]+', '<token>'))
            }
            if (Test-AbkAccessToken -Cloudflared $Cloudflared -HostName $name) {
                Write-Host ('  ' + $name + ': вход в Access выполнен') -ForegroundColor Green
                $state = 'ok'
                break
            }
            if (-not (Read-AbkMirrorRetry ($name + ': вход не завершён.'))) { break }
        }
        $result += [pscustomobject]@{ Name = $name; State = $state }
    }
    $result
}

function Test-AbkRouterAnswers {
    <# Does the router API answer from here. Network probe, not a human step. #>
    param([Parameter(Mandatory)][string]$Address)
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(4)
    try {
        $answer = $client.GetAsync("http://$Address/auth").GetAwaiter().GetResult()
        return ([int]$answer.StatusCode -in @(200, 401))
    } catch { return $false } finally { $client.Dispose() }
}

function Test-AbkRouterLogin {
    <# A real login with this password; the error text or '' on success. #>
    param([string]$Address, [string]$User, [securestring]$Password)
    try {
        $session = Connect-Router -Address $Address -User $User -Password $Password
        Disconnect-Router -Session $session
        return ''
    } catch { return $_.Exception.Message.Split("`n")[0] }
}

function Read-AbkRouterShared {
    <# Asks once whether the owner keeps one password on every router. #>
    param([string]$From, [string[]]$Others)
    $answer = Read-Host ('  Тот же пароль, что у ' + $From + ', стоит и на ' + ($Others -join ', ') + '? [y - да, Enter - нет]')
    return ("$answer".Trim() -match '^[yYдД]')
}

function Invoke-AbkRouterLogins {
    <#
        Router passwords DATA does not hold yet. Each password is proven by a
        real login before it is saved; a wrong one is asked again, an empty
        answer skips. Whether one password serves every router is the owner's
        choice (targets.json `_routers.sharedPassword`): asked once, kept in
        DATA. Only then is a proven password tried on the other routers that
        answer from here and stored for routers of other sites. Stored
        passwords are never overwritten.
    #>
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$DataRoot, [switch]$NoPrompt)
    Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -Force -DisableNameChecking
    $targetsPath = Join-Path $DataRoot 'Tunnel\RemoteDesktop\config\targets.json'
    $targets = [IO.File]::ReadAllText($targetsPath) | ConvertFrom-Json
    $routers = @()
    foreach ($key in @('router-base', 'router-home', 'router-work')) {
        if (-not $targets.PSObject.Properties[$key]) { continue }
        $address = try { Get-RouterAddress -Router $key -Root $DataRoot } catch { '' }
        if (-not $address) { continue }
        $entry = $targets.$key
        $routers += [pscustomobject]@{
            Key = $key; Address = $address
            User = $(if ($entry.PSObject.Properties['user'] -and $entry.user) { [string]$entry.user } else { 'admin' })
            Label = ('{0} ({1})' -f $key.ToUpperInvariant(), $address)
            Kept = [bool](Get-RouterSecret -Router $key -Root $DataRoot)
            Answers = $false; State = ''
        }
    }
    $policy = Get-RouterPasswordShared -Root $DataRoot
    $source = $null
    foreach ($router in @($routers | Where-Object { $_.Kept })) {
        if (-not $source) { $source = $router }
        $router.State = 'ok'
        Write-Host ('  ' + $router.Label + ': пароль есть в DATA') -ForegroundColor Green
    }
    $lacking = @($routers | Where-Object { -not $_.Kept })
    if ($source -and $lacking.Count -and $null -eq $policy -and -not $NoPrompt) {
        $policy = Read-AbkRouterShared -From $source.Label -Others @($lacking | ForEach-Object { $_.Label })
        Set-RouterPasswordShared -Shared $policy -Root $DataRoot
    }
    $shared = $(if ($policy -eq $true -and $source) { Get-RouterSecret -Router $source.Key -Root $DataRoot } else { $null })
    foreach ($router in $lacking) {
        $router.Answers = Test-AbkRouterAnswers -Address $router.Address
        if (-not $router.Answers) { continue }
        if ($shared -and -not (Test-AbkRouterLogin -Address $router.Address -User $router.User -Password $shared)) {
            $kept = Save-RouterSecret -Router $router.Key -Password $shared -Root $DataRoot
            Write-Host ('  ' + $router.Label + ': общий пароль подошёл, сохранён: ' + $kept) -ForegroundColor Green
            $router.State = 'ok'
            continue
        }
        if ($NoPrompt) {
            Write-Host ('  ' + $router.Label + ': пароля нет (NoPrompt)') -ForegroundColor Yellow
            $router.State = 'missing'
            continue
        }
        $router.State = 'skipped'
        while ($true) {
            $password = Read-Host ('  Пароль ' + $router.User + ' на ' + $router.Label + ', пустой Enter - пропустить') -AsSecureString
            if (-not $password -or $password.Length -eq 0) { break }
            $failure = Test-AbkRouterLogin -Address $router.Address -User $router.User -Password $password
            if ($failure) { Write-Host ('  ' + $router.Label + ': ' + $failure) -ForegroundColor Yellow; continue }
            $kept = Save-RouterSecret -Router $router.Key -Password $password -Root $DataRoot
            Write-Host ('  ' + $router.Label + ': вход проверен, пароль сохранён: ' + $kept) -ForegroundColor Green
            $router.State = 'ok'
            if (-not $shared) {
                $rest = @($lacking | Where-Object { $_.Key -ne $router.Key -and $_.State -ne 'ok' })
                if ($null -eq $policy -and $rest.Count) {
                    $policy = Read-AbkRouterShared -From $router.Label -Others @($rest | ForEach-Object { $_.Label })
                    Set-RouterPasswordShared -Shared $policy -Root $DataRoot
                }
                if ($policy -eq $true) { $shared = $password }
            }
            break
        }
    }
    # Routers of other sites cannot be checked from here: only with the owner's
    # "one password everywhere" do they get the password proven on this site.
    foreach ($router in @($lacking | Where-Object { -not $_.Answers })) {
        if ($shared) {
            $kept = Save-RouterSecret -Router $router.Key -Password $shared -Root $DataRoot
            Write-Host ('  ' + $router.Label + ': отсюда не виден, сохранён общий пароль (не проверен): ' + $kept)
            $router.State = 'shared'
        } else {
            Write-Host ('  ' + $router.Label + ': отсюда не виден - пропущен')
            $router.State = 'unreachable'
        }
    }
    @($routers | ForEach-Object { [pscustomobject]@{ Name = $_.Key; State = $_.State } })
}
