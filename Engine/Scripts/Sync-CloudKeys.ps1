<#
.SYNOPSIS
    Ключи облаков между машинами: положить golden copy на MAIN VPS, забрать на машину.

.DESCRIPTION
    Токен облака не привязан к машине - привязан лишь замок, которым он у нас
    закрыт. DPAPI запечатывает на этого пользователя и эту Windows: переставили
    систему - и заново проходи вход во все восемь облаков.

    Поэтому golden copy живёт там, где ничего не переустанавливают, - на MAIN
    VPS, в `~/.audion/clouds.conf` с правами 600. Она зашифрована тем же rclone,
    что и здесь; пароль от неё на MAIN VPS не уезжает.

    Пароль хранится в папке данных: `Tunnel\clouds.key`, открытым текстом; права
    на файл - только владелец, администраторы и система. EXPORT KEYS и IMPORT
    KEYS его не переносят: на новую машину файл кладут руками. На самой машине
    пароль дополнительно запечатан DPAPI, но это лишь кэш: потеряется -
    возьмётся из папки данных.

    Отсюда порядок для новой машины: `Tunnel\clouds.key` в папку данных, затем
    `clouds-pull.cmd` - и все облака на месте без единого повторного входа.

.PARAMETER Push
    Положить конфиг облаков на MAIN VPS как golden copy.

.PARAMETER Pull
    Забрать golden copy с MAIN VPS на эту машину.

.PARAMETER Server
    Хосты MAIN VPS по порядку: работает первый ответивший.

.PARAMETER Check
    Только посмотреть, что где лежит.

.EXAMPLE
    .\Sync-CloudKeys.ps1 -Check
    Что на машине, что в папке данных, что на MAIN VPS.

.EXAMPLE
    .\Sync-CloudKeys.ps1 -Pull
    Забрать golden copy с MAIN VPS на эту машину.
#>
[CmdletBinding()]
param(
    [switch]$Push,
    [switch]$Pull,
    [switch]$Check,
    [string[]]$Server = @('audion-vps-direct', 'audion-vps'),
    [string]$Root,
    # Ключ враппера из Runs: паузу держит он и читает ключ тоже он. Здесь ключ
    # только принимается, чтобы вызов с ним не падал на разборе аргументов.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$AppRoot = Split-Path -Parent (Split-Path -Parent $Here)

. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\Clouds.ps1')
$secrets = Join-Path $AppRoot 'Engine\Secrets.ps1'
if (Test-Path -LiteralPath $secrets) { . $secrets }

$Server = @($Server | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })

$DataRoot = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$VaultKey = Join-Path $DataRoot 'Tunnel\clouds.key'
$Remote = '~/.audion/clouds.conf'

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Invoke-Server {
    <# Одна команда на первом отвечающем плече. Возвращает вывод и код. #>
    param([Parameter(Mandatory)][string]$Command)

    foreach ($leg in $Server) {
        $ErrorActionPreference = 'Continue'
        $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 $leg $Command 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) { return @{ Ok = $true; Text = ($out | Out-String); Leg = $leg } }
    }
    return @{ Ok = $false; Text = ''; Leg = '' }
}

Write-Host ''
Write-Host '=== КЛЮЧИ ОБЛАКОВ: МАШИНА, ПАПКА ДАННЫХ, MAIN VPS ===' -ForegroundColor Cyan
Write-Host ''

$local = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
$sealed = Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot

# --- осмотр ----------------------------------------------------------------
if ($Check -or (-not $Push -and -not $Pull)) {
    Write-Line ('на машине : {0}' -f $(if (Test-Path -LiteralPath $local) { 'конфиг есть' } else { 'конфига нет' })) `
        $(if (Test-Path -LiteralPath $local) { 'Green' } else { 'Yellow' })
    Write-Line ('замок DPAPI: {0}' -f $(if (Test-Path -LiteralPath $sealed) { 'есть' } else { 'нет' })) `
        $(if (Test-Path -LiteralPath $sealed) { 'Green' } else { 'Yellow' })
    Write-Line ('в данных  : {0}' -f $(if (Test-Path -LiteralPath $VaultKey) { $VaultKey } else { 'пароля нет' })) `
        $(if (Test-Path -LiteralPath $VaultKey) { 'Green' } else { 'Yellow' })

    $answer = Invoke-Server -Command ("test -f {0} && stat -c '%s байт, права %a' {0} || echo 'нет'" -f $Remote)
    Write-Line ('на MAIN VPS: {0}' -f $(
        if (-not $answer.Ok) { 'MAIN VPS молчит' } else { $answer.Text.Trim() })) `
        $(if ($answer.Ok -and $answer.Text -notmatch 'нет') { 'Green' } else { 'Yellow' })
    Write-Host ''
    Write-Line 'положить golden copy: clouds-push.cmd · забрать на эту машину: clouds-pull.cmd'
    Write-Host ''
    exit 0
}

# --- положить на MAIN VPS -----------------------------------------------------
if ($Push) {
    if (-not (Test-Path -LiteralPath $local)) {
        Write-Line 'на этой машине облака не заведены: clouds-add.cmd' Yellow
        Write-Host ''
        exit 1
    }

    $password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not $password) {
        Write-Line 'пароль от конфига не открывается - без него golden copy бесполезна' Yellow
        Write-Host ''
        exit 1
    }

    # Пароль кладём в папку данных, а не рядом с конфигом на MAIN VPS: MAIN VPS
    # держит замок, папка данных - ключ от него. Порознь ни то, ни другое не работает.
    $folder = Split-Path -Parent $VaultKey
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    [System.IO.File]::WriteAllText($VaultKey, $password, [System.Text.UTF8Encoding]::new($false))
    if (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue) { $null = Protect-AbkSecret -Path $VaultKey }
    Write-Line ('пароль положен в папку данных: {0}' -f $VaultKey) Green

    $prepared = Invoke-Server -Command 'mkdir -p ~/.audion && chmod 700 ~/.audion && echo ok'
    if (-not $prepared.Ok) { Write-Line 'MAIN VPS молчит' Yellow; Write-Host ''; exit 1 }

    $ErrorActionPreference = 'Continue'
    & scp -o BatchMode=yes -o ConnectTimeout=20 $local ('{0}:.audion/clouds.conf' -f $prepared.Leg)
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) { Write-Line 'скопировать не вышло' Yellow; Write-Host ''; exit 1 }

    $null = Invoke-Server -Command ('chmod 600 {0}' -f $Remote)
    Write-Line ('golden copy на MAIN VPS: {0} ({1})' -f $Remote, $prepared.Leg) Green
    Write-Host ''
    Write-Line 'на новой машине: Tunnel\clouds.key в папку данных, затем clouds-pull.cmd - входить заново не придётся'
    Write-Host ''
    exit 0
}

# --- забрать на машину ------------------------------------------------------
if ($Pull) {
    $answer = Invoke-Server -Command ("test -f {0} && echo ok || echo 'нет'" -f $Remote)
    if (-not $answer.Ok -or $answer.Text -match 'нет') {
        Write-Line 'на MAIN VPS golden copy нет: положите её с той машины, где облака уже заведены' Yellow
        Write-Host ''
        exit 1
    }

    $password = ''
    if (Test-Path -LiteralPath $VaultKey) {
        $password = ([System.IO.File]::ReadAllText($VaultKey)).Trim()
    }
    if (-not $password) { $password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot }
    if (-not $password) {
        Write-Line 'пароля нет ни в папке данных, ни на машине: перенесите Tunnel\clouds.key с машины, где облака заведены' Yellow
        Write-Host ''
        exit 1
    }

    $folder = Split-Path -Parent $local
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }

    # Забираем рядом, а не поверх. Раньше scp писал прямо в рабочий конфиг,
    # замок пересобирался следом, и только потом шла проверка: если пароль
    # к принесённому не подходил, рабочая пара была уже потеряна - а
    # сценарий всё равно говорил «входить заново не требуется» и возвращал
    # ноль. Теперь до проверки на машине не меняется ничего.
    $incoming = $local + '.incoming'
    Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue

    $ErrorActionPreference = 'Continue'
    & scp -o BatchMode=yes -o ConnectTimeout=20 ('{0}:.audion/clouds.conf' -f $answer.Leg) $incoming
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) {
        Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue
        Write-Line 'забрать не вышло' Yellow; Write-Host ''; exit 1
    }

    $exe = Join-Path $AppRoot 'Tools\rclone\rclone.exe'
    if (Test-Path -LiteralPath $exe) {
        $opens = Test-AbkCloudsOpen -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe -ConfigPath $incoming -Password $password
        if (-not $opens) {
            Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue
            Write-Line 'принесённый конфиг этим паролем не открывается' Red
            Write-Line 'на машине всё осталось как было' Gray
            Write-Host ''
            exit 1
        }
        Write-Line 'принесённый конфиг открывается' Green
    } else {
        # Проверить нечем - значит и менять нечего. Прежде здесь только
        # предупреждали и всё равно ставили принесённое на место: заведомо
        # негодный файл заменял рабочую пару, а сценарий возвращал ноль.
        Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue
        Write-Line 'rclone рядом нет - принесённое проверить нечем' Yellow
        Write-Line 'без проверки менять рабочую пару нельзя: поставьте rclone и повторите' Gray
        Write-Line 'на машине всё осталось как было' Gray
        Write-Host ''
        exit 1
    }

    # Прежнюю пару держим под рукой, пока новая не встанет целиком.
    $keyPath = Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot
    $backConfig = $local + '.previous'
    $backKey = $keyPath + '.previous'
    if (Test-Path -LiteralPath $local) { Copy-Item -LiteralPath $local -Destination $backConfig -Force }
    if (Test-Path -LiteralPath $keyPath) { Copy-Item -LiteralPath $keyPath -Destination $backKey -Force }

    try {
        Move-Item -LiteralPath $incoming -Destination $local -Force
        # Замок на этой машине пересобираем: пароль тот же, а DPAPI у каждой свой.
        Protect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot -Password $password | Out-Null
        if (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue) {
            $null = Protect-AbkSecret -Path $local
            $null = Protect-AbkSecret -Path $keyPath
        }

        if (Test-Path -LiteralPath $exe) {
            $ok = Test-AbkCloudsOpen -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe
            if (-not $ok) { throw 'на месте конфиг не открылся' }
            $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe | Where-Object { $_.Name })
            Write-Line ('облаков забрано: {0}' -f $clouds.Count) Green
            foreach ($cloud in $clouds) { Write-Line ('  {0,-16} {1}' -f $cloud.Name, $cloud.Type) }
        }
    } catch {
        # Возвращаем как было: лучше прежние облака, чем никакие.
        if (Test-Path -LiteralPath $backConfig) { Copy-Item -LiteralPath $backConfig -Destination $local -Force }
        if (Test-Path -LiteralPath $backKey) { Copy-Item -LiteralPath $backKey -Destination $keyPath -Force }
        Remove-Item -LiteralPath $backConfig, $backKey -Force -ErrorAction SilentlyContinue
        Write-Line ('заменить не вышло: ' + $_.Exception.Message) Red
        Write-Line 'прежние конфиг и замок возвращены на место' Gray
        Write-Host ''
        exit 1
    }

    Remove-Item -LiteralPath $backConfig, $backKey -Force -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Line 'входить в облака заново не требуется: токены те же' Green
    Write-Host ''
    exit 0
}
