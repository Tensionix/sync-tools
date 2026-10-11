#requires -Version 5.1
[CmdletBinding()]
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$SourceRoot = $AppRoot
$failed = 0
function Test-Step([string]$Title, [bool]$Ok) {
    if ($Ok) { Write-Host ('PASS ' + $Title) }
    else { Write-Host ('FAIL ' + $Title); $script:failed++ }
}
function Put-File([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function Read-Ast([string]$Path) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Source parse failed' }
    return $ast
}
function Get-FunctionText($Ast, [string]$Name) {
    $f=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if ($f.Count -ne 1) { throw ('Function missing or ambiguous: ' + $Name) }
    $f[0].Extent.Text
}
Import-Module (Join-Path $SourceRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $SourceRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
. (Join-Path $SourceRoot 'Engine\Clouds.ps1')
$import=Read-Ast (Join-Path $SourceRoot 'Engine\Scripts\Import-AudionKeys.ps1')
foreach ($name in @('Test-HasKeys','Get-ImportPrivatePath','Get-ImportPublicKeys','Copy-Secret','Write-Note')) {
    Invoke-Expression (Get-FunctionText $import $name)
}
$stand=Join-Path ([IO.Path]::GetTempPath()) ('abk-setup-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stand | Out-Null
try {
    $AppRoot=Join-Path $stand 'Audion Sync Tools'
    $a=Join-Path $stand 'Audion Backup A'
    $b=Join-Path $stand 'Audion Backup B'
    New-Item -ItemType Directory -Path $AppRoot,$a,$b | Out-Null
    # Exercise the real UAC argument builders without elevation or setup actions.
    $probe = Join-Path $stand 'argument probe.ps1'
    Put-File $probe 'param([string]$Root,[switch]$NoPause) if(-not $NoPause){exit 33}; [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Root)))'
    foreach ($setupName in @('Setup-BaseVpn.ps1','Setup-SshServer.ps1')) {
        $setup = Read-Ast (Join-Path $SourceRoot ('Tunnel\RemoteDesktop\' + $setupName))
        $forward = @($setup.FindAll({param($n)
            $n -is [Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -in @('$Root','$NoPause') -and $n.Extent.Text.Contains('$argList +=')
        }, $true))
        if ($forward.Count -ne 2) { throw 'UAC forwarding blocks changed' }
        foreach ($Root in @($a, ($a + '\'))) {
            $argList = @(); $NoPause = $true
            foreach ($statement in $forward) { Invoke-Expression $statement.Extent.Text }
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = (Get-Process -Id $PID).Path
            $start.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $probe + '" ' + ($argList -join ' ')
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            try {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Argument probe timed out' }
                $expected = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Root))
                Test-Step ("$setupName UAC preserves DATA with spaces and trailing slash: " + $Root.EndsWith('\')) ($process.ExitCode -eq 0 -and $stdout.Result.Trim() -ceq $expected)
            } finally { $process.Dispose() }
        }
    }
    [void](Set-AbkProfilePointer -AppRoot $AppRoot -DataRoot $a -Profile 'A')
    $rargs=@(Get-AbkRcloneArgs -AppRoot $AppRoot -DataRoot $b)
    $renv=Get-AbkRcloneEnvironment -AppRoot $AppRoot -DataRoot $b
    Test-Step 'explicit root selects rclone config over pointer' ($rargs[1] -eq (Join-Path $b 'config\rclone\rclone.conf'))
    Test-Step 'explicit root selects R2 credentials over pointer' ($renv.AWS_SHARED_CREDENTIALS_FILE -eq (Join-Path $b 'config\rclone\r2.credentials'))
    Test-Step 'explicit root selects cloud config over pointer' ((Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $b) -eq (Join-Path $b 'config\rclone\clouds.conf'))
    $sealed=Protect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $b -Password 'synthetic-test-password'
    Test-Step 'cloud password is written only to selected data' ($sealed -eq (Join-Path $b 'config\rclone\clouds.key') -and -not (Test-Path (Join-Path $AppRoot 'config\rclone')))
    Test-Step 'cloud password reads from same explicit root' ((Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $b) -eq 'synthetic-test-password')

    $ambiguousApp=Join-Path $stand 'ambiguous\program'
    $unnamed=Join-Path $stand 'ambiguous\Audion Backup'
    $named=Join-Path $stand 'ambiguous\Audion Backup Named'
    New-Item -ItemType Directory -Path $ambiguousApp,$unnamed,$named -Force | Out-Null
    Test-Step 'ambiguous discovery never selects existing unnamed folder' (-not (Test-Path (Find-AbkDataRoot -AppRoot $ambiguousApp)))
    Test-Step 'ambiguous config resolution never reads existing unnamed folder' (-not (Test-Path (Resolve-AbkWorkRoot -AppRoot $ambiguousApp)))

    # Unknown legacy files are preserved separately, never promoted into an empty target.
    $unknownApp=Join-Path $stand 'legacy-app'
    $emptyData=Join-Path $stand 'empty-data'
    New-Item -ItemType Directory -Path $emptyData | Out-Null
    Put-File (Join-Path $unknownApp 'config\rclone\r2.credentials') 'unknown-owner'
    $moved=@(Restore-AbkMachineState -AppRoot $unknownApp -DataRoot $emptyData)
    Test-Step 'unowned legacy secret is quarantined outside program' ($moved.Count -eq 1 -and $moved[0].Mode -eq 'quarantined' -and -not (Test-Path (Join-Path $emptyData 'config\rclone\r2.credentials')) -and -not (Test-Path (Join-Path $unknownApp 'config\rclone\r2.credentials')))

    # Execute the real SSH import branch against synthetic profiles only.
    $choose=@($import.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.SwitchStatementAst] -and $_.Condition.Extent.Text -eq '$Source'})[0]
    $branch=@($import.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if (-not (Test-Path -LiteralPath $KeySource))')})[0]
    if (-not $choose -or -not $branch) { throw 'Import blocks changed' }
    function Protect-KeyFile { param($Path) }
    function icacls { 'synthetic ACL'; $global:LASTEXITCODE=0 }
    foreach ($case in @('clients-short','clients-suffix','servers-rsa','flat','export','partial-export')) {
        $dir=Join-Path $stand $case
        $Tunnel=Join-Path $dir 'Tunnel'; $Export=Join-Path $Tunnel 'Export'
        $SshDir=Join-Path $dir 'profile\.ssh'; $Source='Auto'; $Check=$false; $Force=$false; $Placed=0; $Kept=0
        $pairDir=switch($case){'clients-short'{Join-Path $Tunnel 'SSH\clients'}'clients-suffix'{Join-Path $Tunnel 'SSH\clients'}'servers-rsa'{Join-Path $Tunnel 'SSH\servers'}'export'{Join-Path $Export 'SSH'}'partial-export'{Join-Path $Export 'SSH'}default{Join-Path $Tunnel 'SSH'}}
        $privateName=if($case -eq 'servers-rsa'){'id_rsa'}else{'synthetic_ed25519'}
        $publicName=if($case -eq 'clients-short'){'synthetic.pub'}else{$privateName+'.pub'}
        Put-File (Join-Path $pairDir $privateName) 'synthetic-private-not-a-key'
        Put-File (Join-Path $pairDir $publicName) 'ssh-ed25519 SYNTHETIC synthetic'
        if ($case -eq 'partial-export') {
            Put-File (Join-Path $Tunnel 'SSH\servers\second_ed25519') 'synthetic-server-private'
            Put-File (Join-Path $Tunnel 'SSH\servers\second_ed25519.pub') 'ssh-ed25519 SERVER server'
            Put-File (Join-Path $Tunnel 'SSH\clients\neighbour_ed25519') 'synthetic-neighbour-private'
            Put-File (Join-Path $Tunnel 'SSH\clients\neighbour_ed25519.pub') 'ssh-ed25519 NEIGHBOUR neighbour'
        }
        Invoke-Expression $choose.Extent.Text
        $KeySource=Join-Path $From 'SSH'
        Invoke-Expression $branch.Extent.Text
        Test-Step ('restore pair: '+$case) ((Test-Path (Join-Path $SshDir $privateName)) -and (Test-Path (Join-Path $SshDir ($privateName+'.pub'))))
        if ($case -eq 'partial-export') {
            Test-Step 'partial export restores missing server pair' (Test-Path (Join-Path $SshDir 'second_ed25519'))
            Test-Step 'partial export does not import neighbouring client private keys' (-not (Test-Path (Join-Path $SshDir 'neighbour_ed25519')))
        }
        if ($case -like 'clients-*') {
            Test-Step ('recognize restored key without ClientName: '+$case) ((Get-AbkMachineKey -Store $pairDir -SshDir $SshDir) -eq $privateName)
        }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($stand)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-setup-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($failed) { throw ($failed.ToString()+' setup checks failed') }
Write-Host 'All setup data checks passed'
exit 0
