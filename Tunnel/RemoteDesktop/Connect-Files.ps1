<#
.SYNOPSIS
    Открыть файлы удалённой машины по SFTP.

.DESCRIPTION
    То же, что Connect-Desktop.ps1, только вместо экрана — файлы. Скрипт сам
    выбирает, каким путём идти:

      прямой   — цель отвечает по своему домашнему адресу. Так бывает дома и
                 так же бывает в поездке, когда поднят путь домой
                 (setup-home-vpn.cmd): туннель делает дальнюю сеть ближней;
      SECOND VPS — цель напрямую не видна. Тогда поднимается временный проброс
                 через SECOND VPS, и файлы идут через него. Пока открыт
                 файловый клиент, держится проброс; закрыл — проброс снят.

    Прямой путь пробуется первым: он быстрее и не гоняет файлы через SECOND VPS.

    Клиент выбирается по тому, что стоит на машине: если есть WinSCP — открывается
    он, иначе идёт в дело штатный консольный sftp из самой Windows.

    Вход по ключу этой машины из профиля: его публичный ключ прописывает на
    целевых машинах setup-ssh-server.cmd. Если ключа нет, sftp спросит пароль
    учётной записи Windows на той машине.

.PARAMETER Target
    Чьи файлы открыть: base (стационар дома), laptop (лэптоп), home (машина HOME),
    router (накопители, воткнутые в сам роутер).

.PARAMETER Check
    Не открывать клиента, только проверить, каким путём цель достижима.

.EXAMPLE
    .\Connect-Files.ps1 base
    Открыть файлы домашнего стационара.

.EXAMPLE
    .\Connect-Files.ps1 base -Check
    Посмотреть, виден ли BASE и каким путём, ничего не открывая.
#>
[CmdletBinding()]
param(
    # Имена те же, что в targets.json. Роутеров там три - BASE, HOME и WORK, -
    # а `router` без уточнения не описан вовсе: старый враппер звал именно
    # его, и вход кончался «цель не описана». Имя оставлено как совместимое:
    # оно означает роутер BASE.
    # Список не зашит: цель ищется в targets.json ниже, и там же понятное
    # объяснение, если её нет. Зашитый перечень отвергал новые машины
    # раньше этой проверки - в окне кнопка есть, а из консоли отказ.
    [string]$Target = 'base',
    [switch]$Check,
    # Папка данных этой машины. Стоит последней: позиционные аргументы
    # старше - `Connect-Files.ps1 router` должен означать цель, а не путь.
    [string]$Root
)

# Куда девать запись об узнанном хосте. Писать «NUL» нельзя: в cmd это
# устройство-пустышка, а OpenSSH под Windows понимает строку как имя файла и
# заводит в текущей папке файл с зарезервированным именем. Такой файл потом не
# копируется и не удаляется обычными средствами - Total Commander на нём
# спотыкается с «Параметр задан неверно». Пишем во временную папку: туда же,
# куда и раньше, по смыслу - лишь бы не оседало в профиле пользователя.
$SshThrowaway = Join-Path $env:TEMP 'audion-ssh-known-hosts'

$ErrorActionPreference = 'Stop'

# --- SECOND VPS и пути -------------------------------------------------------
# `router` - привычное короткое имя роутера BASE. Разворачиваем его в
# настоящее, чтобы дальше по сценарию цель искалась в targets.json как есть.
if ($Target -eq 'router') { $Target = 'router-base' }

$Here       = $PSScriptRoot
$TunnelRoot = Split-Path $Here -Parent
# Ключи остались данными: программа переехала в Audion Sync Tools, склад
# ключей — нет. Путь считается от корня инструментов, буква диска не зашита.
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\DataRoot.ps1')
$DataRoot = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root
# SECOND VPS: адрес, ключ и учётная запись из targets.json.
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\Targets.ps1')
$SecondVps  = Get-AbkSecondVps -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot
$ServerHost = $SecondVps.Host
$SshTarget  = '{0}@{1}' -f $SecondVps.User, $ServerHost
$SecondKey  = Join-Path $DataRoot ('Tunnel\SSH\servers\' + $SecondVps.Key)
# Ключ этой машины: открытая половина лежит в складе clients, закрытая - в
# профиле. Общий ключ старой схемы больше не годится - он отозван, и попытка
# войти им кончается «Permission denied (publickey)».
$MachineKey = ''
foreach ($half in @(Get-ChildItem -LiteralPath (Join-Path $DataRoot 'Tunnel\SSH\clients') `
        -Filter '*.pub' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $candidate = Join-Path $HOME ('.ssh\{0}_ed25519' -f ($half.BaseName -replace '_ed25519$', ''))
    if (Test-Path -LiteralPath $candidate) { $MachineKey = $candidate; break }
}
$Targets     = Join-Path $DataRoot 'Tunnel\RemoteDesktop\config\targets.json'
$KnownHosts  = Join-Path $DataRoot 'config\rclone\known_hosts'

function Get-AbkHostKeyArg {
    <#
        Отпечатки узла для WinSCP - из своего списка ключей хостов.

        Прежде WinSCP получал `-hostkey=*`: он принимал любой ключ, какой бы
        узел ни ответил. В чужой сети с тем же частным адресом - а `192.168.1.x`
        встречается везде - на 22-й порт отвечает соседская машина, и файлы
        уехали бы к ней. SSH-туннель до MAIN VPS или SECOND VPS тут не спасает: он
        проверяет MAIN VPS или SECOND VPS, а не машину на том конце.

        Список ключей собирает окно кнопкой SSH-KEYSCAN. Нет записи для узла -
        значит доверять нечему, и подключение не открывается вовсе.
    #>
    param([Parameter(Mandatory)][string]$HostName)

    if (-not (Test-Path -LiteralPath $KnownHosts)) { return '' }

    $lines = @()
    foreach ($line in [System.IO.File]::ReadAllLines($KnownHosts)) {
        $text = ([string]$line).Trim()
        if (-not $text -or $text.StartsWith('#')) { continue }
        $parts = $text -split '\s+'
        if ($parts.Count -lt 3) { continue }
        # Первое поле - узлы через запятую, иногда в скобках с портом.
        $names = @($parts[0] -split ',' | ForEach-Object { ($_ -replace '^\[', '') -replace '\]:\d+$', '' })
        if ($names -contains $HostName) { $lines += ,@($parts[1], $text) }
    }
    if (-not $lines.Count) { return '' }

    $prints = @()
    foreach ($pair in $lines) {
        $tmp = Join-Path $env:TEMP ('audion-kh-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [System.IO.File]::WriteAllText($tmp, $pair[1] + "`n")
            $said = & ssh-keygen -lf $tmp 2>$null
            foreach ($row in @($said)) {
                $f = ([string]$row) -split '\s+'
                if ($f.Count -ge 2 -and $f[1] -like 'SHA256:*') {
                    $prints += ('{0} {1} {2}' -f $pair[0], $f[0], $f[1])
                }
            }
        } catch { } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    return ($prints -join ';')
}

if (-not (Test-Path $Targets)) { throw "Нет списка целей: $Targets" }

$all = Get-Content $Targets -Raw | ConvertFrom-Json
$t = $all.$Target
if (-not $t) { throw "Цель '$Target' не описана в targets.json" }

$sshPort  = if ($t.sshPort)  { [int]$t.sshPort }  else { 22 }
$localSsh = if ($t.localSsh) { [int]$t.localSsh } else { 13022 }
$user     = if ($t.user)     { $t.user }          else { $env:USERNAME }
# Адрес для прямого пути: lan, а если его нет - host.
$lan      = if ($t.lan)      { $t.lan }           else { $t.host }
# Роутеру ключ не нужен: у него своя учётная запись с паролем, и подсунутый
# ключ только съедает попытку входа.
$keyAuth  = -not ($t.PSObject.Properties.Name -contains 'keyAuth' -and -not $t.keyAuth)
# Что сказать, когда не вышло: у каждой цели своя причина.
$hint     = if ($t.hint) { $t.hint } else { '' }

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Test-Port {
    param([string]$Address, [int]$Port, [int]$TimeoutMs = 3000)
    # Test-NetConnection ждёт до 20 секунд на молчащем адресе, а нам нужно
    # быстро понять, что прямого пути нет, и уйти на запасной.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $wait = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $wait.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($wait)
        return $true
    } catch { return $false } finally { $client.Close() }
}

function Find-WinScp {
    foreach ($p in @("${env:ProgramFiles(x86)}\WinSCP\WinSCP.exe",
                     "$env:ProgramFiles\WinSCP\WinSCP.exe")) {
        if (Test-Path $p) { return $p }
    }
    $c = Get-Command 'WinSCP.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

Write-Host "`n=== Файлы: $($t.desc) ===`n" -ForegroundColor Cyan

# Машина без адреса отложена до настройки на месте — говорим честно, а не делаем вид.
if (-not $t.host -and -not $lan) {
    Write-Host "  $($Target.ToUpper()) ещё не настроена: адрес машины уточняется на месте." -ForegroundColor Yellow
    Write-Host "  Как узнаешь — впиши его в config\targets.json, поле host.`n" -ForegroundColor Yellow
    exit 2
}

# --- Выбор пути --------------------------------------------------------------
# Прямой путь пробуется первым: дома он работает всегда, а в поездке — когда
# поднят туннель до роутера. Через SECOND VPS идём, только если прямого нет.
$direct = $false
if ($lan) {
    Write-Line "пробую прямой путь ${lan}:$sshPort ..."
    $direct = Test-Port -Address $lan -Port $sshPort
}

$sshHost = $null
$sshHostPort = 0
$forward = $null
$routeName = ''

# Маршруты, заведённые в ~\.ssh\config: MAIN VPS напрямую, он же через
# cloudflared, и REVERSE SSH TUN, который машина держит сама. Порядок тот же, что в
# окне, и SECOND VPS в нём последний - через него не должно идти то, что через
# него идти не должно.
function Test-SshHostKnown {
    param([Parameter(Mandatory)][string]$Name)
    $config = Join-Path $env:USERPROFILE '.ssh\config'
    if (-not (Test-Path -LiteralPath $config)) { return $false }
    foreach ($line in [System.IO.File]::ReadAllLines($config)) {
        $text = $line.Trim()
        if ($text -notmatch '^(?i)host\s+(.+)$') { continue }
        foreach ($one in ($Matches[1] -split '\s+')) { if ($one -eq $Name) { return $true } }
    }
    return $false
}

if ($direct) {
    Write-Line "прямой путь есть — идём мимо SECOND VPS" Green
    $sshHost = $lan
    $sshHostPort = $sshPort
} else {
    # Маршруты через MAIN VPS пробуем по очереди, до SECOND VPS. Каждый ведёт на саму
    # машину, поэтому проброс поднимаем на её же порт: WinSCP не читает
    # ~\.ssh\config и о маршрутах не знает.
    foreach ($leg in @("$Target-direct", "$Target-cf", "$Target-ssh")) {
        if (-not (Test-SshHostKnown -Name $leg)) { continue }
        Write-Line "пробую маршрут $leg ..."
        $argString = @(
            '-o','BatchMode=yes',
            '-o','StrictHostKeyChecking=accept-new',
            '-o',("UserKnownHostsFile=" + $SshThrowaway),
            '-o','ExitOnForwardFailure=yes',
            '-o','ConnectTimeout=10',
            '-N','-L',("${localSsh}:127.0.0.1:$sshPort"),$leg
        ) -join ' '
        $try = Start-Process ssh -ArgumentList $argString -PassThru -WindowStyle Hidden
        $up = $false
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 500
            if ($try.HasExited) { break }
            if (Test-Port -Address 'localhost' -Port $localSsh -TimeoutMs 500) { $up = $true; break }
        }
        if ($up) {
            Write-Line "маршрут $leg работает" Green
            $forward = $try
            $routeName = $leg
            $sshHost = 'localhost'
            $sshHostPort = $localSsh
            break
        }
        if (-not $try.HasExited) { Stop-Process -Id $try.Id -Force -ErrorAction SilentlyContinue }
    }
}

if (-not $direct -and -not $forward) {
    Write-Line "маршрутов через MAIN VPS нет, пробую через SECOND VPS" Yellow
    if (-not $ServerHost) { throw 'адрес SECOND VPS не вписан: targets.json, запись second' }
    if (-not (Test-Path $SecondKey)) { throw "Нет ключа SECOND VPS: $SecondKey" }

    $sshCommon = @('-i', $SecondKey, '-p', [string]$SecondVps.Port, '-o','BatchMode=yes',
                   '-o','StrictHostKeyChecking=accept-new',
                   '-o',("UserKnownHostsFile=" + $SshThrowaway))
    $probe = & ssh @sshCommon $SshTarget "timeout 6 bash -c 'echo > /dev/tcp/$($t.host)/$sshPort' 2>/dev/null && echo open || echo shut" 2>$null
    $probe = ($probe | Out-String).Trim()

    if ($probe -ne 'open') {
        Write-Host "  Цель не отвечает на $sshPort ни напрямую, ни со стороны SECOND VPS." -ForegroundColor Red
        if ($hint) { Write-Host "  $hint" -ForegroundColor Yellow }
        Write-Host ""
        exit 1
    }
    Write-Line "цель отвечает со стороны SECOND VPS" Green
    $sshHost = 'localhost'
    $sshHostPort = $localSsh
}

if ($Check) {
    Write-Host ""
    $shown = if ($direct) { 'прямой' } elseif ($routeName) { $routeName } else { 'через SECOND VPS' }
    Write-Host ("  Путь: " + $shown) -ForegroundColor Cyan
    Write-Host "  (только проверка — клиента не открываю)`n" -ForegroundColor Gray
    # Проверка проброс уже подняла - за собой убираем сами, иначе он переживёт
    # сценарий и будет держать порт до перезагрузки.
    if ($forward -and -not $forward.HasExited) {
        Stop-Process -Id $forward.Id -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# --- Проброс, если идём через SECOND VPS ----------------------------------------
# Маршрут через MAIN VPS свой проброс уже поднял - второй раз тот же порт занимать
# нельзя, да и незачем.
if (-not $direct -and -not $forward) {
    $fwd = "${localSsh}:$($t.host):$sshPort"
    Write-Line "поднимаю проброс localhost:$localSsh -> $($t.host):$sshPort"

    # Start-Process сам не квотирует пробелы в пути ключа (у нас "Audion
    # Backup"), поэтому собираем строку аргументов и кавычим ключ вручную.
    $argString = @(
        '-i', ('"{0}"' -f $SecondKey), '-p', [string]$SecondVps.Port,
        '-o','BatchMode=yes',
        '-o','StrictHostKeyChecking=accept-new',
        '-o',("UserKnownHostsFile=" + $SshThrowaway),
        '-o','ExitOnForwardFailure=yes',
        '-N','-L',$fwd,$SshTarget
    ) -join ' '
    $forward = Start-Process ssh -ArgumentList $argString -PassThru -WindowStyle Hidden

    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if ($forward.HasExited) { break }
        if (Test-Port -Address 'localhost' -Port $localSsh -TimeoutMs 500) { $ready = $true; break }
    }
    if (-not $ready) {
        Write-Host "  Проброс не поднялся (SECOND VPS недоступен?).`n" -ForegroundColor Red
        if (-not $forward.HasExited) { Stop-Process -Id $forward.Id -Force }
        exit 1
    }
    Write-Line "проброс готов" Green
}

# --- Клиент ------------------------------------------------------------------
$keyArgs = @()
if ($keyAuth -and (Test-Path $MachineKey)) { $keyArgs = @('-i', $MachineKey) }
elseif ($keyAuth) { Write-Line "ключа доступа нет — sftp спросит пароль учётной записи Windows" Yellow }
else { Write-Line "вход по паролю учётной записи `"$user`"" }

$winscp = Find-WinScp
try {
    if ($winscp) {
        # Отпечаток обязателен. Без него WinSCP пойдёт к любому, кто ответит на
        # этот адрес, и «прямой маршрут» станет маршрутом к чужой машине.
        $hostKey = Get-AbkHostKeyArg -HostName $sshHost
        if (-not $hostKey) {
            Write-Line "ключ узла $sshHost неизвестен - подключение не открываю" Yellow
            Write-Line "соберите ключи хостов кнопкой SSH-KEYSCAN в окне и повторите" Gray
            Write-Host ''
            exit 1
        }

        Write-Line "открываю WinSCP" Green
        $session = "sftp://${user}@${sshHost}:$sshHostPort/"
        $wsArgs = @($session, ('-hostkey="{0}"' -f $hostKey))
        if ($keyAuth -and (Test-Path $MachineKey)) { $wsArgs += "-privatekey=`"$MachineKey`"" }
        Start-Process $winscp -ArgumentList $wsArgs -Wait
    } else {
        Write-Host ""
        Write-Host "  Файловый клиент: штатный sftp (WinSCP не установлен)." -ForegroundColor Cyan
        Write-Host "  Команды: ls, cd, get файл, put файл, lcd (локальная папка), bye" -ForegroundColor Gray
        Write-Host ""
        # Свой список ключей вместо одноразового файла: `accept-new` в пустой
        # файл означает «верю первому, кто ответил», и это ровно та же дыра,
        # что была у WinSCP. Со списком незнакомый узел получит отказ.
        $khArg = $(if (Test-Path -LiteralPath $KnownHosts) { $KnownHosts } else { $SshThrowaway })
        & sftp @keyArgs -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$khArg" `
            -P $sshHostPort "${user}@${sshHost}"
        # Порт может отвечать, а передача файлов не работать: у роутера, скажем,
        # 22 держит SSH-консоль, а подсистема файлов включается отдельно.
        if ($LASTEXITCODE -ne 0 -and $hint) {
            Write-Host ""
            Write-Host "  $hint" -ForegroundColor Yellow
        }
    }
} finally {
    if ($forward -and -not $forward.HasExited) {
        Stop-Process -Id $forward.Id -Force
        Write-Host "`n  проброс снят.`n" -ForegroundColor Gray
    } else {
        Write-Host ""
    }
}
