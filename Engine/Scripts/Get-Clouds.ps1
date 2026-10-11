<#
.SYNOPSIS
    The cloud drives of this machine for the window: which kinds can be attached, which are attached,
    the working config of a session, and saving what a session refreshed.

.DESCRIPTION
    One of four questions is answered, the answer is one line of JSON.

    -Kinds   the clouds the program offers to attach, and how each is signed into.
    -List    the attached clouds: name and type.
    -Open    builds the working config of a session - the transport together with the clouds,
             encrypted - and says where it lies, which clouds it holds and which are hidden by a
             name already taken in the program's rclone.conf. The answer carries the password of
             that config: the window hands it to its own rclone calls in their environment. It is
             printed for the process that started this script alone - never run -Open by hand
             into a journal or a file.
    -Save    writes the keys a session refreshed back into the encrypted clouds.conf of the data.

.EXAMPLE
    .\Get-Clouds.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -List
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Kinds,
    [switch]$List,
    [switch]$Open,
    [switch]$Save,
    [string]$Session = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\Clouds.ps1')

if ($Kinds) {
    [ordered]@{ kinds = @(Get-AbkCloudKinds | ForEach-Object { [ordered]@{ key = $_.Key; label = $_.Label; login = $_.Login } }) } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$exe = Find-AbkRclone -AppRoot $AppRoot
if (-not $exe) { [ordered]@{ ready = $false; why = 'rclone'; clouds = @() } | ConvertTo-Json -Compress; exit 0 }

function Get-Attached {
    @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $data -RcloneExe $exe | Where-Object { $_.Name } |
        ForEach-Object { [ordered]@{ name = [string]$_.Name; type = [string]$_.Type } })
}

if ($List) {
    [ordered]@{ clouds = @(Get-Attached) } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

$password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $data

if ($Save) {
    if (-not $Session -or -not $password) { [ordered]@{ saved = 0 } | ConvertTo-Json -Compress; exit 0 }
    $changed = Save-AbkCloudChanges -AppRoot $AppRoot -DataRoot $data -RcloneExe $exe -Password $password -SessionPath $Session
    [ordered]@{ saved = [int]$changed } | ConvertTo-Json -Compress
    exit 0
}

if ($Open) {
    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $data
    $ready = $password -and (Test-Path -LiteralPath $config) -and (Test-AbkCloudsOpen -AppRoot $AppRoot -DataRoot $data -RcloneExe $exe)
    if (-not $ready) { [ordered]@{ ready = $false; why = 'none'; clouds = @() } | ConvertTo-Json -Compress; exit 0 }
    $made = New-AbkSessionConfig -AppRoot $AppRoot -DataRoot $data -RcloneExe $exe -Password $password
    if (-not $made) { [ordered]@{ ready = $false; why = 'session'; clouds = @() } | ConvertTo-Json -Compress; exit 0 }

    # A cloud whose name is taken by a section of the program's own rclone.conf is not seen: the section wins.
    $all = @(Get-Attached)
    $shadowed = @()
    foreach ($cloud in $all) {
        $free = Test-AbkCloudNameFree -AppRoot $AppRoot -DataRoot $data -RcloneExe $exe -Name $cloud.name -Except $cloud.name
        if (-not $free.Free -and $free.Reason -ne 'другое облако') { $shadowed += $cloud.name }
    }
    [ordered]@{
        ready    = $true
        session  = [string]$made
        password = [string]$password
        clouds   = @($all | Where-Object { $shadowed -notcontains $_.name })
        shadowed = @($shadowed)
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

Write-Host 'name one question: -Kinds, -List, -Open or -Save'
exit 1
