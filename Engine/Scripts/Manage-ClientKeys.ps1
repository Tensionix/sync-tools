<#
.SYNOPSIS
    The public keys of the machines: what is kept and who goes where, SSH-COPY-ID, revoking.

.DESCRIPTION
    One of four things is done.

    -Describe    one line of JSON for the window: the keys that can be revoked, how many public
                 keys CLIENTS holds, and the machines the work would go to.
    -Inventory   the list of the keys (profile, CLIENTS, servers, golden copy, Export Keys), the
                 working files of this machine, and the table "who goes where" read from authorized_keys
                 of every machine that answers.
    -Spread      SSH-COPY-ID: every public key of CLIENTS is appended to authorized_keys of every
                 machine. Lines already there are not touched: an old access works until it is
                 revoked.
    -Revoke      a public key is removed from authorized_keys of every machine that answers. A
                 machine where no key would be left is skipped: one cannot lock oneself out by
                 revoking.

    Nothing is written into the data folder: the keys themselves are made by New-ClientKey.ps1
    and stay where they are.

.PARAMETER Lan
    The machines that answer in the local network now, separated by commas: they are gone to as
    <name>-lan, the others by their name of ~\.ssh\config. The window passes what its probe saw.

.PARAMETER ClientName
    The name of the key of this machine, to mark it in the lists.

.PARAMETER Revoke
    The name of the key as CLIENTS has it, or "machines" - the shared key of the old scheme.

.PARAMETER WhatIf
    With -Spread or -Revoke: say where the work would go and stop.

.EXAMPLE
    .\Manage-ClientKeys.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -Inventory -Lan base
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Describe,
    [switch]$Inventory,
    [switch]$Spread,
    [string]$Revoke = '',
    [string]$Lan = '',
    [string]$ClientName = '',
    [string]$SshDir = '',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The talk with authorized_keys and the list of keys.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
# The module keeps what it dot-sources to itself: the same file is read here for this script.
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')

$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$store = Join-Path $data 'Tunnel\SSH\clients'
if (-not $SshDir) { $SshDir = Join-Path $HOME '.ssh' }
$near = @($Lan -split '[,; ]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
$own = $ClientName -replace '_ed25519$', ''

function Get-Caption([string]$Key) {
    switch ($Key) {
        'server' { 'MAIN VPS' }
        'second' { 'SECOND VPS' }
        default  { $Key.ToUpper() }
    }
}

function Get-Plan([ValidateSet('none', 'name', 'address')][string]$Skip = 'name') {
    <#
        The machines to go to, from targets.json of the data folder: the five of the household
        that have an address, then MAIN VPS. This machine is left out by its name, or by its
        name and its addresses (SSH-COPY-ID: its own authorized_keys is filled by SSHD), or not
        at all (the list: it is one of the places a key goes to).
    #>
    $path = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $data
    $plan = @()
    $mine = @()
    $targets = $null
    if (Test-Path -LiteralPath $path) {
        try { $targets = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $targets = $null }
    }
    if (-not $targets) { return [pscustomobject]@{ Known = $false; Plan = @(); Mine = @() } }
    $addresses = @()
    if ($Skip -eq 'address') {
        # Asked of .NET: Get-NetIPAddress loads CIM for two seconds.
        foreach ($card in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($one in $card.GetIPProperties().UnicastAddresses) {
                if ($one.Address.AddressFamily -eq 'InterNetwork') { $addresses += $one.Address.ToString() }
            }
        }
    }
    foreach ($machine in @('base', 'laptop', 'home', 'dad', 'work')) {
        $entry = $targets.$machine
        if (-not $entry) { continue }
        if (-not $entry.lan -and -not $entry.host) { continue }
        $here = ($Skip -ne 'none') -and ($env:COMPUTERNAME -like ('*' + $machine + '*'))
        if (-not $here -and $Skip -eq 'address') {
            $address = $(if ($entry.lan) { [string]$entry.lan } else { [string]$entry.host })
            $here = ($addresses -contains $address) -or ($entry.host -and ($addresses -contains [string]$entry.host))
        }
        if ($here) { $mine += $machine; continue }
        $sshHost = $(if ($near -contains $machine) { $machine + '-lan' } else { $machine })
        $plan += [pscustomobject]@{ Name = $machine; Caption = (Get-Caption $machine); SshHost = $sshHost; Kind = 'windows' }
    }
    if ($targets.server -and $targets.server.sshHost) {
        $plan += [pscustomobject]@{ Name = 'server'; Caption = 'MAIN VPS'; SshHost = [string]$targets.server.sshHost; Kind = 'unix' }
    }
    return [pscustomobject]@{ Known = $true; Plan = $plan; Mine = $mine }
}

function Get-Revocable {
    <# What can be revoked: the public keys of CLIENTS and the shared key of the old scheme. #>
    $out = @()
    foreach ($half in @(Get-ChildItem -LiteralPath $store -Filter '*.pub' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $text = ([string](Get-Content -LiteralPath $half.FullName -Raw)).Trim() -split ' '
        if ($text.Count -lt 2) { continue }
        $out += [pscustomobject]@{ Name = $half.BaseName; Body = $text[1]; Mine = [bool]($own -and (($half.BaseName -replace '_ed25519$', '') -eq $own)); Shared = $false }
    }
    $shared = Join-Path $data 'Tunnel\SSH\audion_machines_ed25519.pub'
    if (Test-Path -LiteralPath $shared) {
        $text = ([string](Get-Content -LiteralPath $shared -Raw)).Trim() -split ' '
        if ($text.Count -ge 2) { $out += [pscustomobject]@{ Name = 'machines'; Body = $text[1]; Mine = $false; Shared = $true } }
    }
    return $out
}

function Get-ClientKeys {
    @(Get-ChildItem -LiteralPath $store -Filter '*.pub' -ErrorAction SilentlyContinue | Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Line = ([string](Get-Content -LiteralPath $_.FullName -Raw)).Trim() } } |
        Where-Object { $_.Line })
}

# ------------------------------------------------------------ -Describe
if ($Describe) {
    $plan = Get-Plan -Skip address
    [ordered]@{
        targets = [bool]$plan.Known
        clients = @(Get-ClientKeys | ForEach-Object { $_.Name })
        keys    = @(Get-Revocable | ForEach-Object { [ordered]@{ name = $_.Name; mine = $_.Mine; shared = $_.Shared } })
        plan    = @($plan.Plan | ForEach-Object { [ordered]@{ name = $_.Name; caption = $_.Caption; host = $_.SshHost } })
        mine    = @($plan.Mine | ForEach-Object { Get-Caption $_ })
    } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

# ------------------------------------------------------------ -Inventory
if ($Inventory) {
    $rows = @(Get-AbkKeyInventory -SshDir $SshDir -Store (Join-Path $data 'Tunnel\SSH') -Kit (Join-Path $data 'Tunnel\Export\SSH'))
    Write-Host ''
    Write-Host '===== KEYS ====='
    if (-not $rows.Count) { Write-Host '[keys] not one public key was found'; exit 0 }
    # The words of the module for a place and a purpose are Russian keys of its own table.
    $said = @{
        'профиль' = 'profile'; 'машина' = 'machine'; 'старая схема' = 'old scheme'; 'без места' = 'no place'
        'MAIN VPS и SECOND VPS' = 'MAIN VPS and SECOND VPS'
    }
    $mineKey = Get-AbkMachineKey -Store $store -SshDir $SshDir -Preferred $own
    foreach ($row in $rows) {
        $mark = ''
        if ($mineKey -and ($row.Names -contains ($mineKey -replace '_ed25519$', '') -or $row.Names -contains $mineKey)) { $mark = ' <- this machine' }
        $purpose = $(if ($said.ContainsKey([string]$row.Purpose)) { $said[[string]$row.Purpose] } else { [string]$row.Purpose })
        $places = @($row.Places | ForEach-Object { if ($said.ContainsKey([string]$_)) { $said[[string]$_] } else { [string]$_ } })
        Write-Host ('{0,-28} {1,-24} {2}{3}' -f $row.Names[0], $purpose, ($places -join ', '), $mark)
        if (-not $row.Private.Count) {
            Write-Host ('{0,-28} {1}' -f '', 'the private key is nowhere - one cannot sign in with this key')
        } elseif (@($row.Private | Where-Object { $_ -ne 'профиль' }).Count -eq 0) {
            Write-Host ('{0,-28} {1}' -f '', 'the private key is in the profile alone - a reinstall of the system wipes it')
        }
    }

    # The working files of the connections live in the data folder alone (since 1.15.0): the
    # previous window compared them with copies in the program, and there are none any more.
    $what = @{
        'ключи R2 bucket' = 'R2 bucket keys'; 'отпечатки хостов' = 'host fingerprints'
        'план зеркала' = 'mirror plan'; 'адреса машин' = 'machine addresses'
    }
    Write-Host ''
    Write-Host '===== WORKING FILES OF THIS MACHINE ====='
    Write-Host ('kept in: {0}' -f $data)
    foreach ($item in (Get-AbkMachineFiles)) {
        $name = $(if ($what.ContainsKey([string]$item.What)) { $what[[string]$item.What] } else { [string]$item.What })
        $mark = $(if (Test-Path -LiteralPath (Join-Path $data $item.Rel)) { 'there' } else { 'not there' })
        Write-Host ('{0,-24} {1,-44} {2}' -f $name, $item.Rel, $mark)
    }

    # Here this machine is asked too: the table says who goes where, and it is one of the "where".
    $plan = @((Get-Plan -Skip none).Plan)
    if (-not $plan.Count) { exit 0 }
    $known = @($rows | ForEach-Object { [pscustomobject]@{ Body = $_.Body; Name = $_.Names[0] } })
    $found = @{}
    $dead = @()
    $alien = @{}
    Write-Host ''
    Write-Host '----- who goes where'
    foreach ($item in $plan) {
        $alive = $false
        $lines = @(Get-AbkAuthorizedKeys -SshHost $item.SshHost -Kind $item.Kind -Reachable ([ref]$alive))
        if (-not $alive) {
            $dead += $item.Name
            Write-Host ('  {0} - no answer' -f $item.Caption)
            continue
        }
        $names = @()
        foreach ($key in $known) {
            if (@($lines | Where-Object { $_.Body -eq $key.Body }).Count) { $names += $key.Name }
        }
        $found[$item.Name] = $names
        $alien[$item.Name] = $lines.Count - $names.Count
    }
    $foreign = 'foreign lines'
    $wide = 12
    foreach ($key in $known) { if ($key.Name.Length -gt $wide) { $wide = $key.Name.Length } }
    if ($foreign.Length -gt $wide) { $wide = $foreign.Length }
    $head = (' ' * $wide)
    foreach ($item in $plan) { $head += ('  {0,-8}' -f $item.Caption) }
    Write-Host $head
    foreach ($key in $known) {
        $line = ('{0,-' + $wide + '}') -f $key.Name
        foreach ($item in $plan) {
            $mark = $(if ($dead -contains $item.Name) { '?' }
                      elseif (@($found[$item.Name]) -contains $key.Name) { '+' }
                      else { '.' })
            $line += ('  {0,-8}' -f $mark)
        }
        Write-Host $line
    }
    $line = ('{0,-' + $wide + '}') -f $foreign
    foreach ($item in $plan) {
        $mark = $(if ($dead -contains $item.Name) { '?' } else { [string]$alien[$item.Name] })
        $line += ('  {0,-8}' -f $mark)
    }
    Write-Host $line
    Write-Host 'a plus - the key is written there, a dot - it is not, a question mark - the machine did not answer'
    exit 0
}

# ------------------------------------------------------------ -Spread
if ($Spread) {
    $keys = @(Get-ClientKeys)
    if (-not $keys.Count) { Write-Host '[keys] CLIENTS is empty - press SSH-KEYGEN'; exit 1 }
    $plan = Get-Plan -Skip address
    if (-not $plan.Known) { Write-Host '[keys] no targets.json in the data folder - fill it with the button of addresses'; exit 1 }
    Write-Host ''
    Write-Host '===== SSH-COPY-ID ====='
    foreach ($machine in $plan.Mine) {
        Write-Host ('{0}: this is the machine itself - SSHD puts the public keys here' -f (Get-Caption $machine))
    }
    foreach ($item in $plan.Plan) { Write-Host ('{0}: going as {1}' -f $item.Caption, $item.SshHost) }
    if ($WhatIf) { Write-Host ('keys in CLIENTS: {0}; nothing was written' -f $keys.Count); exit 0 }
    $words = @{ added = 'put'; already = 'was there'; unreachable = 'no answer'; failed = 'did not work' }
    $bad = 0
    foreach ($item in $plan.Plan) {
        foreach ($key in $keys) {
            $verdict = Add-AbkAuthorizedKey -SshHost $item.SshHost -PublicKey $key.Line -Kind $item.Kind
            Write-Host ('{0,-10} {1,-22} {2}' -f $item.Caption, $key.Name, $words[[string]$verdict])
            if ($verdict -eq 'failed') { $bad++ }
            # A machine that is silent is silent for every key: no use waiting for each.
            if ($verdict -eq 'unreachable') { break }
        }
    }
    if ($bad) { exit 1 }
    exit 0
}

# ------------------------------------------------------------ -Revoke
if ($Revoke) {
    $name = $Revoke.Trim()
    $pick = @(Get-Revocable | Where-Object { $_.Name -eq $name })[0]
    if (-not $pick) { Write-Host ('[keys] there is no such public key: {0}' -f $name); exit 1 }
    $plan = Get-Plan
    if (-not $plan.Known) { Write-Host '[keys] no targets.json in the data folder - fill it with the button of addresses'; exit 1 }
    Write-Host ''
    Write-Host ('===== REVOKING: {0} =====' -f $pick.Name)
    foreach ($item in $plan.Plan) { Write-Host ('{0}: going as {1}' -f $item.Caption, $item.SshHost) }
    if ($WhatIf) { Write-Host 'nothing was removed'; exit 0 }
    $bad = 0
    foreach ($item in $plan.Plan) {
        $alive = $false
        $rows = @(Get-AbkAuthorizedKeys -SshHost $item.SshHost -Kind $item.Kind -Reachable ([ref]$alive))
        if (-not $alive) { Write-Host ('{0,-10} no answer' -f $item.Caption); continue }
        $here = @($rows | Where-Object { $_.Body -eq $pick.Body })
        if (-not $here.Count) { Write-Host ('{0,-10} this key is not there' -f $item.Caption); continue }
        # The last key of a machine is its only door: it stays.
        if ($rows.Count -le $here.Count) { Write-Host ('{0,-10} skipped: it is the last key, the machine would be left without access' -f $item.Caption); continue }
        $verdict = Remove-AbkAuthorizedKey -SshHost $item.SshHost -KeyBody $pick.Body -Kind $item.Kind
        $word = switch ($verdict) {
            'removed'     { 'revoked, keys left: {0}' -f ($rows.Count - $here.Count) }
            'missing'     { 'this key is not there' }
            'unreachable' { 'no answer' }
            default       { $bad++; 'did not work' }
        }
        Write-Host ('{0,-10} {1}' -f $item.Caption, $word)
    }
    if ($bad) { exit 1 }
    exit 0
}

Write-Host 'name one thing: -Describe, -Inventory, -Spread or -Revoke <name>'
exit 1
