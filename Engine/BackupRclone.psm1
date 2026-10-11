<#
    rclone для Audion Sync Tools.

    Свой, а не соседский. Раньше зеркало брало и бинарник, и ключи к корзине у
    публикатора — «чтобы не держать вторую копию тех же ключей». Цена такой
    экономии: без публикатора рядом бэкап не работал вовсе, а он должен
    подниматься на пустой машине первым, до всего остального.

    Поэтому здесь ровно три функции и никакой логики публикации: найти свой
    бинарник, собрать пути к своему конфигу, позвать с ключами доступа.
#>

# Рабочие файлы живут в папке данных: резолвер оттуда.
. (Join-Path $PSScriptRoot 'DataRoot.ps1')

function Find-AbkRclone {
    <#
        Только своя копия. Транспорт, который тихо переключается на ту версию,
        что случайно оказалась на машине, меняет поведение без ведома автора;
        PATH остаётся лишь на крайний случай, и о нём говорится вслух.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot)

    $own = Join-Path $AppRoot 'Tools\rclone\rclone.exe'
    if (Test-Path -LiteralPath $own -PathType Leaf) {
        return (Resolve-Path -LiteralPath $own).Path
    }

    $found = Get-Command rclone -ErrorAction SilentlyContinue
    if ($found) {
        Write-Host '  rclone взят из PATH: своей копии в Tools\rclone нет' -ForegroundColor Yellow
        return $found.Source
    }

    return ''
}

function Get-AbkRcloneArgs {
    <#
        Свой конфиг и свой кеш, никогда не машинные.

        Конфиг один на все вызовы. Облака в нём не лежат: их ключи хранятся
        отдельно и зашифрованными, а самим вызовам они достаются переменными
        окружения - см. `Get-AbkCloudRemoteEnv` в `Engine\Clouds.ps1`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [switch]$EnsureDirectories,
        [string]$DataRoot
    )

    $configPath = if ($script:AbkConfigPath) { $script:AbkConfigPath }
                  else { Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\rclone.conf' }
    $cacheDir = Join-Path $AppRoot '._runtime\rclone-cache'
    if ($EnsureDirectories) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    return @('--config', $configPath, '--cache-dir', $cacheDir)
}

function Set-AbkRcloneConfigPath {
    <#
        Каким конфигом пользуются вызовы этого процесса.

        Ставит окно, и только для себя: rclone дописывает обновлённый
        OAuth-токен в тот файл, из которого взял remote. Пока активным был
        открытый конфиг, туда и ложились новые токены - вместе с новой
        секцией, которой там отродясь не было. Со своим зашифрованным
        конфигом облаков этого не происходит.

        Пустое значение возвращает всё к обычному конфигу.
    #>
    [CmdletBinding()]
    param([string]$Path)

    $script:AbkConfigPath = $(if ($Path -and (Test-Path -LiteralPath $Path)) { $Path } else { $null })
    return $script:AbkConfigPath
}

function Get-AbkCredentialsPath {
    <# Файл ключей S3 в папке данных. Передаётся не аргументом, а переменной окружения. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot, [string]$DataRoot)
    # Точка вместо подчёркивания: так этот файл зовут в экосистеме AWS, и
    # так же он называется в складе ключей и у публикатора.
    return (Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\r2.credentials' -DataRoot $DataRoot)
}

function Invoke-AbkRclone {
    <#
        Один вход для всех вызовов: ключи подставляются переменной окружения,
        а не строкой в команде, и корзина не прощупывается — токен выдан на
        объекты, и проверка самого бакета отдала бы отказ на ровном месте.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$EnsureDirectories,
        [string]$DataRoot
    )

    $exe = Find-AbkRclone -AppRoot $AppRoot
    if (-not $exe) { throw 'rclone не найден: ни своей копии в Tools\rclone, ни в PATH' }

    $env:AWS_SHARED_CREDENTIALS_FILE = Get-AbkCredentialsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $env:RCLONE_S3_NO_CHECK_BUCKET = 'true'

    $configArgs = Get-AbkRcloneArgs -AppRoot $AppRoot -DataRoot $DataRoot -EnsureDirectories:$EnsureDirectories
    & $exe @configArgs @Arguments
}

function Get-AbkRcloneEnvironment {
    <# Переменные, которые видит дочерний rclone: путь к ключам и запрет щупать бакет. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)

    return @{
        AWS_SHARED_CREDENTIALS_FILE = (Get-AbkCredentialsPath -AppRoot $AppRoot -DataRoot $DataRoot)
        RCLONE_S3_NO_CHECK_BUCKET = 'true'
    }
}

function Invoke-AbkRcloneCommand {
    <#
        Готовая команда массивом: первый элемент — сам rclone, остальное
        аргументы. Ключи подставляются в окружение на время вызова и
        возвращаются как были: сессия окна живёт долго, и оставлять в ней
        путь к ключам после единственного вызова незачем.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string[]]$Command,
        [switch]$PassThru,
        [string]$DataRoot
    )

    # Окно живёт под ErrorActionPreference=Stop, а в PowerShell 7.4+ ненулевой
    # выход нативной команды при этом бросает исключение. Для rclone ненулевой
    # код - обычное дело (недоступная машина), и это не авария: код возврата
    # отдаём наверх, как обещает контракт функции, а не роняем исключением в
    # общий перехватчик окна строкой [сбой]. Присваивание локальное - вызывающих
    # не меняет; все они и так смотрят ExitCode.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false

    $environment = Get-AbkRcloneEnvironment -AppRoot $AppRoot -DataRoot $DataRoot
    $restore = @{}
    foreach ($name in $environment.Keys) {
        $restore[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    try {
        $exe = $Command[0]
        $rest = @($Command | Select-Object -Skip 1)
        if ($PassThru) {
            $output = & $exe @rest 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
        }
        & $exe @rest
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @() }
    } finally {
        foreach ($name in $restore.Keys) {
            # $null goes to a .NET string parameter as '', and PowerShell 7 then
            # keeps an EMPTY variable instead of removing it. Every rclone the
            # window started afterwards - RESTORE, the external windows - died at
            # once on RCLONE_S3_NO_CHECK_BUCKET="" (the SFTP column of RESTORE
            # MIRROR, 26.09.2026). [NullString]::Value is a real null.
            if ($null -eq $restore[$name]) { [System.Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
            else { [System.Environment]::SetEnvironmentVariable($name, $restore[$name]) }
        }
    }
}

Export-ModuleMember -Function Find-AbkRclone, Get-AbkRcloneArgs, Get-AbkCredentialsPath,
    Get-AbkRcloneEnvironment, Invoke-AbkRclone, Invoke-AbkRcloneCommand,
    Set-AbkRcloneConfigPath
