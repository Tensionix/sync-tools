#requires -Version 7.0
<#
    Окно на стенде: поведение, которого не видят остальные проверки.

    Проверки Tests\Test-*.ps1 читают код окна как текст, а шаг отладочной копии
    (Source\Tools\dev-run.ps1) отвечает на вопрос окна мгновенно. Того, что
    происходит МЕЖДУ ожиданием и ответом, не видит ни то ни другое - а именно
    там два аудита переезда на Avalonia (06.10.2026) нашли семь дефектов при
    всех пройденных проверках: закрытие окна во время передачи, смена папки
    данных под идущим подсчётом, операция по адресу, куда панель ушла уже после
    вопроса.

    Стенд - собранное окно (App\AudionSyncTools.dll) под Avalonia.Headless: без
    экрана и без мыши. Вместо PowerShell программы и rclone стоит заглушка
    Tests\Stand\Worker.cs: она никуда не ходит, записывает, с чем её позвали, и
    отвечает то, что нужно пробе. Пробы - Tests\Stand\Harness.cs: вопрос
    открывается и остаётся без ответа, папка данных меняется или панель уходит
    в другое место, и только потом вопрос получает ответ. Вердикт - то, с чем
    позвали заглушку rclone.

    Настоящим исполняется одно: Engine\Scripts\Initialize-DataFolder.ps1 - под
    PowerShell программы, на временной папке данных стенда и с пустым
    ssh-конфигом, названным ему явно.

    Ничего настоящего не трогается: папки данных, указатель, настройки и журнал
    у стенда свои, во временной папке системы; ни к одной машине и ни к одному
    облаку обращений нет, проба сети выключена.

    Нужны dotnet SDK и собранная App\ (builder_main.cmd build_app). Первый
    запуск на машине скачивает пакет Avalonia.Headless. В общий прогон
    Tests\Run-Tests.ps1 не входит: собирает две программы и идёт около двух минут.

      App\AudionPs.exe -NoProfile -ExecutionPolicy Bypass -File Tests\Stand\Run-Stand.ps1

    -Dll <файл>  другая сборка окна - например копия из папки аудита: те же
                 пробы показывают, что было до исправления.
    -Keep        не удалять стенд после прогона; его путь назван в конце.

    Возвращает число проваленных проб; 0 - всё сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = '',
    [string]$Dll = '',
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not $Dll) { $Dll = Join-Path $AppRoot 'App\AudionSyncTools.dll' }
$realPs = Join-Path $AppRoot 'App\AudionPs.exe'

Write-Host ''
Write-Host '===== ОКНО НА СТЕНДЕ ====='

foreach ($need in $Dll, $realPs) {
    if (-not (Test-Path -LiteralPath $need)) {
        Write-Host ('СБОЙ  нет файла: {0} - сначала builder_main.cmd build_app' -f $need)
        exit 1
    }
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host 'СБОЙ  нет dotnet SDK: стенд собирает две программы'
    exit 1
}

# Корень стенда лежит на уровень глубже своей папки: окно первого запуска ищет папки данных
# рядом с программой, и рядом должно быть только то, что положила проба.
$box = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-stand-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stand = Join-Path $box 'program'

function New-Folder { param([string]$Path) [void][System.IO.Directory]::CreateDirectory($Path) }

function Invoke-Build {
    # dotnet говорит много; здесь нужны только ошибки.
    param([string[]]$Arguments)
    $said = & dotnet @Arguments 2>&1 | Out-String
    $errors = @($said -split "`r?`n" | Where-Object { $_ -match '\berror\b' } | ForEach-Object { ($_ -split ' \[')[0].Trim() } | Sort-Object -Unique)
    if ($LASTEXITCODE -ne 0 -or $errors.Count) {
        $errors | ForEach-Object { Write-Host ('      ' + $_) }
        return $false
    }
    return $true
}

$failed = 1
try {
    # --- стенд: то, что окно ищет у себя в папке -----------------------------------
    foreach ($dir in 'App', 'Engine\Scripts', 'Tunnel\RemoteDesktop\config', 'Tools\rclone', 'Worker', 'config', 'build\Worker', 'build\Harness') {
        New-Folder (Join-Path $stand $dir)
    }
    [System.IO.File]::WriteAllText((Join-Path $stand 'stand.marker'), 'Audion Sync Tools: a stand of Tests\Stand\Run-Stand.ps1')

    # Движок: Engine\DataRoot.ps1 - признак корня для окна, остальное нужно настоящему сценарию.
    Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Engine') -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stand ('Engine\' + $_.Name)) }
    # Сценарии: окно проверяет, что файл есть, а исполняет его заглушка - кроме одного.
    Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Engine\Scripts') -Filter '*.ps1' -File |
        ForEach-Object { [System.IO.File]::WriteAllText((Join-Path $stand ('Engine\Scripts\' + $_.Name)), "# a stub of the stand`n") }
    Copy-Item -LiteralPath (Join-Path $AppRoot 'Engine\Scripts\Initialize-DataFolder.ps1') -Destination (Join-Path $stand 'Engine\Scripts\Initialize-DataFolder.ps1') -Force
    Copy-Item -LiteralPath (Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json') -Destination (Join-Path $stand 'Tunnel\RemoteDesktop\config\targets.sample.json')
    Copy-Item -LiteralPath (Join-Path $AppRoot 'config\version.json') -Destination (Join-Path $stand 'config\version.json')
    # Словарь, ряды кнопок и цвета строк едут рядом со сборкой окна.
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $Dll) 'config') -Destination (Join-Path $stand 'App\config') -Recurse

    [System.IO.File]::WriteAllText((Join-Path $stand 'empty-ssh-config'), '')
    # Зашифрованный конфиг rclone для окна - текст без единой секции.
    [System.IO.File]::WriteAllText((Join-Path $stand 'encrypted-session.conf'), "# Encrypted rclone configuration File`n`nRCLONE_ENCRYPT_V0:`nc3RhbmQ6IG5vdCBhIHJlYWwgY29uZmlnLCBub3QgYSByZWFsIGtleQ==`n")
    foreach ($name in 'Audion Backup A', 'Audion Backup B') {
        New-Folder (Join-Path $stand ($name + '\config\rclone'))
        # Адреса из сети для документации (192.0.2.0/24): к ним никто не ходит.
        # [laptop] с адресом самой машины: «эта машина под другим именем» для пробы вложенных папок.
        # Дальняя дорога BASE - своей программой ssh, как в настоящем конфиге; у DAD - своим адресом и портом:
        # проба BISYNC смотрит, чем окно передаёт rclone дорогу под прямым именем машины. У HOME наоборот:
        # прямая дорога - программой ssh, а дальняя говорит «ssh =» и называет адрес - чужая ssh не наследуется.
        [System.IO.File]::WriteAllText((Join-Path $stand ($name + '\config\rclone\rclone.conf')), "[base]`ntype = sftp`nhost = 192.0.2.10`n`n[base-via]`ntype = sftp`nssh = ssh base-far`n`n[dad]`ntype = sftp`nhost = 192.0.2.30`n`n[dad-via]`ntype = sftp`nhost = 192.0.2.40`nport = 2222`n`n[home]`ntype = sftp`nssh = ssh home-straight`n`n[home-via]`ntype = sftp`nssh =`nhost = 192.0.2.60`n`n[laptop]`ntype = sftp`nhost = 127.0.0.1`n")
        [System.IO.File]::WriteAllText((Join-Path $stand ($name + '\session.conf')), "# the session config of the stand`n")
    }

    # --- заглушка PowerShell и rclone ---------------------------------------------
    $workerProject = Join-Path $stand 'build\Worker\Worker.csproj'
    [System.IO.File]::WriteAllText($workerProject, @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>Worker</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <PublishSingleFile>true</PublishSingleFile>
    <SelfContained>false</SelfContained>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$(Join-Path $AppRoot 'Tests\Stand\Worker.cs')" />
  </ItemGroup>
</Project>
"@)
    $workerOut = Join-Path $stand 'build\worker-out'
    if (-not (Invoke-Build @('publish', $workerProject, '-c', 'Release', '-r', 'win-x64', '-o', $workerOut, '--nologo', '-v', 'q'))) {
        Write-Host 'СБОЙ  заглушка не собралась'
        exit 1
    }
    foreach ($to in 'Worker\Worker.exe', 'App\AudionPs.exe', 'Tools\rclone\rclone.exe') {
        Copy-Item -LiteralPath (Join-Path $workerOut 'Worker.exe') -Destination (Join-Path $stand $to) -Force
    }

    # --- пробы ----------------------------------------------------------------------
    # Пакеты Avalonia - той же версии, с которой собрано окно.
    $windowProject = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Source\AudionSyncTools.csproj'))
    $packages = [ordered]@{}
    foreach ($hit in [regex]::Matches($windowProject, '<PackageReference Include="(Avalonia[\w\.]*)" Version="([^"]+)"')) { $packages[$hit.Groups[1].Value] = $hit.Groups[2].Value }
    $packages.Remove('AvaloniaUI.DiagnosticsSupport')
    $packages['Avalonia.Headless'] = $packages['Avalonia']
    $references = ($packages.GetEnumerator() | ForEach-Object { '    <PackageReference Include="{0}" Version="{1}" />' -f $_.Key, $_.Value }) -join "`n"

    $harnessProject = Join-Path $stand 'build\Harness\Harness.csproj'
    [System.IO.File]::WriteAllText($harnessProject, @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>Harness</AssemblyName>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>false</SelfContained>
    <OutputPath>$(Join-Path $stand 'App')\</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
    <AppendRuntimeIdentifierToOutputPath>false</AppendRuntimeIdentifierToOutputPath>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="$(Join-Path $AppRoot 'Tests\Stand\Harness.cs')" />
    <Reference Include="AudionSyncTools"><HintPath>$Dll</HintPath></Reference>
$references
  </ItemGroup>
</Project>
"@)
    if (-not (Invoke-Build @('build', $harnessProject, '-c', 'Release', '--nologo', '-v', 'q'))) {
        Write-Host 'СБОЙ  пробы не собрались: окно изменило то, что они зовут по имени, - поправить Tests\Stand\Harness.cs'
        exit 1
    }

    $built = Get-Item -LiteralPath $Dll
    Write-Host ('окно: {0}, собрано {1:dd.MM HH:mm:ss}' -f $built.FullName, $built.LastWriteTime)
    Write-Host ''

    # --- прогон ---------------------------------------------------------------------
    $env:AUDION_STAND_PS = $realPs
    try {
        & (Join-Path $stand 'App\Harness.exe') 2>&1 | ForEach-Object { Write-Host "$_" }
        $failed = $LASTEXITCODE
    } finally {
        $env:AUDION_STAND_PS = $null
    }
    if ($failed -lt 0 -or $failed -gt 90) {
        Write-Host ''
        Write-Host ('СБОЙ  прогон оборвался, код {0}: проба упала раньше вердикта' -f $failed)
        $failed = 1
    }
} finally {
    # Своих процессов стенд не оставляет: что осталось - его же заглушки, выбранные по полному пути.
    $left = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($box, [StringComparison]::OrdinalIgnoreCase) })
    foreach ($process in $left) { try { $process.Kill() } catch { } }
    if ($left.Count) { Start-Sleep -Milliseconds 500 }
    if ($Keep) { Write-Host ('стенд оставлен: {0}' -f $stand) }
    elseif (Test-Path -LiteralPath $box) {
        try { [System.IO.Directory]::Delete($box, $true) } catch { Write-Host ('стенд не удалился: {0}' -f $box) }
    }
}
exit $failed
