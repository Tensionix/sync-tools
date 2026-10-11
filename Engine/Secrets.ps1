<#
    Права на файлы с секретами - одной процедурой для всех сценариев.

    Приватная половина ключа лежит не только в `.key`: тот же материал стоит
    строкой `PrivateKey` внутри `.conf`. Защищать один файл и оставлять второй
    открытым - значит не защитить ничего.

    Права наследуются от места: на `E:\TOOLS` это «Пользователи» с чтением и
    «Прошедшие проверку» с изменением. Для ключа это чужие глаза, а для конфига
    ещё и чужая рука: подменённый файл вступит в силу при следующем подъёме
    туннеля. Поэтому наследование снимается, и остаются трое - владелец,
    администраторы и система.

    Процедура возвращает $true, когда после правки посторонних записей не
    осталось: сказанное «защищено» должно быть проверенным, а не обещанным.
#>

function Get-AbkSecretSubjects {
    <# Кому оставляем доступ: владелец, администраторы, система. #>
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return @($me, 'S-1-5-18', 'S-1-5-32-544')
}

function Test-AbkSecretAcl {
    <#
        Смотрит, остались ли у файла посторонние. Считаем по SID, а не по
        именам: на русской Windows это «Пользователи» и «Прошедшие проверку»,
        на английской - Users и Authenticated Users, и сравнение по тексту
        ломается при первой же смене языка системы.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $ours = Get-AbkSecretSubjects
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { return $null }

    $strangers = @()
    foreach ($rule in $acl.Access) {
        try {
            $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        } catch {
            $sid = [string]$rule.IdentityReference
        }
        if ($ours -notcontains $sid) { $strangers += $sid }
    }
    # Запятая обязательна: пустой массив PowerShell при возврате превращает в
    # $null, и «посторонних нет» стало бы неотличимо от «прочитать не вышло».
    return ,@($strangers | Select-Object -Unique)
}

function Protect-AbkSecret {
    <#
        Закрывает файл или каталог: своим - полный доступ, чужие записи
        снимаются поимённо.

        Два подхода отпали по пути. `Set-Acl` с собранным дескриптором
        требует привилегии `SeSecurityPrivilege` - её у обычного процесса нет,
        и правка падает даже у владельца файла. А один `icacls /inheritance:r
        /grant:r` убирает только унаследованное: чужая явная запись остаётся.
        Так открытая половина ключа после «защиты» оставалась читаемой для
        всех - `ssh-keygen` выдаёт ей явное разрешение «Все».

        Поэтому здесь два шага: выдать права своим, затем снять всех, кого в
        списке быть не должно. Оба идут через `icacls` и работают под правами
        владельца, без администратора.
    #>
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [switch]$Directory
    )

    $ours = Get-AbkSecretSubjects
    $flags = if ($Directory) { '(OI)(CI)F' } else { 'F' }
    $grants = @($ours | ForEach-Object { '*{0}:{1}' -f $_, $flags })

    $good = $true
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item)) { continue }

        try { & icacls.exe $item /inheritance:r /grant:r @grants /C /Q 2>&1 | Out-Null } catch { }

        # Снимаем лишних по SID. Имена тут не годятся: на русской Windows это
        # «Все» и «Пользователи», на английской Everyone и Users, а icacls
        # понимает и то, и другое только на своём языке.
        $strangers = Test-AbkSecretAcl -Path $item
        if ($null -ne $strangers) {
            foreach ($sid in $strangers) {
                if ($sid -notmatch '^S-\d') { continue }
                try { & icacls.exe $item /remove:g ('*' + $sid) /C /Q 2>&1 | Out-Null } catch { }
            }
        }

        $left = Test-AbkSecretAcl -Path $item
        if ($null -eq $left -or $left.Count) { $good = $false }
    }
    return $good
}

function Test-AbkSshPrivateKeyAcl {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSIsContainer) { return $false }
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $ours = Get-AbkSecretSubjects
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $readable = $false
        foreach ($rule in $acl.Access) {
            if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq $me -and
                $rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadData)) { $readable = $true }
        }
        $strangers = Test-AbkSecretAcl -Path $item.FullName
        return ($readable -and $acl.AreAccessRulesProtected -and $owner -in $ours -and
            $null -ne $strangers -and $strangers.Count -eq 0 -and
            @($acl.Access | Where-Object AccessControlType -eq 'Deny').Count -eq 0)
    } catch { return $false }
}

function Protect-AbkSshPrivateKey {
    # Только ACL и владелец. Содержимое приватного ключа не читается и не меняется.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if (Test-AbkSshPrivateKeyAcl -Path $item.FullName) { return $true }
        $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin (Get-AbkSecretSubjects)) {
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            & icacls.exe $item.FullName /setowner ('*' + $me) /C /Q 2>&1 | Out-Null
        }
        if (-not (Protect-AbkSecret -Path $item.FullName)) { return $false }
        return (Test-AbkSshPrivateKeyAcl -Path $item.FullName)
    } catch { return $false }
}

function Protect-AbkSecretStore {
    <#
        Каталог с ключами целиком: сам каталог и всё, что в нём лежит. Зовётся
        при каждой установке - права приезжают от места, а файлы переезжают
        между машинами и папками данных, и однажды закрытый склад открывается
        заново после первого же переноса.

        Открытые половины (`.pub`) закрываются заодно: они не секрет, но им и
        не нужны чужие руки, а отдельный разбор «этот файл секретный, а этот
        нет» лишний.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$Say
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $good = Protect-AbkSecret -Path $Path -Directory
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if ($files.Count) {
        if (-not (Protect-AbkSecret -Path $files)) { $good = $false }
    }

    if ($Say) {
        if ($good) { & $Say ("права на папке ключей: только владелец, администраторы и система ({0} файлов)" -f $files.Count) 'Green' }
        else { & $Say "права на папке ключей закрыть не вышло - к ключам есть посторонний доступ" 'Yellow' }
    }
    return $good
}
