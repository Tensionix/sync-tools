<#
.SYNOPSIS
    Makes a data folder ready for the window, and says what it did as JSON.

.DESCRIPTION
    The window calls it when it starts and when another data folder is chosen. No button does
    these three things - a window has to do them by itself, or a fresh data folder has nowhere
    to write an address to:

    1. Working files a version before 1.15.0 left in the program folder move into the data
       folder (Restore-AbkMachineState). A copy that differs from what the data already holds
       goes to Recovery\migrated-<time>-<id> of the data: nothing is lost, and nothing foreign
       gets into the identity of a machine.
    2. The frame of the addresses: targets.json is laid out from the sample the program carries
       when the data folder has none (Restore-AbkTargetsFile). A file that is there is never
       replaced.
    3. The entry of SECOND VPS comes into targets.json from ~\.ssh\config of a machine set up by
       an earlier version, or empty from the sample (Update-AbkSecondVpsEntry).

    With -Previous the folder is a newly chosen one. What the program folder still holds
    belongs to the previous folder and is moved there first; what is left after that is nobody's
    for certain and goes to the quarantine of the new folder instead of into it.

    One line of JSON:

    moved        the working files moved into the data folder: what, rel
    quarantined  the copies put into the quarantine: what, rel
    quarantine   the folder of the quarantine, when anything went there
    targets      true - the frame of the addresses was laid out just now
    second       where the entry of SECOND VPS came from: ssh-config, sample, or empty - untouched

.PARAMETER Previous
    The data folder the window worked with before this one.

.PARAMETER SshConfig
    The ssh config to look for SECOND VPS in. ~\.ssh\config by default; a test names its own file.

.EXAMPLE
    .\Initialize-DataFolder.ps1 -Root "E:\TOOLS\Audion Backup Laptop"
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$Previous = '',
    [string]$SshConfig = '',
    [switch]$MigrateProgram
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\StorageLayout.ps1')
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\Targets.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
[void](Move-AbkRuntimeStorage -AppRoot $AppRoot -DataRoot $data -IncludeProgram:$MigrateProgram)

$moved = @()
$quarantined = @()
$quarantine = ''

function Add-Restored($items) {
    foreach ($item in @($items)) {
        if (-not $item) { continue }
        $row = [ordered]@{ what = [string]$item.What; rel = [string]$item.Rel }
        if ([string]$item.Mode -eq 'quarantined') { $script:quarantined += $row } else { $script:moved += $row }
    }
}

$switched = [bool]($Previous -and (Test-Path -LiteralPath $Previous) -and
    ((Resolve-Path -LiteralPath $Previous).Path.TrimEnd('\') -ne $data.TrimEnd('\')))

if ($switched) {
    # What the program still holds was the previous folder's: it goes there, not into the new one.
    try { [void](Restore-AbkMachineState -AppRoot $AppRoot -DataRoot $Previous -Client (Split-Path -Leaf $Previous)) } catch { }
    $leftovers = @(Get-AbkMachinePairs -AppRoot $AppRoot -MachineRoot $data | Where-Object { Test-Path -LiteralPath $_.App })
    if ($leftovers.Count) {
        $quarantine = Join-Path $data ('Recovery\migrated-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        Protect-AbkStorageRecovery $quarantine
        foreach ($pair in $leftovers) {
            try {
                $to = Join-Path $quarantine $pair.Rel
                $dir = Split-Path -Parent $to
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item -LiteralPath $pair.App -Destination $to -Force
                $quarantined += [ordered]@{ what = [string]$pair.What; rel = [string]$pair.Rel }
            } catch { }
        }
    }
} else {
    try { Add-Restored (Restore-AbkMachineState -AppRoot $AppRoot -DataRoot $data -Client (Split-Path -Leaf $data)) } catch { }
}

$fresh = ''
try { $fresh = [string](Restore-AbkTargetsFile -AppRoot $AppRoot -DataRoot $data) } catch { }

$second = ''
try {
    $extra = @{}
    if ($SshConfig) { $extra['SshConfig'] = $SshConfig }
    $second = [string](Update-AbkSecondVpsEntry -AppRoot $AppRoot -DataRoot $data @extra)
} catch { }

[ordered]@{
    moved       = @($moved)
    quarantined = @($quarantined)
    quarantine  = [string]$quarantine
    targets     = [bool]$fresh
    second      = [string]$second
} | ConvertTo-Json -Compress -Depth 4
exit 0
