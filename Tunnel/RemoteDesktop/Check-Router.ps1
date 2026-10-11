<#
.SYNOPSIS
    Проверка разговора с роутером: вход и чтение. Ничего не меняет.

.DESCRIPTION
    Показывает, что программа умеет разговаривать с роутером по его API:
    входит по имени и паролю учётной записи роутера, читает модель, версию
    прошивки и список пиров WG-сервера.

    Только чтение. Ни одной команды, которая что-то меняет, здесь нет — это
    первый шаг к автоматической выписке конфига, и его задача убедиться, что
    роутер отвечает и говорит на ожидаемом языке.

    Пароль спрашивается закрытым вводом и живёт только в памяти этого запуска:
    ни в файл, ни в журнал он не попадает.

.PARAMETER Address
    Адрес роутера. По умолчанию - из записи -Router в targets.json (lan или host).

.PARAMETER User
    Учётная запись роутера. По умолчанию admin.

.PARAMETER Schema
    Показать, какими командами описаны интерфейсы WireGuard в самом роутере.
    Нужно, чтобы выписывать пиров теми же словами, что и его веб-интерфейс.
    Ключи в выводе заменяются на «<ключ>»: разбираем синтаксис, а не секреты.

.EXAMPLE
    .\Check-Router.ps1
    Проверить домашний роутер.

.EXAMPLE
    .\Check-Router.ps1 -Address 192.168.2.1
    Проверить другой роутер — HOME или WORK.
#>
[CmdletBinding()]
param(
    [string]$Address = '',
    [string]$Router = 'router-base',
    [string]$User = 'admin',
    [switch]$Schema,
    [switch]$Remember,
    # Папка данных этой машины: окно передаёт её каждому врапперу, и пароль
    # роутера читается и сохраняется именно в ней.
    [string]$Root,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RouterNdm.psm1') -Force -DisableNameChecking

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

if (-not $Address) { $Address = Get-RouterAddress -Router $Router -Root $Root }

Write-Host "`n=== Роутер $Address : проверка разговора ===`n" -ForegroundColor Cyan

# Пароль спрашиваем только когда его негде взять: сохранённый лежит в папке
# данных, зашифрованный под эту учётную запись и эту машину.
$password = Get-RouterSecret -Router $Router -Root $Root
if ($password) {
    Write-Line 'пароль взят из сохранённого' DarkGray
} else {
    $password = Read-Host "  Пароль учётной записи $User на роутере" -AsSecureString
    Write-Host ""
}
if ($Remember) {
    $kept = Save-RouterSecret -Router $Router -Password $password -Root $Root
    Write-Line "пароль сохранён: $kept" DarkGray
}

$session = $null
try {
    $session = Connect-Router -Address $Address -User $User -Password $password
    Write-Line $session.Note Green

    $version = Invoke-Rci -Session $session -Path 'show/version'
    Write-Line ("модель:   {0}" -f $version.device) Green
    Write-Line ("прошивка: {0} ({1})" -f $version.title, $version.release)

    # WG-сервер: имя интерфейса у него своё, поэтому ищем по описанию.
    $interfaces = Invoke-Rci -Session $session -Path 'show/interface'
    $servers = @($interfaces.PSObject.Properties |
        Where-Object { $_.Value.type -eq 'Wireguard' } |
        ForEach-Object { $_.Value })

    if (-not $servers.Count) {
        Write-Line 'интерфейсов WireGuard не найдено' Yellow
    }

    foreach ($wg in $servers) {
        $label = if ($wg.PSObject.Properties['description']) { $wg.description } else { $wg.id }
        Write-Host ""
        Write-Line ("WireGuard: {0} ({1}), состояние {2}" -f $label, $wg.id, $wg.state) Green

        if ($wg.PSObject.Properties['wireguard'] -and $wg.wireguard.PSObject.Properties['peer']) {
            foreach ($peer in @($wg.wireguard.peer)) {
                # Имя пира прошивки кладут в разные поля, поэтому берём первое
                # непустое из вероятных, а если не нашлось - показываем, какие
                # поля вообще есть. Значения не печатаем: среди них ключи.
                $name = '(без имени)'
                foreach ($field in 'comment', 'description', 'name', 'label') {
                    if ($peer.PSObject.Properties[$field] -and $peer.$field) {
                        $name = $peer.$field
                        break
                    }
                }

                # Прошивка отвечает предельным int вместо нуля, когда пир ещё
                # ни разу не отозвался: 2147483647 секунд - это 68 лет.
                $seen = 'рукопожатий не было'
                if ($peer.PSObject.Properties['last-handshake']) {
                    $age = [int64]$peer.'last-handshake'
                    if ($age -gt 0 -and $age -lt 2147483647) { $seen = "{0} c назад" -f $age }
                }

                Write-Line ("  пир {0,-14} {1}" -f $name, $seen)

                if ($name -eq '(без имени)') {
                    Write-Line ("       поля пира: " + (($peer.PSObject.Properties.Name) -join ', ')) DarkGray
                }
            }
        }
    }

    if ($Schema) {
        Write-Host ""
        Write-Line 'Что роутер рассказывает о туннелях (значения ключей скрыты):' Cyan

        foreach ($wg in $servers) {
            Write-Host ""
            Write-Line ("  {0} ({1})" -f $wg.description, $wg.id) DarkGray
            foreach ($field in $wg.PSObject.Properties) {
                if ($field.Name -eq 'wireguard') { continue }
                if ($field.Value -is [string] -or $field.Value -is [int] -or $field.Value -is [bool]) {
                    Write-Host ("      {0} = {1}" -f $field.Name, $field.Value) -ForegroundColor DarkGray
                }
            }

            if ($wg.PSObject.Properties['wireguard']) {
                Write-Line '    раздел wireguard:' DarkGray
                foreach ($field in $wg.wireguard.PSObject.Properties) {
                    if ($field.Name -eq 'peer') { continue }
                    $value = if ($field.Value -match '^[A-Za-z0-9+/]{40,}={0,2}$') { '<ключ>' } else { $field.Value }
                    Write-Host ("      {0} = {1}" -f $field.Name, $value) -ForegroundColor DarkGray
                }

                if ($wg.wireguard.PSObject.Properties['peer']) {
                    $first = @($wg.wireguard.peer)[0]
                    if ($first) {
                        Write-Line '    поля пира:' DarkGray
                        foreach ($field in $first.PSObject.Properties) {
                            $value = if ("$($field.Value)" -match '^[A-Za-z0-9+/]{40,}={0,2}$') { '<ключ>' } else { $field.Value }
                            Write-Host ("      {0} = {1}" -f $field.Name, $value) -ForegroundColor DarkGray
                        }
                    }
                }
            }
        }

        Write-Host ""
        Write-Line 'Как роутер описывает свои туннели:' Cyan

        $config = Invoke-Rci -Session $session -Path 'show/running-config'
        $text = if ($config -is [string]) { $config } elseif ($config.PSObject.Properties['message']) { $config.message } else { $config | Out-String }

        $inside = $false
        foreach ($line in ($text -split "`r?`n")) {
            # Держим только блоки интерфейсов WireGuard: остальная конфигурация
            # роутера к делу не относится и незачем её вычитывать.
            if ($line -match '^\s*interface\s+Wireguard') { $inside = $true }
            elseif ($line -match '^\S' -and $line -notmatch '^\s*!') { $inside = $false }
            if (-not $inside) { continue }

            # Ключи и пароли заменяем на метку: разбираем синтаксис, а не
            # секреты. Под базой 64 длиной от 40 символов ходят все ключи
            # WireGuard - и публичные, и приватные, и общий.
            $safe = $line -replace '[A-Za-z0-9+/]{40,}={0,2}', '<ключ>'
            Write-Host "    $safe" -ForegroundColor DarkGray
        }
    }

    Write-Host "`n  Роутер отвечает и понят. Менять ничего не пробовали.`n" -ForegroundColor Cyan
    exit 0
} catch {
    Write-Host "`n  Сорвалось: $($_.Exception.Message)`n" -ForegroundColor Red
    exit 1
} finally {
    if ($session) { Disconnect-Router -Session $session }
}
