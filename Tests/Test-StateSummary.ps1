#requires -Version 7.0
<#
    Сводка состояния в журнале окна.

    Окно пишет в журнал «===== СОСТОЯНИЕ =====» и «===== ТУННЕЛИ =====» по
    фактам сценария Engine\Scripts\Get-StateSummary.ps1: одна строка JSON.
    Сценарий гоняется здесь целиком, на временной папке данных; службы и
    туннели этой машины он только читает.

    Проверяется:
      - пустая папка данных - это ответ «ничего нет», а не остановка;
      - из нескольких архивов Snapshots назван самый свежий, с размером и
        возрастом; посторонний файл архивом не считается;
      - пара ключей R2 видна по файлу в данных;
      - туннели приходят списком, и туннель, чьего конфига в данных нет, -
        чужой: его дальний конец не спрашивают;
      - окно читает только те поля, которые сценарий отдаёт: поле, переименованное
        с одной стороны, оставило бы в журнале пустое место без единой ошибки;
      - соседний сценарий точек, Get-SetupState.ps1, узнаёт ключ этой машины по
        папке данных и профилю, а не по имени, которое помнит окно.

    За пределами временной папки ничего не меняет. Возвращает 0, когда всё сходится.
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
    if ($Note) { Write-Host ('{0}  {1,-50} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

$summaryScript = Join-Path $AppRoot 'Engine\Scripts\Get-StateSummary.ps1'

function Get-Summary {
    param([string]$Data)
    $global:LASTEXITCODE = 0
    $said = @(& $summaryScript -Root $Data 6>&1 2>&1 | ForEach-Object { "$_" })
    $line = @($said | Where-Object { $_.StartsWith('{') })
    if (-not $line.Count) { return $null }
    return ($line[-1] | ConvertFrom-Json)
}

Write-Host ''
Write-Host '===== СВОДКА СОСТОЯНИЯ ====='

$data = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-summary-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $data -Force | Out-Null
try {
    # --- 1. пустая папка данных ---------------------------------------------------------
    $empty = Get-Summary -Data $data
    Test-Step -Title 'пустая папка данных - ответ есть' -Ok ($null -ne $empty)
    Test-Step -Title 'без архивов снимка нет' -Ok ($empty -and $null -eq $empty.snapshot)
    Test-Step -Title 'без файла ключей R2 их нет' -Ok ($empty -and $empty.r2 -eq $false)
    Test-Step -Title 'без конфига туннель до роутера не заведён' `
        -Ok ($empty -and $empty.vpn -and $empty.vpn.conf -eq $false -and [string]$empty.vpn.name)

    # --- 2. снимок и ключи ----------------------------------------------------------------
    $snapshots = Join-Path $data 'Snapshots'
    New-Item -ItemType Directory -Path $snapshots -Force | Out-Null
    $old = Join-Path $snapshots 'audion-old.tar.gz'
    $new = Join-Path $snapshots 'audion-new.tar.gz'
    $stray = Join-Path $snapshots 'notes.txt'
    [System.IO.File]::WriteAllBytes($old, [byte[]]::new(10))
    [System.IO.File]::WriteAllBytes($new, [byte[]]::new(2048))
    [System.IO.File]::WriteAllText($stray, 'not an archive')
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddHours(-50)
    (Get-Item -LiteralPath $new).LastWriteTime = (Get-Date).AddHours(-5)

    $credentials = Join-Path $data 'config\rclone\r2.credentials'
    New-Item -ItemType Directory -Path (Split-Path -Parent $credentials) -Force | Out-Null
    [System.IO.File]::WriteAllText($credentials, 'synthetic')

    $filled = Get-Summary -Data $data
    Test-Step -Title 'назван самый свежий архив' -Ok ($filled -and $filled.snapshot -and $filled.snapshot.name -eq 'audion-new.tar.gz') `
        -Note $(if ($filled -and $filled.snapshot) { [string]$filled.snapshot.name } else { 'снимка нет' })
    Test-Step -Title 'размер и возраст архива' `
        -Ok ($filled -and $filled.snapshot -and [long]$filled.snapshot.bytes -eq 2048 -and [int]$filled.snapshot.hours -eq 5)
    # ConvertFrom-Json отдаёт такую строку уже датой; окно разбирает её само, без оглядки на язык системы.
    $when = [datetime]::MinValue
    try {
        $when = $filled.snapshot.time
        if ($when -isnot [datetime]) { $when = [datetime]::Parse([string]$when, [cultureinfo]::InvariantCulture) }
    } catch { $when = [datetime]::MinValue }
    Test-Step -Title 'время архива разбирается' `
        -Ok ([math]::Abs(((Get-Date).AddHours(-5) - $when).TotalMinutes) -lt 5) -Note $when.ToString('dd.MM HH:mm')
    Test-Step -Title 'файл ключей R2 виден' -Ok ($filled -and $filled.r2 -eq $true)

    # --- 3. туннели -----------------------------------------------------------------------
    # Сколько служб туннелей на этой машине, тест не знает. В данных конфигов нет,
    # значит своих среди них быть не может: ни пропавшего клиента, ни стука внутрь.
    $tunnels = @($(if ($filled) { $filled.tunnels }))
    Test-Step -Title 'туннели приходят списком' -Ok ($filled -and $filled.PSObject.Properties['tunnels'] -and $filled.tunnels -is [array]) `
        -Note ('служб туннелей на этой машине: {0}' -f $tunnels.Count)
    $touched = @($tunnels | Where-Object { -not $_.foreign -or $_.peer -or $_.lost })
    Test-Step -Title 'туннель без конфига в данных - чужой, его не трогают' -Ok ($touched.Count -eq 0)
    Test-Step -Title 'питание туннеля - on или off' -Ok (@($tunnels | Where-Object { $_.power -notin 'on', 'off' }).Count -eq 0)
    Test-Step -Title 'клиенты приходят списком' -Ok ($filled -and $filled.clients -is [array] -and
        ((-not $filled.clients.Count) -eq (-not [string]$filled.pick)))
} finally {
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 4. окно читает то, что сценарий отдаёт ---------------------------------------------
$scriptText = [System.IO.File]::ReadAllText($summaryScript)
$given = @([regex]::Matches($scriptText, '(?m)^\s+(\w+)\s+= ') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$stateCode = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Source\MainWindow.State.cs'))
$from = $stateCode.IndexOf('static List<string> SummaryLines')
$to = $stateCode.IndexOf('static string HandshakeSaid')
Test-Step -Title 'окно пишет сводку' -Ok ($from -gt 0 -and $to -gt $from -and $stateCode.Contains('SetupScript("Get-StateSummary.ps1")'))
if ($from -gt 0 -and $to -gt $from) {
    $lines = $stateCode.Substring($from, $to - $from)
    $read = @([regex]::Matches($lines, '(?:(?:Text|Flag|Number)\(\w+, |\.TryGetProperty\()"(\w+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $unknown = @($read | Where-Object { $given -notcontains $_ })
    Test-Step -Title 'окно читает только поля сценария' -Ok ($read.Count -ge 15 -and $unknown.Count -eq 0) `
        -Note $(if ($unknown.Count) { 'сценарий не отдаёт: ' + ($unknown -join ', ') } else { 'полей: {0}' -f $read.Count })
}

# --- 5. точки ключей: какой ключ здешний, говорит папка данных ---------------------------
# Указать папку данных - вся настройка. Свежая копия программы имени ключа не помнит: настройки
# окна уходят с чисткой. Здешний ключ узнаётся по паре - публичная половина в CLIENTS, закрытая
# рядом, в профиле. До 06.10.2026 точка SSH-KEYGEN смотрела на запомненное имя и без него была
# серой при ключе на месте.
$setupScript = Join-Path $AppRoot 'Engine\Scripts\Get-SetupState.ps1'
function Get-Setup {
    param([string]$Data, [string]$Ssh, [string]$Name = '')
    $global:LASTEXITCODE = 0
    $extra = @{}
    if ($Name) { $extra['ClientName'] = $Name }
    $said = @(& $setupScript -Root $Data -SshDir $Ssh @extra 6>&1 2>&1 | ForEach-Object { "$_" })
    $line = @($said | Where-Object { $_.StartsWith('{') })
    if (-not $line.Count) { return $null }
    return ($line[-1] | ConvertFrom-Json)
}
$stand = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $standData = Join-Path $stand 'Audion Backup Stand'
    $standSsh = Join-Path $stand 'profile'
    $clients = Join-Path $standData 'Tunnel\SSH\clients'
    New-Item -ItemType Directory -Path $clients -Force | Out-Null
    New-Item -ItemType Directory -Path $standSsh -Force | Out-Null
    # Две машины в CLIENTS. Содержимое файлов сценарий не читает - только имена.
    [System.IO.File]::WriteAllText((Join-Path $clients 'stand-box_ed25519.pub'), 'synthetic public half of stand-box')
    [System.IO.File]::WriteAllText((Join-Path $clients 'other-box_ed25519.pub'), 'synthetic public half of other-box')

    $none = Get-Setup -Data $standData -Ssh $standSsh
    Test-Step -Title 'без закрытой половины в профиле точки ключей серые' -Ok ($none -and -not $none.newKey -and -not $none.keys)

    [System.IO.File]::WriteAllText((Join-Path $standSsh 'stand-box_ed25519'), 'synthetic private half')
    $found = Get-Setup -Data $standData -Ssh $standSsh
    Test-Step -Title 'ключ машины узнан без запомненного имени' -Ok ($found -and $found.newKey -and $found.keys)

    $named = Get-Setup -Data $standData -Ssh $standSsh -Name 'stand-box'
    Test-Step -Title 'с запомненным именем ответ тот же' -Ok ($named -and $named.newKey -and $named.keys)

    # Имя запомнено, а ключа под ним в профиле нет: решает пара, а не память окна.
    $stale = Get-Setup -Data $standData -Ssh $standSsh -Name 'gone-box'
    Test-Step -Title 'устаревшее имя ключ машины не прячет' -Ok ($stale -and $stale.newKey -and $stale.keys)
} finally {
    Remove-Item -LiteralPath $stand -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
