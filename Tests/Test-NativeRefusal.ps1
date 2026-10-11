#requires -Version 7.0
<#
    Отказ программы, которую сценарий запустил сам, не теряется.

    Код сценария - его собственный: число его exit, а без exit - ноль
    (Tests\Test-ScriptExit.ps1). Раньше обёртка окна кончалась кодом последней
    программы сценария, и отказ icacls или git, оставшийся без присмотра,
    изредка всё же показывался в окне - случайно, когда эта программа была
    последней. Теперь такой сценарий «готово» везде, как и под враппером
    (аудит 08.10.2026). Поэтому там, где отказ программы решает, о чём сценарий
    докладывает, сценарий смотрит на её код сам.

    Сбор ключей исполняется по-настоящему, дважды: с настоящим icacls и с
    заглушкой, которая отказывает. Профиль пользователя, папка данных и ключ -
    свои, во временной папке системы: настоящий профиль и настоящие ключи не
    читаются. Остальные места проверяются чтением.

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

Write-Host ''
Write-Host '===== ОТКАЗ ПРОГРАММЫ В СЦЕНАРИИ ====='

$shell = (Get-Process -Id $PID).Path
$export = Join-Path $AppRoot 'Engine\Scripts\Export-AudionKeys.ps1'
$box = Join-Path ([System.IO.Path]::GetTempPath()) ('abk native refusal ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$profile_ = Join-Path $box 'profile'
$data = Join-Path $box 'Audion Backup Probe'
$stubs = Join-Path $box 'bin'
foreach ($dir in (Join-Path $profile_ '.ssh'), $data, $stubs) { [void][System.IO.Directory]::CreateDirectory($dir) }
# Не ключ: две строки текста с именами пары. Сценарий ключей не читает - он их копирует.
[System.IO.File]::WriteAllText((Join-Path $profile_ '.ssh\probe_ed25519'), "not a key: a file of the check`n")
[System.IO.File]::WriteAllText((Join-Path $profile_ '.ssh\probe_ed25519.pub'), "not a key: its public half`n")
# icacls, который отказывает: стоит в PATH раньше настоящего.
[System.IO.File]::WriteAllText((Join-Path $stubs 'icacls.cmd'), "@exit /b 5`r`n", [System.Text.Encoding]::ASCII)

function Invoke-Export {
    # Сбор ключей под той же оболочкой, что и эта проверка, с домом и PATH песочницы.
    param([switch]$Refusing)
    $keep = @{ USERPROFILE = $env:USERPROFILE; HOMEDRIVE = $env:HOMEDRIVE; HOMEPATH = $env:HOMEPATH; PATH = $env:PATH }
    try {
        $env:USERPROFILE = $profile_
        $env:HOMEDRIVE = $profile_.Substring(0, 2)
        $env:HOMEPATH = $profile_.Substring(2)
        if ($Refusing) { $env:PATH = $stubs + ';' + $env:PATH }
        $said = @(& $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $export -Root $data -Force 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Code = $LASTEXITCODE; Said = $said }
    } finally {
        foreach ($name in $keep.Keys) { Set-Item -LiteralPath ('Env:' + $name) -Value $keep[$name] }
    }
}

try {
    $taken = Join-Path $data 'Tunnel\Export\SSH\probe_ed25519'

    $good = Invoke-Export
    $closed = (Test-Path -LiteralPath $taken) -and (Get-Acl -LiteralPath $taken).AreAccessRulesProtected
    Test-Step -Title 'сбор ключей с настоящим icacls: ключ взят и закрыт' `
        -Ok ($good.Code -eq 0 -and $closed -and @($good.Said | Where-Object { $_ -match 'taken: probe_ed25519$' }).Count -eq 1) `
        -Note ('код {0}; наследование прав снято: {1}' -f $good.Code, $closed)
    # Песочница не должна была дотянуться до настоящего профиля: в Export лежит только пробная пара.
    $names = @(Get-ChildItem -LiteralPath (Join-Path $data 'Tunnel\Export') -Recurse -File | ForEach-Object { $_.Name } | Sort-Object)
    Test-Step -Title 'взята только пробная пара - настоящий профиль не тронут' -Ok (($names -join ',') -eq 'probe_ed25519,probe_ed25519.pub') -Note ($names -join ', ')

    $bad = Invoke-Export -Refusing
    Test-Step -Title 'icacls отказал: сценарий кончается ошибкой и говорит, какой ключ остался открыт' `
        -Ok ($bad.Code -eq 1 -and @($bad.Said | Where-Object { $_ -match 'icacls failed to close it.*probe_ed25519$' }).Count -eq 1 -and
             @($bad.Said | Where-Object { $_ -match 'failed: 1 - keys left' }).Count -eq 1 -and @($bad.Said | Where-Object { $_ -match 'taken: probe_ed25519$' }).Count -eq 0) `
        -Note ('код {0}' -f $bad.Code)
} finally {
    try { [System.IO.Directory]::Delete($box, $true) } catch { }
}

# --- остальные места: чтением ---------------------------------------------------
function Read-Script { param([string]$Relative) [System.IO.File]::ReadAllText((Join-Path $AppRoot $Relative)) }
$newKey = Read-Script 'Engine\Scripts\New-ClientKey.ps1'
$import = Read-Script 'Engine\Scripts\Import-AudionKeys.ps1'
$openssh = Read-Script 'Tunnel\RemoteDesktop\Install-OpenSSH.ps1'
$clouds = Read-Script 'Engine\Scripts\Manage-Clouds.ps1'
Test-Step -Title 'SSH-KEYGEN говорит о ключе, оставшемся открытым в папке данных' `
    -Ok ($newKey -match "icacls \`$To /inheritance:r[^\r\n]*\r?\n[^\r\n]*\r?\n\s*if \(\`$LASTEXITCODE -ne 0\) \{ Write-Host \('\[keys\] icacls failed") -Note 'New-ClientKey.ps1: Set-PrivateHalf'
Test-Step -Title 'IMPORT KEYS пишет «fixed» только когда git принял правку' `
    -Ok ($import -match "config core\.sshCommand \`$wanted\r?\n\s*if \(\`$LASTEXITCODE -ne 0\) \{\r?\n[^\r\n]*git failed to take the fix[^\r\n]*\r?\n\s*\`$Failed\+\+") -Note 'Import-AudionKeys.ps1: счётчик failed и код 1'
Test-Step -Title 'OpenSSH: файл ключей с невыставленными правами - отказ, а не «прописаны»' `
    -Ok ($openssh -match "icacls \`$dst /inheritance:r[^\r\n]*\r?\n[^\r\n]*\r?\n\s*if \(\`$LASTEXITCODE -ne 0\) \{ throw ") -Note 'Install-OpenSSH.ps1'
Test-Step -Title 'ОБЛАКА: запись, которую rclone не убрал, не названа убранной' `
    -Ok ($clouds -match "config delete \`$Name\r?\n\s*\`$gone = \(\`$LASTEXITCODE -eq 0\)" -and $clouds.Contains('if (-not $gone) {') -and
         $clouds -match "config delete \`$Name \| Out-Null\r?\n\s*\`$stayed = \(\`$LASTEXITCODE -ne 0\)") -Note 'Manage-Clouds.ps1: -Remove и -Rename'

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
