<#
    Не перекрывает ли туннель адреса той сети, в которой машина стоит.

    Туннель WireGuard забирает себе всё, что перечислено в `AllowedIPs`: пакеты
    к этим адресам уходят в него, а не в местную сеть. Если такой адрес уже
    занят там, где машина находится, - он для неё пропадает.

    Пересечение диапазонов само по себе не беда. В сети, где занят весь
    `192.168.0.0/16`, адреса вида `192.168.1.10/32` формально внутри неё - но
    если в той сети они свободны, туннель работает. Отнять можно только занятое.

    Поэтому проверка идёт в два шага: сперва арифметика - попадает ли адрес в
    местную сеть, - и лишь для попавших живая проба: отвечает ли по нему
    кто-нибудь здесь и сейчас. Тревога поднимается только тогда, когда адрес и
    правда занят кем-то другим.
#>

function ConvertTo-AbkUInt32 {
    <# Адрес в число: сравнивать подсети иначе неудобно. #>
    param([Parameter(Mandatory)][string]$Address)
    $bytes = ([System.Net.IPAddress]::Parse($Address)).GetAddressBytes()
    [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-AbkNetOverlap {
    <#
        Пересекаются ли две сети. Общая часть определяется меньшим префиксом:
        сеть с /16 содержит любую /32 внутри себя, и наоборот - /32 внутри /16
        считается пересечением.
    #>
    param(
        [Parameter(Mandatory)][string]$FirstAddress, [Parameter(Mandatory)][int]$FirstPrefix,
        [Parameter(Mandatory)][string]$SecondAddress, [Parameter(Mandatory)][int]$SecondPrefix
    )

    $prefix = [Math]::Min($FirstPrefix, $SecondPrefix)
    if ($prefix -le 0) { return $true }
    $mask = [uint32]((0xFFFFFFFFL -shl (32 - $prefix)) -band 0xFFFFFFFFL)
    return (((ConvertTo-AbkUInt32 $FirstAddress) -band $mask) -eq ((ConvertTo-AbkUInt32 $SecondAddress) -band $mask))
}

function Get-AbkLocalNets {
    <#
        Сети, в которых машина стоит прямо сейчас. Туннельные адаптеры
        пропускаем: их адреса - наши же, и спорить с ними не о чем.
    #>
    $out = @()
    try {
        $tunnels = @(Get-NetAdapter -ErrorAction Stop |
            Where-Object { $_.InterfaceDescription -match 'WireGuard|Amnezia|Wintun|TAP|VPN' } |
            ForEach-Object { [int]$_.ifIndex })
    } catch { $tunnels = @() }

    try {
        foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop) {
            if ($tunnels -contains [int]$ip.InterfaceIndex) { continue }
            if ($ip.IPAddress -like '127.*' -or $ip.IPAddress -like '169.254.*') { continue }
            $out += [pscustomobject]@{
                Address = [string]$ip.IPAddress
                Prefix  = [int]$ip.PrefixLength
                Alias   = [string]$ip.InterfaceAlias
            }
        }
    } catch { }
    return $out
}

function Get-AbkAllowedIPs {
    <# Что забирает себе туннель - строки AllowedIPs из его конфига. #>
    param([Parameter(Mandatory)][string]$Path)

    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\s*AllowedIPs\s*=\s*(.+)$') { continue }
        foreach ($piece in ($Matches[1] -split ',')) {
            $text = $piece.Trim()
            if (-not $text -or $text -notmatch '^\d{1,3}(\.\d{1,3}){3}(/\d{1,2})?$') { continue }
            $parts = $text -split '/'
            $out += [pscustomobject]@{
                Address = $parts[0]
                Prefix  = $(if ($parts.Count -gt 1) { [int]$parts[1] } else { 32 })
                Text    = $text
            }
        }
    }
    return $out
}

function Test-AbkAddressBusy {
    <#
        Отвечает ли кто-нибудь по этому адресу прямо сейчас, до подъёма
        туннеля.

        Пинг плюс пара обычных портов: устройства часто молчат на ICMP, но
        отзываются на 445, 80 или 22. Полсекунды на пробу - этого хватает в
        местной сети и не хватает, чтобы кого-то ждать зря.
    #>
    param([Parameter(Mandatory)][string]$Address)

    try {
        if ([System.Net.NetworkInformation.Ping]::new().Send($Address, 500).Status -eq 'Success') { return $true }
    } catch { }

    foreach ($port in 445, 80, 22, 443) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $task = $client.ConnectAsync($Address, $port)
            $ok = $task.Wait(400) -and $client.Connected
            $client.Close()
            if ($ok) { return $true }
        } catch { }
    }
    return $false
}

function Test-AbkTunnelClash {
    <#
        Что из забираемого туннелем уже занято вокруг. Возвращает список
        столкновений; пустой список - поднимать безопасно.

        Отдельно оговорка про полный туннель: `0.0.0.0/0` перекрывает всё
        вообще, и это не ошибка, а осознанный выбор - его и показываем особо.
    #>
    param([Parameter(Mandatory)][string]$ConfPath)

    $wanted = Get-AbkAllowedIPs -Path $ConfPath
    $local = Get-AbkLocalNets
    $clash = @()

    foreach ($w in $wanted) {
        foreach ($l in $local) {
            if (-not (Test-AbkNetOverlap -FirstAddress $w.Address -FirstPrefix $w.Prefix `
                                         -SecondAddress $l.Address -SecondPrefix $l.Prefix)) { continue }

            # Пересечение диапазонов - ещё не беда. Туннель отнимает адрес
            # только у того, кто этот адрес занимает: если в местной сети по
            # нему никто не отвечает, отбирать нечего и мешать некому.
            #
            # Так бывает в большой сети вроде 192.168.0.0/16: отдельный адрес
            # вроде 192.168.1.10 в ней может быть свободен, и туннель до сети
            # BASE тогда работает.
            $busy = $true
            if ($w.Prefix -eq 32) { $busy = Test-AbkAddressBusy -Address $w.Address }
            if (-not $busy) { continue }

            $clash += [pscustomobject]@{
                Wanted = $w.Text
                Local  = ('{0}/{1}' -f $l.Address, $l.Prefix)
                Alias  = $l.Alias
                Whole  = ($w.Prefix -eq 0)
            }
        }
    }
    return ,@($clash)
}
