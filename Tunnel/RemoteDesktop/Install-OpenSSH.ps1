<#
.SYNOPSIS
    Поставить OpenSSH Server на этой машине без Windows Update.
.DESCRIPTION
    Самостоятельный сценарий - работает на голой машине, набор не нужен. Тянет
    официальный пакет (Microsoft, PowerShell/Win32-OpenSSH), проверяет подпись
    Microsoft и ставит из временной папки. Пакет нигде не хранится - всегда
    берётся свежий. Дальше включает службу и открывает порт 22 своим сетям.
    Windows Update, Microsoft Store и Дополнительные компоненты не нужны.
.PARAMETER MsiPath
    Локальный .msi (например с флешки). Задан - без скачивания. На случай, когда
    у машины нет интернета к GitHub.
.PARAMETER AdminKeys
    Файл с публичными ключами: ляжет в administrators_authorized_keys и получит
    жёсткие права. Для учётки-администратора.
.PARAMETER Anywhere
    Открыть порт 22 без ограничения по сетям (по умолчанию - только свои подсети).
.EXAMPLE
    .\Install-OpenSSH.ps1
.EXAMPLE
    .\Install-OpenSSH.ps1 -AdminKeys .\administrators_authorized_keys
.EXAMPLE
    .\Install-OpenSSH.ps1 -MsiPath D:\OpenSSH-Win64-v10.0.0.0.msi -AdminKeys .\administrators_authorized_keys
#>
[CmdletBinding()]
param(
    [string]$MsiPath,
    [string]$AdminKeys,
    [switch]$Anywhere,
    [switch]$Elevated,
    [string]$Root,
    [switch]$NoPause
)
$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
function Say { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }

if (-not (Test-Admin)) {
    Say "нужны права администратора - поднимаю (UAC)..." Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Elevated')
    if ($MsiPath)   { $a += @('-MsiPath',   "`"$MsiPath`"") }
    if ($AdminKeys) { $a += @('-AdminKeys', "`"$AdminKeys`"") }
    if ($Anywhere)  { $a += '-Anywhere' }
    if ($Root) { $a += @('-Root', ('"' + ($Root -replace '(\\+)$', '$1$1') + '"')) }
    if ($NoPause) { $a += '-NoPause' }
    $child = Start-Process powershell -Verb RunAs -ArgumentList $a -Wait -PassThru
    exit $child.ExitCode
}

trap { Write-Host "`n  Сорвалось: $($_.Exception.Message)`n" -ForegroundColor Red; if ($Elevated -and -not $NoPause) { Read-Host "Enter - закрыть" | Out-Null }; exit 1 }

Write-Host "`n=== OpenSSH Server на $env:COMPUTERNAME ===`n" -ForegroundColor Cyan

$appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$identityLibrary = Join-Path $appRoot 'Engine\SshHostIdentity.ps1'
if (Test-Path -LiteralPath $identityLibrary) {
    . (Join-Path $appRoot 'Engine\DataRoot.ps1')
    $Root = Get-AbkDataRootPath -AppRoot $appRoot -Root $Root
    . $identityLibrary
    $null = Restore-AbkSshHostIdentity -DataRoot $Root
} elseif ($Root) { throw 'Host identity library missing; use the complete Sync Tools program' }
else { Say 'Standalone installer: no DATA identity backup. Use Sync Tools SSHD before reinstalling Windows.' Yellow }

if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Say "sshd уже установлен" Green
} else {
    $tmp = $null
    if ($MsiPath) {
        if (-not (Test-Path -LiteralPath $MsiPath)) { throw "файл не найден: $MsiPath" }
        $msi = (Resolve-Path -LiteralPath $MsiPath).Path
        Say "ставлю из локального файла: $msi" Yellow
    } else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Say "ищу свежий пакет OpenSSH на GitHub..." Yellow
        $rels = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases' -Headers @{ 'User-Agent' = 'audion-sync-tools' } -UseBasicParsing
        $asset = $null
        foreach ($r in $rels) { $asset = $r.assets | Where-Object { $_.name -match '^OpenSSH-Win64.*\.msi$' } | Select-Object -First 1; if ($asset) { break } }
        if (-not $asset) { throw "в релизах нет пакета OpenSSH-Win64 .msi" }
        $tmp = Join-Path $env:TEMP ("audion-openssh-" + [Guid]::NewGuid().ToString('N').Substring(0,8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $msi = Join-Path $tmp $asset.name
        Say ("качаю " + $asset.name + " (" + [math]::Round($asset.size / 1MB, 1) + " МБ)...") Yellow
        Invoke-WebRequest $asset.browser_download_url -OutFile $msi -UseBasicParsing
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $msi
    if ($sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'Microsoft') {
        throw "подпись не подтверждена (Status=$($sig.Status)) - установка отменена"
    }
    Say "подпись Microsoft подтверждена" Green

    Say "ставлю пакет..." Yellow
    $pr = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
    if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($pr.ExitCode -ne 0) { throw "msiexec вернул код $($pr.ExitCode)" }
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw "служба sshd не появилась после установки" }
    Say "пакет установлен" Green
}

Set-Service sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }
Say "служба sshd: $((Get-Service sshd).Status), автозапуск" Green
if ($Root) { $null = Save-AbkSshHostIdentity -DataRoot $Root }

$RuleName = 'Audion Remote Files (SSH 22)'
$Trusted = @('192.168.10.0/24','192.168.2.0/24','192.168.5.0/24','10.11.0.0/24','10.10.0.0/24','10.12.0.0/24','192.168.15.0/24','172.16.6.0/24')
Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue | Disable-NetFirewallRule -ErrorAction SilentlyContinue
if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -DisplayName $RuleName }
$scope = if ($Anywhere) { 'Any' } else { $Trusted }
New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -RemoteAddress $scope | Out-Null
Say ("порт 22 открыт " + $(if ($Anywhere) { 'без ограничения по сетям' } else { "для своих сетей ($($Trusted.Count))" })) Green

if ($AdminKeys) {
    if (-not (Test-Path -LiteralPath $AdminKeys)) { throw "файл ключей не найден: $AdminKeys" }
    $dst = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    Copy-Item -LiteralPath $AdminKeys -Destination $dst -Force
    & icacls $dst /inheritance:r /grant '*S-1-5-18:(F)' /grant '*S-1-5-32-544:(F)' | Out-Null
    # С правами, которые не выставились, sshd этот файл не примет вовсе: вход по ключу не заработает.
    if ($LASTEXITCODE -ne 0) { throw "права на файл ключей не выставились (icacls $LASTEXITCODE), sshd его не примет: $dst" }
    Say "ключи прописаны: $dst" Green
}

Start-Sleep 2
$listen = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
Write-Host ""
if ($listen) { Write-Host "  ГОТОВО: sshd принимает подключения на порту 22." -ForegroundColor Green }
else { Write-Host "  Служба запущена, но порт 22 не слушается - Get-WinEvent -LogName OpenSSH/Operational -Max 10" -ForegroundColor Yellow }
if ($Elevated -and -not $NoPause) { Write-Host "`n  Enter - закрыть окно." -ForegroundColor DarkGray; Read-Host | Out-Null }
if (-not $listen) { exit 1 }
