#requires -Version 5.1
<#
    REVERSE SSH TUN: ключ без пароля, остановка канала, выбор MAIN VPS или SECOND VPS, свой индикатор
    и VPS в подписи кнопки.

    Всё синтетическое: процессы - записи CIM без процессов, MAIN VPS и SECOND VPS - имена без
    соединений, ключ - одноразовая пара во временной папке, нигде не прописанная.
    Настоящие ключи, ssh config и каналы не трогаются.

    Возвращает 0, когда всё сходится, иначе 1.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }

$failed = 0

function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

function Get-FunctionText {
    <# Текст одной функции из файла: проверяется настоящий код, а не его копия. #>
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $found = @($ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { throw ('функция {0} не найдена в {1}' -f $Name, $Path) }
    return $found[0].Extent.Text
}

function New-FakeProcess {
    param([int]$Id, [int]$Parent, [string]$Image, [string]$Command, [datetime]$Born = (Get-Date).AddMinutes(-5))
    New-CimInstance -ClientOnly -ClassName Win32_Process -Property @{
        Name = $Image; ProcessId = [uint32]$Id; ParentProcessId = [uint32]$Parent
        CommandLine = $Command; CreationDate = $Born
    }
}

Write-Host ''
Write-Host '===== REVERSE SSH TUN ====='

$beaconScript = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
$stateScript = Join-Path $AppRoot 'Engine\Scripts\Get-BeaconState.ps1'
. (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1')
$DataRoot = 'C:\AUDIT'

# --- 1. ключ маячка - общим способом --------------------------------------------------
# Сценарий создавал ключ своим `ssh-keygen -N '""'`, и под PowerShell 7 две
# кавычки становились паролем: ключ создан, а держатель его не открывает.
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($beaconScript, [ref]$tokens, [ref]$errors)
$direct = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'ssh-keygen' }, $true))
$shared = @($ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-AbkKeyPair' }, $true))
Test-Step -Title 'ключ REVERSE SSH TUN создаётся общим способом' -Ok ($direct.Count -eq 0 -and $shared.Count -eq 1) `
    -Note ('ssh-keygen напрямую: {0}' -f $direct.Count)

. (Join-Path $AppRoot 'Engine\KeyPair.ps1')
$lab = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-beacon-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $lab -Force | Out-Null
try {
    if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) {
        $key = Join-Path $lab 'synthetic_beacon_ed25519'
        $made = New-AbkKeyPair -Path $key -Comment 'audion-test-not-authorized'
        $cipher = ''
        if (Test-Path -LiteralPath $key) {
            # Шифр закрытой половины - прямо из заголовка формата openssh-key-v1:
            # none значит «без пароля», и спрашивать ssh-keygen для этого не нужно.
            $body = ([System.IO.File]::ReadAllLines($key) | Where-Object { $_ -and $_ -notmatch '^-----' }) -join ''
            $bytes = [Convert]::FromBase64String($body)
            $length = ([int]$bytes[15] -shl 24) + ([int]$bytes[16] -shl 16) + ([int]$bytes[17] -shl 8) + [int]$bytes[18]
            $cipher = [System.Text.Encoding]::ASCII.GetString($bytes, 19, $length)
        }
        Test-Step -Title 'пара создаётся без пароля' -Ok ($made.Ok -and $cipher -eq 'none') `
            -Note ('шифр приватного ключа: {0}' -f $cipher)

        # Проверка обязана видеть пароль: пара с ним держателю не годится. И
        # ответить сразу: ssh-keygen спрашивает пароль у консоли, закрытый ввод
        # его не останавливает, и прежняя проверка висела здесь бесконечно.
        $locked = Join-Path $lab 'synthetic_locked_ed25519'
        $null = & cmd.exe /c ('ssh-keygen -q -t ed25519 -f "{0}" -N "not-empty" -C "audion-test-locked" 2>&1' -f $locked)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $lockedOpens = Test-AbkKeyOpens -Path $locked
        $clock.Stop()
        Test-Step -Title 'пара с паролем распознаётся' -Ok ((Test-Path -LiteralPath $locked) -and -not $lockedOpens)
        Test-Step -Title 'проверка пароля не ждёт ввода' -Ok ($clock.Elapsed.TotalSeconds -lt 10) `
            -Note ('секунд: {0:N1}' -f $clock.Elapsed.TotalSeconds)
        Test-Step -Title 'пара без пароля проверку проходит' -Ok (Test-AbkKeyOpens -Path $key)
    } else {
        Test-Step -Title 'пара создаётся без пароля' -Ok $true -Note 'ssh-keygen на машине нет - пропущено'
    }
} finally {
    Remove-Item -LiteralPath $lab -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 2. остановка канала ----------------------------------------------------------------
# Единственный держатель приходил из функции одиночной записью без Count, и его
# ssh переживал снятие. Отказ остановить ssh обязан делать снятие ошибкой.
Invoke-Expression (Get-FunctionText -Path $beaconScript -Name 'Get-Holders')
Invoke-Expression (Get-FunctionText -Path $beaconScript -Name 'Stop-Holders')
$Name = 'audit'
function Reset-Fakes {
    $script:fakes = @{
        970001 = (New-FakeProcess -Id 970001 -Parent 0 -Image 'pwsh.exe' -Command 'pwsh -File C:\AUDIT\Setup-SshBeacon.ps1 -Hold -Name audit -Root C:\AUDIT')
        970002 = (New-FakeProcess -Id 970002 -Parent 970001 -Image 'ssh.exe' -Command 'ssh -N -R 127.0.0.1:22000:127.0.0.1:22 audit-server')
        970099 = (New-FakeProcess -Id 970099 -Parent 0 -Image 'ssh.exe' -Command 'ssh unrelated-session')
        970010 = (New-FakeProcess -Id 970010 -Parent 0 -Image 'pwsh.exe' -Command 'pwsh -File C:\OTHER\Setup-SshBeacon.ps1 -Hold -Name audit -Root C:\OTHER')
        970011 = (New-FakeProcess -Id 970011 -Parent 970010 -Image 'ssh.exe' -Command 'ssh -N -R 127.0.0.1:22000:127.0.0.1:22 other-server')
    }
    $script:refuse = 0
}
function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) @($script:fakes.Values) }
function Stop-Process {
    param($Id, [switch]$Force, $ErrorAction)
    if ($script:refuse -and [int]$Id -eq $script:refuse) { throw 'test: refused' }
    [void]$script:fakes.Remove([int]$Id)
}
function Start-Sleep { param($Seconds, $Milliseconds) }

Reset-Fakes
$gone = Stop-Holders
Test-Step -Title 'единственный процесс туннеля уходит вместе с ssh' `
    -Ok ($gone.Left -eq 0 -and -not $script:fakes.ContainsKey(970002) -and -not $script:fakes.ContainsKey(970001)) `
    -Note ('остановлено {0}, осталось {1}' -f $gone.Stopped, $gone.Left)
Test-Step -Title 'чужой ssh не тронут' -Ok ($script:fakes.ContainsKey(970099))
Test-Step -Title 'то же имя в другой DATA и его ssh не тронуты' -Ok ($script:fakes.ContainsKey(970010) -and $script:fakes.ContainsKey(970011))

Reset-Fakes
$script:refuse = 970002
$gone = Stop-Holders
Test-Step -Title 'не остановленный ssh - это не снятие' -Ok ($gone.Left -eq 1 -and @($gone.Refused).Count -eq 1) `
    -Note ('осталось {0}' -f $gone.Left)
Remove-Item Function:\Get-CimInstance, Function:\Stop-Process, Function:\Start-Sleep

# --- 3. куда идут осмотр и снятие ----------------------------------------------------------
# Оба шли на плечи по умолчанию, к MAIN VPS: маячок, заведённый через SECOND VPS,
# снимался «успешно», а его ключ оставался на SECOND VPS.
Invoke-Expression (Get-FunctionText -Path $beaconScript -Name 'Get-BeaconLegs')
Invoke-Expression (Get-FunctionText -Path $beaconScript -Name 'Test-BeaconRemoved')
$saved = [pscustomobject]@{ Servers = @('second-leg', 'main-direct', 'main-cf'); Via = 'main-cf'; Registered = @('second-leg') }
$checkLegs = @(Get-BeaconLegs -State $saved -For check)
$removeLegs = @(Get-BeaconLegs -State $saved -For remove)
Test-Step -Title 'осмотр начинается с хоста, через который держится канал' -Ok ($checkLegs[0] -eq 'main-cf' -and $checkLegs.Count -eq 3) `
    -Note ($checkLegs -join ' -> ')
Test-Step -Title 'снятие начинается с места регистрации' -Ok ($removeLegs[0] -eq 'second-leg' -and $removeLegs.Count -eq 3) `
    -Note ($removeLegs -join ' -> ')
Test-Step -Title 'явный -Server сильнее состояния' `
    -Ok ((@(Get-BeaconLegs -State $saved -Explicit @('chosen') -For remove) -join ',') -eq 'chosen')
Test-Step -Title 'без состояния хостов нет' -Ok (@(Get-BeaconLegs -State $null -For check).Count -eq 0)

$verdict = Test-BeaconRemoved -Answers ([ordered]@{ 'second-leg' = ''; 'main-direct' = 'absent' }) -Places @('second-leg')
Test-Step -Title '«ключа нет» оттуда, где ключ не прописывали, - не снятие' -Ok ((-not $verdict.Done) -and @($verdict.Missed) -contains 'second-leg')
$verdict = Test-BeaconRemoved -Answers ([ordered]@{ 'second-leg' = 'removed'; 'main-direct' = '' }) -Places @('second-leg')
Test-Step -Title 'место регистрации ответило - снято' -Ok $verdict.Done
$verdict = Test-BeaconRemoved -Answers ([ordered]@{ 'a' = 'absent'; 'b' = '' }) -Places @()
Test-Step -Title 'прежнее состояние: молчание - не снятие' -Ok (-not $verdict.Done)
$verdict = Test-BeaconRemoved -Answers ([ordered]@{ 'a' = 'removed'; 'b' = '' }) -Places @()
Test-Step -Title 'прежнее состояние: убрано хоть где-то' -Ok $verdict.Done

# --- 4. точка окна: свой канал, а не номер порта --------------------------------------------
# Точку SSH TUN окну говорит сценарий Engine\Scripts\Get-BeaconState.ps1 (JSON). Он гоняется
# здесь целиком, в этом же процессе: процессы Windows ему подменяет функция Get-CimInstance.
function Get-BeaconDot {
    $global:LASTEXITCODE = 0
    $said = @(& $stateScript -Root $data 6>&1 2>&1 | ForEach-Object { "$_" })
    return (($said | Where-Object { $_.StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json)
}
$computer = "$env:COMPUTERNAME".ToLower()
$data = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-beacon-data-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $stateDir = Join-Path $data 'Tunnel\SSH\beacon'
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    $ownKey = 'C:\AUDIT\own_beacon_ed25519'
    $stateFile = Join-Path $stateDir ($computer + '.beacon.json')
    [System.IO.File]::WriteAllText($stateFile, (@{ Port = 22000; Via = 'second-leg'; KeyFile = $ownKey } | ConvertTo-Json))

    $holderLine = 'pwsh -NoProfile -File "C:\AUDIT\Setup-SshBeacon.ps1" -Hold -Name {0} -Root "{1}"' -f $computer,$data
    $foreignLine = 'ssh -N -i C:\AUDIT\foreign.key -R 127.0.0.1:22000:127.0.0.1:22 unrelated-server'
    $ownLine = 'ssh -N -T -i "{0}" -R 127.0.0.1:22000:127.0.0.1:22 second-leg' -f $ownKey
    function global:Get-CimInstance {
        param($ClassName, $Filter, $ErrorAction)
        if ("$Filter" -like '*ssh.exe*') { @($global:AbkTestSsh) } else { @($global:AbkTestHolders) }
    }

    $global:AbkTestHolders = @()
    $global:AbkTestSsh = @(New-FakeProcess -Id 971099 -Parent 0 -Image 'ssh.exe' -Command $foreignLine)
    $foreign = Get-BeaconDot
    Test-Step -Title 'чужой проброс с тем же портом - не свой' -Ok ($foreign.made -and -not $foreign.alive -and -not $foreign.holder)

    $global:AbkTestHolders = @(New-FakeProcess -Id 971001 -Parent 0 -Image 'pwsh.exe' -Command $holderLine)
    $global:AbkTestSsh = @(
        (New-FakeProcess -Id 971099 -Parent 0 -Image 'ssh.exe' -Command $foreignLine),
        (New-FakeProcess -Id 971002 -Parent 971001 -Image 'ssh.exe' -Command $ownLine)
    )
    $own = Get-BeaconDot
    Test-Step -Title 'ssh своего процесса - канал держится' -Ok ($own.holder -and $own.alive)

    $global:AbkTestSsh = @(New-FakeProcess -Id 971002 -Parent 971001 -Image 'ssh.exe' -Command $ownLine -Born (Get-Date))
    $young = Get-BeaconDot
    Test-Step -Title 'только что поднятый ssh ещё не держит' -Ok ($young.starting -and -not $young.alive)

    $global:AbkTestSsh = @(New-FakeProcess -Id 971002 -Parent 971001 -Image 'ssh.exe' -Command ($ownLine -replace [regex]::Escape($ownKey), 'C:\AUDIT\other_key'))
    $otherKey = Get-BeaconDot
    Test-Step -Title 'чужой ключ у дочернего ssh процесса - не свой' -Ok ($otherKey.holder -and -not $otherKey.alive)

    # --- 5. VPS в подписи кнопки ------------------------------------------------------------
    # Канал, заведённый через SECOND VPS, уходит на MAIN VPS, когда SECOND VPS молчит.
    # Подпись называет VPS по имени хоста из состояния и о незнакомом не гадает.
    $global:AbkTestHolders = @()
    $global:AbkTestSsh = @()
    $targetsFile = Join-Path $data 'Tunnel\RemoteDesktop\config\targets.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $targetsFile) -Force | Out-Null
    [System.IO.File]::WriteAllText($targetsFile, '{ "second": { "host": "192.0.2.20", "sshHost": "second-leg", "sshHostCf": "second-leg-cf" } }')
    function Get-VpsOf([string]$Via) {
        [System.IO.File]::WriteAllText($stateFile, (@{ Port = 22000; Via = $Via; KeyFile = $ownKey } | ConvertTo-Json))
        return [string](Get-BeaconDot).vps
    }
    Test-Step -Title 'хост SECOND VPS из targets.json - SECOND VPS' -Ok ((Get-VpsOf 'second-leg') -eq 'SECOND VPS')
    Test-Step -Title 'его имя поверх cloudflared - тоже SECOND VPS' -Ok ((Get-VpsOf 'second-leg-cf') -eq 'SECOND VPS')
    Test-Step -Title 'audion-vps-direct и audion-vps - MAIN VPS' `
        -Ok ((Get-VpsOf 'audion-vps-direct') -eq 'MAIN VPS' -and (Get-VpsOf 'audion-vps') -eq 'MAIN VPS')
    Test-Step -Title 'незнакомый хост - без VPS' -Ok ((Get-VpsOf 'somewhere-else') -eq '')
} finally {
    Remove-Item -Path Function:\global:Get-CimInstance -ErrorAction SilentlyContinue
    Remove-Variable -Name AbkTestHolders, AbkTestSsh -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 6. ключ туннеля на VPS: своя строка и только свой порт ----------------------------------
# Регистрация и снятие ключа идут на VPS сценариями bash. Метка раньше искалась
# подстрокой, и ключ `lab` уносил с собой ключ машины `lab2`, а проверка числа
# строк этого не видела. Здесь настоящие тексты этих сценариев из
# Setup-SshBeacon.ps1 гоняются в Git Bash на синтетическом файле: подменён путь,
# заглушён chown, остальное - как на сервере.
$beaconTokens = $null
$beaconErrors = $null
$beaconAst = [System.Management.Automation.Language.Parser]::ParseFile($beaconScript, [ref]$beaconTokens, [ref]$beaconErrors)
function Get-AssignmentText {
    <# Текст присваивания переменной в сценарии; -Contains отбирает нужное среди одноимённых. #>
    param([string]$Variable, [string]$Contains = '')
    $found = @($beaconAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq ('$' + $Variable) -and $node.Extent.Text.Contains($Contains) }, $true))
    if ($found.Count) { return $found[0].Extent.Text }
    return ''
}

$Name = 'lab'
$ServerUser = 'synthetic'
$wanted = 22000
$pub = 'ssh-ed25519 AAAANEW audion-beacon-lab'
$mark = 'audion-beacon-' + $Name
$line = ''
$lineText = Get-AssignmentText -Variable 'line' -Contains 'restrict,'
if ($lineText) { Invoke-Expression $lineText }
Test-Step -Title 'ключ туннеля ограничен своим портом' `
    -Ok ($line -like 'restrict,*' -and $line.Contains('permitlisten="127.0.0.1:22000"') -and $line.Contains('permitopen="127.0.0.1:22000"')) `
    -Note $(if ($line) { $line.Substring(0, [Math]::Min(96, $line.Length)) } else { 'строка ключа в сценарии не найдена' })

# Учётная запись сервера - своя у туннеля, не рабочая: в неё упирается
# украденный ключ туннеля. Вернуть сюда рабочего пользователя значит вернуть
# ключу его файлы, группы и служебные сокеты.
$tunnelAccount = ''
$accountText = Get-AssignmentText -Variable 'ServerUser'
if ($accountText -match "=\s*'([^']+)'") { $tunnelAccount = $Matches[1] }
Test-Step -Title 'ключ туннеля живёт в своей учётной записи' -Ok ($tunnelAccount -eq 'tunnel') `
    -Note ('учётная запись на сервере: {0}' -f $(if ($tunnelAccount) { $tunnelAccount } else { 'не найдена' }))

$bashExe = @((Join-Path $env:ProgramFiles 'Git\bin\bash.exe'), 'C:\Program Files\Git\bin\bash.exe') |
    Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if ($bashExe) {
    Invoke-Expression (Get-AssignmentText -Variable 'register')
    Invoke-Expression (Get-AssignmentText -Variable 'purge')
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-beacon-keys-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $fixture = "ssh-ed25519 AAAAOLD audion-beacon-lab`nssh-ed25519 AAAAOTHER audion-beacon-lab2`nssh-ed25519 AAAAOWNER owner-admin`n"
        $outcome = @{}
        foreach ($action in 'register', 'purge') {
            $dir = Join-Path $sandbox $action
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $keysFile = Join-Path $dir 'authorized_keys'
            [System.IO.File]::WriteAllText($keysFile, $fixture, (New-Object System.Text.UTF8Encoding $false))
            $body = (Get-Variable -Name $action -ValueOnly).Replace('/home/synthetic/.ssh', '.').Replace("`r`n", "`n")
            [System.IO.File]::WriteAllText((Join-Path $dir 'run.sh'), "chown() { :; }`nid() { :; }`n" + $body + "`n", (New-Object System.Text.UTF8Encoding $false))
            Push-Location -LiteralPath $dir
            try { $said = @(& $bashExe --noprofile --norc ./run.sh 2>&1) } finally { Pop-Location }
            $outcome[$action] = @{
                Said = (@($said | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
                Left = [System.IO.File]::ReadAllText($keysFile)
            }
        }
        $reg = $outcome['register']
        Test-Step -Title 'регистрация меняет только свою строку' `
            -Ok ($reg.Said -eq '1' -and $reg.Left.Contains('audion-beacon-lab2') -and $reg.Left.Contains('owner-admin') -and
                 -not $reg.Left.Contains('AAAAOLD') -and $reg.Left.Contains('permitlisten')) `
            -Note ('ответ сценария: {0}' -f $reg.Said)
        $gone = $outcome['purge']
        Test-Step -Title 'снятие убирает только свою строку' `
            -Ok ($gone.Said -eq 'removed' -and $gone.Left.Contains('audion-beacon-lab2') -and $gone.Left.Contains('owner-admin') -and
                 -not $gone.Left.Contains('AAAAOLD')) `
            -Note ('ответ сценария: {0}' -f $gone.Said)

        # Сбой файловой операции при снятии не должен обнулить файл и выдать
        # успех: без set -e $purge печатал removed после любого исхода, а
        # держатель наверху принимал это за снятие и стирал состояние. Ломаем
        # mv - с set -e сценарий обрывается до echo, прежний файл цел.
        $failDir = Join-Path $sandbox 'purge-mv-fails'
        New-Item -ItemType Directory -Path $failDir -Force | Out-Null
        $failKeys = Join-Path $failDir 'authorized_keys'
        [System.IO.File]::WriteAllText($failKeys, $fixture, (New-Object System.Text.UTF8Encoding $false))
        $purgeBody = (Get-Variable -Name 'purge' -ValueOnly).Replace('/home/synthetic/.ssh', '.').Replace("`r`n", "`n")
        [System.IO.File]::WriteAllText((Join-Path $failDir 'run.sh'),
            "chown() { :; }`nid() { :; }`nmv() { return 1; }`n" + $purgeBody + "`n",
            (New-Object System.Text.UTF8Encoding $false))
        Push-Location -LiteralPath $failDir
        try { $failSaid = @(& $bashExe --noprofile --norc ./run.sh 2>&1) } finally { Pop-Location }
        $failText = (@($failSaid | ForEach-Object { "$_".Trim() }) -join ' ').Trim()
        $failLeft = [System.IO.File]::ReadAllText($failKeys)
        Test-Step -Title 'сбой снятия не рушит файл и не выдаёт успех' `
            -Ok ($failText -notmatch 'removed' -and $failLeft.Contains('AAAAOLD') -and
                 $failLeft.Contains('audion-beacon-lab2') -and $failLeft.Contains('owner-admin')) `
            -Note ('ответ: {0}' -f $(if ($failText) { $failText } else { '(пусто)' }))
    } finally {
        $ErrorActionPreference = $was
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} else {
    Test-Step -Title 'регистрация и снятие ключа туннеля' -Ok $true -Note 'Git Bash на машине нет - пропущено'
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
