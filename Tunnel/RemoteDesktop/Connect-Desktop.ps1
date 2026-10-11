<#
.SYNOPSIS
    Открыть удалённый рабочий стол машины через SECOND VPS.

.DESCRIPTION
    Поднимает временный проброс через SECOND VPS до нужной машины и открывает
    рабочий стол. Работает «отовсюду»: с любой доверенной машины, где лежит
    ключ SECOND VPS, — из дома, из кафе, из другой сети. Пока открыт рабочий стол,
    держится и проброс; закрыл окно — проброс закрывается сам.

    SECOND VPS здесь только труба: RDP-трафик идёт через него в туннель к нужной
    сети (BASE, HOME, лэптоп) и обратно. Сам SECOND VPS рабочий стол не видит и
    подключения не запоминает.

    Цели заданы в config\targets.json. Путь и ключ SECOND VPS вычисляются от
    расположения скрипта, диск не зашит.

.PARAMETER Target
    Какую машину открыть: base (стационар дома), laptop (лэптоп),
    home (машина HOME). По умолчанию base.

.PARAMETER Check
    Не открывать рабочий стол, только проверить: виден ли с SECOND VPS нужный порт
    RDP у цели.

.EXAMPLE
    .\Connect-Desktop.ps1 base
    Открыть рабочий стол домашнего стационара.

.EXAMPLE
    .\Connect-Desktop.ps1 base -Check
    Проверить, доступен ли BASE, не открывая окно.
#>
[CmdletBinding()]
param(
    # Список не зашит: цель ищется в targets.json ниже, и там же понятное
    # объяснение, если её нет. В зашитом перечне не было даже WORK, у
    # которой рабочий стол описан.
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
$SshKey     = Join-Path $DataRoot ('Tunnel\SSH\servers\' + $SecondVps.Key)
$Targets    = Join-Path $DataRoot 'Tunnel\RemoteDesktop\config\targets.json'

if (-not (Test-Path $SshKey))  { throw "Нет ключа SECOND VPS: $SshKey" }
if (-not (Test-Path $Targets)) { throw "Нет списка целей: $Targets" }

$all = Get-Content $Targets -Raw | ConvertFrom-Json
$t = $all.$Target
if (-not $t) { throw "Цель '$Target' не описана в targets.json" }

# Адрес для прямого пути: lan, а если его нет - host.
$lan = if ($t.lan) { $t.lan } else { $t.host }

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

$sshCommon = @('-i', $SshKey, '-p', [string]$SecondVps.Port, '-o','BatchMode=yes',
               '-o','StrictHostKeyChecking=accept-new',
               '-o',("UserKnownHostsFile=" + $SshThrowaway))

Write-Host "`n=== Рабочий стол: $($t.desc) ===`n" -ForegroundColor Cyan

# Машина без адреса отложена до настройки на месте — предупредим честно, а не сделаем вид.
if (-not $t.host -and -not $lan) {
    Write-Host "  $($Target.ToUpper()) ещё не настроена: адрес машины уточняется на месте." -ForegroundColor Yellow
    Write-Host "  Как узнаешь — впиши его в config	argets.json, поле host.`n" -ForegroundColor Yellow
    exit 2
}

# --- Прямой путь -------------------------------------------------------------
# Дома цель отвечает сама; в поездке она отвечает так же, если поднят путь домой
# (setup-home-vpn.cmd). Крюк через SECOND VPS нужен, только когда прямого нет: он
# добавляет задержку, а в рабочем столе она видна сразу.
$direct = $false
if ($lan) {
    Write-Host "  пробую прямой путь ${lan}:$($t.port) ..." -ForegroundColor Gray
    $direct = Test-Port -Address $lan -Port ([int]$t.port)
}

if ($direct) {
    Write-Host "  прямой путь есть — идём мимо SECOND VPS" -ForegroundColor Green
    if ($Check) {
        Write-Host "  (только проверка — окно не открываю)`n" -ForegroundColor Gray
        exit 0
    }
    Write-Host "  открываю рабочий стол`n" -ForegroundColor Green
    Start-Process mstsc -ArgumentList "/v:${lan}:$($t.port)" -Wait
    Write-Host "  рабочий стол закрыт.`n" -ForegroundColor Gray
    exit 0
}

# --- Маршруты через MAIN VPS, до SECOND VPS -------------------------------------
# Порядок тот же, что в окне и у файлового сценария: MAIN VPS напрямую,
# он же через cloudflared, REVERSE SSH TUN машины - и только потом SECOND VPS. Через него
# не должно идти то, что через него идти не должно, а рабочий стол показывает
# ровно то же, что и файлы.
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

$local = [int]$t.local
$forward = $null
$routeName = ''

foreach ($leg in @("$Target-direct", "$Target-cf", "$Target-ssh")) {
    if (-not (Test-SshHostKnown -Name $leg)) { continue }
    Write-Host "  пробую маршрут $leg ..." -ForegroundColor Gray
    $argsLeg = @(
        '-o','BatchMode=yes',
        '-o','StrictHostKeyChecking=accept-new',
        '-o',("UserKnownHostsFile=" + $SshThrowaway),
        '-o','ExitOnForwardFailure=yes',
        '-o','ConnectTimeout=10',
        '-N','-L',("${local}:127.0.0.1:$($t.port)"),$leg
    ) -join ' '
    $try = Start-Process ssh -ArgumentList $argsLeg -PassThru -WindowStyle Hidden
    $up = $false
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 500
        if ($try.HasExited) { break }
        if (Test-Port -Address 'localhost' -Port $local -TimeoutMs 500) { $up = $true; break }
    }
    if ($up) {
        Write-Host "  маршрут $leg работает" -ForegroundColor Green
        $forward = $try
        $routeName = $leg
        break
    }
    if (-not $try.HasExited) { Stop-Process -Id $try.Id -Force -ErrorAction SilentlyContinue }
}

if ($forward) {
    if ($Check) {
        Write-Host "  Путь: $routeName" -ForegroundColor Cyan
        Write-Host "  (только проверка — окно не открываю)`n" -ForegroundColor Gray
        # Проверка подняла проброс сама - за собой убираем тоже сами.
        if (-not $forward.HasExited) { Stop-Process -Id $forward.Id -Force -ErrorAction SilentlyContinue }
        exit 0
    }
    Write-Host "  открываю рабочий стол через $routeName`n" -ForegroundColor Green
    try {
        Start-Process mstsc -ArgumentList "/v:localhost:$local" -Wait
    } finally {
        if (-not $forward.HasExited) { Stop-Process -Id $forward.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "  рабочий стол закрыт.`n" -ForegroundColor Gray
    exit 0
}

# --- Проверка: виден ли RDP цели со стороны SECOND VPS -----------------------
if (-not $ServerHost) {
    Write-Host "  адрес SECOND VPS не вписан: targets.json, запись second`n" -ForegroundColor Red
    exit 1
}
Write-Host "  маршрутов через MAIN VPS нет, пробую через SECOND VPS" -ForegroundColor Yellow
Write-Host "  проверяю доступность $($t.host):$($t.port) через SECOND VPS..." -ForegroundColor Gray
$probe = & ssh @sshCommon $SshTarget "timeout 6 bash -c 'echo > /dev/tcp/$($t.host)/$($t.port)' 2>/dev/null && echo open || echo shut" 2>$null
$probe = ($probe | Out-String).Trim()

if ($probe -ne 'open') {
    Write-Host "  Цель не отвечает на $($t.port) со стороны SECOND VPS." -ForegroundColor Red
    Write-Host "  Проверь, включён ли на машине удалённый рабочий стол и жив ли туннель." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host "  цель отвечает" -ForegroundColor Green

if ($Check) {
    Write-Host "  (только проверка — окно не открываю)`n" -ForegroundColor Gray
    exit 0
}

# --- Проброс через SECOND VPS --------------------------------------------------
$fwd = "${local}:$($t.host):$($t.port)"
Write-Host "  поднимаю проброс localhost:$local -> $($t.host):$($t.port)" -ForegroundColor Gray

# Start-Process сам не квотирует пробелы в пути ключа (у нас "Audion Backup"),
# поэтому собираем строку аргументов и кавычим ключ вручную. Через splat (&)
# выше кавычки не нужны — там оператор вызова квотирует сам.
$argString = @(
    '-i', ('"{0}"' -f $SshKey), '-p', [string]$SecondVps.Port,
    '-o','BatchMode=yes',
    '-o','StrictHostKeyChecking=accept-new',
    '-o',("UserKnownHostsFile=" + $SshThrowaway),
    '-o','ExitOnForwardFailure=yes',
    '-N','-L',$fwd,$SshTarget
) -join ' '
$ssh = Start-Process ssh -ArgumentList $argString -PassThru -WindowStyle Hidden

# Ждём, пока локальный порт начнёт слушаться (до ~10 секунд).
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if ($ssh.HasExited) { break }
    if ((Test-NetConnection -ComputerName localhost -Port $local -WarningAction SilentlyContinue -InformationLevel Quiet)) {
        $ready = $true; break
    }
}

if (-not $ready) {
    Write-Host "  Проброс не поднялся (SECOND VPS недоступен?)." -ForegroundColor Red
    if (-not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
    Write-Host ""
    exit 1
}
Write-Host "  проброс готов, открываю рабочий стол`n" -ForegroundColor Green

# --- Рабочий стол ------------------------------------------------------------
# Пока окно открыто — держим проброс; закрылось — снимаем.
try {
    Start-Process mstsc -ArgumentList "/v:localhost:$local" -Wait
} finally {
    if (-not $ssh.HasExited) { Stop-Process -Id $ssh.Id -Force }
    Write-Host "  рабочий стол закрыт, проброс снят.`n" -ForegroundColor Gray
}
