<#
.SYNOPSIS
    REVERSE SSH TUN: вход на эту машину издалека обратным SSH-туннелем, без
    туннеля в системе. Подвес - MAIN VPS или SECOND VPS.

.DESCRIPTION
    Задача: машина за чужим NAT должна быть доступна снаружи. Раньше рядом
    стоял туннель WireGuard до MAIN VPS или SECOND VPS; 09.09.2026 его убрали из
    программы, и проброс остался единственным маршрутом к машине снаружи.

    Разница в цене и в охвате. WireGuard даёт третий уровень: видно машину
    целиком, любой порт, файлы и рабочий стол напрямую - но ради этого он
    поднимает в системе адаптер и службу, забирает маршруты, ставит свой DNS,
    спорит с купленным VPN за общий драйвер и падает при загрузке, пока сеть не
    готова. Обратный проброс не делает ничего из этого: машина сама держит одно
    исходящее соединение и просит MAIN VPS или SECOND VPS открыть у себя порт на
    localhost. Кто вошёл на MAIN VPS или SECOND VPS - через этот порт попадает
    сюда. Ни адаптера, ни маршрутов, ни драйвера; зато и порт один - двадцать
    второй, а всё остальное только тем, что умеет ssh.

    И это TCP, а не UDP: из-под чужого VPN и мобильного оператора он проходит
    там, где WireGuard молчит - проверено на этой же машине.

    Канал держит отдельный процесс в режиме -Hold: он переподнимает ssh, пока
    его не остановят. Ни службы, ни задачи в расписании - служба из ssh не
    выходит вовсе, а задача Windows срабатывает при входе в систему и на этом
    успокаивается: умер процесс, и никто его не поднял. Здесь проще:
    с -Persistent канал живёт независимо от GUI и запускается ярлыком
    в shell:startup при входе в Windows. -Toggle выключает канал и автозапуск
    либо включает с прежними настройками. Без -Persistent сохраняется прежний
    режим, привязанный к запускающему GUI/терминалу.

.PARAMETER Name
    Имя машины. По умолчанию - имя компьютера.

.PARAMETER Server
    Хосты MAIN VPS или SECOND VPS - имена из ~\.ssh\config, по порядку
    проб. По умолчанию сперва прямой адрес MAIN VPS, затем он же через
    cloudflared. Подвес может быть любым: `-Server second-vps` вешает
    REVERSE SSH TUN на SECOND VPS - его видно без VPN, и готовый враппер
    `reverse-ssh-second-vps.cmd` делает ровно это.

.PARAMETER Port
    Порт на MAIN VPS или SECOND VPS (loopback). По умолчанию он называет
    свободный сам.

.PARAMETER Stop
    Опустить канал: процесс останавливается, ключ и состояние остаются.

.PARAMETER Check
    Только осмотр: ничего не менять.

.PARAMETER Remove
    Удалить: остановить канал, удалить ключ с MAIN VPS или SECOND VPS и файл
    состояния.

.PARAMETER Hold
    Внутренний режим: держать соединение. Так его поднимает сам сценарий.

.EXAMPLE
    .\Setup-SshBeacon.ps1 -Check
    Посмотреть, какой REVERSE SSH TUN заведён.

.EXAMPLE
    .\Setup-SshBeacon.ps1
    Завести и поднять проброс для этой машины.

.EXAMPLE
    .\Setup-SshBeacon.ps1 -Stop
    Опустить канал, оставив всё заведённое на месте.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Name,
    [string[]]$Server = @('audion-vps-direct', 'audion-vps'),
    [int]$Port = 0,
    [switch]$Stop,
    [switch]$Check,
    [switch]$Remove,
    [switch]$Hold,
    [switch]$Persistent,
    [switch]$Toggle,
    [switch]$Resume,
    # Папка данных этой машины. Стоит последней: позиционные аргументы
    # старше - `Connect-Files.ps1 router` должен означать цель, а не путь.
    [string]$Root,
    # Внутренний журнал этапов отдельного процесса, без содержимого ключей.
    [string]$RuntimeLog,
    [string]$RuntimeErrorLog,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
if (@($Stop, $Check, $Remove, $Hold, $Toggle, $Resume | Where-Object { $_ }).Count -gt 1) {
    throw 'REVERSE SSH TUN: select only one action.'
}
trap {
    if ($RuntimeErrorLog) {
        try { [IO.File]::AppendAllText($RuntimeErrorLog, ($_ | Out-String), [Text.UTF8Encoding]::new($false)) } catch { }
    }
    break
}

# Список плеч приходит от враппера одной строкой: powershell -File не делит
# аргумент по запятым, и «second-vps,audion-vps-direct» досталось бы ssh
# как одно имя хоста. Делим сами - тогда оба пути вызова дают одно и то же.
$Server = @($Server | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })

# --- Пути от расположения сценария ------------------------------------------
$Here = $PSScriptRoot
$TunnelRoot = Split-Path $Here -Parent
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\DataRoot.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\Secrets.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\Targets.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\KeyPair.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\BeaconLifecycle.ps1')

# `second-vps` во врапперах - условное имя SECOND VPS: настоящее у
# каждого своё и лежит в targets.json.
$SecondVps = Get-AbkSecondVps -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot (Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root)
$Server = @($Server | ForEach-Object { if ($_ -eq 'second-vps') { $SecondVps.SshHost } else { $_ } })

$DataRoot = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root
$KeyDir = Join-Path $DataRoot 'Tunnel\SSH\beacon'

if (-not $Name) { $Name = Get-AbkLocalBeaconName -DataRoot $DataRoot }
$KeyFile = Join-Path $KeyDir "$Name`_beacon_ed25519"
$PubFile = "$KeyFile.pub"
$StateFile = Join-Path $KeyDir "$Name.beacon.json"
$script:SetupLogFile = ''

# Учётная запись на MAIN VPS или SECOND VPS, под которой живёт проброс. Своя, не
# рабочая: ключ туннеля лежит на машине, которая стоит в чужой сети, и красть
# его будут оттуда. В пустой учётной записи брать нечего - ни файлов, ни групп,
# ни служебных сокетов рабочего пользователя. Оболочки у неё нет, пароль
# заблокирован, а её ограничения на стороне сервера едут образцом рядом:
# config\sshd-tunnel.sample.conf. Строка ключа сужает проброс до одного порта,
# учётная запись - второй рубеж.
$ServerUser = 'tunnel'

function Write-Line {
    param($Text, $Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
    if ($script:SetupLogFile) {
        $record = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
        try { Add-Content -LiteralPath $script:SetupLogFile -Value $record -Encoding UTF8 } catch { }
    }
}

function Get-BeaconHint {
    # Сырую ошибку ssh -> понятный шаг. Матчим англ. и рус.: ssh пишет на
    # языке системы, у семейных машин часто русский.
    param([string]$Err)
    $e = "$Err"
    if (-not $e) { return '' }
    if ($e -match 'UNPROTECTED PRIVATE KEY FILE|bad permissions|permissions.*too open') {
        return 'OpenSSH отклонил права локального приватного ключа - исправьте ACL через IMPORT KEYS; авторизация на VPS ещё не проверялась' }
    if ($e -match 'REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key|ключ.*измен') {
        return 'отпечаток VPS изменился - сверьте его через консоль сервера; прежняя запись known_hosts сохранена' }
    if ($e -match 'known_hosts|Host key|verification failed|подлинност') {
        return 'подтвердите отпечаток VPS при установке REVERSE SSH TUN в отдельном окне; SSH-KEYSCAN пишет отдельный список для rclone' }
    if ($e -match 'no such identity|Identity file .*not accessible') {
        return 'файл приватного ключа из IdentityFile не найден - проверьте путь в ~/.ssh/config и IMPORT KEYS' }
    if ($e -match 'resolve|not known|No address|неизвест|не известн') {
        return 'имени VPS нет в ~/.ssh/config - сделай TUNNEL -> INSTALL' }
    if ($e -match 'Permission denied|publickey|Отказано в доступе') {
        return 'ключ не пускает - SSH KEYS -> IMPORT KEYS, и VPS должен авторизовать ключ' }
    if ($e -match 'timed out|refused|No route|unreachable|время ожидания|отказано в подключении') {
        return 'VPS не отвечает по сети - проверь интернет и адрес VPS' }
    return ''
}

function Get-Holders {
    <#
        Держатели этого проброса - по имени, а не по общему `-R`: на машине их
        может быть несколько, и трогать надо свой.

        Командная строка есть только у записи Win32_Process. У объекта, который
        отдаёт Get-Process, такого свойства нет вовсе - прежний фильтр молча не
        выбирал ничего, и держатель переживал снятие.
    #>
    return @(Get-AbkBeaconRuntimeProcesses -Name $Name -DataRoot $DataRoot | Where-Object { $_.ProcessId -ne $PID })
}

function Stop-Holders {
    <#
        Остановить своих держателей вместе с их ssh. Возвращает список отказов:
        раньше отказ проглатывался, и «снято» печаталось даже тогда, когда
        держатель продолжал работать.

        Список держателей оборачивается в @() у каждого, кто его берёт. Функция
        отдаёт массив, но PowerShell разворачивает его на выходе, и единственный
        держатель приходит одиночной записью Win32_Process - а у неё в
        PowerShell 5.1 нет Count. Проверка `if ($holders.Count)` тогда молчала,
        ssh держателя в список остановки не попадал и переживал снятие, держа
        порт на MAIN VPS или SECOND VPS.
    #>
    $holders = @(Get-Holders)
    $ids = @($holders | ForEach-Object { [int]$_.ProcessId })

    # ssh держателя ищется по родителю. После остановки родителя эта запись у
    # ssh остаётся прежней, поэтому тем же поиском проверяется и то, что ssh
    # действительно ушёл.
    $findTails = {
        if (-not $ids.Count) { return @() }
        @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'ssh.exe' -and ($ids -contains [int]$_.ParentProcessId) })
    }
    $tails = @(& $findTails)

    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($one in @($tails) + @($holders)) {
        try {
            Stop-Process -Id ([int]$one.ProcessId) -Force -ErrorAction Stop
        } catch {
            $refused.Add(('{0} PID {1}: {2}' -f $one.Name, $one.ProcessId, $_.Exception.Message)) | Out-Null
        }
    }

    # Ждём, пока уйдут и держатели, и их ssh: порт на MAIN VPS или SECOND VPS держит именно
    # ssh, и пока он жив, «снято» было бы неправдой - даже при остановленном
    # держателе.
    $waited = 0
    while ($waited -lt 10 -and (@(Get-Holders).Count + @(& $findTails).Count)) {
        Start-Sleep -Seconds 1
        $waited++
    }

    $left = @(Get-Holders).Count + @(& $findTails).Count
    return @{ Stopped = ($holders.Count + $tails.Count); Left = $left; Refused = $refused }
}

function Start-Holder {
    <#
        Поднять держателя отдельным процессом. Папку данных передаём явно:
        держатель работает сам по себе, и гадать ему нельзя.
    #>
    $launched = Start-AbkBeaconRuntime -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot -Name $Name
    if (-not $launched) { throw 'REVERSE SSH TUN: процесс не запущен — проверьте состояние и уже работающие процессы' }
    Write-Line ('PID {0}; журнал запуска: {1}' -f $launched.Process.Id, $launched.ErrLog)
    $launched.Process.Dispose()
}

function Find-Ssh {
    $c = Get-Command ssh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Test-BeaconConsole {
    # Окно GUI открывает установку в отдельной консоли. При перенаправленном
    # вводе запрос доверия некому подтвердить, поэтому остаётся только ошибка.
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Confirm-BeaconHost {
    param([string]$Target)
    Write-Line ("SSH {0}: сверьте SHA256-отпечаток с консолью VPS и подтвердите его в запросе OpenSSH." -f $Target) Cyan
    # Только приветствие: удалённая команда установки здесь не исполняется.
    # ask принимает новый ключ лишь по ответу человека и отвергает изменённый.
    # Пароль и парольная фраза не запрашиваются: следующий запуск будет BatchMode.
    & ssh -o BatchMode=no -o StrictHostKeyChecking=ask -o UpdateHostKeys=no `
        -o NumberOfPasswordPrompts=0 -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no `
        -o ConnectTimeout=15 $Target 'exit 0' | Out-Host
}

function Repair-BeaconIdentity {
    param([string]$Target)
    $shown = @(& ssh -G $Target 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    $roots = @((Join-Path $DataRoot 'Tunnel\SSH'), (Join-Path $DataRoot 'Tunnel\Export\SSH'), (Join-Path $HOME '.ssh'))
    $fixed = $false
    foreach ($setting in $shown) {
        if ($setting -notmatch '^identityfile\s+(.+)$') { continue }
        $path = $Matches[1].Trim('"')
        if ($path -match '^~[/\\]') { $path = Join-Path $HOME $path.Substring(2) }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $full = (Get-Item -LiteralPath $path).FullName
        $allowed = $false
        foreach ($rootPath in $roots) {
            if ($full.StartsWith(([IO.Path]::GetFullPath($rootPath).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { $allowed = $true }
        }
        if (-not $allowed) { Write-Line ('ACL вне папки данных и профиля не меняется: ' + $full) Yellow; continue }
        if (Protect-AbkSshPrivateKey -Path $full) {
            Write-Line ('права приватного SSH-ключа проверены: ' + $full) Green
            $fixed = $true
        } else { Write-Line ('исправить права приватного SSH-ключа не удалось: ' + $full) Yellow }
    }
    return $fixed
}

function Invoke-Server {
    <#
        Команда на MAIN VPS или SECOND VPS. Свёрнута в base64: аргумент с кавычками PowerShell
        нативной программе передаёт по своим правилам и половину съедает - на
        том конце оставался обрубок.
    #>
    param([Parameter(Mandatory)][string]$Command, [string[]]$Target = $Server,
          [switch]$ConfirmHostKey)

    # Переносы строк приводим к юниксовым. Файл сценария лежит с CRLF, и
    # here-string несёт их внутрь команды, а bash читает возврат каретки как
    # часть слова и ругается на несуществующую команду.
    $unix = $Command -replace "`r`n", "`n"
    $wrapped = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($unix))
    $line = "echo $wrapped | base64 -d | bash"

    # Плечи пробуются по порядку. Их два к одному и тому же MAIN VPS или SECOND VPS: прямой
    # адрес и он же через cloudflared. Прямой короче, зато его режут первым;
    # cloudflared выглядит обычным HTTPS и проходит там, где остальное нет.
    $errFile = Join-Path $env:TEMP ('audion-ssh-err-' + [guid]::NewGuid().ToString('N') + '.txt')
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $out = $null
    $script:LastVia = ''
    $script:LastSshError = ''
    $failures = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($alias in $Target) {
            $out = & ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=15 $alias $line 2>$errFile
            $code = $LASTEXITCODE
            $said = $(if (Test-Path $errFile) { Get-Content $errFile -Raw } else { $null })
            if ($code -ne 0 -and $ConfirmHostKey -and
                "$said" -match 'Host key verification failed' -and
                "$said" -notmatch 'REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key' -and
                (Test-BeaconConsole)) {
                Write-Line ("SSH {0}: {1}" -f $alias, "$said".Trim()) Yellow
                Confirm-BeaconHost -Target $alias
                # После подтверждения снова проверяем доступ без диалога.
                # Даже отказ от доверия не должен запустить команду с ask/no.
                $out = & ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=15 $alias $line 2>$errFile
                $code = $LASTEXITCODE
                $said = $(if (Test-Path $errFile) { Get-Content $errFile -Raw } else { $null })
            }
            if ($code -ne 0 -and $ConfirmHostKey -and
                "$said" -match 'UNPROTECTED PRIVATE KEY FILE|bad permissions|permissions.*too open') {
                Write-Line ("SSH {0}: {1}" -f $alias, "$said".Trim()) Yellow
                if (Repair-BeaconIdentity -Target $alias) {
                    $out = & ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=15 $alias $line 2>$errFile
                    $code = $LASTEXITCODE
                    $said = $(if (Test-Path $errFile) { Get-Content $errFile -Raw } else { $null })
                }
            }
            if ($code -eq 0) {
                $script:LastVia = $alias
                Write-Line ("SSH {0}: команда выполнена" -f $alias) Green
                return ($out | Out-String).Trim()
            }
            $failure = '[{0}] exit={1}: {2}' -f $alias, $code, "$said".Trim()
            $failures.Add($failure)
            Write-Line $failure Yellow
            $hint = Get-BeaconHint "$said"
            if ($hint) { Write-Line ('  -> ' + $hint) Cyan }
        }
    } finally {
        $ErrorActionPreference = $was
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $script:LastSshError = $failures -join "`n"
    # stdout неуспешной команды не может быть ответом о свободном порте.
    return ''
}

function Get-BeaconState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { return Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-BeaconLegs {
    <#
        Плечи для осмотра и снятия - туда, где маячок заведён.

        Осмотр и снятие шли на плечи по умолчанию, к MAIN VPS. Маячок, заведённый
        через SECOND VPS, так не найти и не снять: на MAIN VPS его ключа нет,
        MAIN VPS честно отвечал, что убирать нечего, и снятие отчитывалось
        успехом, оставляя открытую дверь на SECOND VPS.

        Явный -Server сильнее всего: это осознанное указание. Иначе для осмотра
        первым идёт плечо, которое держит канал сейчас, для снятия - места, где
        ключ прописывался; следом - плечи из состояния.
    #>
    param(
        $State,
        [string[]]$Explicit = @(),
        [ValidateSet('check', 'remove')][string]$For = 'check'
    )

    if ($Explicit.Count) { return @($Explicit) }
    if (-not $State) { return @() }
    $first = $(if ($For -eq 'check') { @($State.Via) + @($State.Registered) } else { @($State.Registered) + @($State.Via) })
    $legs = New-Object System.Collections.Generic.List[string]
    foreach ($leg in (@($first) + @($State.Servers))) {
        $legName = [string]$leg
        if ($legName -and -not $legs.Contains($legName)) { $legs.Add($legName) }
    }
    return $legs.ToArray()
}

function Test-BeaconRemoved {
    <#
        Снят ли ключ по ответам плеч: removed - строка была и убрана, absent -
        строки не было, пусто - MAIN VPS или SECOND VPS не ответил.

        Места, где ключ прописывался, обязаны ответить: «нечего убирать» с
        другого из двух за них не отвечает. У состояний прежних версий этих
        мест нет - тогда хватает ключа, убранного хоть где-то, или ответа
        всех плеч.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Answers,
        [string[]]$Places = @()
    )

    $known = @($Places | Where-Object { $_ })
    $silent = @($Answers.Keys | Where-Object { -not $Answers[$_] })
    $removed = @($Answers.Keys | Where-Object { $Answers[$_] -eq 'removed' })
    $unanswered = @($known | Where-Object { -not $Answers.Contains($_) -or -not $Answers[$_] })
    $done = $(if ($known.Count) { -not $unanswered.Count } else { [bool]$removed.Count -or -not $silent.Count })
    return @{
        Done    = [bool]$done
        Missed  = $(if ($unanswered.Count) { $unanswered } else { $silent })
        Removed = $removed
    }
}

function Get-FreePort {
    <#
        Свободный порт называет MAIN VPS или SECOND VPS: занятость знает он, а не мы. Диапазон
        22000-22099 выбран пустым - 2222 занят докером, 2000 туннелем
        cloudflared, и наступать на них незачем.
    #>
    $ask = @'
for p in $(seq 22000 22099); do
    if ! ss -tln 2>/dev/null | grep -q "127.0.0.1:$p "; then echo "$p"; exit 0; fi
done
echo none
'@
    $said = Invoke-Server -Command $ask -ConfirmHostKey
    if ($said -match '^\d+$') { return [int]$said }
    return 0
}

# --- Режим держателя: его поднимает сам сценарий --------------------------
if ($Hold) {
    if (-not $RuntimeLog) {
        $runtimeLogDir = Join-Path (Split-Path -Parent $TunnelRoot) 'logs'
        New-Item -ItemType Directory -Path $runtimeLogDir -Force | Out-Null
        $RuntimeLog = Join-Path $runtimeLogDir ('ssh-beacon-{0}-worker-{1}-{2}.trace.log' -f $Name,(Get-Date).ToString('yyyyMMdd-HHmmss'),$PID)
    }
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.enter' -Detail ('PowerShell={0}; CLR={1}; bits={2}' -f $PSVersionTable.PSVersion,[Environment]::Version,([IntPtr]::Size * 8))
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.os' -Detail ([Environment]::OSVersion.VersionString)
    $spec = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot -Name $Name
    if (-not $spec) { throw 'REVERSE SSH TUN: нет разрешённой конфигурации для запуска' }
    $state = $spec.State
    $runtimeGuard = Enter-AbkBeaconRuntime -DataRoot $DataRoot -Name $Name
    if (-not $runtimeGuard) { Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.duplicate'; exit 0 }
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.job.begin'
    Initialize-AbkBeaconLifetime
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.job.ready'
    $ssh = Find-Ssh
    if (-not $ssh) { throw 'REVERSE SSH TUN: ssh.exe не найден' }
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.ssh.resolved' -Detail $ssh
    try { Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.ssh.version' -Detail ([Diagnostics.FileVersionInfo]::GetVersionInfo($ssh).ProductVersion) } catch { }

    # Журнал держателя. Без него разбираться нечем: он живёт отдельным
    # процессом, без окна, и всё, что он скажет, иначе уходит в пустоту.
    $logDir = Join-Path (Split-Path -Parent $TunnelRoot) 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ('ssh-beacon-' + $Name + '.log')
    $sshLog = Join-Path $logDir ('ssh-beacon-' + $Name + '-ssh.log')

    function Write-Beacon {
        param([string]$Text)
        $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
        try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
    }

    # Строгий режим здесь вреден. ssh здоровается в поток ошибок по любому
    # поводу - предупреждает про постквантовый обмен ключами, про новый ключ
    # хоста, про закрытое соединение, - а при $ErrorActionPreference = 'Stop'
    # каждое такое слово превращается в исключение и выносит цикл. Держатель
    # умирал молча: задача показывала Ready, порт на MAIN VPS или SECOND VPS молчал, а в
    # журнале обрывалась строка на середине истории.
    $ErrorActionPreference = 'Continue'

    Write-Beacon ('процесс поднялся; хосты: ' + (@($state.Servers) -join ' -> '))
    Write-Beacon ('этапы запуска: ' + $RuntimeLog)

    # Бесконечно, с паузой: обрыв связи - обычное дело для машины, которая
    # ездит. ExitOnForwardFailure обязателен: без него ssh молча остаётся жив
    # с непробросившимся портом, и снаружи это выглядит как живой SSH BEACON.
    #
    # Плечи перебираются по кругу. Оборвалось - берём следующее, а не долбимся
    # в одно и то же: сеть под ногами меняется, и то, что не прошло минуту
    # назад, могло стать единственным работающим.
    $legs = @($state.Servers)
    if (-not $legs) { $legs = @($state.Via) }
    if (-not $legs) { exit 1 }

    $n = 0
    while ($true) {
        $enabled = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot -Name $Name
        if (-not $enabled) { Write-Beacon 'канал отключён в сохранённом состоянии'; exit 0 }
        $state = $enabled.State
        $leg = $legs[$n % $legs.Count]
        $n++
        Write-Beacon ('SSH: подключение к {0}, порт туннеля {1}' -f $leg, $state.Port)
        Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.attempt.begin' -Detail ('attempt=' + $n)
        [IO.File]::WriteAllText($sshLog, '')

        # Какое плечо держит канал сейчас - видно снаружи, без входа на машину.
        try {
            $state | Add-Member -NotePropertyName Via -NotePropertyValue $leg -Force
            $state | Add-Member -NotePropertyName Since -NotePropertyValue ((Get-Date).ToString('s')) -Force
            $state | Add-Member -NotePropertyName SshLog -NotePropertyValue $sshLog -Force
            $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
        } catch { }

        $errFile = Join-Path $env:TEMP ('audion-beacon-' + $Name + '.err')
        try {
        # Свой конфиг вместо пользовательского: под SYSTEM пользовательский
        # не читается вовсе, и плечо, заданное алиасом, разрешить нечем.
        $confArgs = @()
        if ($state.SshConfig -and (Test-Path -LiteralPath $state.SshConfig)) {
            $confArgs = @('-F', $state.SshConfig)
        }

        $sshArgs = @('-N','-T','-v') + $confArgs + @(
            '-i', $state.KeyFile,
            '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes',
            '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=15',
            '-o', 'ConnectionAttempts=1', '-o', 'ServerAliveInterval=30',
            '-o', 'ServerAliveCountMax=3', '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no',
            '-l', $state.User, '-R', ("127.0.0.1:{0}:127.0.0.1:22" -f $state.Port), $leg
        )
        Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.ssh.invoke'
        $sshExit = Invoke-AbkBeaconSsh -File $ssh -Arguments $sshArgs -Log $sshLog -TraceLog $RuntimeLog
        Write-Beacon ('SSH {0}: exit={1}' -f $leg, $sshExit)
        } catch {
            # Даже если что-то прорвалось - это повод попробовать следующее
            # плечо, а не закончить работу.
            Write-Beacon ('хост {0}: {1}' -f $leg, $_.Exception.Message)
            Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'worker.attempt.exception' -Detail $_.Exception.ToString()
        }

        $said = (Read-AbkBeaconSshLog -Path $sshLog).Trim()
        # Keep the old diagnostic location useful for existing command recipes.
        [IO.File]::WriteAllText($errFile, $said, [Text.UTF8Encoding]::new($false))
        Write-Beacon ("хост {0}: {1}" -f $leg, $(if ($said) { ($said -split "`n")[0].Trim() } else { 'соединение закрылось' }))
        Write-Beacon ('подробности SSH: ' + $sshLog)

        # Порт на MAIN VPS или SECOND VPS мог остаться за оборвавшейся сессией: sshd замечает
        # это не сразу. Ломиться в занятый порт бесполезно - ждём, пока он
        # освободится сам, и лишь потом берём следующее плечо.
        if ($said -match 'remote port forwarding failed') {
            Write-Beacon "порт туннеля ещё занят прежней сессией - жду"
            Start-Sleep 60
        } else {
            Start-Sleep 15
        }
    }
}

$state = Get-BeaconState
if ($Toggle -and $state) {
    if (-not $state.PSObject.Properties['AutoStart'] -or $state.AutoStart) { $Stop = $true }
    else { $Resume = $true }
}

# Осмотр и снятие идут туда, где маячок заведён: плечи из состояния, а не плечи
# по умолчанию. Явно названный -Server сильнее - это осознанный выбор.
$explicitServer = @()
if ($PSBoundParameters.ContainsKey('Server')) { $explicitServer = @($Server) }
if (($Check -or $Remove) -and $state) {
    $stateLegs = @(Get-BeaconLegs -State $state -Explicit $explicitServer -For $(if ($Remove) { 'remove' } else { 'check' }))
    if ($stateLegs.Count) { $Server = $stateLegs }
}

Write-Host ("`n=== REVERSE SSH TUN '{0}' через {1} ===`n" -f $Name, (@($Server) -join ' -> ')) -ForegroundColor Cyan

$ssh = Find-Ssh
if (-not $ssh) {
    Write-Line "ssh на машине не найден - поставьте клиент OpenSSH" Yellow
    Write-Host ''
    exit 1
}

# --- Осмотр -----------------------------------------------------------------
if ($Check) {
    Write-Line ("ключ: " + $(if (Test-Path $KeyFile) { 'на месте' } else { 'нет' }))
    if ($state) {
        Write-Line ("порт туннеля: {0}, пользователь {1}@{2}" -f $state.Port, $state.User, $state.Host)
        $legs = @($state.Servers)
        if ($legs) { Write-Line ("хосты по порядку: " + ($legs -join ' -> ')) }
        if ($state.PSObject.Properties['Via'] -and $state.Via) {
            Write-Line ("держит канал: {0}{1}" -f $state.Via,
                $(if ($state.PSObject.Properties['Since'] -and $state.Since) { ', с ' + $state.Since } else { '' }))
        }
        if ($state.PSObject.Properties['Registered'] -and $state.Registered) {
            Write-Line ("ключ прописан через: " + (@($state.Registered) -join ', '))
        }
    } else {
        Write-Line "проброс не заведён"
    }
    $holders = @(Get-Holders)
    Write-Line ("процесс: " + $(if ($holders.Count) { 'работает' } else { 'не работает' })) `
        $(if ($holders.Count) { 'Green' } else { 'Yellow' })

    if ($state) {
        $script:LastVia = ''
        $alive = Invoke-Server -Command ("ss -tln 2>/dev/null | grep -q '127.0.0.1:{0} ' && echo up || echo down" -f $state.Port)
        $where = $(if ($script:LastVia) { ' (' + $script:LastVia + ')' } else { '' })
        Write-Line ("порт туннеля сейчас{0}: {1}" -f $where,
            $(if ($alive -eq 'up') { 'слушает - REVERSE SSH TUN жив' } elseif ($script:LastVia) { 'молчит' } else { 'MAIN VPS или SECOND VPS не ответил' })) `
            $(if ($alive -eq 'up') { 'Green' } else { 'Yellow' })
    }
    Write-Host ''
    exit 0
}

# --- Опустить ---------------------------------------------------------------
if ($Stop) {
    # Кнопка питания в окне: канал гаснет, ключ и состояние остаются на месте.
    # Поднять обратно - тем же запуском без ключей.
    if ($state) {
        $state | Add-Member -NotePropertyName AutoStart -NotePropertyValue $false -Force
        $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    }
    $startupError = ''
    try { $null = Set-AbkBeaconStartup -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot -Name $Name -Enabled $false }
    catch { $startupError = $_.Exception.Message }
    $gone = Stop-Holders
    # A worker could have written its last connection status just before it
    # stopped. Keep the explicit OFF decision after process termination too.
    if ($state) { $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
    if ($startupError) { Write-Line $startupError Yellow }
    if ($gone.Left) {
        Write-Line ("процесс не остановился: осталось {0}" -f $gone.Left) Red
        foreach ($one in $gone.Refused) { Write-Line ('  ' + $one) Gray }
        Write-Host ''
        exit 1
    }
    if ($gone.Stopped) {
        Write-Line ("канал опущен: остановлено процессов {0}" -f $gone.Stopped) Green
    } else {
        Write-Line "канал и так не поднят"
    }
    Write-Host ''
    if ($startupError) { exit 1 }
    exit 0
}

# --- Снятие -----------------------------------------------------------------
if ($Remove) {
    # Порядок обратный привычному: сперва гасим живое, потом убираем запись.
    # Держатель хранит состояние в памяти и продолжает бесконечный цикл, так
    # что удалённый файл состояния он заведёт заново, а канал останется открытым.

    # Проверяем делом: живой держатель означает открытый канал, и говорить
    # «снято» в этом случае - неправда. Ключ на MAIN VPS или SECOND VPS при этом уже мог быть
    # убран, поэтому состояние оставляем для повторной попытки.
    if ($state) {
        $state | Add-Member -NotePropertyName AutoStart -NotePropertyValue $false -Force
        $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    }
    $startupError = ''
    try { $null = Set-AbkBeaconStartup -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot -Name $Name -Enabled $false }
    catch { $startupError = $_.Exception.Message }
    $gone = Stop-Holders
    if ($state) { $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 }
    if ($startupError) { Write-Line $startupError Yellow }
    if ($gone.Left) {
        Write-Line ("процесс не остановился: осталось {0}" -f $gone.Left) Red
        foreach ($one in $gone.Refused) { Write-Line ('  ' + $one) Gray }
        Write-Line 'канал остался открытым - ключ не трогаю' Yellow
        Write-Line 'повторите удаление с правами, достаточными для остановки процесса' Gray
        Write-Host ''
        exit 1
    }

    if ($gone.Stopped) {
        Write-Line ("остановлено процессов: {0}" -f $gone.Stopped) Green
    } else {
        Write-Line "процесс не работал"
    }

    if ((Test-Path $PubFile) -or $state) {
        # Убираем с MAIN VPS или SECOND VPS только свою строку - по комментарию ключа,
        # а не по всему файлу: в authorized_keys живут и другие машины.
        # MAIN VPS или SECOND VPS отвечает, была ли строка: «убирать нечего»
        # с другого из двух - не успех.
        $mark = 'audion-beacon-' + $Name
        # Снятие тоже с копией: чужие ключи в этом файле дороже нашего. Строку
        # узнаём по комментарию ключа целиком - последнему полю строки: поиск
        # подстрокой вместе с ключом `lab` снимал и ключ машины `lab2`.
        $purge = @"
set -e
f=/home/$ServerUser/.ssh/authorized_keys
if [ ! -f "`$f" ]; then echo absent; exit 0; fi
# Метку ищем последним полем строки. Код awk: 0 - нашли, 1 - нет, больше -
# файл не прочитан. Сбой чтения и отсутствие ключа - разные ответы: молчаливый
# absent при сбое сказал бы «убирать нечего» там, где ключ на месте.
set +e
awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k); if (k == m) hit = 1 } END { exit !hit }' "`$f"
rc=`$?
set -e
if [ "`$rc" -gt 1 ]; then echo read-error; exit 1; fi
if [ "`$rc" -ne 0 ]; then echo absent; exit 0; fi
# Как регистрация: копия до правки, а итог сверяем по числу строк до подмены -
# оставшихся должно стать ровно столько, сколько строк не с нашей меткой. Без
# set -e сбой любой из команд ниже (фильтр, подмена, права) прежде печатал
# removed на пустом файле; теперь он обрывает сценарий до echo, файл цел, и
# держатель наверху пустой ответ за успех не примет - состояние оставит.
cp -a "`$f" "`$f.audion-bak"
keep=`$(awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k) } k != m' "`$f" | wc -l)
awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k) } k != m' "`$f" > "`$f.new"
after=`$(wc -l < "`$f.new")
if [ "`$after" -ne "`$keep" ]; then
    rm -f "`$f.new"
    echo "count-mismatch keep=`$keep after=`$after"
    exit 1
fi
mv "`$f.new" "`$f"
chown ${ServerUser}:${ServerUser} "`$f"; chmod 600 "`$f"
echo removed
"@
        # Каждое плечо спрашивается отдельно: маячок мог прописываться на MAIN VPS и
        # SECOND VPS, и первый ответивший за остальных не отвечает.
        $answers = [ordered]@{}
        foreach ($leg in @($Server)) {
            $said = Invoke-Server -Command $purge -Target @($leg)
            $answers[$leg] = $(if ($said -match 'removed') { 'removed' } elseif ($said -match 'absent') { 'absent' } else { '' })
            $shown = switch ($answers[$leg]) {
                'removed' { 'ключ убран' }
                'absent'  { 'ключа не было' }
                default   { 'MAIN VPS или SECOND VPS не ответил' }
            }
            Write-Line ("{0}: {1}" -f $leg, $shown) $(if ($answers[$leg]) { 'Gray' } else { 'Yellow' })
        }

        $places = @()
        if ($state -and $state.PSObject.Properties['Registered']) { $places = @($state.Registered) }
        $result = Test-BeaconRemoved -Answers $answers -Places $places
        if (-not $result.Done) {
            # Оставшийся на MAIN VPS или SECOND VPS ключ - это открытая дверь, и молчаливый ноль
            # здесь означал бы «снято», хотя снято не всё. Состояние остаётся:
            # по нему повторное снятие найдёт те же места.
            Write-Line "ключ с MAIN VPS или SECOND VPS удалить не удалось" Yellow
            Write-Line ("не ответили: " + (@($result.Missed) -join ', ')) Gray
            if ($script:LastSshError) { Write-Line ('  ' + $script:LastSshError) Gray }
            $h = Get-BeaconHint $script:LastSshError; if ($h) { Write-Line ('  -> ' + $h) Cyan }
            Write-Line "канал закрыт, состояние оставлено для повторного удаления" Yellow
            Write-Host ''
            exit 1
        }
        if (-not @($result.Removed).Count) { Write-Line "ключа не нашлось ни на одном ответившем из MAIN VPS и SECOND VPS" Gray }
    }

    Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    Write-Line "REVERSE SSH TUN удалён; ключ остался в данных" Green
    Write-Host ''
    exit 0
}

# Resume never re-registers a key or chooses another server/port.
if ($Resume) {
    $spec = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot -Name $Name -IncludeDisabled
    if (-not $spec) { throw 'REVERSE SSH TUN: configure the tunnel before resuming it.' }
    $state = $spec.State
    $state | Add-Member -NotePropertyName AutoStart -NotePropertyValue $true -Force
    if ($Persistent) { $state | Add-Member -NotePropertyName Persistent -NotePropertyValue $true -Force }
    $state | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
    if ($state.Persistent) {
        $null = Set-AbkBeaconStartup -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot -Name $Name -Enabled $true
    }
    if (-not @(Get-Holders).Count) { Start-Holder }
    Write-Line 'REVERSE SSH TUN enabled; saved key and server were reused.' Green
    exit 0
}

# --- Установка --------------------------------------------------------------
$setupLogs = Join-Path (Split-Path -Parent $TunnelRoot) 'logs'
try {
    New-Item -ItemType Directory -Path $setupLogs -Force | Out-Null
    $script:SetupLogFile = Join-Path $setupLogs ('ssh-beacon-setup-{0}-{1}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $PID)
    Write-Line ('журнал установки: ' + $script:SetupLogFile)
    Write-Line ('хосты: ' + (@($Server) -join ' -> '))
} catch { Write-Line ('журнал установки не создан: ' + $_.Exception.Message) Yellow }
if (-not (Test-Path $KeyDir)) { New-Item -ItemType Directory -Path $KeyDir -Force | Out-Null }

# 1. Ключ SSH BEACON. Отдельный от машинного: этим ключом на MAIN VPS или
#    SECOND VPS нельзя ничего, кроме проброса, и потерять его не так больно.
#    Создаётся тем же способом, что и ключ машины: через cmd и с проверкой, что
#    пара открывается без пароля. Прежний вызов с `-N '""'` под PowerShell 7
#    давал пару с паролем из двух кавычек, и держатель с BatchMode её не открывал.
if (-not (Test-Path $KeyFile)) {
    $made = New-AbkKeyPair -Path $KeyFile -Comment ('audion-beacon-' + $Name)
    if (-not $made.Ok) {
        Write-Line "ключ REVERSE SSH TUN создать не удалось" Red
        foreach ($said in @($made.Said)) { if ("$said".Trim()) { Write-Line ('  ' + "$said".Trim()) Gray } }
        Write-Host ''
        exit 1
    }
    Write-Line "ключ REVERSE SSH TUN создан" Green
} elseif (-not (Test-AbkKeyOpens -Path $KeyFile)) {
    # Пара с паролем держателю не годится, а ключи правит владелец: сценарий её
    # не трогает и говорит, что делать.
    Write-Line "ключ REVERSE SSH TUN закрыт паролем - процесс с ним не поднимется" Red
    Write-Line ("уберите пару {0} и её .pub и запустите снова: создастся новая" -f $KeyFile) Gray
    Write-Host ''
    exit 1
} else {
    Write-Line "ключ REVERSE SSH TUN уже есть"
}
[void](Protect-AbkSecretStore -Path $KeyDir -Say { param($t, $c) Write-Line $t $c })

# 1а. Свой конфиг для плеч. Алиасы вроде audion-vps-direct описаны в
#     пользовательском ~\.ssh\config, а держатель может подняться от другой
#     учётной записи и этого файла не увидеть: ни адреса, ни ProxyCommand, ни
#     ключа. Со своим конфигом ему всё равно, чей профиль его запустил.
#
#     Значения берём у самого ssh: `ssh -G` печатает итоговые настройки, уже
#     разрешённые по всем Include и Match. Разбирать чужой файл руками не надо.
$BeaconConfig = Join-Path $KeyDir ('beacon-' + $Name + '.sshconfig')
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Собран Setup-SshBeacon.ps1 - правится пересборкой REVERSE SSH TUN, не руками.')
$lines.Add('')
$missing = @()
foreach ($leg in @($Server)) {
    $shown = @()
    try { $shown = @(& ssh -G $leg 2>$null) } catch { }
    $map = @{}
    foreach ($line in $shown) {
        $parts = ([string]$line).Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and -not $map.ContainsKey($parts[0])) { $map[$parts[0]] = $parts[1] }
    }
    if (-not $map['hostname']) { $missing += $leg; continue }

    $lines.Add('Host ' + $leg)
    $lines.Add('    HostName ' + $map['hostname'])
    if ($map['user']) { $lines.Add('    User ' + $map['user']) }
    if ($map['port']) { $lines.Add('    Port ' + $map['port']) }
    if ($map['proxycommand']) { $lines.Add('    ProxyCommand ' + $map['proxycommand']) }
    $lines.Add('    ServerAliveInterval 30')
    $lines.Add('    ServerAliveCountMax 3')
    $lines.Add('')
}
if ($missing.Count) {
    Write-Line ("хосты без описания в ssh config: " + ($missing -join ', ')) Yellow
    Write-Line "REVERSE SSH TUN сможет ходить только через описанные" Gray
}
[System.IO.File]::WriteAllLines($BeaconConfig, $lines)
Write-Line ("конфиг хостов собран: " + (Split-Path -Leaf $BeaconConfig)) Green


# 2. Порт маячка.
$wanted = $Port
if (-not $wanted -and $state) { $wanted = [int]$state.Port }
if (-not $wanted) { $wanted = Get-FreePort }
if (-not $wanted) {
    Write-Line "MAIN VPS или SECOND VPS не назвал свободный порт" Yellow
    Write-Host ''
    exit 1
}
Write-Line ("порт туннеля: {0}" -f $wanted)

# 3. Ключ на MAIN VPS или SECOND VPS - с ограничениями. `restrict` запрещает всё
#    разом, `port-forwarding` возвращает проброс портов, а `permitlisten` и
#    `permitopen` сужают его до порта этого туннеля: `-R` только на
#    127.0.0.1:<порт>, `-L` только туда же, то есть обратно в эту же машину.
#    Без них ключ разрешал и `-L` к любым адресам, видимым с VPS, и `-R` на
#    любых портах. Ни оболочки, ни агента, ни X11. Проброс unix-сокетов ключом
#    не закрыть - это `AllowStreamLocalForwarding` в настройках sshd самого VPS.
#    Держатель просит ровно `-R 127.0.0.1:<порт>:127.0.0.1:22`, а sshd сверяет
#    адрес строкой: `permitlisten` обязан называть тот же 127.0.0.1.
$pub = (Get-Content $PubFile -Raw).Trim()
$mark = 'audion-beacon-' + $Name
$line = ('restrict,port-forwarding,permitlisten="127.0.0.1:{0}",permitopen="127.0.0.1:{0}",command="/bin/false" ' -f $wanted) + $pub
# В файле живут и другие ключи - в том числе те, которыми владелец входит на
# MAIN VPS или SECOND VPS. Поэтому перед правкой снимается копия, а после
# сверяется число строк: новых должно стать ровно на одну больше прежних без
# нашей метки. Не сошлось - возвращаем прежний файл и говорим об этом. Метку
# сравниваем с комментарием ключа целиком: подстрокой `lab` задевала `lab2`.
$register = @"
set -e
id $ServerUser >/dev/null 2>&1 || { echo no-user; exit 0; }
d=/home/$ServerUser/.ssh
f=`$d/authorized_keys
mkdir -p "`$d"
touch "`$f"
cp -a "`$f" "`$f.audion-bak"
before=`$(awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k) } k != m' "`$f" | wc -l)
awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k) } k != m' "`$f" > "`$f.new"
printf '%s\n' '$line' >> "`$f.new"
after=`$(wc -l < "`$f.new")
if [ "`$after" -ne "`$((before + 1))" ]; then
    rm -f "`$f.new"
    echo "count-mismatch before=`$before after=`$after"
    exit 1
fi
mv "`$f.new" "`$f"
chown -R ${ServerUser}:${ServerUser} "`$d"
chmod 700 "`$d"; chmod 600 "`$f"
awk -v m='$mark' '{ k = `$NF; sub(/\r`$/, "", k); if (k == m) n++ } END { print n + 0 }' "`$f"
"@
$said = Invoke-Server -Command $register -ConfirmHostKey
if ($said -match 'no-user') {
    Write-Line ("на сервере нет учётной записи {0} - ключ туннеля прописывать некуда" -f $ServerUser) Yellow
    Write-Line "её заводят руками один раз на MAIN VPS и на SECOND VPS" Gray
    Write-Line "что ей разрешено - в Tunnel\RemoteDesktop\config\sshd-tunnel.sample.conf" Gray
    Write-Host ''
    exit 1
}
if ($said -notmatch '^\s*1\s*$') {
    Write-Line "ключ на MAIN VPS или SECOND VPS не прописался" Yellow
    Write-Host ''
    exit 1
}
Write-Line "ключ прописан на MAIN VPS или SECOND VPS: только проброс своего порта" Green

# 4. Запоминаем, чем живём.
# Имя MAIN VPS или SECOND VPS - для отчёта: сам проброс ходит по алиасу из ~\.ssh\config, и
# смена адреса MAIN VPS или SECOND VPS переживается сама, без правки состояния.
$first = @($Server)[0]
$hostName = (& ssh -G $first 2>$null | Where-Object { $_ -match '^hostname ' } | Select-Object -First 1) -replace '^hostname ', ''
if (-not $hostName) { $hostName = $first }
# Места, где ключ прописан: прежние и нынешнее. Снятие обходит их все - маячок,
# переведённый с MAIN VPS на SECOND VPS или обратно, иначе оставил бы ключ на первом.
$registered = New-Object System.Collections.Generic.List[string]
$before = @()
if ($state -and $state.PSObject.Properties['Registered']) { $before = @($state.Registered) }
foreach ($leg in (@($before) + @($script:LastVia))) {
    $legName = [string]$leg
    if ($legName -and -not $registered.Contains($legName)) { $registered.Add($legName) }
}
@{
    Name    = $Name
    AutoStart = $true
    Persistent = [bool]($Persistent -or ($state -and $state.Persistent))
    Port    = $wanted
    User    = $ServerUser
    Host    = $hostName
    Servers = @($Server)
    Registered = $registered.ToArray()
    Via     = $(if ($script:LastVia) { $script:LastVia } else { $first })
    KeyFile = $KeyFile
    # Свой конфиг плеч: под SYSTEM пользовательский недоступен.
    SshConfig = $BeaconConfig
    Made    = (Get-Date).ToString('s')
} | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
[void](Protect-AbkSecret -Path $StateFile)
$installed = Get-BeaconState
if ($installed.Persistent) {
    $null = Set-AbkBeaconStartup -AppRoot (Split-Path -Parent $TunnelRoot) -DataRoot $DataRoot -Name $Name -Enabled $true
}

# 5. Держатель канала. Прежде его поднимала задача планировщика - и это
#    оказалось хуже, чем ничего: задача срабатывает при входе в систему и на
#    этом успокаивается. Умер держатель - никто его не поднял, а задача всё
#    так же `Ready`, и машина считается на связи при молчащем порте.
#
#    GUI восстанавливает процесс после закрытия установочной консоли.
#    Расписания в этом хозяйстве живут таймерами на MAIN VPS.
$gone = Stop-Holders
if ($gone.Left) {
    # Новый держатель рядом с живым прежним упёрся бы в занятый порт и ждал бы
    # его вечно, а здесь было бы напечатано «поднят».
    Write-Line ("прежний процесс не остановился: осталось {0}" -f $gone.Left) Red
    foreach ($one in $gone.Refused) { Write-Line ('  ' + $one) Gray }
    Write-Host ''
    exit 1
}
if ($gone.Stopped) { Write-Line ("прежний процесс остановлен: {0}" -f $gone.Stopped) Gray }
Start-Holder
Write-Line "процесс поднят" Green

# 6. Проверка делом: порт маячка должен ожить.
Start-Sleep 6
$alive = Invoke-Server -Command ("ss -tln 2>/dev/null | grep -q '127.0.0.1:{0} ' && echo up || echo down" -f $wanted)
if ($alive -eq 'up') {
    Write-Line "порт туннеля слушает - REVERSE SSH TUN жив" Green
    Write-Host ''
    Write-Line ("входить так: ssh -J {0} -p {1} {2}@127.0.0.1" -f @($Server)[0], $wanted, $env:USERNAME) Gray
    Write-Host ''
    Write-Line "а чтобы маршрут был именем, впишите на той машине, откуда ходите:" Gray
    Write-Host ("    Host {0}-ssh" -f $Name) -ForegroundColor DarkGray
    Write-Host  "        HostName 127.0.0.1" -ForegroundColor DarkGray
    Write-Host ("        Port {0}" -f $wanted) -ForegroundColor DarkGray
    Write-Host ("        User {0}" -f $env:USERNAME) -ForegroundColor DarkGray
    Write-Host ("        ProxyJump {0}" -f @($Server)[0]) -ForegroundColor DarkGray
    Write-Host  "        ServerAliveInterval 30" -ForegroundColor DarkGray
    Write-Host ''
    Write-Line "если машина известна окну под ролью - base, laptop, work, home, -" Gray
    Write-Line ("поставьте роль первым именем: Host <роль>-ssh {0}-ssh. rclone.conf" -f $Name) Gray
    Write-Line "зовёт маршрут по роли, человек - по имени машины." Gray
} else {
    Write-Line "порт туннеля пока молчит - дайте минуту и посмотрите -Check" Yellow
}
Write-Host ''
