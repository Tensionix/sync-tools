<#
    Облака и ключи доступа к ним.

    Ключ доступа к облаку - это не пароль от аккаунта, а выданная облаком
    строка, по которой программа ходит вместо человека. Украсть её - значит
    получить доступ к файлам, поэтому в общем `rclone.conf` ей не место: тот
    файл лежит открытым, его копируют между машинами.

    Отсюда отдельная пара файлов в `config\rclone`:

        clouds.conf   конфиг rclone только под облака, зашифрованный им самим
        clouds.key    пароль от этого конфига, запечатанный DPAPI

    DPAPI запечатывает на текущего пользователя этой машины: скопированный
    на другую машину или открытый другим пользователем файл не расшифруется.
    Пароль в открытом виде не хранится нигде и в командную строку не попадает
    - rclone получает его через переменную окружения на время вызова.

    Здесь только хранение. Заводит облака мастер окна: вход делает сам человек
    в браузере, программа не видит ни логина, ни пароля от аккаунта.
#>

# Рабочие файлы облаков живут в папке данных: резолвер оттуда.
. (Join-Path $PSScriptRoot 'DataRoot.ps1')

function Get-AbkCloudsPath {
    <# Конфиг облаков. Рядом с обычным, но своим файлом. #>
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)
    return (Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\clouds.conf')
}

function Get-AbkCloudsKeyPath {
    <# Запечатанный пароль от конфига облаков. #>
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)
    return (Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\clouds.key')
}

function New-AbkCloudsPassword {
    <#
        Пароль конфига: тридцать два знака из криптографического источника.
        Человеку его не показывают и вводить не просят - он живёт только
        внутри запечатанного файла.
    #>
    # Через экземпляр, а не статическим Fill: того нет в .NET Framework, на
    # котором работает Windows PowerShell 5.1, и первое заведение облака
    # там падало с MethodNotFound. Врапперы 5.1 поддерживают явно.
    $bytes = [byte[]]::new(24)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Protect-AbkCloudsPassword {
    <# Запечатывает пароль DPAPI и кладёт рядом с конфигом. #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Password,
        [string]$DataRoot
    )

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $path = Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    $plain = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $sealed = [System.Security.Cryptography.ProtectedData]::Protect($plain, $null, 'CurrentUser')
    [System.IO.File]::WriteAllBytes($path, $sealed)
    # Следов в памяти оставлять незачем: строка ещё поживёт, а массив чистим.
    [Array]::Clear($plain, 0, $plain.Length)
    return $path
}

function Unprotect-AbkCloudsPassword {
    <#
        Достаёт пароль из запечатанного файла. Пусто - значит облака ещё не
        заводились либо файл принесён с чужой машины: DPAPI такой не откроет,
        и это правильно.
    #>
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)

    $path = Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $path)) { return '' }

    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    try {
        $sealed = [System.IO.File]::ReadAllBytes($path)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect($sealed, $null, 'CurrentUser')
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch {
        return ''
    }
}

function Get-AbkCloudsEnvironment {
    <#
        Окружение для вызова rclone по облакам. Пароль передаётся здесь, а не
        ключом командной строки: командную строку видно в списке процессов.
    #>
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)

    $password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not $password) { return @{} }
    return @{ RCLONE_CONFIG_PASS = $password }
}

function Test-AbkCloudsReady {
    <# Есть ли чем открыть конфиг облаков: и пароль, и сам файл. #>
    param([Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot)

    return (Test-Path -LiteralPath (Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot)) -and
           [bool](Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot)
}

function Initialize-AbkClouds {
    <#
        Готовит хранилище под первое облако: пароль, пустой конфиг, шифрование.

        Пароль подаётся rclone в стандартный ввод, а не ключом командной
        строки и не файлом: в списке процессов его тогда не видно, а на диске
        не остаётся.

        Возвращает $true, когда после работы конфиг зашифрован и открывается
        своим паролем. Обещать больше, чем проверено, нельзя.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$DataRoot
    )

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $folder = Split-Path -Parent $config
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    if (Test-AbkCloudsReady -AppRoot $AppRoot -DataRoot $DataRoot) { return $true }

    $password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not $password) {
        $password = New-AbkCloudsPassword
        Protect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot -Password $password | Out-Null
    }

    # Пустой конфиг: rclone не станет шифровать то, чего нет.
    if (-not (Test-Path -LiteralPath $config)) {
        [System.IO.File]::WriteAllText($config, '', [System.Text.UTF8Encoding]::new($false))
    }

    $already = $false
    try {
        $probe = & $RcloneExe --config $config config encryption check 2>&1 | Out-String
        $already = ($LASTEXITCODE -eq 0 -and $probe -notmatch 'NOT encrypted')
    } catch { }

    if (-not $already) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $RcloneExe
        $psi.Arguments = '--config "{0}" config encryption set' -f $config
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true

        try {
            $process = [System.Diagnostics.Process]::Start($psi)
        } catch {
            return $false
        }

        # Пароль и его подтверждение - двумя строками, как спрашивает rclone.
        $process.StandardInput.WriteLine($password)
        $process.StandardInput.WriteLine($password)
        $process.StandardInput.Close()
        $null = $process.WaitForExit(30000)
        if (-not $process.HasExited) {
            try { $process.Kill() } catch { }
            return $false
        }
        if ($process.ExitCode -ne 0) { return $false }
    }

    return (Test-AbkCloudsOpen -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe)
}

function Test-AbkCloudsOpen {
    <# Открывается ли конфиг своим паролем - проверка делом, а не на слово. #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        # Проверить не свой конфиг, а принесённый - до того, как он займёт
        # место рабочего. И своим паролем, а не тем, что лежит на машине:
        # принесённое запечатывают уже после того, как оно себя показало.
        [string]$ConfigPath,
        [string]$Password,
        [string]$DataRoot
    )

    $config = if ($ConfigPath) { $ConfigPath } else { Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot }
    if (-not (Test-Path -LiteralPath $config)) { return $false }

    $answer = Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Password $Password `
        -Arguments @('--config', $config, 'listremotes')
    return [bool]$answer.Ok
}

function Invoke-AbkCloudsRclone {
    <#
        Зовёт rclone по облачному конфигу и возвращает его вывод.

        Пароль передаётся окружением самого дочернего процесса, а не общим:
        общее окружение правят разные места, и однажды в нём осталась пустая
        `RCLONE_CONFIG_PASS`. Rclone с пустым паролем не отказывается работать -
        он отдаёт структуру конфига без значений, и это худший вид ошибки:
        всё как будто на месте, а тип пустой и панель не открывается.

        Возвращает @{ Ok; Text }.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        # Пароль можно принести с собой: так проверяют файл, который ещё не
        # запечатан на этой машине. По умолчанию берётся здешний.
        [string]$Password,
        # Открытый конфиг пароля не требует вовсе, и передавать его туда
        # незачем: читаем транспорт этим же путём, чтобы не заводить второй.
        [switch]$NoPassword,
        [int]$WaitMs = 40000,
        [string]$DataRoot
    )

    # Имя нарочно другое. PowerShell не различает регистр, поэтому `$password`
    # и параметр `$Password` - одна и та же переменная: присваивание пустой
    # строки стирало принесённый пароль, и дальше всегда брался здешний. Из-за
    # этого проверка принесённого конфига шла не тем ключом.
    $effective = ''
    if (-not $NoPassword) {
        $effective = if ($Password) { $Password } else { Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot }
        if (-not $effective) { return @{ Ok = $false; Text = '' } }
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $RcloneExe
    $psi.Arguments = (@($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
    }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    # Обращение к этой коллекции копирует окружение родителя - дальше правим
    # только свою копию, чужого процесса не трогая.
    #
    # И первым делом выбрасываем из копии описания облаков. Rclone считает
    # переменные `RCLONE_CONFIG_<ИМЯ>_<ПОЛЕ>` главнее файла, а окно само же их и
    # раскладывает - и тогда `config dump` показывал не конфиг, а собственную
    # раскладку окна. Первый раз, пока окружение чистое, всё читалось верно;
    # второй возвращал имена полей без значений, и панель падала на пустом типе.
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ($name -like 'RCLONE_CONFIG_*' -and $name -ne 'RCLONE_CONFIG_PASS') {
            [void]$psi.EnvironmentVariables.Remove($name)
        }
    }
    if ($NoPassword) {
        [void]$psi.EnvironmentVariables.Remove('RCLONE_CONFIG_PASS')
    } else {
        $psi.EnvironmentVariables['RCLONE_CONFIG_PASS'] = $effective
    }

    try { $process = [System.Diagnostics.Process]::Start($psi) } catch { return @{ Ok = $false; Text = '' } }
    try { $process.StandardInput.Close() } catch { }

    $reader = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit($WaitMs)) {
        try { $process.Kill() } catch { }
        return @{ Ok = $false; Text = '' }
    }

    $text = ''
    try { $text = $reader.Result } catch { }
    return @{ Ok = ($process.ExitCode -eq 0); Text = $text }
}

function Get-AbkCloudList {
    <#
        Заведённые облака: имя и тип. Порядок - как в конфиге, то есть в
        порядке подключения.

        Пустой список - не беда: значит ни одного облака ещё не завели.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$DataRoot
    )

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $config)) { return @() }

    $answer = Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe `
        -Arguments @('--config', $config, 'config', 'dump')
    if (-not $answer.Ok -or -not $answer.Text.Trim()) { return @() }

    $found = @()
    try {
        $dump = $answer.Text | ConvertFrom-Json
        foreach ($property in $dump.PSObject.Properties) {
            $found += [pscustomobject]@{
                Name = $property.Name
                Type = [string]$property.Value.type
            }
        }
    } catch {
        return @()
    }

    return @($found)
}

function Get-AbkRemoteShape {
    <#
        Имя remote так, как его видит rclone в переменных окружения: прописными
        и со всем, кроме букв и цифр, заменённым подчёркиванием.

        Отсюда и берётся ловушка: `audit-a` и `audit_a` для rclone одно и то же
        имя, хотя человеку они разные.
    #>
    param([Parameter(Mandatory)][string]$Name)
    return ($Name.ToUpper() -replace '[^A-Z0-9]', '_')
}

function Test-AbkCloudNameFree {
    <#
        Свободно ли имя для облака.

        Имена облаков и транспорта живут в одном пространстве: rclone читает
        remote и из конфига, и из переменных окружения, причём переменные
        главнее файла. Пока это не проверялось, облако можно было назвать
        `base`, `server` или `r2` - и операция ушла бы не туда, куда показывает
        панель, молча и без единой жалобы.

        Разными считаются только по-настоящему разные имена: см.
        `Get-AbkRemoteShape`.

        Возвращает @{ Free; Reason }.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$Name,
        # Своё же прежнее имя при переименовании занятым не считается.
        [string]$Except = '',
        [string]$DataRoot
    )

    $want = Get-AbkRemoteShape -Name $Name
    $taken = @{}

    foreach ($key in @((Get-AbkTransportEnv -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe).Keys)) {
        if ($key -like '*_TYPE') {
            $taken[(($key -replace '^RCLONE_CONFIG_', '') -replace '_TYPE$', '')] = 'машина или R2 bucket'
        }
    }
    foreach ($cloud in @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe)) {
        if ($cloud.Name) { $taken[(Get-AbkRemoteShape -Name $cloud.Name)] = 'другое облако' }
    }

    if ($Except) { [void]$taken.Remove((Get-AbkRemoteShape -Name $Except)) }

    if ($taken.ContainsKey($want)) { return @{ Free = $false; Reason = $taken[$want] } }
    return @{ Free = $true; Reason = '' }
}

function Get-AbkConfigText {
    <#
        Открытый текст конфига. Для зашифрованного - через сам rclone: пароль
        уходит в стандартный ввод дочернего процесса, на диск ничего не ложится.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$Path,
        [string]$Password,
        [string]$DataRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }

    $answer = if ($Password) {
        Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Password $Password `
            -Arguments @('--config', $Path, 'config', 'show')
    } else {
        Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -NoPassword `
            -Arguments @('--config', $Path, 'config', 'show')
    }
    if (-not $answer.Ok) { return '' }
    return [string]$answer.Text
}

function Split-AbkConfigSections {
    <#
        Разбирает текст конфига на секции: имя -> текст секции целиком.
        Порядок сохраняется, потому что порядок в конфиге - это порядок в окне.
    #>
    param([AllowEmptyString()][string]$Text)

    $found = [ordered]@{}
    $name = ''
    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            if ($name) { $found[$name] = ($body -join "`n").TrimEnd() }
            $name = $Matches[1].Trim()
            $body = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if ($name) { $body.Add($line) | Out-Null }
    }
    if ($name) { $found[$name] = ($body -join "`n").TrimEnd() }
    return $found
}

function New-AbkSessionConfig {
    <#
        Собирает рабочий конфиг окна: транспорт из открытого файла плюс облака
        из своего, зашифрованный тем же паролем.

        Почему не переменными окружения, как раньше: rclone складывает имя
        переменной, заменяя всё, кроме букв и цифр, подчёркиванием. Маршрут
        `base-direct` превращался в remote `base_direct`, а окно звало его по
        настоящему имени - и получало «didn't find section». Под это подпадали
        все маршруты с дефисом: base-cf, base-via, laptop-ssh, server-cf.

        Возвращает путь к собранному файлу или пустую строку.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$Password,
        [string]$DataRoot
    )

    $plain = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\rclone.conf'
    $clouds = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot

    $transportText = Get-AbkConfigText -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Path $plain
    $cloudText = Get-AbkConfigText -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Path $clouds -Password $Password
    if (-not $cloudText.Trim()) { return '' }

    $transport = Split-AbkConfigSections -Text $transportText
    $cloud = Split-AbkConfigSections -Text $cloudText

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $transport.Keys) {
        $lines.Add('[' + $key + ']') | Out-Null
        $lines.Add($transport[$key]) | Out-Null
        $lines.Add('') | Out-Null
    }
    foreach ($key in $cloud.Keys) {
        # Транспорт старше: имя, занятое машиной или корзиной, облаку не
        # отдаём. Завести такое облако запрещает Test-AbkCloudNameFree, но
        # старый или принесённый конфиг мог быть собран до этого запрета.
        if ($transport.Contains($key)) { continue }
        $lines.Add('[' + $key + ']') | Out-Null
        $lines.Add($cloud[$key]) | Out-Null
        $lines.Add('') | Out-Null
    }

    $folder = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel '._runtime'
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $session = Join-Path $folder 'session.conf'

    [System.IO.File]::WriteAllText($session, ($lines -join "`n"), [System.Text.UTF8Encoding]::new($false))

    # Шифруем тем же паролем: файл живёт рядом с программой, и открытым ему
    # лежать незачем.
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $RcloneExe
    $psi.Arguments = '--config "{0}" config encryption set' -f $session
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ($name -like 'RCLONE_CONFIG_*') { [void]$psi.EnvironmentVariables.Remove($name) }
    }

    try { $process = [System.Diagnostics.Process]::Start($psi) } catch { return '' }
    $process.StandardInput.WriteLine($Password)
    $process.StandardInput.WriteLine($Password)
    $process.StandardInput.Close()
    $null = $process.WaitForExit(30000)
    if (-not $process.HasExited) { try { $process.Kill() } catch { }; return '' }
    if ($process.ExitCode -ne 0) { return '' }

    # Права на файл ставит соседний модуль. Он есть не в каждом вызове -
    # эта библиотека подключается и там, где окна нет вовсе.
    if (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue) {
        [void](Protect-AbkSecret -Path $session)
    }
    return $session
}

function Save-AbkCloudChanges {
    <#
        Возвращает изменения облаков из рабочего конфига в свой.

        Обновлённый OAuth-токен rclone пишет туда, откуда взял remote, то есть
        в рабочий конфиг. Свой должен оставаться эталоном - его увозят на
        MAIN VPS и приносят на другую машину, - поэтому облачные секции
        переписываются обратно.

        Возвращает число обновлённых облаков.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$SessionPath,
        [string]$DataRoot
    )

    if (-not (Test-Path -LiteralPath $SessionPath)) { return 0 }

    $clouds = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $sessionText = Get-AbkConfigText -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Path $SessionPath -Password $Password
    $cloudText = Get-AbkConfigText -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -Path $clouds -Password $Password
    if (-not $sessionText.Trim() -or -not $cloudText.Trim()) { return 0 }

    $session = Split-AbkConfigSections -Text $sessionText
    $cloud = Split-AbkConfigSections -Text $cloudText

    $changed = 0
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $cloud.Keys) {
        $body = $cloud[$key]
        if ($session.Contains($key) -and $session[$key] -ne $body) {
            $body = $session[$key]
            $changed++
        }
        $lines.Add('[' + $key + ']') | Out-Null
        $lines.Add($body) | Out-Null
        $lines.Add('') | Out-Null
    }
    if (-not $changed) { return 0 }

    # Пишем через временный файл: оборванная запись не должна оставить
    # хранилище облаков наполовину.
    $temp = $clouds + '.new'
    [System.IO.File]::WriteAllText($temp, ($lines -join "`n"), [System.Text.UTF8Encoding]::new($false))

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $RcloneExe
    $psi.Arguments = '--config "{0}" config encryption set' -f $temp
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ($name -like 'RCLONE_CONFIG_*') { [void]$psi.EnvironmentVariables.Remove($name) }
    }
    try { $process = [System.Diagnostics.Process]::Start($psi) } catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return 0
    }
    $process.StandardInput.WriteLine($Password)
    $process.StandardInput.WriteLine($Password)
    $process.StandardInput.Close()
    $null = $process.WaitForExit(30000)
    if (-not $process.HasExited -or $process.ExitCode -ne 0) {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return 0
    }

    Move-Item -LiteralPath $temp -Destination $clouds -Force
    if (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue) {
        [void](Protect-AbkSecret -Path $clouds)
    }
    return $changed
}

function Get-AbkTransportEnv {
    <#
        Описание транспорта - машин и корзин - переменными окружения.

        Зеркальная пара к `Get-AbkCloudRemoteEnv`, и появилась она не от
        симметрии. Раньше активным конфигом окна был открытый, а облака
        подкладывались поверх переменными - и rclone, обновив OAuth-токен,
        заводил облаку секцию прямо в открытом файле и клал туда новые
        access и refresh открытым текстом.

        Теперь наоборот: активный конфиг - зашифрованный конфиг облаков,
        обновление токена уходит внутрь него, а транспорт живёт в
        переменных. Терять ему нечего: у машин и корзин нет ключей,
        которые rclone переписывал бы сам.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$DataRoot
    )

    $config = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\rclone.conf'
    if (-not (Test-Path -LiteralPath $config)) { return @{} }

    $answer = Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe -NoPassword `
        -Arguments @('--config', $config, 'config', 'dump')
    if (-not $answer.Ok -or -not $answer.Text.Trim()) { return @{} }

    $found = @{}
    try {
        $dump = $answer.Text | ConvertFrom-Json
        foreach ($remote in $dump.PSObject.Properties) {
            $prefix = 'RCLONE_CONFIG_{0}_' -f ($remote.Name.ToUpper() -replace '[^A-Z0-9]', '_')
            foreach ($field in $remote.Value.PSObject.Properties) {
                $found[($prefix + $field.Name.ToUpper())] = [string]$field.Value
            }
        }
    } catch {
        return @{}
    }

    return $found
}

function Get-AbkCloudRemoteEnv {
    <#
        Описание заведённых облаков в виде переменных окружения.

        rclone читает remote не только из конфига: переменные
        `RCLONE_CONFIG_<ИМЯ>_<ПОЛЕ>` описывают его целиком. Это и нужно, чтобы
        облака были видны обычным вызовам - тем самым, которыми копируются
        машины и корзины. Конфиг у них остаётся свой, открытый; облака
        добавляются поверх и живут только в памяти процесса.

        Ключи доступа при этом не попадают ни в командную строку, ни во
        временные файлы: переменные видит только сам rclone, запущенный отсюда.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$DataRoot
    )

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $config)) { return @{} }

    $password = Unprotect-AbkCloudsPassword -AppRoot $AppRoot -DataRoot $DataRoot
    if (-not $password) { return @{} }

    $answer = Invoke-AbkCloudsRclone -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe `
        -Arguments @('--config', $config, 'config', 'dump')
    if (-not $answer.Ok -or -not $answer.Text.Trim()) { return @{} }

    $found = @{}
    try {
        $dump = $answer.Text | ConvertFrom-Json
        foreach ($remote in $dump.PSObject.Properties) {
            # Имя переменной берёт имя remote прописными: так его ищет rclone.
            $prefix = 'RCLONE_CONFIG_{0}_' -f ($remote.Name.ToUpper() -replace '[^A-Z0-9]', '_')
            foreach ($field in $remote.Value.PSObject.Properties) {
                $found[($prefix + $field.Name.ToUpper())] = [string]$field.Value
            }
        }
    } catch {
        return @{}
    }

    return $found
}

function Get-AbkCloudKinds {
    <#
        Облака, которые предлагаем заводить.

        `Login` говорит, как входят: `oauth` - в браузере, на стороне самого
        облака, программа пароля не видит вовсе; `password` - облако другого
        способа не даёт, и пароль вводит сам человек в окне.

        Список неполный намеренно: rclone умеет вчетверо больше, но в ряду
        кнопок нужны те, которыми пользуются.
    #>
    return @(
        [pscustomobject]@{ Key = 'drive';       Label = 'GOOGLE DRIVE'; Login = 'oauth' }
        [pscustomobject]@{ Key = 'dropbox';     Label = 'DROPBOX';      Login = 'oauth' }
        [pscustomobject]@{ Key = 'onedrive';    Label = 'ONEDRIVE';     Login = 'oauth' }
        [pscustomobject]@{ Key = 'yandex';      Label = 'ЯНДЕКС.ДИСК';  Login = 'oauth' }
        [pscustomobject]@{ Key = 'pcloud';      Label = 'PCLOUD';       Login = 'oauth' }
        [pscustomobject]@{ Key = 'box';         Label = 'BOX';          Login = 'oauth' }
        [pscustomobject]@{ Key = 'mega';        Label = 'MEGA';         Login = 'password' }
        [pscustomobject]@{ Key = 'protondrive'; Label = 'PROTON DRIVE'; Login = 'password' }
    )
}
