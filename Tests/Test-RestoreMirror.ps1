#requires -Version 5.1
# RESTORE MIRROR building blocks in a temporary lab: no profile, ProgramData,
# network or UAC of the real machine is touched.
param([string]$AppRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $AppRoot 'Engine\RestoreMirror.ps1')
. (Join-Path $AppRoot 'Engine\SshHostIdentity.ps1')
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host ('PASS ' + $Message)
}
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-restore-mirror-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
try {
    $data = Join-Path $lab 'DATA with spaces'
    $backup = New-AbkMirrorBackup -DataRoot $data
    $acl = Get-Acl -LiteralPath $backup
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    Assert ($backup.StartsWith((Join-Path $data 'Recovery\mirror-')) -and $acl.AreAccessRulesProtected -and
        @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed }).Count -eq 0) 'MIRROR backup lives in DATA\Recovery with a closed ACL'

    $profile = Join-Path $lab 'profile\.ssh'
    Put (Join-Path $profile 'old_key') 'OLD PRIVATE'
    Put (Join-Path $profile 'known_hosts') 'old.invalid ssh-ed25519 AAAA'
    Put (Join-Path $profile 'nested\leftover') 'x'
    (Get-Item -LiteralPath (Join-Path $profile 'known_hosts')).Attributes = 'Hidden'
    $moved = Move-AbkMirrorItem -Path $profile -Backup $backup -Name 'profile-ssh'
    Assert (-not (Test-Path -LiteralPath $profile) -and [IO.File]::ReadAllText((Join-Path $moved 'old_key')) -eq 'OLD PRIVATE' -and
        (Test-Path -LiteralPath (Join-Path $moved 'known_hosts')) -and (Test-Path -LiteralPath (Join-Path $moved 'nested\leftover'))) 'the whole profile folder leaves C: including hidden and nested files'
    Assert ($null -eq (Move-AbkMirrorItem -Path $profile -Backup $backup -Name 'again')) 'missing source is not an error'
    $refused = $false
    Put $profile 'second copy'
    try { $null = Move-AbkMirrorItem -Path $profile -Backup $backup -Name 'profile-ssh' } catch { $refused = $true }
    Assert ($refused -and (Test-Path -LiteralPath $profile)) 'an existing backup entry is never overwritten'

    $startup = Join-Path $lab 'Startup'
    Put (Join-Path $startup 'Audion SSH Beacon old-1234.lnk') 'lnk'
    Put (Join-Path $startup 'Telegram.lnk') 'lnk'
    $left = @(Get-AbkMirrorLeftovers -StartupFolder $startup | Where-Object { $_.Path.StartsWith($startup) })
    Assert ($left.Count -eq 1 -and $left[0].Name -eq 'Startup\Audion SSH Beacon old-1234.lnk') 'only program Startup shortcuts count as leftovers'

    $config = Join-Path $lab 'config'
    Put $config ("Host viacf`r`n    HostName ssh.example.invalid`r`n    ProxyCommand `"C:/x/cloudflared.exe`" access ssh --hostname %h`r`n" +
        "Host direct`r`n    HostName direct.example.invalid`r`n" +
        "Host jump`r`n    HostName 10.0.0.1`r`n    ProxyJump viacf`r`n" +
        "Host *`r`n    ProxyCommand cloudflared access ssh --hostname %h`r`n")
    $hosts = @(Get-AbkAccessHosts -SshConfig $config)
    Assert ($hosts.Count -eq 1 -and $hosts[0] -eq 'ssh.example.invalid') 'Access sign-in is asked only for cloudflared routes'
    $door = Get-AbkAccessLeg -SshConfig $config -Alias 'viacf'
    Assert ($door -and $door.HostName -eq 'ssh.example.invalid' -and $door.Cloudflared -eq 'C:/x/cloudflared.exe') 'REVERSE SSH TUN finds the Access door of a cloudflared leg'
    Assert ($null -eq (Get-AbkAccessLeg -SshConfig $config -Alias 'direct') -and $null -eq (Get-AbkAccessLeg -SshConfig $config -Alias 'jump') -and
        $null -eq (Get-AbkAccessLeg -SshConfig $config -Alias 'unknown')) 'direct, jump and unknown legs have no Access door'

    $fake = Join-Path $lab 'fake-cloudflared.cmd'
    Put $fake "@exit /b 1`r`n"
    $state = @(Invoke-AbkAccessLogins -Cloudflared $fake -SshConfig $config -NoPrompt)
    Assert ($state.Count -eq 1 -and $state[0].State -eq 'missing') 'NoPrompt reports a missing Access sign-in without waiting'
    Put $fake "@exit /b 0`r`n"
    $state = @(Invoke-AbkAccessLogins -Cloudflared $fake -SshConfig $config -NoPrompt)
    Assert ($state[0].State -eq 'ok') 'an existing Access sign-in is left alone'

    # administrators_authorized_keys: MIRROR keeps exactly CLIENTS.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshServer.ps1'), [ref]$tokens, [ref]$errors)
    $merge = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Merge-AccessKeys' }, $true)
    Invoke-Expression $merge.Extent.Text
    $existing = @('# old comment', 'ssh-ed25519 AAAA base', 'ssh-ed25519 FFFF neighbour', 'ssh-ed25519 OLDL laptop')
    $keys = @([pscustomobject]@{ Name = 'base'; Line = 'ssh-ed25519 AAAA base' }, [pscustomobject]@{ Name = 'laptop'; Line = 'ssh-ed25519 LLLL laptop' })
    $soft = Merge-AccessKeys -Existing $existing -Keys $keys
    Assert ($soft.Lines -contains 'ssh-ed25519 FFFF neighbour' -and $soft.Lines -contains '# old comment') 'ordinary SSHD keeps neighbours added by SSH-COPY-ID'
    $exact = Merge-AccessKeys -Existing $existing -Keys $keys -Exact
    Assert ((@($exact.Lines) -join '|') -eq 'ssh-ed25519 AAAA base|ssh-ed25519 LLLL laptop' -and $exact.Removed -contains 'neighbour' -and $exact.Removed -contains 'laptop') 'MIRROR leaves exactly CLIENTS in administrators_authorized_keys'
    $empty = Merge-AccessKeys -Existing $existing -Keys @() -Exact
    Assert (-not $empty.Changed) 'an empty CLIENTS never wipes the access file'

    # SSHD host identity: MIRROR puts DATA back over a different live identity.
    # Windows ssh-keygen gives its own files Modify without WRITE_OWNER; the
    # elevated SSHD step may take ownership, a lab user may not. Generate aside.
    $old = Join-Path $lab 'old Windows\ssh'
    [void][IO.Directory]::CreateDirectory($old)
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command ssh-keygen.exe).Source
    $psi.Arguments = '-q -t ed25519 -N "" -f "' + (Join-Path $old 'ssh_host_ed25519_key') + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $keygen = [Diagnostics.Process]::Start($psi)
    try { if (-not $keygen.WaitForExit(15000)) { $keygen.Kill(); throw 'Keygen timeout' } } finally { $keygen.Dispose() }
    $hash = (Get-FileHash -LiteralPath (Join-Path $old 'ssh_host_ed25519_key')).Hash
    Assert ((Save-AbkSshHostIdentity -DataRoot $data -SshDirectory $old) -eq 'saved') 'identity fixture saved'
    $live = Join-Path $lab 'new Windows\ssh'
    $private = Join-Path $live 'ssh_host_ed25519_key'
    Put ($private + '.pub') ([IO.File]::ReadAllText((Join-Path $old 'ssh_host_ed25519_key.pub')))
    # Live sshd files need administrator ownership; the lab keeps the same rules under its own owner.
    $protect = ${function:Protect-AbkHostIdentityFile}
    function Protect-AbkHostIdentityFile { param($Path, [switch]$Archive, [switch]$Directory) & $protect -Path $Path -Archive -Directory:$Directory }
    Put $private 'NEW WINDOWS KEY'
    Put (Join-Path $live 'ssh_host_rsa_key') 'EXTRA NEW WINDOWS KEY'
    $refused = $false
    try { $null = Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $live } catch { $refused = $_.Exception.Message -like '*conflict*' }
    Assert ($refused -and [IO.File]::ReadAllText($private) -eq 'NEW WINDOWS KEY') 'ordinary RESTORE still stops on a different identity'
    $result = Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $live -Replace -Backup $backup
    Assert ($result -eq 'replaced' -and (Get-FileHash -LiteralPath $private).Hash -eq $hash -and -not (Test-Path -LiteralPath (Join-Path $live 'ssh_host_rsa_key'))) 'MIRROR restores the DATA identity and removes extra live keys'
    Assert ([IO.File]::ReadAllText((Join-Path $backup 'ProgramData-ssh\ssh_host_ed25519_key')) -eq 'NEW WINDOWS KEY' -and
        (Test-Path -LiteralPath (Join-Path $backup 'ProgramData-ssh\ssh_host_rsa_key'))) 'replaced live host keys are kept in the MIRROR backup'
    Assert ((Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $live -Replace -Backup $backup) -eq 'verified') 'repeat MIRROR on a matching identity changes nothing'

    # Router passwords: one password for all only by the owner's choice. No network.
    $fakeApp = Join-Path $lab 'app'
    Put (Join-Path $fakeApp 'Tunnel\RemoteDesktop\RouterNdm.psm1') @'
function Get-RouterAddress { param($Router, $Root) @{ 'router-base' = '10.0.0.1'; 'router-home' = '10.0.0.2'; 'router-work' = '10.0.0.3' }[$Router] }
function Get-RouterSecret { param($Router, $Root) $p = Join-Path $Root ($Router + '.secret'); if (Test-Path -LiteralPath $p) { ConvertTo-SecureString ([IO.File]::ReadAllText($p)) -AsPlainText -Force } }
function Save-RouterSecret { param($Router, [securestring]$Password, $Root) $p = Join-Path $Root ($Router + '.secret'); [IO.File]::WriteAllText($p, [Net.NetworkCredential]::new('', $Password).Password); $p }
function Connect-Router { param($Address, $User, [securestring]$Password) if ([Net.NetworkCredential]::new('', $Password).Password -ne 'right' -or $Address -eq $env:ABK_TEST_ROUTER_DENY) { throw 'denied' }; [pscustomobject]@{} }
function Disconnect-Router { param($Session) }
function Get-RouterPasswordShared { param($Root) $p = Join-Path $Root 'policy'; if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) -eq 'true' } else { $null } }
function Set-RouterPasswordShared { param([bool]$Shared, $Root) [IO.File]::WriteAllText((Join-Path $Root 'policy'), ([string]$Shared).ToLowerInvariant()) }
Export-ModuleMember -Function *
'@
    $routerData = Join-Path $lab 'router DATA'
    Put (Join-Path $routerData 'Tunnel\RemoteDesktop\config\targets.json') '{"router-base":{"lan":"x","user":"admin"},"router-home":{"lan":"x","user":"admin"},"router-work":{"lan":"x","user":"admin"}}'
    function Test-AbkRouterAnswers { param($Address) $Address -ne '10.0.0.3' }
    function Get-States { param($Rows) (@($Rows | ForEach-Object { $_.State }) -join ',') }
    $env:ABK_TEST_ROUTER_DENY = ''
    $state = @(Invoke-AbkRouterLogins -AppRoot $fakeApp -DataRoot $routerData -NoPrompt)
    Assert ((Get-States $state) -eq 'missing,missing,unreachable' -and -not @(Get-ChildItem -LiteralPath $routerData -Filter '*.secret').Count) 'no password is stored before one is proven'
    Put (Join-Path $routerData 'router-base.secret') 'right'
    $state = @(Invoke-AbkRouterLogins -AppRoot $fakeApp -DataRoot $routerData -NoPrompt)
    Assert ((Get-States $state) -eq 'ok,missing,unreachable' -and -not (Test-Path -LiteralPath (Join-Path $routerData 'router-home.secret'))) 'without the owner choice a password is never tried on another router'
    Put (Join-Path $routerData 'policy') 'false'
    $state = @(Invoke-AbkRouterLogins -AppRoot $fakeApp -DataRoot $routerData -NoPrompt)
    Assert ((Get-States $state) -eq 'ok,missing,unreachable') 'owner said each router has its own password'
    Put (Join-Path $routerData 'policy') 'true'
    $env:ABK_TEST_ROUTER_DENY = '10.0.0.2'
    $state = @(Invoke-AbkRouterLogins -AppRoot $fakeApp -DataRoot $routerData -NoPrompt)
    Assert ($state[1].State -eq 'missing' -and -not (Test-Path -LiteralPath (Join-Path $routerData 'router-home.secret'))) 'a shared password the router rejects is not stored'
    Assert ($state[2].State -eq 'shared' -and [IO.File]::ReadAllText((Join-Path $routerData 'router-work.secret')) -eq 'right') 'with one password for all a router of another site gets it'
    $env:ABK_TEST_ROUTER_DENY = ''
    $state = @(Invoke-AbkRouterLogins -AppRoot $fakeApp -DataRoot $routerData -NoPrompt)
    Assert ((Get-States $state) -eq 'ok,ok,ok' -and [IO.File]::ReadAllText((Join-Path $routerData 'router-home.secret')) -eq 'right') 'a reachable router takes the shared password after a real login'
    $env:ABK_TEST_ROUTER_DENY = $null

    # The real choice writer keeps targets.json valid and its formatting.
    $realData = Join-Path $lab 'policy DATA'
    $targetsFile = Join-Path $realData 'Tunnel\RemoteDesktop\config\targets.json'
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetsFile))
    [IO.File]::WriteAllText($targetsFile, "{`r`n  `"_comment`": `"x`",`r`n  `"router-base`": { `"lan`": `"192.0.2.1`" }`r`n}`r`n", [Text.UTF8Encoding]::new($true))
    Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -Force -DisableNameChecking
    Assert ($null -eq (Get-RouterPasswordShared -Root $realData)) 'no choice until the owner answers'
    Set-RouterPasswordShared -Shared $true -Root $realData
    Assert ((Get-RouterPasswordShared -Root $realData) -eq $true -and [IO.File]::ReadAllText($targetsFile).Contains('"_comment": "x",') -and [IO.File]::ReadAllBytes($targetsFile)[0] -eq 0xEF) 'choice is added without rebuilding targets.json'
    Set-RouterPasswordShared -Shared $false -Root $realData
    Assert ((Get-RouterPasswordShared -Root $realData) -eq $false -and ([regex]::Matches([IO.File]::ReadAllText($targetsFile), '_routers')).Count -eq 1) 'choice is changed in place, never duplicated'
    Assert ((Get-RouterAddress -Router 'router-base' -Root $realData) -eq '192.0.2.1') 'router entries stay readable next to the choice'
} finally {
    $resolved = [IO.Path]::GetFullPath($lab)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-restore-mirror-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All RESTORE MIRROR checks passed.'
