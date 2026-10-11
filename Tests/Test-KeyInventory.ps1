#requires -Version 5.1
<#
    Проверка единого списка ключей.

    Список собирает `Get-AbkKeyInventory`. Его две опоры легко подломить
    правкой «для порядка», поэтому они проверяются здесь:

    Ключ узнаётся по телу, а не по имени файла. Одна и та же половина лежит
    под разными именами - в складе `audion-nova.pub`, в профиле
    `audion-nova_ed25519.pub`, - и по именам это выглядело бы двумя разными
    ключами.

    Назначение выводится из места, а не из названия. Название врёт: имя
    `audion_codex_ed25519` однажды приняли за ключ машины, хотя это дверь на
    MAIN VPS.

    Работает на подставных папках, ничего живого не трогает.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }

$failed = 0

function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-keys-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$ssh = Join-Path $sandbox 'profile'
$store = Join-Path $sandbox 'SSH'
$kit = Join-Path $sandbox 'Export'
foreach ($dir in @($ssh, $store, (Join-Path $store 'clients'), (Join-Path $store 'servers'), $kit)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

function Write-Half {
    <# Открытая половина, при -WithPrivate рядом ложится и закрытая. #>
    param([string]$Dir, [string]$Name, [string]$Body, [switch]$WithPrivate)
    Set-Content -LiteralPath (Join-Path $Dir ($Name + '.pub')) -Encoding ascii `
        -Value ('ssh-ed25519 {0} {1}' -f $Body, $Name)
    if ($WithPrivate) {
        Set-Content -LiteralPath (Join-Path $Dir $Name) -Encoding ascii -Value 'PRIVATE KEY STUB'
    }
}

Write-Host ''
Write-Host '===== СПИСОК КЛЮЧЕЙ ====='

try {
    # Одна и та же половина под тремя именами в трёх местах.
    Write-Half -Dir (Join-Path $store 'clients') -Name 'audion-nova' -Body 'AAAAnova'
    Write-Half -Dir $ssh -Name 'audion-nova_ed25519' -Body 'AAAAnova' -WithPrivate
    Write-Half -Dir $kit -Name 'audion-nova_ed25519' -Body 'AAAAnova' -WithPrivate

    # Дверь на MAIN VPS: имя похоже на машинное, но лежит в servers.
    Write-Half -Dir (Join-Path $store 'servers') -Name 'audion_codex_ed25519' -Body 'AAAAcodex' -WithPrivate

    # Общий ключ старой схемы - в корне склада.
    Write-Half -Dir $store -Name 'audion_machines_ed25519' -Body 'AAAAshared'

    # Битая строка не должна попасть в список вовсе.
    Set-Content -LiteralPath (Join-Path $ssh 'broken.pub') -Encoding ascii -Value 'not-a-key'

    $rows = @(Get-AbkKeyInventory -SshDir $ssh -Store $store -Kit $kit)

    Test-Step -Title 'ключей ровно столько, сколько разных тел' -Ok ($rows.Count -eq 3) `
        -Note ('строк: {0}' -f $rows.Count)

    $nova = @($rows | Where-Object { $_.Body -eq 'AAAAnova' })[0]
    Test-Step -Title 'копии под разными именами - один ключ' -Ok ($nova -and $nova.Names.Count -eq 2) `
        -Note $(if ($nova) { $nova.Names -join ', ' } else { '' })
    Test-Step -Title 'видны все три места' -Ok ($nova -and $nova.Places.Count -eq 3) `
        -Note $(if ($nova) { $nova.Places -join ', ' } else { '' })
    Test-Step -Title 'назначение взято из места в Tunnel\SSH, не из имени' -Ok ($nova -and $nova.Purpose -eq 'машина')
    Test-Step -Title 'приватный ключ отмечен там, где лежит' `
        -Ok ($nova -and $nova.Private.Count -eq 2 -and $nova.Private -notcontains 'CLIENTS') `
        -Note $(if ($nova) { $nova.Private -join ', ' } else { '' })

    $codex = @($rows | Where-Object { $_.Body -eq 'AAAAcodex' })[0]
    Test-Step -Title 'дверь на MAIN VPS не считается машиной' -Ok ($codex -and $codex.Purpose -eq 'MAIN VPS и SECOND VPS') `
        -Note $(if ($codex) { $codex.Names[0] } else { '' })

    $shared = @($rows | Where-Object { $_.Body -eq 'AAAAshared' })[0]
    Test-Step -Title 'ключ из корня Tunnel\SSH - старая схема' -Ok ($shared -and $shared.Purpose -eq 'старая схема')
    Test-Step -Title 'у него нет приватного ключа' -Ok ($shared -and $shared.Private.Count -eq 0)

    Test-Step -Title 'битая строка в список не попала' `
        -Ok (-not @($rows | Where-Object { $_.Names -contains 'broken' }).Count)

    # Пустые пути не должны ронять сбор: на новой машине ничего ещё нет.
    $empty = @(Get-AbkKeyInventory -SshDir (Join-Path $sandbox 'нет') -Store (Join-Path $sandbox 'нет') -Kit '')
    Test-Step -Title 'на пустом месте список пуст, а не падает' -Ok ($empty.Count -eq 0)
} finally {
    Remove-Module BackupEngine -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
