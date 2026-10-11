<#
.SYNOPSIS
    Собирает ключи этой машины в `Tunnel\Export`.

.DESCRIPTION
    Обратная сторона `import-keys.cmd`. Тот раскладывает ключи из Export Keys
    по штатным местам Windows, этот собирает их обратно в одну папку — чтобы
    перенести на другую машину вместе с папкой данных.

    Берётся то, что программы держат каждая у себя: ssh-ключи из профиля
    пользователя, маршруты из `~\.ssh\config`, ключи к R2 bucket из
    `config\rclone` программы. Ключом считается файл, у которого рядом лежит
    парный `.pub`, — так в Export Keys попадают любые имена и не попадают
    `known_hosts` и прочее хозяйство ssh.

    Golden copy `Tunnel\SSH` при этом не трогается: она собрана однажды и живёт
    своей жизнью. EXPORT KEYS нужен, когда на машине появился ключ, которого в
    golden copy нет, или комментарий у ключа поменяли на месте.

    Содержимое ключей не читается и не печатается — файлы только копируются.

.PARAMETER Check
    Ничего не менять, показать, что и куда легло бы.

.PARAMETER Force
    Перезаписать то, что в `Export` уже лежит.

.EXAMPLE
    export-keys.cmd -Check
    Показать, что попадёт в Export Keys.

.EXAMPLE
    export-keys.cmd
    Собрать Export Keys в Tunnel\Export.
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [switch]$Check,
    [switch]$Force,
    # Ключ враппера из Runs: паузу держит он и читает ключ тоже он. Здесь ключ
    # только принимается, чтобы вызов с ним не падал на разборе аргументов.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root) {
    . (Join-Path $AppRoot 'Engine\DataRoot.ps1')
    $Root = Get-AbkDataRootPath -AppRoot $AppRoot
}
$Tunnel = Join-Path $Root 'Tunnel'
$Export = Join-Path $Tunnel 'Export'
$SshDir = Join-Path $HOME '.ssh'
$SshConfig = Join-Path $SshDir 'config'

# Ключи к корзине берутся из выбранной папки данных.
$RcloneDir = Join-Path $Root 'config\rclone'

$Taken = 0
$Kept = 0
$Open = 0

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "===== $Text" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Text, [string]$Colour = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Colour
}

function Protect-KeyFile {
    # Наследование снимается, доступ остаётся у одного пользователя. Копия,
    # положенная в папку на диске с общими правами, наследует их — и ssh такой
    # ключ молча отвергает, жалуясь на «unprotected private key file».
    # Отказ icacls - несделанное дело, а не строка, которой никто не видит: функция
    # отвечает, закрыт ли ключ, и сценарий с незакрытым ключом кончается ошибкой.
    param([string]$Path)
    $me = (& whoami).Trim()
    & icacls $Path /inheritance:r /grant:r "${me}:F" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Copy-Secret {
    param(
        [string]$From,
        [string]$To,
        [string]$Title,
        [switch]$Protect,
        [switch]$Fresh
    )

    if (-not (Test-Path -LiteralPath $From)) { return }

    $exists = Test-Path -LiteralPath $To
    if ($exists -and -not $Force -and -not $Fresh) {
        Write-Note "already in Export Keys: $Title"
        $script:Kept++
        return
    }

    if ($Check) {
        $verb = if ($exists) { 'would overwrite' } else { 'would take' }
        Write-Note "$verb : $Title" 'Yellow'
        return
    }

    $parent = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $From -Destination $To -Force
    if ($Protect -and -not (Protect-KeyFile -Path $To)) {
        Write-Note "taken, but icacls failed to close it - ssh refuses a key left open: $Title" 'Red'
        $script:Open++
    } else {
        Write-Note "taken: $Title" 'Green'
    }
    $script:Taken++
}

Write-Host '======================================================================'
Write-Host 'AUDION SYNC TOOLS - EXPORT KEYS: this machine -> Tunnel\Export'
Write-Host '======================================================================'
Write-Note "profile : $SshDir"
Write-Note "program : $AppRoot"
Write-Note "export  : $Export"
if ($Check) { Write-Note 'mode    : dry run, nothing is written' 'Yellow' }
if ($Force) { Write-Note 'mode    : overwrite what exists' 'Yellow' }

# ---------------------------------------------------------------------- ssh

Write-Step 'The machine keys - from the profile'

if (-not (Test-Path -LiteralPath $SshDir)) {
    Write-Note 'the profile holds no .ssh folder - nothing to take' 'Yellow'
} else {
    # Ключом считается файл с парным .pub: так в комплект едут любые имена, а
    # known_hosts, config и прочее хозяйство ssh остаётся на месте.
    $pubs = @(Get-ChildItem -LiteralPath $SshDir -File -Filter '*.pub')
    if (-not $pubs.Count) {
        Write-Note 'no key pairs found in the profile' 'Yellow'
    }

    foreach ($pub in $pubs) {
        $private = Join-Path $SshDir ($pub.BaseName)
        if (-not (Test-Path -LiteralPath $private)) {
            Write-Note "public key only: $($pub.Name)" 'Yellow'
            continue
        }

        Copy-Secret -From $private -To (Join-Path $Export "SSH\$($pub.BaseName)") -Title $pub.BaseName -Protect
        Copy-Secret -From $pub.FullName -To (Join-Path $Export "SSH\$($pub.Name)") -Title $pub.Name
    }
}

# Лишнее из комплекта не выбрасывается: удалять ключи — дело владельца, а
# молчать о них нельзя. Ключ, снятый с машины, но оставшийся в комплекте,
# вернётся на следующую машину как живой.
$exportedKeys = Join-Path $Export 'SSH'
if (Test-Path -LiteralPath $exportedKeys) {
    $stale = @(Get-ChildItem -LiteralPath $exportedKeys -File |
        Where-Object { $_.Name -ne 'config' -and -not (Test-Path -LiteralPath (Join-Path $SshDir $_.Name)) })

    if ($stale.Count) {
        Write-Note "Export Keys holds what the machine no longer has:" 'Yellow'
        foreach ($item in $stale) { Write-Note "  $($item.Name)" 'Yellow' }
        Write-Note 'nothing is deleted here - decide yourself' 'Yellow'
    }
}

# ------------------------------------------------------------------- маршруты

# Маршруты меняются чаще ключей: хост добавили, маршрут переименовали. Старый
# config в комплекте уже стоил половины дня - на рабочей машине не было ни
# base, ни laptop, и ssh не понимал их имён. Поэтому его берём всегда.
Write-Step 'The ~\.ssh\config routes'

if (Test-Path -LiteralPath $SshConfig) {
    Copy-Secret -From $SshConfig -To (Join-Path $Export 'SSH\config') -Title 'config' -Fresh
} else {
    Write-Note 'the profile holds no config' 'Yellow'
}

# ------------------------------------------------------------------- корзина

Write-Step 'The R2 bucket keys - from config\rclone'

if (-not (Test-Path -LiteralPath $RcloneDir)) {
    Write-Note "no folder $RcloneDir - nothing to take" 'Yellow'
} else {
    # Только ключи корзины. Собранный rclone.conf в комплект не идёт: он
     # ссылается на ключ той машины, где собран, и на новой машине панели
     # молчат с «unable to authenticate». Транспорт там собирает мастер
     # RCLONE.CONF - под её собственный ключ.
    Copy-Secret -From (Join-Path $RcloneDir 'r2.credentials') `
                -To (Join-Path $Export 'rclone\r2.credentials') `
                -Title 'rclone\r2.credentials'
}

# ---------------------------------------------------------------------- итог

Write-Step 'Summary'
if ($Check) {
    Write-Note 'dry run: nothing on disk was changed' 'Yellow'
} else {
    Write-Note "taken into Export Keys: $Taken"
}
if ($Kept) { Write-Note "left as it was: $Kept" }
if ($Open) { Write-Note "failed: $Open - keys left with the permissions of their folder" 'Red' }

Write-Host ''
Write-Note 'the folder holds keys: it never goes outside in any form' 'Yellow'
Write-Note 'on another machine: import-keys.cmd lays Export Keys into place'
if ($Open) { exit 1 }
