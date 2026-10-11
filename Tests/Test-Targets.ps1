#requires -Version 5.1
<#
    Проверка записи адреса в targets.json.

    Мастер адресов правит файл текстом, а не пересобирает его из объекта:
    пересборка теряет порядок ключей и пояснения, ради которых файл и написан
    по-человечески. Тест следит, что правится ровно одна цель и что всё
    остальное - соседние точки, пояснения, отступы и BOM - остаётся на месте.

    Рабочий файл не трогается: всё делается на копии во временной папке.
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
Write-Host '===== АДРЕСА ====='

# Исходник - образец из сборки, а не рабочий файл машины: рабочий в историю не
# входит, и на чистой копии исходников тест падал первой же строкой, не дойдя
# до проверок.
$source = Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json'
$copy = Join-Path ([System.IO.Path]::GetTempPath()) ('targets-test-{0}.json' -f $PID)
Copy-Item -LiteralPath $source -Destination $copy -Force

try {
    $before = Get-Content -LiteralPath $copy -Raw | ConvertFrom-Json
    $ok = Set-AbkTargetEntry -Path $copy -Key 'home' -Address '10.20.30.40' -Port 2222 -User 'Audion'
    Test-Step -Title 'адрес записывается' -Ok $ok

    $raw = Get-Content -LiteralPath $copy -Raw
    $after = $raw | ConvertFrom-Json

    Test-Step -Title 'адрес встал в поле lan' -Ok ($after.home.lan -eq '10.20.30.40') -Note $after.home.lan
    Test-Step -Title 'пустой host заполнен тем же адресом' -Ok ($after.home.host -eq '10.20.30.40')
    Test-Step -Title 'порт записан' -Ok ([int]$after.home.sshPort -eq 2222) -Note $after.home.sshPort

    $moved = @()
    foreach ($key in 'base', 'laptop', 'server', 'second', 'work', 'router-base', 'router-home', 'router-work') {
        $was = '{0}|{1}|{2}|{3}' -f $before.$key.lan, $before.$key.host, $before.$key.sshPort, $before.$key.user
        $now = '{0}|{1}|{2}|{3}' -f $after.$key.lan, $after.$key.host, $after.$key.sshPort, $after.$key.user
        if ($was -ne $now) { $moved += $key }
    }
    Test-Step -Title 'соседние цели не тронуты' -Ok (-not $moved.Count) -Note ($moved -join ', ')

    Test-Step -Title 'пояснения в файле целы' -Ok ($raw -like '*_comment*')
    Test-Step -Title 'число строк не изменилось' `
        -Ok ((Get-Content -LiteralPath $copy).Count -eq (Get-Content -LiteralPath $source).Count)

    $bytes = [System.IO.File]::ReadAllBytes($copy)
    Test-Step -Title 'BOM на месте' -Ok ($bytes[0] -eq 0xEF)

    # Несуществующая цель - не повод переписать файл наугад.
    $stamp = (Get-Item -LiteralPath $copy).LastWriteTime
    $wrote = Set-AbkTargetEntry -Path $copy -Key 'нет-такой-цели' -Address '1.2.3.4'
    Test-Step -Title 'чужой ключ не пишется' `
        -Ok ((-not $wrote) -and ((Get-Item -LiteralPath $copy).LastWriteTime -eq $stamp))

    # У SECOND VPS домашнего адреса нет: мастер пишет ему host, а lan
    # оставляет пустым.
    $wroteSecond = Set-AbkTargetEntry -Path $copy -Key 'second' -Address '203.0.113.7' -Port 22 -User 'root' -Field 'host'
    $secondBack = Get-Content -LiteralPath $copy -Raw | ConvertFrom-Json
    Test-Step -Title 'SECOND VPS пишется host, а не lan' `
        -Ok ($wroteSecond -and $secondBack.second.host -eq '203.0.113.7' -and -not $secondBack.second.lan) `
        -Note ('host: {0}' -f $secondBack.second.host)
} finally {
    Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# --- чистая установка ---------------------------------------------------------
# targets.json - не только данные, но и каркас: в нём заведены сами машины.
# Сборка его не везёт (адреса чужие), поэтому рядом едет образец, а программа
# разворачивает его при первом запуске. Без этого кнопка АДРЕСА нажимается
# впустую: запись правит текст файла и на отсутствующем молча отвечает «не
# удалось» - ровно так чистая установка и встала на рабочей машине.
$sample = Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json'
Test-Step -Title 'образец адресов лежит в сборке' -Ok (Test-Path -LiteralPath $sample) `
    -Note 'targets.sample.json'

if (Test-Path -LiteralPath $sample) {
    $text = Get-Content -LiteralPath $sample -Raw
    $filled = [regex]::Matches($text, '"(?:lan|host|user)"\s*:\s*"(?<value>[^"]+)"')
    Test-Step -Title 'в образце нет чужих адресов' -Ok ($filled.Count -eq 0) `
        -Note $(if ($filled.Count) { 'осталось: ' + (($filled | ForEach-Object { $_.Groups['value'].Value }) -join ', ') } else { 'все поля пусты' })

    foreach ($name in @('base', 'laptop', 'work', 'home', 'server')) {
        if ($text -notmatch ('"{0}"\s*:' -f $name)) {
            Test-Step -Title ('в образце заведена {0}' -f $name.ToUpper()) -Ok $false
        }
    }
    Test-Step -Title 'в образце заведены все машины' -Ok $true -Note 'base, laptop, work, home, server'
    Test-Step -Title 'в образце заведён SECOND VPS' -Ok ($text -match '"second"\s*:') -Note 'SECOND VPS'
}

$bare = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-bare-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path (Join-Path $bare 'Tunnel\RemoteDesktop\config') -Force | Out-Null
    if (Test-Path -LiteralPath $sample) {
        Copy-Item -LiteralPath $sample -Destination (Join-Path $bare 'Tunnel\RemoteDesktop\config\targets.sample.json')
    }

    $made = Restore-AbkTargetsFile -AppRoot $bare -DataRoot $bare
    $live = Join-Path $bare 'Tunnel\RemoteDesktop\config\targets.json'
    Test-Step -Title 'каркас разворачивается при первом запуске' -Ok ([bool]$made -and (Test-Path -LiteralPath $live)) `
        -Note 'из образца рядом'

    . (Join-Path $AppRoot 'Engine\Targets.ps1')
    # Свой ssh config здесь не читается: у машины, где идёт проверка, SECOND VPS
    # может быть прописан, и ответ зависел бы от неё, а не от образца.
    $vps = Get-AbkSecondVps -AppRoot $bare -DataRoot $bare -SshConfig (Join-Path $bare 'ssh-config-none')
    Test-Step -Title 'SECOND VPS без адреса, имена нейтральные' `
        -Ok ((-not $vps.Host) -and $vps.SshHost -eq 'second-vps' -and $vps.Key -eq 'second_vps_ed25519') `
        -Note ('{0}, {1}' -f $vps.SshHost, $vps.Key)

    $wrote = Set-AbkTargetEntry -Path $live -Key 'work' -Address '192.168.50.7' -Port 22 -User 'worker'
    Test-Step -Title 'адрес пишется сразу после распаковки' -Ok $wrote `
        -Note 'то, что не сработало на рабочей машине'

    if ($wrote) {
        $back = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json
        Test-Step -Title 'записанное читается обратно' -Ok ($back.work.lan -eq '192.168.50.7') `
            -Note ('work.lan: {0}' -f $back.work.lan)
    }

    # Повторный запуск не должен затирать вписанное.
    $again = Restore-AbkTargetsFile -AppRoot $bare -DataRoot $bare
    $kept = Get-Content -LiteralPath $live -Raw | ConvertFrom-Json
    Test-Step -Title 'второй запуск не затирает адреса' -Ok ((-not $again) -and ($kept.work.lan -eq '192.168.50.7')) `
        -Note 'разворачивается только отсутствующее'
} finally {
    Remove-Item -LiteralPath $bare -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# --- перенос SECOND VPS ---------------------------------------------------
# Машина, настроенная до записи second, держит SECOND VPS только в своём
# ~\.ssh\config: так его прописывал клиент туннеля. Без переноса сборка
# транспорта брала образцовое имя second-vps - хост, которого нет нигде, - и
# панель SECOND VPS замолкала после первого же нажатия RCLONE.CONF. Всё
# здесь синтетическое: адреса из документационных сетей, имена выдуманные.
$legacy = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-legacy-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $conf = Join-Path $legacy 'Tunnel\RemoteDesktop\config'
    New-Item -ItemType Directory -Path $conf -Force | Out-Null
    Copy-Item -LiteralPath $sample -Destination (Join-Path $conf 'targets.sample.json')

    # Прежний файл целей: тот же образец, только без записи second.
    $model = [System.IO.File]::ReadAllText($sample)
    $cut = $model.IndexOf('  "second":')
    $rest = $model.IndexOf('  "base":', $cut)
    $old = $model.Substring(0, $cut) + $model.Substring($rest)
    $oldTargets = Join-Path $conf 'targets.json'
    [System.IO.File]::WriteAllText($oldTargets, $old, [System.Text.UTF8Encoding]::new($true))

    # Прежний ssh config: блок клиента туннеля с тремя хостами, рядом тот же
    # SECOND VPS прыжком через главный и одна из машин.
    $sshConfig = Join-Path $legacy 'ssh-config'
    [System.IO.File]::WriteAllLines($sshConfig, [string[]]@(
        '# >>> audion-tunnel >>>',
        'Host audion-vps',
        '    HostName ssh.example.invalid',
        '    User root',
        'Host audion-vps-direct',
        '    HostName direct.example.invalid',
        '    User root',
        'Host old-second',
        '    HostName 192.0.2.20',
        '    User audit',
        '    IdentityFile ~/.ssh/old_second_ed25519',
        '# <<< audion-tunnel <<<',
        'Host old-second-via',
        '    HostName 192.0.2.20',
        '    ProxyJump audion-vps',
        'Host old-second-cf',
        '    HostName 192.0.2.20',
        '    ProxyJump audion-vps',
        'Host base',
        '    HostName 192.168.50.10',
        '    ProxyJump old-second'
    ))
    $noConfig = Join-Path $legacy 'ssh-config-none'

    $found = Get-AbkSecondVps -AppRoot $legacy -DataRoot $legacy -SshConfig $sshConfig
    Test-Step -Title 'SECOND VPS найден в прежнем ssh config' `
        -Ok ($found.Source -eq 'ssh-config' -and $found.SshHost -eq 'old-second' -and $found.Host -eq '192.0.2.20') `
        -Note ('{0} -> {1}' -f $found.SshHost, $found.Host)
    Test-Step -Title 'вариант поверх cloudflared - имя на -cf' -Ok ($found.SshHostCf -eq 'old-second-cf') `
        -Note $found.SshHostCf
    Test-Step -Title 'ключ и учётная запись - оттуда же' `
        -Ok ($found.Key -eq 'old_second_ed25519' -and $found.User -eq 'audit') `
        -Note ('{0}, {1}' -f $found.Key, $found.User)

    $moved = Update-AbkSecondVpsEntry -AppRoot $legacy -DataRoot $legacy -SshConfig $sshConfig
    $movedText = [System.IO.File]::ReadAllText($oldTargets)
    $movedBack = $movedText | ConvertFrom-Json
    Test-Step -Title 'запись second перенесена в targets.json' `
        -Ok ($moved -eq 'ssh-config' -and $movedBack.second.sshHost -eq 'old-second' -and
             $movedBack.second.host -eq '192.0.2.20' -and $movedBack.second.sshHostCf -eq 'old-second-cf') `
        -Note $moved
    $order = @($movedBack.PSObject.Properties | ForEach-Object { $_.Name })
    Test-Step -Title 'запись встала следом за MAIN VPS' `
        -Ok (([array]::IndexOf($order, 'second') - [array]::IndexOf($order, 'server')) -eq 1) `
        -Note ($order -join ', ')
    Test-Step -Title 'соседние записи и пояснения целы' `
        -Ok ([int]$movedBack.base.localSsh -eq 13022 -and [bool]$movedBack.'router-base' -and $movedText -like '*_comment*')
    Test-Step -Title 'BOM после переноса на месте' -Ok ([System.IO.File]::ReadAllBytes($oldTargets)[0] -eq 0xEF)

    $again = Update-AbkSecondVpsEntry -AppRoot $legacy -DataRoot $legacy -SshConfig $sshConfig
    Test-Step -Title 'повторный запуск ничего не переносит' -Ok (-not $again)

    $resolved = Get-AbkSecondVps -AppRoot $legacy -DataRoot $legacy -SshConfig $noConfig
    Test-Step -Title 'дальше SECOND VPS читается из записи' `
        -Ok ($resolved.Source -eq 'targets' -and $resolved.SshHost -eq 'old-second') -Note $resolved.Source

    [void](Set-AbkTargetEntry -Path $oldTargets -Key 'second' -Address '198.51.100.9' -Field 'host')
    $kept = Update-AbkSecondVpsEntry -AppRoot $legacy -DataRoot $legacy -SshConfig $sshConfig
    $still = Get-Content -LiteralPath $oldTargets -Raw | ConvertFrom-Json
    Test-Step -Title 'вписанный адрес ничем не перетирается' `
        -Ok ((-not $kept) -and $still.second.host -eq '198.51.100.9') -Note $still.second.host

    # Машина без прежнего SECOND VPS получает пустую запись из образца.
    [System.IO.File]::WriteAllText($oldTargets, $old, [System.Text.UTF8Encoding]::new($true))
    $empty = Update-AbkSecondVpsEntry -AppRoot $legacy -DataRoot $legacy -SshConfig $noConfig
    $blank = Get-Content -LiteralPath $oldTargets -Raw | ConvertFrom-Json
    Test-Step -Title 'без прежнего SECOND VPS запись заводится пустой' `
        -Ok ($empty -eq 'sample' -and [bool]$blank.second -and -not $blank.second.host -and $blank.second.sshHost -eq 'second-vps') `
        -Note $empty

    # Пустая запись дозаполняется, когда ssh config знает SECOND VPS.
    $filled = Update-AbkSecondVpsEntry -AppRoot $legacy -DataRoot $legacy -SshConfig $sshConfig
    $full = Get-Content -LiteralPath $oldTargets -Raw | ConvertFrom-Json
    Test-Step -Title 'пустая запись дозаполняется из ssh config' `
        -Ok ($filled -eq 'ssh-config' -and $full.second.host -eq '192.0.2.20' -and $full.second.key -eq 'old_second_ed25519') `
        -Note $filled
} finally {
    Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
# --- ssh config: Include, порт, имена --------------------------------------------
# Имя, описанное во включённом файле, ssh знает, а поиск строки Host в одном
# файле его не видел - и сборка транспорта затирала рабочий хост меткой. Порт
# SECOND VPS из мастера АДРЕСА обязан дойти до резолвера: иначе клиент
# туннеля и пробы ходят на 22.
$sshLab = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-sshlab-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory -Path $sshLab -Force | Out-Null
    $included = Join-Path $sshLab 'hosts.conf'
    [System.IO.File]::WriteAllLines($included, [string[]]@(
        'Host inc-second',
        '    HostName 192.0.2.21',
        '    Port 2200'
    ))
    $mainConfig = Join-Path $sshLab 'config'
    [System.IO.File]::WriteAllLines($mainConfig, [string[]]@(
        ('Include "{0}"' -f ($included -replace '\\', '/')),
        'Host plain-host',
        '    HostName 192.0.2.22'
    ))

    $seen = @(Read-AbkSshConfig -Path $mainConfig)
    $inc = @($seen | Where-Object { $_.Names -contains 'inc-second' })
    Test-Step -Title 'Include раскрывается при разборе' -Ok ($inc.Count -eq 1 -and $inc[0].HostName -eq '192.0.2.21') `
        -Note ('хостов: {0}' -f $seen.Count)
    Test-Step -Title 'порт из ssh config читается' -Ok ($inc.Count -eq 1 -and [int]$inc[0].Port -eq 2200)
    Test-Step -Title 'имя из включённого файла известно' -Ok (Test-AbkSshHost -Name 'inc-second' -Path $mainConfig)
    Test-Step -Title 'неописанное имя неизвестно' -Ok (-not (Test-AbkSshHost -Name 'nobody-here' -Path $mainConfig))

    # Порт SECOND VPS - из записи.
    $portApp = Join-Path $sshLab 'app'
    $portConf = Join-Path $portApp 'Tunnel\RemoteDesktop\config'
    New-Item -ItemType Directory -Path $portConf -Force | Out-Null
    $portTargets = Join-Path $portConf 'targets.json'
    Copy-Item -LiteralPath $sample -Destination $portTargets
    [void](Set-AbkTargetEntry -Path $portTargets -Key 'second' -Address '203.0.113.9' -Port 2222 -Field 'host')
    $portVps = Get-AbkSecondVps -AppRoot $portApp -DataRoot $portApp -SshConfig (Join-Path $sshLab 'none')
    Test-Step -Title 'порт SECOND VPS доходит до резолвера' -Ok ([int]$portVps.Port -eq 2222) -Note $portVps.Port

    # Порт - и из прежнего ssh config при переносе.
    $legacyConfig = Join-Path $sshLab 'legacy-config'
    [System.IO.File]::WriteAllLines($legacyConfig, [string[]]@(
        '# >>> audion-tunnel >>>',
        'Host audion-vps',
        '    HostName ssh.example.invalid',
        'Host port-second',
        '    HostName 192.0.2.30',
        '    Port 2022',
        '    User audit',
        '# <<< audion-tunnel <<<'
    ))
    $legacyApp = Join-Path $sshLab 'legacy-app'
    $legacyConf = Join-Path $legacyApp 'Tunnel\RemoteDesktop\config'
    New-Item -ItemType Directory -Path $legacyConf -Force | Out-Null
    Copy-Item -LiteralPath $sample -Destination (Join-Path $legacyConf 'targets.sample.json')
    $template = [System.IO.File]::ReadAllText($sample)
    $cutAt = $template.IndexOf('  "second":')
    $withoutSecond = $template.Substring(0, $cutAt) + $template.Substring($template.IndexOf('  "base":', $cutAt))
    [System.IO.File]::WriteAllText((Join-Path $legacyConf 'targets.json'), $withoutSecond, [System.Text.UTF8Encoding]::new($true))
    $movedPort = Update-AbkSecondVpsEntry -AppRoot $legacyApp -DataRoot $legacyApp -SshConfig $legacyConfig
    $portBack = Get-Content -LiteralPath (Join-Path $legacyConf 'targets.json') -Raw | ConvertFrom-Json
    Test-Step -Title 'перенос забирает и порт' -Ok ($movedPort -eq 'ssh-config' -and [int]$portBack.second.sshPort -eq 2022) `
        -Note $portBack.second.sshPort

    # Имена SECOND VPS правятся мастером адресов.
    $namesOk = Set-AbkSecondVpsNames -Path $portTargets -SshHost 'my-second' -SshHostCf 'my-second-cf' -Key 'my_second_ed25519'
    $namesBack = Get-Content -LiteralPath $portTargets -Raw | ConvertFrom-Json
    Test-Step -Title 'имена SECOND VPS пишутся в запись' `
        -Ok ($namesOk -and $namesBack.second.sshHost -eq 'my-second' -and $namesBack.second.sshHostCf -eq 'my-second-cf' -and
             $namesBack.second.key -eq 'my_second_ed25519')
    $namesAgain = Set-AbkSecondVpsNames -Path $portTargets -SshHost 'my-second'
    Test-Step -Title 'те же имена второй раз ничего не меняют' -Ok (-not $namesAgain)
} finally {
    Remove-Item -LiteralPath $sshLab -Recurse -Force -ErrorAction SilentlyContinue
}


if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
