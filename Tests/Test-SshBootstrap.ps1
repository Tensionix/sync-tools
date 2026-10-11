#requires -Version 5.1
<#
    First VPS connection: synthetic known_hosts and ssh only. The real profile,
    keys, servers and services are never used. Functions are extracted from
    production source; an unexpected ssh invocation fails inside the stub.
#>
[CmdletBinding()]
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$failed = 0
function Test-Step {
    param([string]$Title, [bool]$Ok)
    if ($Ok) { Write-Host ('PASS ' + $Title) }
    else { Write-Host ('FAIL ' + $Title); $script:failed++ }
}
function Get-FunctionText {
    param([string]$Path, [string]$Name)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $found = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true))
    if ($found.Count -ne 1) { throw ('Expected one function: ' + $Name) }
    $found[0].Extent.Text
}

$beacon = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
$nativeSsh = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
foreach ($name in 'Write-Line', 'Get-BeaconHint', 'Confirm-BeaconHost', 'Invoke-Server', 'Get-FreePort') {
    Invoke-Expression (Get-FunctionText $beacon $name)
}
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-ssh-bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $lab | Out-Null
$known = Join-Path $lab 'known_hosts'
$script:SetupLogFile = Join-Path $lab 'setup.log'
$Server = @('second-test')
function Reset-Lab {
    param([string]$Mode, [string]$Trusted = '')
    $script:Mode = $Mode
    $script:Interactive = $true
    $script:Prompts = 0
    $script:RemoteCalls = 0
    $script:Calls = New-Object System.Collections.Generic.List[object]
    $script:LastVia = 'stale-route'
    $script:LastSshError = 'stale-error'
    [IO.File]::WriteAllText($known, $Trusted)
    [IO.File]::WriteAllText($script:SetupLogFile, '')
}
function Test-BeaconConsole { return $script:Interactive }
function ssh {
    $argv = @($args)
    $script:Calls.Add($argv)
    $alias = [string]$argv[-2]
    $command = [string]$argv[-1]
    $global:LASTEXITCODE = 255
    if ($alias -notin @('second-test', 'main-direct-test', 'main-cf-test')) { throw ('Unexpected host: ' + $alias) }
    if ($argv -contains 'BatchMode=no') {
        $script:Prompts++
        if ($command -ne 'exit 0' -or $argv -notcontains 'StrictHostKeyChecking=ask' -or
            $argv -notcontains 'UpdateHostKeys=no' -or $argv -notcontains 'NumberOfPasswordPrompts=0' -or
            $argv -notcontains 'PasswordAuthentication=no' -or $argv -notcontains 'KbdInteractiveAuthentication=no') {
            throw 'Unsafe interactive invocation'
        }
        if ($script:Mode -eq 'accept') {
            [IO.File]::WriteAllText($known, 'trusted-fixture-host')
            $global:LASTEXITCODE = 0
        }
        return
    }
    if ($argv -notcontains 'BatchMode=yes' -or $argv -notcontains 'StrictHostKeyChecking=yes' -or
        $argv -notcontains 'UpdateHostKeys=no') { throw 'Batch command may change trust or prompt' }
    if ($script:Mode -eq 'all-fail') {
        $errorText = switch ($alias) {
            'second-test' { 'Host key verification failed.' }
            'main-direct-test' { 'Connection timed out' }
            'main-cf-test' { 'no such identity: missing-fixture-key: No such file or directory. Permission denied (publickey,password).' }
        }
        Write-Error $errorText -ErrorAction Continue
        return
    }
    if ($script:Mode -eq 'changed') {
        Write-Error 'REMOTE HOST IDENTIFICATION HAS CHANGED! Host key verification failed.' -ErrorAction Continue
        return
    }
    if ($script:Mode -eq 'nonzero-stdout') {
        Write-Output '22023'
        Write-Error 'Connection lost after output' -ErrorAction Continue
        return
    }
    if ($script:Mode -eq 'fallback' -and $alias -eq 'second-test') {
        Write-Error 'Host key verification failed.' -ErrorAction Continue
        return
    }
    if (-not [IO.File]::ReadAllText($known)) {
        Write-Error 'No ED25519 host key is known. Host key verification failed.' -ErrorAction Continue
        return
    }
    if ($command -notmatch '^echo [A-Za-z0-9+/=]+ \| base64 -d \| bash$') { throw 'Unexpected remote command' }
    $script:RemoteCalls++
    $global:LASTEXITCODE = 0
    '22023'
}

try {
    Reset-Lab 'known' 'trusted-fixture-host'
    $port = Get-FreePort
    Test-Step 'known host: one batch command, no confirmation' ($port -eq 22023 -and $script:Prompts -eq 0 -and $script:Calls.Count -eq 1)
    Test-Step 'success resets previous route and error' ($script:LastVia -eq 'second-test' -and $script:LastSshError -eq '')

    Reset-Lab 'accept'
    $port = Get-FreePort
    Test-Step 'empty known_hosts: confirm, then run batch command' ($port -eq 22023 -and $script:Prompts -eq 1 -and $script:Calls.Count -eq 3)
    Test-Step 'setup command runs only once after trust' ($script:RemoteCalls -eq 1 -and [IO.File]::ReadAllText($known) -eq 'trusted-fixture-host')
    if ($nativeSsh) {
        # -G never connects. -F isolates both user and system ssh config.
        $isolatedConfig = Join-Path $lab 'ssh_config'
        [IO.File]::WriteAllText($isolatedConfig, "Host *`n    HostName server.example.invalid`n    User fixture`n")
        $confirmArgs = @($script:Calls[1])
        $effective = @(& $nativeSsh.Source -G -F $isolatedConfig @confirmArgs 2>$null)
        Test-Step 'real OpenSSH accepts the interactive host confirmation options' ($LASTEXITCODE -eq 0 -and
            $effective -contains 'batchmode no' -and $effective -contains 'stricthostkeychecking ask' -and
            $effective -contains 'numberofpasswordprompts 0' -and $effective -contains 'passwordauthentication no' -and
            $effective -contains 'kbdinteractiveauthentication no' -and $effective -contains 'updatehostkeys false')
    }

    Reset-Lab 'decline'
    $before = (Get-FileHash -LiteralPath $known).Hash
    $port = Get-FreePort
    Test-Step 'declined trust: no remote command or success' ($port -eq 0 -and $script:RemoteCalls -eq 0 -and $script:LastVia -eq '')
    Test-Step 'declined trust keeps known_hosts unchanged' ((Get-FileHash -LiteralPath $known).Hash -eq $before -and $script:Prompts -eq 1)

    Reset-Lab 'changed' 'old-trusted-fixture-host'
    $before = (Get-FileHash -LiteralPath $known).Hash
    $port = Get-FreePort
    Test-Step 'changed host key: no confirmation or replacement' ($port -eq 0 -and $script:Prompts -eq 0 -and (Get-FileHash -LiteralPath $known).Hash -eq $before)

    Reset-Lab 'accept'
    $answer = Invoke-Server -Command 'echo readonly'
    Test-Step 'inspection/removal calls cannot confirm a new host' ($answer -eq '' -and $script:Prompts -eq 0 -and $script:RemoteCalls -eq 0 -and [IO.File]::ReadAllText($known) -eq '')
    Reset-Lab 'accept'
    $script:Interactive = $false
    $port = Get-FreePort
    Test-Step 'redirected input: fail without waiting for confirmation' ($port -eq 0 -and $script:Prompts -eq 0 -and $script:Calls.Count -eq 1)

    Reset-Lab 'all-fail'
    $answer = Invoke-Server -Command 'echo payload-must-not-be-logged' -Target @('second-test', 'main-direct-test', 'main-cf-test')
    $log = [IO.File]::ReadAllText($script:SetupLogFile)
    Test-Step 'all failed routes remain in the error and log' ($answer -eq '' -and $script:LastVia -eq '' -and
        $script:LastSshError.Contains('[second-test]') -and $script:LastSshError.Contains('[main-direct-test]') -and
        $script:LastSshError.Contains('[main-cf-test]') -and $log.Contains('[second-test]') -and
        $log.Contains('Connection timed out') -and $log.Contains('missing-fixture-key'))
    Test-Step 'journal excludes the remote command payload' (-not $log.Contains('payload-must-not-be-logged'))
    Test-Step 'host trust hint does not suggest importing private keys' ((Get-BeaconHint 'Host key verification failed.') -notmatch 'IMPORT KEYS')
    Test-Step 'missing identity is explained before authentication denial' ((Get-BeaconHint 'no such identity: missing. Permission denied (publickey,password).') -match 'IdentityFile')

    Reset-Lab 'fallback' 'trusted-fixture-host'
    $answer = Invoke-Server -Command 'echo test' -Target @('second-test', 'main-direct-test')
    Test-Step 'fallback succeeds without losing the first error in the journal' ($answer -eq '22023' -and $script:LastVia -eq 'main-direct-test' -and
        $script:LastSshError -eq '' -and [IO.File]::ReadAllText($script:SetupLogFile).Contains('[second-test]'))
    Reset-Lab 'nonzero-stdout'
    $port = Get-FreePort
    Test-Step 'numeric stdout with failed ssh is not a free port' ($port -eq 0 -and $script:LastVia -eq '')

    # Both installation entry points must request trust; maintenance must not.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($beacon, [ref]$tokens, [ref]$errors)
    $confirmCalls = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Server' -and
        @($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ConfirmHostKey' }).Count -gt 0
    }, $true))
    Test-Step 'confirmation is limited to port selection and registration' ($confirmCalls.Count -eq 2 -and
        @($confirmCalls | Where-Object { $_.Extent.Text -match '-Command \$(ask|register)' }).Count -eq 2)

} finally {
    $labFull = [IO.Path]::GetFullPath($lab)
    $tempFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $labFull.StartsWith($tempFull, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $labFull) -notlike 'abk-ssh-bootstrap-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $labFull -Recurse -Force
}
if ($failed) { throw ('Failed checks: ' + $failed) }
Write-Host 'All SSH bootstrap checks passed.'
