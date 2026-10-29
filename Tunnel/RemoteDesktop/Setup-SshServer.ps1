<#
.SYNOPSIS
    SSHD: включить на этой машине sshd и доступ по SFTP/SSH.

.DESCRIPTION
    Рабочий стол показывает экран, а забрать или положить файл им неудобно.
    Этот скрипт включает на машине штатный sshd (OpenSSH Server), который есть в самой
    Windows — ставить ничего стороннего не нужно. После него к машине ходят
    файловым клиентом: files-base.cmd, files-laptop.cmd и так далее.

    Порт 22 открывается НЕ всему свету, а только своим сетям: домашним подсетям
    и туннелям. Из интернета машина по-прежнему не видна — снаружи к ней ведёт
    либо туннель до дома, либо проброс через SECOND VPS.

    Вход по ключу. У каждой машины своя пара: приватный ключ с неё не
    уезжает, а публичный лежит в CLIENTS - Tunnel\SSH\clients папки данных; здесь
    прописываются все публичные ключи из CLIENTS разом. Строка машины из CLIENTS
    с другим ключом заменяется ключом из CLIENTS. Строки машин, которых в CLIENTS
    нет, остаются: их приносит SSH-COPY-ID с соседних машин. Вход по паролю
    Windows тоже остаётся: ключ удобнее, пароль — на случай, когда CLIENTS под
    рукой нет.

.PARAMETER Check
    Ничего не менять, только показать: стоит ли sshd, запущен ли, открыт ли
    порт, прописан ли ключ. Права администратора не нужны.

.PARAMETER Remove
    Выключить sshd: остановить службу, убрать правило файрвола. Сам компонент
    Windows остаётся — снять его можно только руками, и это не мешает.

.PARAMETER Anywhere
    Открыть порт 22 без ограничения по сетям. По умолчанию порт виден только
    своим подсетям; ключ нужен, если машина стоит в сети, которой здесь нет.

.EXAMPLE
    .\Setup-SshServer.ps1
    Включить sshd на этой машине.

.EXAMPLE
    .\Setup-SshServer.ps1 -Check
    Посмотреть состояние, ничего не трогая.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Remove,
    [switch]$Anywhere,
    # Служебный признак: скрипт запустил сам себя с правами администратора.
    # Повышенное окно — отдельное, и без задержки оно закрывается раньше, чем
    # видно, чем всё кончилось. Руками не передавать.
    [switch]$Elevated,
    # Папка данных этой машины. Окно передаёт её каждому врапперу; без этого
    # параметра сценарий падал на привязке ещё до первой строки.
    [string]$Root,
    # RESTORE MIRROR: хост-ключи - из DATA, даже если живые другие; в файле
    # ключей администраторов - ровно CLIENTS. Прежнее уходит в MirrorBackup.
    [switch]$Mirror,
    [string]$MirrorBackup,
    # Журнал повышенного окна: RESTORE показывает его в своей консоли.
    [string]$LogPath,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# --- Пути от расположения скрипта, без жёсткого диска ------------------------
# Папка сценария - $Here: имя $Root занято параметром, папкой данных от окна.
# Прежде здесь стояло $Root = $PSScriptRoot, и оно затирало параметр: SSHD
# искал CLIENTS внутри папки сценария и не находил ни одного ключа.
$Here       = $PSScriptRoot
$TunnelRoot = Split-Path $Here -Parent                       # ...\Tunnel
# Ключи остались данными: программа переехала в Audion Sync Tools, склад
# ключей — нет. Путь считается от корня инструментов, буква диска не зашита.
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\DataRoot.ps1')
$DataRoot   = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root
# Половины машин: у каждой своя, и все они лежат в складе clients. Общий
# ключ старой схемы сюда больше не подставляется: он отозван, и прописанная
# им строка была бы мёртвой - вход по ней всё равно не проходит.
$ClientStore = Join-Path $DataRoot 'Tunnel\SSH\clients'

function Get-AccessKeys {
    <# Все половины, которые эта машина должна принимать. #>
    $found = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ClientStore -Filter '*.pub' -ErrorAction SilentlyContinue)) {
        $line = (Get-Content -LiteralPath $file.FullName -Raw).Trim()
        if ($line) { $found += [pscustomobject]@{ Name = $file.BaseName; Line = $line } }
    }
    return $found
}

function Merge-AccessKeys {
    <#
        Каким стать файлу ключей этой машины.

        Прежде ключи только дописывались, и файл отставал: ключ машины,
        заменённый в складе, оставался прописанным, а новый рядом с ним не
        пускал, пока кнопку не нажимали снова. Теперь склад решает за свои
        машины: строка с подписью машины из склада, но с другим ключом,
        снимается, и на её место встаёт половина из склада.

        Строки машин, которых в складе нет, остаются: склад у каждой машины
        свой, и публичные ключи соседей приходят сюда через SSH-COPY-ID, мимо склада. Удалить их
        здесь - значит молча закрыть вход соседу.

        Ключ узнаётся по телу, машина - по подписи. Одна половина под двумя
        именами файла даёт одну строку, повторы в файле схлопываются. Пустой
        склад файл не меняет.

        Возвращает @{ Lines; Changed; Added; Kept; Removed; Foreign }: строки
        файла и подписи того, что дописано, осталось, снято и оставлено чужим.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Existing = @(),
        [AllowEmptyCollection()][object[]]$Keys = @(),
        # RESTORE MIRROR: файл становится ровно складом - строки машин не из
        # CLIENTS и прочие строки снимаются. Пустой склад файл по-прежнему не
        # меняет: иначе зеркало закрыло бы вход всем.
        [switch]$Exact
    )

    # Строка ключа: необязательные ограничения, тип, тело, подпись. Тип ищем,
    # а не берём первым словом: перед ним могут стоять ограничения.
    $split = {
        param([string]$Text)
        $parts = @($Text.Trim() -split '\s+')
        if (-not $parts.Count -or $parts[0].StartsWith('#')) { return $null }
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if ($parts[$i] -match '^(ssh-|ecdsa-|sk-)') {
                return [pscustomobject]@{
                    Body  = $parts[$i + 1]
                    Label = $(if ($parts.Count -gt $i + 2) { $parts[($i + 2)..($parts.Count - 1)] -join ' ' } else { '' })
                }
            }
        }
        return $null
    }

    $before = @($Existing | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

    $wanted = [ordered]@{}
    $machines = @{}
    foreach ($key in $Keys) {
        $line = "$($key.Line)".Trim()
        $half = & $split $line
        if (-not $half -or $wanted.Contains($half.Body)) { continue }
        $wanted[$half.Body] = [pscustomobject]@{
            Line = $line
            Name = $(if ($half.Label) { $half.Label } else { "$($key.Name)" })
        }
        if ($half.Label) { $machines[$half.Label] = $true }
    }

    if (-not $wanted.Count) {
        return @{ Lines = $before; Changed = $false; Added = @(); Kept = @(); Removed = @(); Foreign = @() }
    }

    $lines = @()
    $seen = @{}
    $kept = @()
    $removed = @()
    $foreign = @()
    foreach ($text in $before) {
        $half = & $split $text
        if (-not $half) { if (-not $Exact) { $lines += $text }; continue }
        if ($seen.ContainsKey($half.Body)) { continue }
        if ($wanted.Contains($half.Body)) {
            $seen[$half.Body] = $true
            $lines += $text
            $kept += $wanted[$half.Body].Name
            continue
        }
        if ($Exact -or ($half.Label -and $machines.ContainsKey($half.Label))) {
            $removed += $(if ($half.Label) { $half.Label } else { '(без подписи)' })
            continue
        }
        $seen[$half.Body] = $true
        $lines += $text
        $foreign += $(if ($half.Label) { $half.Label } else { '(без подписи)' })
    }

    $added = @()
    foreach ($body in @($wanted.Keys)) {
        if ($seen.ContainsKey($body)) { continue }
        $lines += $wanted[$body].Line
        $added += $wanted[$body].Name
    }

    @{
        Lines   = $lines
        Changed = (($lines -join "`n") -ne ($before -join "`n"))
        Added   = $added
        Kept    = $kept
        Removed = $removed
        Foreign = $foreign
    }
}

function Test-SshdAnswers {
    <#
        Отвечает ли sshd этой машины: стук в порт 22 у себя и приветствие SSH в
        ответ. Таблица соединений Windows для этого не годится: в 26H2 (сборка
        26300) она отдаёт состояния вразнобой, и живой порт 22 то есть среди
        слушающих, то нет - SSHD и RESTORE кончались «порт 22 не слушается» при
        работающем sshd. Несколько попыток: после перезапуска служба поднимается
        не сразу. Двойник - в Install-OpenSSH.ps1: тот сценарий самостоятельный.
    #>
    param([int]$Tries = 5)
    for ($try = 1; $try -le $Tries; $try++) {
        foreach ($address in @([System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback)) {
            $client = New-Object System.Net.Sockets.TcpClient ($address.AddressFamily)
            try {
                if ($client.ConnectAsync($address, 22).Wait(2000)) {
                    $stream = $client.GetStream()
                    $stream.ReadTimeout = 3000
                    $buffer = New-Object byte[] 64
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).StartsWith('SSH-')) { return $true }
                }
            } catch {
            } finally {
                $client.Close()
            }
        }
        if ($try -lt $Tries) { Start-Sleep 1 }
    }
    return $false
}

# Свои сети: домашние подсети за домашний роутер, плечи SECOND VPS и сеть WG-сервера
# роутера. Из них к машине ходят; всё остальное порт не увидит.
$TrustedNets = @(
    '192.168.10.0/24',  # сеть BASE, основная
    '192.168.2.0/24',   # сеть BASE, вторая
    '192.168.5.0/24',   # сеть HOME (деревня)
    '10.11.0.0/24',     # плечо SECOND VPS <-> BASE
    '10.10.0.0/24',     # плечо SECOND VPS <-> HOME
    '10.12.0.0/24',     # WG SECOND VPS <-> роутер на работе
    '192.168.15.0/24',  # сеть роутера на работе
    '172.16.6.0/24'     # клиенты WG-сервера роутера BASE
)

$RuleName = 'Audion Remote Files (SSH 22)'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Get-SshCapability {
    # Имя компонента у разных сборок Windows отличается версией в хвосте,
    # поэтому ищем по началу имени, а не по точному совпадению.
    Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

function Install-OpenSshFromGithub {
    # Запасной путь, когда Windows Update не отдаёт компонент. Тянет официальный
    # пакет (Microsoft, PowerShell/Win32-OpenSSH) во временную папку, проверяет
    # подпись Microsoft и ставит из неё. В программе пакет не хранится - всегда
    # берётся свежий, поддерживать нечего. Возвращает $true при успехе.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Line "ищу свежий пакет OpenSSH на GitHub..." Yellow
    try {
        $rels = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases' -Headers @{ 'User-Agent' = 'audion-sync-tools' } -UseBasicParsing
    } catch {
        throw "GitHub недоступен: $($_.Exception.Message)"
    }
    $asset = $null
    foreach ($r in $rels) {
        $asset = $r.assets | Where-Object { $_.name -match '^OpenSSH-Win64.*\.msi$' } | Select-Object -First 1
        if ($asset) { break }
    }
    if (-not $asset) { throw "в релизах не нашёл пакет OpenSSH-Win64 .msi" }
    $tmp = Join-Path $env:TEMP ("audion-openssh-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $msi = Join-Path $tmp $asset.name
    try {
        Write-Line ("качаю " + $asset.name + " (" + [math]::Round($asset.size / 1MB, 1) + " МБ)...") Yellow
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msi -UseBasicParsing
        $sig = Get-AuthenticodeSignature -LiteralPath $msi
        if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'Microsoft') {
            throw "подпись не подтверждена (Status=$($sig.Status)) - установка отменена"
        }
        Write-Line "подпись Microsoft подтверждена" Green
        Write-Line "ставлю пакет..." Yellow
        $pr = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), '/quiet', '/norestart') -Wait -PassThru
        if ($pr.ExitCode -ne 0) { throw "msiexec вернул код $($pr.ExitCode)" }
        return $true
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Самоподнятие прав -------------------------------------------------------
if (-not $Check -and -not (Test-Admin)) {
    Write-Host "Нужны права администратора — поднимаю (UAC)..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Elevated')
    if ($Remove)   { $argList += '-Remove' }
    if ($Anywhere) { $argList += '-Anywhere' }
    if ($Root) { $argList += @('-Root', ('"' + ($Root -replace '(\\+)$', '$1$1') + '"')) }
    if ($Mirror) { $argList += '-Mirror' }
    if ($MirrorBackup) { $argList += @('-MirrorBackup', ('"' + ($MirrorBackup -replace '(\\+)$', '$1$1') + '"')) }
    if ($LogPath) { $argList += @('-LogPath', ('"' + $LogPath + '"')) }
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    if ($NoPause) { $argList += '-NoPause' }
    $elevatedProcess = Start-Process $psExe -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $elevatedProcess.ExitCode
}

if ($LogPath -and -not $Check) {
    try { Start-Transcript -LiteralPath $LogPath -Force | Out-Null } catch { }
}

function Complete-Run {
    # Повышенное окно закрывается само; придержим его, чтобы итог успели прочесть.
    param([int]$Code = 0)
    if ($LogPath) { try { Stop-Transcript | Out-Null } catch { } }
    if ($Elevated -and -not $NoPause) {
        Write-Host "  Нажми Enter, чтобы закрыть окно." -ForegroundColor DarkGray
        [void](Read-Host)
    }
    exit $Code
}

trap {
    Write-Host "`n  Сорвалось: $($_.Exception.Message)`n" -ForegroundColor Red
    Complete-Run 1
}

Write-Host "`n=== SSHD на $env:COMPUTERNAME ===`n" -ForegroundColor Cyan

# --- Режим осмотра -----------------------------------------------------------
if ($Check) {
    $cap = if (Test-Admin) { Get-SshCapability } else { $null }
    if ($cap) {
        Write-Line ("Компонент OpenSSH Server: " + $cap.State) `
            $(if ($cap.State -eq 'Installed') { 'Green' } else { 'Yellow' })
    } else {
        Write-Line "Компонент OpenSSH Server: видно только с правами администратора"
    }

    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Line ("Служба sshd: $($svc.Status), запуск $($svc.StartType)") `
            $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })
    } else { Write-Line "Служба sshd: нет" 'Yellow' }

    $rule = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    Write-Line ("Правило файрвола: " + $(if ($rule) { "есть, включено: $($rule.Enabled)" } else { 'нет' })) `
        $(if ($rule) { 'Green' } else { 'Yellow' })

    $adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    $keys = @(Get-AccessKeys)
    if (-not $keys.Count) {
        Write-Line "Ключи доступа: CLIENTS пуст" 'Yellow'
    } elseif (-not (Test-Path $adminKeys)) {
        Write-Line "Ключи доступа: не прописаны" 'Yellow'
    } else {
        # Файл закрыт для всех, кроме системы и администраторов - иначе sshd
        # его не читает. Осмотр идёт без прав, и читать файл ему незачем:
        # важно не то, что в нём написано, а пускает ли ключ. Это проверяется
        # входом на самого себя - без всяких прав.
        #
        # Прежний осмотр читал файл и, получив отказ, говорил «прописано 0 из
        # 1» при живом ключе, который прекрасно пускал.
        $mine = @($keys | Where-Object {
            Test-Path -LiteralPath (Join-Path $HOME ('.ssh\{0}_ed25519' -f ($_.Name -replace '_ed25519$', '')))
        })

        if (-not $mine.Count) {
            Write-Line ("Ключи доступа: в CLIENTS {0} ({1}); приватных ключей здесь нет, проверить входом нечем" -f
                $keys.Count, (($keys | ForEach-Object { $_.Name }) -join ', ')) 'Gray'
        } else {
            foreach ($key in $mine) {
                $file = Join-Path $HOME ('.ssh\{0}_ed25519' -f ($key.Name -replace '_ed25519$', ''))
                $was = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $answer = & ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new `
                        -o IdentitiesOnly=yes -i $file ('{0}@127.0.0.1' -f $env:USERNAME) 'echo ok' 2>$null
                } finally {
                    $ErrorActionPreference = $was
                }
                $ok = ("$answer".Trim() -eq 'ok')
                Write-Line ("Ключ {0}: {1}" -f $key.Name,
                    $(if ($ok) { 'пускает (проверено входом)' } else { 'не пускает' })) `
                    $(if ($ok) { 'Green' } else { 'Yellow' })
            }
        }
    }

    $listen = Test-SshdAnswers
    Write-Line ("Порт 22: " + $(if ($listen) { 'слушается' } else { 'не слушается' })) `
        $(if ($listen) { 'Green' } else { 'Yellow' })
    Write-Host ""
    exit 0
}

# --- Снятие ------------------------------------------------------------------
if ($Remove) {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service sshd -Force -ErrorAction SilentlyContinue
        Set-Service sshd -StartupType Disabled
        Write-Line "служба sshd остановлена и выключена" Green
    } else { Write-Line "службы не было" }

    if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -DisplayName $RuleName
        Write-Line "правило файрвола убрано" Green
    }
    Write-Host "`n  Приём выключен. Компонент Windows остался — включить снова одним запуском.`n" -ForegroundColor Cyan
    Complete-Run 0
}

# Restore before the installer as well: an MSI may start sshd itself.
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\SshHostIdentity.ps1')
if ($Mirror -and -not $MirrorBackup) {
    . (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\RestoreMirror.ps1')
    $MirrorBackup = New-AbkMirrorBackup -DataRoot $DataRoot
}
$identity = Restore-AbkSshHostIdentity -DataRoot $DataRoot -Replace:$Mirror -Backup $MirrorBackup
Write-Line ("SSHD identity: " + $identity) Green
if ($identity -eq 'replaced') { Write-Line ("прежние хост-ключи убраны в " + (Join-Path $MirrorBackup 'ProgramData-ssh')) Yellow }

# --- 1. OpenSSH: качаем и ставим (Windows Update - только фолбэк) -------------
if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Write-Line "sshd уже установлен" Green
} else {
    $ok = $false

    # Первым делом: тянем официальный пакет и ставим. Не ждём Windows Update.
    try {
        if (Install-OpenSshFromGithub) { $ok = $true }
    } catch {
        Write-Line ("пакет с GitHub не вышел: " + $_.Exception.Message) Yellow
    }

    # Фолбэк: Windows Update, и то не дольше 10 секунд - чтобы никогда не висло.
    if (-not $ok) {
        $cap = Get-SshCapability
        if ($cap -and $cap.State -eq 'Installed') {
            $ok = $true
        } elseif ($cap) {
            Write-Line "пробую компонент из Windows Update (до 10 c)..." Yellow
            $capName = $cap.Name
            $job = Start-Job { Add-WindowsCapability -Online -Name $using:capName }
            $t0 = Get-Date
            while ($job.State -eq 'Running' -and ((Get-Date) - $t0).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 500 }
            if ($job.State -eq 'Running') {
                Stop-Job $job -ErrorAction SilentlyContinue
                Write-Line "Windows Update не ответил за 10 c - пропускаю." Yellow
            } else {
                try { Receive-Job $job -ErrorAction Stop | Out-Null } catch { Write-Line ("Windows Update: " + $_.Exception.Message) Yellow }
                if ((Get-SshCapability).State -eq 'Installed') { $ok = $true }
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep 1
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        Write-Line "sshd установлен" Green
    } else {
        throw "sshd поставить не удалось: ни пакетом с GitHub, ни из Windows Update"
    }
}

# --- 2. Служба: автозапуск ---------------------------------------------------
Set-Service sshd -StartupType Automatic
# Папку C:\ProgramData\ssh могли снести целиком, чтобы начать с чистого листа.
# На старте sshd заводит её сам: sshd_config из sshd_config_default и хост-ключи.
# Но запущенная служба, у которой файлы вынули из-под ног, живёт в памяти и
# новых соединений не принимает - её надо именно перезапустить, а не «запустить,
# если не запущена». Хост-ключи при этом рождаются новые: на других машинах
# known_hosts для этой машины устареет, если копия ещё не была сохранена.
$sshDir  = Join-Path $env:ProgramData 'ssh'
$sshConf = Join-Path $sshDir 'sshd_config'
$reborn  = $false
if (-not (Test-Path -LiteralPath $sshConf)) {
    Write-Line "sshd_config нет - перезапускаю службу: она заведёт папку, конфиг и хост-ключи заново" Yellow
    Restart-Service sshd -Force
    $reborn = $true
} elseif ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
elseif ($identity -in @('restored', 'replaced')) { Restart-Service sshd -Force }
Write-Line "служба sshd: $((Get-Service sshd).Status), автозапуск" Green
$savedIdentity = Save-AbkSshHostIdentity -DataRoot $DataRoot
Write-Line ("SSHD identity: " + $savedIdentity + ' -> DATA\Tunnel\SSHD') Green
if ($reborn -and $identity -eq 'not-saved') {
    Write-Line "Это новая идентичность SSHD: доверие к машине нужно подтвердить на клиентах один раз." Yellow
}

# --- 3. Файрвол: только свои сети --------------------------------------------
# Windows заводит своё правило на 22 при установке компонента; оно открывает
# порт шире, чем нужно, поэтому гасим его и ставим своё.
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue |
    Disable-NetFirewallRule -ErrorAction SilentlyContinue

if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $RuleName
}
$scope = if ($Anywhere) { 'Any' } else { $TrustedNets }
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP `
    -LocalPort 22 -Action Allow -Profile Any -RemoteAddress $scope | Out-Null
Write-Line ("порт 22 открыт " + $(if ($Anywhere) { 'без ограничения по сетям' }
                                 else { "для своих сетей ($($TrustedNets.Count) шт.)" })) Green

# --- 4. Ключ доступа ---------------------------------------------------------
# Принимаем половины всех машин: у каждой своя пара, закрытая половина с неё
# не уезжает. Ключи здесь не заводятся - это делает окно на той машине,
# которой ключ принадлежит (раздел SSH KEYS, кнопка SSH-KEYGEN).
$keys = @(Get-AccessKeys)
if (-not $keys.Count) {
    Write-Line "в CLIENTS нет ни одного публичного ключа: заведите ключ машины в окне" Yellow
    Write-Line "  раздел SSH KEYS, кнопка SSH-KEYGEN - она же положит публичный ключ в CLIENTS" Gray
}

# Учётка администратора в Windows читает ключи не из профиля, а из общего файла
# с жёсткими правами — иначе sshd их молча игнорирует.
$adminKeys = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
# Папка должна быть: без неё запись упадёт. Обычно её уже завела служба выше.
if (-not (Test-Path -LiteralPath $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
# Файл читается и пишется как UTF-8 без BOM: sshd не узнаёт первую строку с
# BOM, а чтение по умолчанию в Windows PowerShell портило бы чужие подписи.
$existing = @(if (Test-Path $adminKeys) { [System.IO.File]::ReadAllLines($adminKeys) })
$merge = Merge-AccessKeys -Existing $existing -Keys $keys -Exact:$Mirror
foreach ($name in $merge.Kept)    { Write-Line ("ключ уже прописан: " + $name) Green }
foreach ($name in $merge.Added)   { Write-Line ("ключ прописан: " + $name) Green }
foreach ($name in $merge.Removed) { Write-Line ("снят ключ: " + $name) Yellow }
foreach ($name in $merge.Foreign) { Write-Line ("оставлен ключ машины не из CLIENTS: " + $name) Gray }

if ($merge.Changed -and $Mirror -and (Test-Path -LiteralPath $adminKeys)) {
    $keptDir = Join-Path $MirrorBackup 'ProgramData-ssh'
    New-Item -ItemType Directory -Path $keptDir -Force | Out-Null
    Copy-Item -LiteralPath $adminKeys -Destination (Join-Path $keptDir 'administrators_authorized_keys') -Force
    Write-Line ("прежний файл ключей сохранён в " + $keptDir) Gray
}
if ($merge.Changed) {
    [System.IO.File]::WriteAllLines($adminKeys, [string[]]$merge.Lines, (New-Object System.Text.UTF8Encoding $false))
} elseif (-not (Test-Path $adminKeys)) {
    Set-Content -Path $adminKeys -Value '' -Encoding ascii
}
# Права: только система и администраторы, иначе sshd откажется читать файл.
# Обращаемся по SID, а не по имени: в русской Windows группа зовётся
# «Администраторы», и icacls с английским именем отваливается с жалобой на
# несопоставленное имя — молча, посреди успешного вывода, оставляя файл с
# унаследованными правами и чтением для всех прошедших проверку.
$aclFailed = $false
$icaclsOut = & icacls $adminKeys /inheritance:r `
    /grant '*S-1-5-18:(F)' `
    /grant '*S-1-5-32-544:(F)' 2>&1
if ($LASTEXITCODE -ne 0) {
    $aclFailed = $true
    Write-Line "не удалось закрыть права на файле ключей:" Yellow
    $icaclsOut | ForEach-Object { Write-Line "  $_" Yellow }
} else {
    Write-Line "права на файле ключей закрыты" Green
}

# --- 5. Проверка -------------------------------------------------------------
Start-Sleep 2
$listen = Test-SshdAnswers
Write-Host ""
# Готовность заявляем только доказанную: без закрытых прав sshd молча не читает
# файл ключей, без слушателя не принимает никого. Иначе код выхода ненулевой -
# окно и врапперы не считают шаг сделанным (ревью 15.09.2026, P2).
$ready = [bool]$listen -and -not $aclFailed
if ($ready) {
    Write-Host "  ГОТОВО: машина принимает файлы по SFTP." -ForegroundColor Green
    Write-Host "  С другой своей машины: files-base.cmd / files-laptop.cmd / files-home.cmd" -ForegroundColor Cyan
    Write-Host ""
} else {
    if ($aclFailed) {
        Write-Host "  НЕ ГОТОВО: права на файле ключей не закрыты - вход по ключу работать не будет." -ForegroundColor Red
    }
    if (-not $listen) {
        Write-Host "  НЕ ГОТОВО: служба запущена, но порт 22 не слушается." -ForegroundColor Red
        Write-Host "  Посмотреть, что случилось: Get-WinEvent -LogName 'OpenSSH/Operational' -Max 10" -ForegroundColor Yellow
    }
    Write-Host ""
}
Complete-Run $(if ($ready) { 0 } else { 1 })
