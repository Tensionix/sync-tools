#requires -Version 5.1
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-beacon-persistent-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $lab 'app'; $data = Join-Path $lab 'Audion Backup Laptop'
$startup = Join-Path $lab 'synthetic startup'
$name = 'fixture-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$failed = 0
function Check($Title, [bool]$Ok) { if ($Ok) { Write-Host ('PASS ' + $Title) } else { Write-Host ('FAIL ' + $Title); $script:failed++ } }
function Put($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true)) }
function Wait-File($Path) {
    $until = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $Path)) { throw ('Fixture did not start: ' + $Path) }
}
try {
    foreach ($dir in @((Join-Path $app 'Engine'),(Join-Path $app 'Tunnel\RemoteDesktop'),(Join-Path $data 'Tunnel\SSH\beacon'),(Join-Path $data 'Tunnel\RemoteDesktop\config'),$startup)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    foreach ($file in 'BeaconLifecycle.ps1','DataRoot.ps1','Secrets.ps1','Targets.ps1','KeyPair.ps1','RestoreMirror.ps1') {
        Copy-Item -LiteralPath (Join-Path $AppRoot ('Engine\' + $file)) -Destination (Join-Path $app 'Engine')
    }
    # Only the OS startup-folder resolver is redirected to this fixture.
    $lib = Join-Path $app 'Engine\BeaconLifecycle.ps1'
    $code = [IO.File]::ReadAllText($lib).Replace("[Environment]::GetFolderPath('Startup')", ("'" + $startup.Replace("'","''") + "'"))
    Put $lib $code
    . $lib
    $entry = Join-Path $app 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
    Copy-Item -LiteralPath (Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1') -Destination $entry
    Put (Join-Path $data 'Tunnel\RemoteDesktop\config\targets.json') '{"second":{"host":"127.0.0.1","sshHost":"fixture.invalid"}}'
    $keyDir = Join-Path $data 'Tunnel\SSH\beacon'
    $key = Join-Path $keyDir 'synthetic.key'; $conf = Join-Path $keyDir 'synthetic.config'
    Put $key 'not a real private key'
    $proxyPid = Join-Path $lab 'proxy.pid'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(('[IO.File]::WriteAllText(''{0}'',[string]$PID); Start-Sleep -Seconds 90' -f $proxyPid.Replace("'","''"))))
    $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Put $conf (@('Host *',' HostName 127.0.0.1',' IdentityAgent none',' UserKnownHostsFile NUL',' GlobalKnownHostsFile NUL',(' ProxyCommand "{0}" -NoProfile -NonInteractive -EncodedCommand {1}' -f $ps5.Replace('\','/'),$encoded)) -join "`r`n")
    $file = Join-Path $keyDir ($name + '.beacon.json')
    $saved = @{Name=$name;Port=22346;User='fixture';Servers=@('fixture.invalid');KeyFile=$key;SshConfig=$conf;AutoStart=$false;Persistent=$true}
    Put $file ($saved | ConvertTo-Json)
    $keyHash = (Get-FileHash -LiteralPath $key).Hash
    $result = @(& $ps5 -NoProfile -ExecutionPolicy Bypass -File $entry -Toggle -Persistent -Name $name -Root $data 2>&1)
    $rc = $LASTEXITCODE
    if ($rc) { $result | Write-Host }
    Wait-File $proxyPid
    $holders = @(Get-AbkBeaconRuntimeProcesses -Name $name -DataRoot $data)
    $fresh = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Check 'first toggle resumes saved tunnel without server writes' ($rc -eq 0 -and $fresh.AutoStart -and $fresh.Port -eq $saved.Port -and $fresh.Servers[0] -eq 'fixture.invalid' -and (Get-FileHash -LiteralPath $key).Hash -eq $keyHash)
    Check 'worker and its SSH proxy survive the launching console exit' ($holders.Count -eq 1 -and (Get-Process -Id ([int](Get-Content -LiteralPath $proxyPid)) -ErrorAction SilentlyContinue))
    Check 'startup shortcut is created only in the synthetic startup folder' (@(Get-ChildItem -LiteralPath $startup -Filter '*.lnk').Count -eq 1)
    $result = @(& $ps5 -NoProfile -ExecutionPolicy Bypass -File $entry -Toggle -Persistent -Name $name -Root $data 2>&1)
    $rc = $LASTEXITCODE
    $fresh = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    Check 'second toggle disables saved autostart and stops its worker' ($rc -eq 0 -and -not $fresh.AutoStart -and @(Get-AbkBeaconRuntimeProcesses -Name $name -DataRoot $data).Count -eq 0)
    Check 'second toggle removes startup but preserves key and port' (@(Get-ChildItem -LiteralPath $startup -Filter '*.lnk').Count -eq 0 -and (Get-FileHash -LiteralPath $key).Hash -eq $keyHash -and $fresh.Port -eq $saved.Port)
    Check 'stop removes SSH/proxy descendants without leaving orphans' (-not (Get-Process -Id ([int](Get-Content -LiteralPath $proxyPid)) -ErrorAction SilentlyContinue))
    $path = Set-AbkBeaconStartup -AppRoot $app -DataRoot $data -Name $name -Enabled $true
    $otherData = Join-Path $lab 'other data'
    $other = Set-AbkBeaconStartup -AppRoot $app -DataRoot $otherData -Name $name -Enabled $true
    $null = Set-AbkBeaconStartup -AppRoot $app -DataRoot $data -Name $name -Enabled $false
    Check 'removing one startup entry preserves another DATA entry' (-not (Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $other))
} finally {
    if (Get-Command Get-AbkBeaconRuntimeProcesses -ErrorAction SilentlyContinue) {
        foreach ($p in @(Get-AbkBeaconRuntimeProcesses -Name $name -DataRoot $data)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    $resolved = [IO.Path]::GetFullPath($lab)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'abk-beacon-persistent-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failed) { exit 1 }
Write-Host 'Persistent beacon checks passed'; exit 0
