#requires -Version 7.0
<# Throwaway roots only: runtime deletion must preserve durable recovery and cloud tokens. #>
param([string]$AppRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $AppRoot 'Engine\StorageLayout.ps1')
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\Clouds.ps1')
function Assert([bool]$Ok, [string]$Message) { if (-not $Ok) { throw $Message }; Write-Host ('PASS ' + $Message) }
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-runtime-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
try {
    $app = Join-Path $lab 'program'
    $data = Join-Path $lab 'Audion Backup Stand'
    [void][IO.Directory]::CreateDirectory($app)
    [void][IO.Directory]::CreateDirectory($data)
    Put (Join-Path $app 'config\example.json') '{"template":true}'
    Put (Join-Path $app '._runtime\bisync\pairs.json') 'private pair paths'
    Put (Join-Path $app '._runtime\bisync\state\one\first.path1.lst') 'first listing'
    Put (Join-Path $app '._runtime\bisync\state\one\first.path2.lst') 'second listing'
    Put (Join-Path $app '._runtime\rclone-cache\junk') 'disposable'
    Put (Join-Path $data '._runtime\tunnel-refresh-old\Tunnel.before\key') 'synthetic private key'
    [void][IO.Directory]::CreateDirectory((Join-Path $data '._runtime\tunnel-refresh-old\empty'))
    Put (Join-Path $data '._runtime\migrated-old\old.conf') 'synthetic conflicting settings'
    Put (Join-Path $data '._runtime\session.conf') 'encrypted fixture, not opened'
    Put (Join-Path $data '._runtime\sync-all-20000101T000000Z-deadbeef\transaction.json') '{"status":"complete"}'
    Put (Join-Path $data '._runtime\rclone-cache\junk') 'disposable'
    $before = Get-AbkStorageFingerprint (Join-Path $data '._runtime\tunnel-refresh-old')
    $moved = @(Move-AbkRuntimeStorage -AppRoot $app -DataRoot $data -IncludeProgram)
    Assert ($moved.Count -eq 5) 'all five durable legacy entries moved'
    Assert ((Get-AbkStorageFingerprint (Join-Path $data 'Recovery\legacy-runtime\tunnel-refresh-old')) -ceq $before) 'backup bytes, hidden paths and empty folders preserved'
    foreach ($root in @($app, $data)) {
        $scratch = Assert-AbkStoragePath $root (Join-Path $root '._runtime')
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
    Assert ([IO.File]::ReadAllText((Join-Path $data 'config\bisync\pairs.json')) -eq 'private pair paths' -and
        (Test-Path -LiteralPath (Join-Path $data 'config\bisync\state\one\first.path1.lst')) -and
        (Test-Path -LiteralPath (Join-Path $data 'config\bisync\state\one\first.path2.lst'))) 'BISYNC pairs and both listings survive removal of both runtime folders'
    Assert (Test-Path -LiteralPath (Join-Path $data 'config\rclone\session.conf')) 'cloud session survives runtime removal'
    Assert (Test-Path -LiteralPath (Join-Path $data 'Recovery\sync-all\sync-all-20000101T000000Z-deadbeef\transaction.json')) 'SYNC ALL journal is durable'
    Assert (@(Move-AbkRuntimeStorage -AppRoot $app -DataRoot $data -IncludeProgram).Count -eq 0) 'second migration is a no-op'
    Assert ((Get-ChildItem -LiteralPath (Join-Path $app 'config') -Recurse -File).Count -eq 1) 'no machine state or secrets are written to public project config'

    Put (Join-Path $app '._runtime\bisync\pairs.json') 'different legacy pair'
    [void](Move-AbkRuntimeStorage -AppRoot $app -DataRoot $data -IncludeProgram)
    Assert ([IO.File]::ReadAllText((Join-Path $data 'config\bisync\pairs.json')) -eq 'private pair paths' -and
        @(Get-ChildItem -LiteralPath (Join-Path $data 'config') -Directory -Filter 'bisync.legacy-*').Count -eq 1) 'a conflicting old state is preserved separately, never merged over live listings'
    Put (Join-Path $data '._runtime\must-stay\key') 'busy fixture'
    $held = [IO.File]::Open((Join-Path $data 'config\sync-all.lock'), 'Open', 'ReadWrite', 'None')
    $refused = $false
    try { [void](Move-AbkRuntimeStorage -AppRoot $app -DataRoot $data) } catch { $refused = $true } finally { $held.Dispose() }
    Assert ($refused -and (Test-Path -LiteralPath (Join-Path $data '._runtime\must-stay\key'))) 'active SYNC ALL prevents migration'

    $oldRun = Join-Path $data '._runtime\sync-all-20000101T000000Z-deadbeef'
    $newRun = Join-Path $data 'Recovery\sync-all\sync-all-20000101T000000Z-deadbeef'
    Put (Join-Path $oldRun 'transaction.json') '{"status":"pending","different":true}'
    $refused = $false
    try { [void](Move-AbkRuntimeStorage -AppRoot $app -DataRoot $data) } catch { $refused = $true }
    Assert ($refused -and (Test-Path -LiteralPath (Join-Path $oldRun 'transaction.json')) -and
        [IO.File]::ReadAllText((Join-Path $newRun 'transaction.json')) -eq '{"status":"complete"}') 'conflicting transaction journals are both retained without merging'
    $outside = Join-Path $lab 'outside'
    Put (Join-Path $outside 'keep.txt') 'outside remains'
    $linked = Join-Path $app '._runtime\linked-state'
    [void][IO.Directory]::CreateDirectory($linked)
    $junction = Join-Path $linked 'escape'
    & cmd.exe /c mklink /J $junction $outside 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create junction fixture' }
    $refused = $false
    try { [void](Get-AbkStorageFingerprint $linked) } catch { $refused = $true }
    [IO.Directory]::Delete($junction)
    Assert ($refused -and [IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -eq 'outside remains') 'nested junction never escapes migration scope'

    $cloudData = Join-Path $lab 'Cloud DATA'
    $clouds = Join-Path $cloudData 'config\rclone\clouds.conf'
    Put $clouds "[fixture]`ntype = alias`nremote = C:/fixture`ntoken = token-before`n"
    Put (Join-Path $cloudData 'config\rclone\rclone.conf') "[transport]`ntype = alias`nremote = C:/transport`n"
    $exe = Find-AbkRclone -AppRoot $AppRoot
    $password = 'synthetic-test-password'
    $session = New-AbkSessionConfig -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Password $password
    Assert ($session -eq (Join-Path $cloudData 'config\rclone\session.conf')) 'new session belongs to durable DATA, not project or scratch'
    # Simulate rclone refreshing a token; no remote or OAuth endpoint is contacted.
    $plain = (Get-AbkConfigText -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Path $session -Password $password).Replace('token-before','token-refreshed')
    Put $session $plain
    Put (Join-Path $cloudData '._runtime\junk') 'disposable'
    Remove-Item -LiteralPath (Assert-AbkStoragePath $cloudData (Join-Path $cloudData '._runtime')) -Recurse -Force
    $again = New-AbkSessionConfig -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Password $password
    $kept = Get-AbkConfigText -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Path $clouds -Password $password
    Assert ($again -eq $session -and $kept.Contains('token-refreshed')) 'restart replays refreshed OAuth token from durable session after scratch deletion'
    $opaque = [IO.File]::ReadAllText($session)
    Assert ($opaque.Contains('RCLONE_ENCRYPT_V0:') -and -not $opaque.Contains('token-refreshed')) 'rebuilt session is encrypted at rest'

    # A stale session must not undo an explicit reconnect performed outside this window.
    $oldSessionHash = (Get-FileHash -LiteralPath $session -Algorithm SHA256).Hash
    Put $clouds "[fixture]`ntype = alias`nremote = C:/fixture`ntoken = explicit-reconnect`n"
    $result = Save-AbkCloudChanges -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Password $password -SessionPath $session
    Assert ($result -eq 0 -and [IO.File]::ReadAllText($clouds).Contains('explicit-reconnect')) 'closing a stale window never overwrites a newer canonical cloud config'
    [void](New-AbkSessionConfig -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Password $password)
    $kept = Get-AbkConfigText -AppRoot $app -DataRoot $cloudData -RcloneExe $exe -Path $session -Password $password
    Assert ($kept.Contains('explicit-reconnect') -and
        (Test-Path -LiteralPath (Join-Path $cloudData ('Recovery\cloud-sessions\' + $oldSessionHash + '.conf')))) 'canonical reconnect wins on restart, with conflicting session bytes preserved in DATA recovery'
} finally {
    $resolved = [IO.Path]::GetFullPath($lab)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\') -or (Split-Path -Leaf $resolved) -notlike 'abk-runtime-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
