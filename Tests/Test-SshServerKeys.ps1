#requires -Version 5.1
<#
    Ключи sshd на этой машине: SSHD приводит к складу строки машин из склада и не
    трогает строки соседей. Проверяется настоящая функция Merge-AccessKeys из
    Setup-SshServer.ps1 на выдуманных строках: сценарий не запускается, настоящий
    файл ключей и склад не трогаются.

    Возвращает 0, когда всё сходится, иначе 1.
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

function Get-FunctionText {
    <# Текст одной функции из файла: проверяется настоящий код, а не его копия. #>
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $found = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { throw ('функция {0} не найдена в {1}' -f $Name, $Path) }
    return $found[0].Extent.Text
}

Write-Host ''
Write-Host '===== КЛЮЧИ SSHD ====='

Invoke-Expression (Get-FunctionText -Path (Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshServer.ps1') -Name 'Merge-AccessKeys')

$base   = [pscustomobject]@{ Name = 'audion-base_ed25519';   Line = 'ssh-ed25519 BASEBODY audion-base' }
$carbon = [pscustomobject]@{ Name = 'audion-carbon';         Line = 'ssh-ed25519 CARBONBODY audion-carbon' }
$twin   = [pscustomobject]@{ Name = 'audion-carbon_ed25519'; Line = 'ssh-ed25519 CARBONBODY audion-carbon' }
$work   = [pscustomobject]@{ Name = 'audion-work';           Line = 'ssh-ed25519 NEWWORKBODY audion-work' }

# Файл, который отстал: прежний ключ WORK, нет BASE, есть половина соседа,
# принесённая SSH-COPY-ID, пустая строка и заметка.
$file = @(
    'ssh-ed25519 CARBONBODY audion-carbon',
    'ssh-ed25519 OLDWORKBODY audion-work',
    'ssh-ed25519 HOMEBODY audion-home',
    '',
    '# заметка'
)

$merge = Merge-AccessKeys -Existing $file -Keys @($base, $carbon, $twin, $work)
Test-Step -Title 'строки после приведения' `
    -Ok ((@($merge.Lines) -join '|') -eq 'ssh-ed25519 CARBONBODY audion-carbon|ssh-ed25519 HOMEBODY audion-home|# заметка|ssh-ed25519 BASEBODY audion-base|ssh-ed25519 NEWWORKBODY audion-work') `
    -Note ('строк: {0}' -f @($merge.Lines).Count)
Test-Step -Title 'файл нужно переписать' -Ok ([bool]$merge.Changed)
Test-Step -Title 'прописанный ключ остаётся' -Ok ((@($merge.Kept) -join ',') -eq 'audion-carbon') -Note (@($merge.Kept) -join ', ')
Test-Step -Title 'недостающие дописываются' -Ok ((@($merge.Added) -join ',') -eq 'audion-base,audion-work') -Note (@($merge.Added) -join ', ')
Test-Step -Title 'прежний ключ машины из CLIENTS заменяется' -Ok ((@($merge.Removed) -join ',') -eq 'audion-work') `
    -Note 'та же подпись, другое тело'
Test-Step -Title 'ключ соседа, которого нет в CLIENTS, остаётся' -Ok ((@($merge.Foreign) -join ',') -eq 'audion-home') `
    -Note 'CLIENTS у каждой машины свой'
Test-Step -Title 'один публичный ключ под двумя именами - одна строка' `
    -Ok (@($merge.Lines | Where-Object { $_ -like '*CARBONBODY*' }).Count -eq 1)

$same = Merge-AccessKeys -Existing @('ssh-ed25519 BASEBODY audion-base', '') -Keys @($base)
Test-Step -Title 'совпадает с CLIENTS - файл не трогается' `
    -Ok (-not $same.Changed -and @($same.Added).Count -eq 0 -and @($same.Removed).Count -eq 0)

$empty = Merge-AccessKeys -Existing $file -Keys @()
Test-Step -Title 'пустой CLIENTS файл не трогает' `
    -Ok (-not $empty.Changed -and @($empty.Removed).Count -eq 0) `
    -Note 'иначе вход по ключам пропал бы весь'

$twice = Merge-AccessKeys -Existing @('ssh-ed25519 BASEBODY audion-base', 'ssh-ed25519 BASEBODY audion-base') -Keys @($base)
Test-Step -Title 'повтор ключа в файле схлопывается' `
    -Ok ($twice.Changed -and @($twice.Lines).Count -eq 1)

$odd = Merge-AccessKeys -Existing @('restrict,port-forwarding ssh-ed25519 BEACONBODY beacon', 'ssh-ed25519 LONEBODY') -Keys @($base)
Test-Step -Title 'строка с ограничениями и без подписи - чужие' `
    -Ok ((@($odd.Foreign) -join ',') -eq 'beacon,(без подписи)' -and @($odd.Lines).Count -eq 3) `
    -Note (@($odd.Foreign) -join ', ')

Write-Host ''
if ($failed) { Write-Host ('сбоев: {0}' -f $failed); exit 1 }
Write-Host 'всё сходится'
exit 0
