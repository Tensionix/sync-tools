#requires -Version 7.0
<#
    СПИСОК, SSH-COPY-ID и ОТОЗВАТЬ - на стенде, без единой настоящей машины.

    На настоящих машинах эти кнопки не проверяются никогда: раздать ключ или
    отозвать его «для пробы» значит открыть или закрыть настоящий вход. Поэтому
    сценарий Engine\Scripts\Manage-ClientKeys.ps1 гоняется здесь целиком, а
    вместо ssh стоит заглушка: authorized_keys каждой «машины» - файл во
    временной папке, машина без файла молчит.

    Стенд: BASE отвечает в локальной сети (зовётся base-lan) и держит первый
    ключ и чужую строку; MAIN VPS держит один второй ключ; HOME молчит.

    Проверяется:
      - -Describe: ключи CLIENTS, свой ключ помечен, план машин и их имена;
      - -Spread -WhatIf ничего не пишет; -Spread дописывает недостающее,
        чужую строку не трогает, молчащую машину пропускает; повтор ничего
        не добавляет;
      - -Revoke неизвестного ключа - отказ; -WhatIf ничего не убирает;
        отзыв убирает ключ везде, где он не последний, и оставляет последний
        ключ машины на месте;
      - -Inventory доходит до таблицы «кто куда ходит».

    В настоящий ~\.ssh и в настоящую папку данных не пишет: ключи стенда
    делаются во временной папке, она же удаляется в конце.
    Возвращает 0, когда всё сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$scripts = Join-Path $AppRoot 'Engine\Scripts'

$failed = 0
function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-52} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Write-Host ''
Write-Host '===== КЛЮЧИ МАШИН: СПИСОК, SSH-COPY-ID, ОТОЗВАТЬ ====='

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-keys-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stand = Join-Path $root 'Audion Backup Stand'
$stub = Join-Path $root 'machines'
New-Item -ItemType Directory -Path (Join-Path $stand 'Tunnel\RemoteDesktop\config'), $stub -Force | Out-Null

try {
    # --- стенд: адреса -------------------------------------------------------
    $targets = Get-Content -LiteralPath (Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $targets.base.lan = '192.0.2.10'
    $targets.home.lan = '192.0.2.11'
    $serverHost = [string]$targets.server.sshHost
    [System.IO.File]::WriteAllText((Join-Path $stand 'Tunnel\RemoteDesktop\config\targets.json'), ($targets | ConvertTo-Json -Depth 8))

    # --- заглушка ssh ----------------------------------------------------------
    # ssh -o BatchMode=yes -o ConnectTimeout=10 <машина> <команда>: файл машины - её authorized_keys.
    $global:AbkStubDir = $stub
    function global:ssh {
        $target = [string]$args[4]
        $command = [string]$args[5]
        $file = Join-Path $global:AbkStubDir ($target + '.txt')
        if (-not (Test-Path -LiteralPath $file)) { $global:LASTEXITCODE = 255; return }
        $rows = @(Get-Content -LiteralPath $file)
        $body = $(if ($command -match '(AAAA[0-9A-Za-z+/=]+)') { $Matches[1] } else { '' })
        $global:LASTEXITCODE = 0
        if ($command -match 'Add-Content|printf') {
            $line = $(if ($command -match "(ssh-ed25519 AAAA\S+(?: [^']+)?)'") { $Matches[1] } else { '' })
            Add-Content -LiteralPath $file -Value $line
            return
        }
        if ($command -match 'Select-String') { return [string]([bool](@($rows | Where-Object { $_ -like "*$body*" }).Count)) }
        if ($command -match 'grep -qF .* echo yes') { if (@($rows | Where-Object { $_ -like "*$body*" }).Count) { return 'yes' } else { return 'no' } }
        if ($command -match '\$keep|grep -vF') {
            $keep = @($rows | Where-Object { $_ -notlike "*$body*" })
            if ($keep.Count -eq $rows.Count) { return 'missing' }
            Set-Content -LiteralPath $file -Value $keep
            return 'removed'
        }
        return $rows
    }

    function Invoke-Keys([hashtable]$Arguments) {
        $global:LASTEXITCODE = 0
        $said = @(& (Join-Path $scripts 'Manage-ClientKeys.ps1') @Arguments 6>&1 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Code = $LASTEXITCODE; Said = $said }
    }
    function Get-Machine([string]$Name) { @(Get-Content -LiteralPath (Join-Path $stub ($Name + '.txt')) -ErrorAction SilentlyContinue | Where-Object { $_ }) }
    function Get-Label([string]$Name) { @(Get-Machine $Name | ForEach-Object { ($_ -split ' ')[2] }) -join ',' }

    # --- стенд: два ключа ------------------------------------------------------
    foreach ($name in 'stand-one', 'stand-two') {
        $global:LASTEXITCODE = 0
        $null = & (Join-Path $scripts 'New-ClientKey.ps1') -Root $stand -Name $name -SshDir (Join-Path $root "ssh-$name") 6>&1 2>&1
    }
    $clients = Join-Path $stand 'Tunnel\SSH\clients'
    $made = (Test-Path -LiteralPath (Join-Path $clients 'stand-one.pub')) -and (Test-Path -LiteralPath (Join-Path $clients 'stand-two.pub'))
    Test-Step -Title 'ключи стенда сделаны во временной папке' -Ok $made
    if (-not $made) { throw 'без ключей стенда проверять нечего' }
    $one = (Get-Content -LiteralPath (Join-Path $clients 'stand-one.pub') -Raw).Trim()
    $two = (Get-Content -LiteralPath (Join-Path $clients 'stand-two.pub') -Raw).Trim()
    Set-Content -LiteralPath (Join-Path $stub 'base-lan.txt') -Value @($one, 'ssh-ed25519 AAAAFOREIGNLINE0000 somebody')
    Set-Content -LiteralPath (Join-Path $stub ($serverHost + '.txt')) -Value @($two)

    $common = @{ Root = $stand; Lan = 'base'; ClientName = 'stand-one' }

    # --- -Describe -------------------------------------------------------------
    $run = Invoke-Keys ($common + @{ Describe = $true })
    $state = $null
    try { $state = ($run.Said | Where-Object { $_.StartsWith('{') } | Select-Object -Last 1) | ConvertFrom-Json } catch { }
    Test-Step -Title '-Describe отвечает' -Ok ($run.Code -eq 0 -and $null -ne $state)
    if ($state) {
        Test-Step -Title 'ключи CLIENTS названы' -Ok ((@($state.clients) -join ',') -eq 'stand-one,stand-two') -Note (@($state.clients) -join ', ')
        $mine = @($state.keys | Where-Object { $_.mine }) | ForEach-Object { $_.name }
        Test-Step -Title 'ключ этой машины помечен' -Ok ((@($mine) -join ',') -eq 'stand-one') -Note (@($mine) -join ', ')
        $hosts = @($state.plan | ForEach-Object { $_.host }) -join ','
        Test-Step -Title 'машина в локальной сети зовётся <имя>-lan' -Ok ($hosts -eq ('base-lan,home,' + $serverHost)) -Note $hosts
    }

    # --- SSH-COPY-ID -----------------------------------------------------------
    $run = Invoke-Keys ($common + @{ Spread = $true; WhatIf = $true })
    Test-Step -Title '-Spread -WhatIf ничего не пишет' -Ok ($run.Code -eq 0 -and (Get-Machine 'base-lan').Count -eq 2 -and (Get-Machine $serverHost).Count -eq 1)

    $run = Invoke-Keys ($common + @{ Spread = $true })
    Test-Step -Title '-Spread дописывает недостающий ключ' -Ok ($run.Code -eq 0 -and (Get-Label 'base-lan') -eq 'stand-one,somebody,stand-two' -and (Get-Label $serverHost) -eq 'stand-two,stand-one') `
        -Note ('BASE: {0}; MAIN VPS: {1}' -f (Get-Label 'base-lan'), (Get-Label $serverHost))
    Test-Step -Title 'чужая строка на месте' -Ok (@(Get-Machine 'base-lan' | Where-Object { $_ -like '*AAAAFOREIGNLINE0000*' }).Count -eq 1)
    Test-Step -Title 'молчащая машина названа и пропущена' -Ok (@($run.Said | Where-Object { $_ -match '^HOME\s' -and $_ -match 'no answer' }).Count -eq 1)

    $run = Invoke-Keys ($common + @{ Spread = $true })
    Test-Step -Title 'повторный -Spread ничего не добавляет' -Ok ($run.Code -eq 0 -and (Get-Machine 'base-lan').Count -eq 3 -and (Get-Machine $serverHost).Count -eq 2)

    # --- ОТОЗВАТЬ --------------------------------------------------------------
    $run = Invoke-Keys ($common + @{ Revoke = 'nobody' })
    Test-Step -Title 'отзыв неизвестного ключа - отказ' -Ok ($run.Code -eq 1)

    $run = Invoke-Keys ($common + @{ Revoke = 'stand-two'; WhatIf = $true })
    Test-Step -Title '-Revoke -WhatIf ничего не убирает' -Ok ($run.Code -eq 0 -and (Get-Machine 'base-lan').Count -eq 3 -and (Get-Machine $serverHost).Count -eq 2)

    $run = Invoke-Keys ($common + @{ Revoke = 'stand-two' })
    Test-Step -Title 'отзыв убирает ключ со всех ответивших' -Ok ($run.Code -eq 0 -and (Get-Label 'base-lan') -eq 'stand-one,somebody' -and (Get-Label $serverHost) -eq 'stand-one') `
        -Note ('BASE: {0}; MAIN VPS: {1}' -f (Get-Label 'base-lan'), (Get-Label $serverHost))

    $run = Invoke-Keys ($common + @{ Revoke = 'stand-one' })
    Test-Step -Title 'последний ключ машины остаётся' -Ok ($run.Code -eq 0 -and (Get-Label $serverHost) -eq 'stand-one' -and (Get-Label 'base-lan') -eq 'somebody') `
        -Note ('BASE: {0}; MAIN VPS: {1}' -f (Get-Label 'base-lan'), (Get-Label $serverHost))

    # --- СПИСОК ----------------------------------------------------------------
    $run = Invoke-Keys ($common + @{ Inventory = $true; SshDir = (Join-Path $root 'ssh-stand-one') })
    $table = @($run.Said | Where-Object { $_ -match '^stand-(one|two)\S*\s+[+.?]' })
    Test-Step -Title '-Inventory доходит до таблицы «кто куда ходит»' -Ok ($run.Code -eq 0 -and $table.Count -eq 2) -Note ('строк таблицы: {0}' -f $table.Count)
}
catch {
    Test-Step -Title 'проверка дошла до конца' -Ok $false -Note $_.Exception.Message
}
finally {
    Remove-Item -Path Function:\global:ssh -ErrorAction SilentlyContinue
    # Приватные ключи стенда закрыты на чтение одному читателю: права возвращаем, иначе папку не убрать.
    # Без флагов наследования: с ними icacls обходит файлы стороной, а закрыты именно они.
    & icacls $root /grant ('{0}:F' -f $env:USERNAME) /T /C /Q *>$null
    Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
