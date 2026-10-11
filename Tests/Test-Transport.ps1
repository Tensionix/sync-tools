#requires -Version 5.1
<#
    Проверка сборки транспорта из заготовки.

    Мастер собирает config\rclone\rclone.conf из config\rclone.sample.conf,
    подставляя адреса, учётные записи и пути. Тест следит за тремя вещами:
    подстановка попадает куда надо, незаполненные метки честно называются, а
    шапка заготовки в рабочий файл не переезжает.

    Рабочий файл не трогается: сборка идёт во временную папку.
    Возвращает 0, когда всё сходится, иначе 1.
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
Write-Host '===== RCLONE.CONF ====='

$template = Join-Path $AppRoot 'config\rclone.sample.conf'
$out = Join-Path ([System.IO.Path]::GetTempPath()) ('rclone-test-{0}.conf' -f $PID)

Test-Step -Title 'заготовка на месте' -Ok (Test-Path -LiteralPath $template)

$values = @{
    R2_ACCOUNT      = 'abcdef0123456789'
    R2_PROFILE      = 'audion_r2'
    BASE_ADDRESS    = '192.168.1.10'
    BASE_USER       = 'Audion'
    LAPTOP_ADDRESS  = '192.168.1.130'
    LAPTOP_USER     = 'Audion'
    WORK_ADDRESS    = '198.51.100.30'
    WORK_USER       = 'worker'
    HOME_ADDRESS    = '192.168.9.20'
    HOME_USER       = 'Audion'
    DAD_ADDRESS     = '192.0.2.50'
    DAD_USER        = 'relative'
    DAD_PORT        = 2222
    MACHINE_KEY     = '~/.ssh/audion_machines_ed25519'
    SERVER_ADDRESS  = '10.0.0.1'
    SERVER_USER     = 'root'
    SERVER_KEY      = '~/.ssh/audion_vps_root_ed25519'
    SERVER_SSH_HOST = 'audion-vps'
    SECOND_SSH_HOST    = 'second-vps'
    SECOND_SSH_HOST_CF = 'second-vps-cf'
    KNOWN_HOSTS     = 'E:/Program/config/rclone/known_hosts'
}

try {
    $left = @(Build-AbkTransport -Template $template -Path $out -Values $values)
    Test-Step -Title 'все метки заполнены' -Ok (-not $left.Count) -Note ($left -join ', ')

    $text = [System.IO.File]::ReadAllText($out)
    Test-Step -Title 'DAD uses its configured SSH port' -Ok ($text -match '(?s)\[dad\].*?port = 2222')
    Test-Step -Title 'адрес R2 bucket подставлен' -Ok ($text -like '*abcdef0123456789.r2.cloudflarestorage.com*')
    Test-Step -Title 'адрес BASE подставлен' -Ok ($text -match '(?m)^host = 192\.168\.1\.10$')
    Test-Step -Title 'ключ машин подставлен' -Ok ($text -like '*~/.ssh/audion_machines_ed25519*')
    Test-Step -Title 'запасной ход MAIN VPS подставлен' -Ok ($text -like '*ConnectTimeout=20 audion-vps*')
    Test-Step -Title 'SECOND VPS подставлен' -Ok ($text -match '(?m)^\[second\]$' -and $text -like '*ConnectTimeout=20 second-vps-cf*')
    Test-Step -Title 'шапка заготовки не переехала' -Ok ($text -notlike '*{{R2_ACCOUNT}}*' -and $text -notlike '*Заготовка транспорта*')

    $sections = @([regex]::Matches($text, '(?m)^\[([a-z0-9-]+)\]$') | ForEach-Object { $_.Groups[1].Value })
    # Секций восемнадцать. У рабочей машины одна, прямо по адресу; дальнему маршруту
    # до дома нужны свои. Шестнадцатой была `laptop-ssh` -
    # обратный проброс ноутбука; он снят 09.09.2026 вместе с самим пробросом.
    # Последними добавились две точки: сама SECOND VPS и она же поверх
    # cloudflared - на него кладут файлы так же, как на любую машину.
    Test-Step -Title 'секции на месте' -Ok ($sections.Count -eq 18) -Note ($sections -join ' ')
    Test-Step -Title 'панель рабочей машины собрана' `
        -Ok ($text -match '(?m)^\[work\]$' -and $text -match '198\.51\.100\.30') `
        -Note 'адрес рабочей машины'

    # Незаполненное должно называться, а не молча уходить в файл.
    $short = @{ R2_ACCOUNT = 'x'; BASE_ADDRESS = '192.168.1.10' }
    $left = @(Build-AbkTransport -Template $template -Path $out -Values $short)
    Test-Step -Title 'пропущенные метки названы' -Ok ($left -contains 'LAPTOP_ADDRESS' -and $left -contains 'SERVER_KEY') `
        -Note ('осталось {0}' -f $left.Count)

    # Пересборка не вправе портить рабочий файл: метка, которой нечем
    # заполниться, берёт строку того же раздела из прежнего транспорта. Так
    # SECOND VPS, чьё имя окно не подтвердило, остаётся как был.
    [void](Build-AbkTransport -Template $template -Path $out -Values $values)
    $partial = @{} + $values
    $partial.Remove('SECOND_SSH_HOST')
    $partial.Remove('LAPTOP_ADDRESS')
    $report = @{}
    $left = @(Build-AbkTransport -Template $template -Path $out -Values $partial -KeepFrom $out -Report $report)
    $rebuilt = [System.IO.File]::ReadAllText($out)
    Test-Step -Title 'рабочие строки переживают пересборку' `
        -Ok ((-not $left.Count) -and $rebuilt -match '(?m)ConnectTimeout=20 second-vps$' -and $rebuilt -match '(?m)^host = 192\.168\.1\.130$') `
        -Note ('сохранено: {0}' -f (@($report['Kept']) -join ', '))
    Test-Step -Title 'сохранённое названо' `
        -Ok (@($report['Kept']) -contains 'SECOND_SSH_HOST' -and @($report['Kept']) -contains 'LAPTOP_ADDRESS')

    $bytes = [System.IO.File]::ReadAllBytes($out)
    Test-Step -Title 'BOM на месте' -Ok ($bytes[0] -eq 0xEF)
} finally {
    Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
