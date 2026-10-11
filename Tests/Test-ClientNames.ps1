#requires -Version 5.1
<#
    Проверка имени машины.

    Имя даёт человек, а ложится оно в имя файла ключа и в подпись в
    authorized_keys на всех машинах - там годится только латиница в нижнем
    регистре, цифры, тире и подчёркивание. Отказывать из-за раскладки глупо,
    поэтому мастер переводит написанное в годный вид и спрашивает согласия.

    Тест следит за обеими сторонами: что проверка не пропускает лишнего и что
    перевод даёт имя, которое эту проверку проходит.

    Ничего не запускает и не меняет. Возвращает 0, когда всё сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }

Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking

$failed = 0

function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Write-Host ''
Write-Host '===== ИМЯ МАШИНЫ ====='

foreach ($good in 'laptop', 'base-1', 'work_pc', 'a1', 'my-old-pc') {
    Test-Step -Title ('годится: {0}' -f $good) -Ok (Test-AbkClientName -Name $good)
}

foreach ($bad in 'Nova', 'мой-пк', 'my pc', 'dot.name', 'a', '', '-start', ('x' * 40)) {
    $shown = $(if ($bad) { $bad } else { '(пусто)' })
    Test-Step -Title ('отклонено: {0}' -f $shown) -Ok (-not (Test-AbkClientName -Name $bad))
}

Write-Host ''
foreach ($pair in @(
        @{ In = 'Мой ПК'; Out = 'moy-pk' },
        @{ In = 'Nova'; Out = 'nova' },
        @{ In = 'work.pc'; Out = 'work-pc' },
        @{ In = 'BASE_1'; Out = 'base-1' },
        @{ In = '  дом  '; Out = 'dom' },
        @{ In = 'Стационар дома (BASE)'; Out = 'statsionar-doma-base' })) {
    $got = ConvertTo-AbkClientName -Name $pair.In
    Test-Step -Title ('перевод: {0}' -f $pair.In) -Ok ($got -eq $pair.Out) -Note $got
}

# Перевод обязан давать имя, которое проходит проверку - иначе мастер
# предложит человеку то, что сам же и отвергнет.
$slips = @()
foreach ($sample in 'Мой ПК', 'Ноутбук Максима', 'Стационар дома (BASE)', 'work.pc', 'ЭТОТ ПК') {
    $got = ConvertTo-AbkClientName -Name $sample
    if (-not (Test-AbkClientName -Name $got)) { $slips += $sample }
}
Test-Step -Title 'перевод всегда даёт годное имя' -Ok (-not $slips.Count) -Note ($slips -join ', ')

# Пустое остаётся пустым: предлагать нечего, и мастер об этом скажет.
Test-Step -Title 'из пустого не рождается имя' -Ok ((ConvertTo-AbkClientName -Name '   ') -eq '')

Write-Host ''
# Предложение собирается из учётной записи и имени компьютера. Повторы
# убираются: учётка Audion на машине AUDION-NOVA не должна давать
# «audion-audion-nova».
foreach ($case in @(
        @{ User = 'Audion'; Computer = 'AUDION-NOVA'; Out = 'audion-nova' },
        @{ User = 'Audion'; Computer = 'AUDION-BASE'; Out = 'audion-base' },
        @{ User = 'Max'; Computer = 'DESKTOP-4F3A'; Out = 'max-desktop-4f3a' },
        @{ User = 'admin'; Computer = 'SRV1'; Out = 'admin-srv1' })) {
    $got = Get-AbkSuggestedName -User $case.User -Computer $case.Computer
    Test-Step -Title ('предложение: {0} на {1}' -f $case.User, $case.Computer) `
        -Ok ($got -eq $case.Out) -Note $got
}

$mine = Get-AbkSuggestedName
Test-Step -Title 'предложение для этой машины годится' -Ok (Test-AbkClientName -Name $mine) -Note $mine

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
