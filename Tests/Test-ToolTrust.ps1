#requires -Version 7.0
<#
    Скачанный инструмент проверяется раньше, чем запускается.

    Программа работает с правами администратора и сама качает то, чем работает:
    клиент туннеля, rclone, терминал, архиватор, редакторы. До проверки
    08.10.2026 «проверкой» скачанного был его запуск: файл спрашивали о версии и
    по ответу судили, годен ли он, - то есть чужой файл сперва исполнялся.

    Теперь до первого запуска сверяется, чьё скачанное:
      - клиент туннеля - подпись Cloudflare (Update-Tools.ps1 и
        Tunnel\Install-TunnelClient.ps1);
      - терминал и Microsoft Edit - подпись Microsoft;
      - rclone, micro и PeaZip, которых издатели не подписывают, - сумма SHA-256
        из файла, который издатель кладёт рядом с выпуском (SHA256SUMS у rclone,
        <архив>.sha у micro, SHA256.txt у PeaZip): не сошлась - не ставится, не
        нашлась - сказано и ставится.

    Проверяется:
      - функции сверки, взятые из Update-Tools.ps1 и Install-Tools.ps1 так, как
        они там написаны: подпись ожидаемого издателя проходит; другой издатель
        и файл без подписи - отказ; сумма сошлась, не сошлась, не нашлась;
      - в трёх сценариях сверка стоит раньше первого запуска скачанного.

    Подпись сверяется на файлах, которые есть на любой машине с программой:
    библиотека PowerShell из App\ (Microsoft Corporation), библиотека окна (без
    подписи) и notepad.exe Windows (другой издатель). Ничего не качает; пишет
    только во временную папку. Возвращает 0, когда всё сходится.
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
function Test-Throws { param([scriptblock]$Do) try { & $Do | Out-Null; return $false } catch { return $true } }

Write-Host ''
Write-Host '===== ДОВЕРИЕ К СКАЧАННОМУ ====='

# --- функции сверки, как они написаны в сценарии -------------------------------
$updatePath = Join-Path $AppRoot 'Engine\Scripts\Update-Tools.ps1'
$update = [System.IO.File]::ReadAllText($updatePath)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($updatePath, [ref]$null, [ref]$null)
$found = @{}
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) { $found[$node.Name] = $node.Extent.Text }
$have = $found.ContainsKey('Assert-Publisher') -and $found.ContainsKey('Assert-PublisherSum')
Test-Step -Title 'функции сверки есть в Update-Tools.ps1' -Ok $have -Note 'Assert-Publisher, Assert-PublisherSum'
if (-not $have) { Write-Host ''; Write-Host 'провалено проверок: 1'; exit 1 }
# Сверка суммы говорит своё через Write-Line сценария; здесь его слова не нужны.
function Write-Line { param($Text, $Color = 'Gray') }
Invoke-Expression $found['Assert-Publisher']
Invoke-Expression $found['Assert-PublisherSum']

# --- подпись -------------------------------------------------------------------
$microsoft = '^CN=Microsoft Corporation,'
$cloudflare = [regex]::Match($update, "Assert-Publisher -Path \`$fresh -Publisher '(?<text>[^']+)'").Groups['text'].Value
$signed = Join-Path $AppRoot 'App\System.Management.Automation.dll'
$plain = Join-Path $AppRoot 'App\AudionSyncTools.dll'
if ((Test-Path -LiteralPath $signed) -and (Test-Path -LiteralPath $plain)) {
    Test-Step -Title 'подпись ожидаемого издателя проходит' -Ok (-not (Test-Throws { Assert-Publisher -Path $signed -Publisher $microsoft -What 'probe' })) -Note 'библиотека PowerShell, Microsoft Corporation'
    Test-Step -Title 'тот же файл под именем другого издателя - отказ' -Ok ($cloudflare.Length -gt 0 -and (Test-Throws { Assert-Publisher -Path $signed -Publisher $cloudflare -What 'probe' })) -Note 'ждали Cloudflare'
    Test-Step -Title 'файл без подписи - отказ' -Ok (Test-Throws { Assert-Publisher -Path $plain -Publisher $microsoft -What 'probe' }) -Note 'библиотека окна'
    Test-Step -Title 'из нескольких файлов хватает одного негодного' -Ok (Test-Throws { Assert-Publisher -Path @($signed, $plain) -Publisher $microsoft -What 'probe' }) -Note 'подписанный и неподписанный'
} else {
    Test-Step -Title 'App\ собрана: есть на чём сверять подпись' -Ok $false -Note 'нет App\System.Management.Automation.dll - сначала builder_main.cmd build_app'
}
# Подпись действительна, но издатель не тот: у Windows свои файлы подписаны «Microsoft Windows».
$windows = Join-Path $env:WINDIR 'System32\notepad.exe'
$other = $(if (Test-Path -LiteralPath $windows) { Get-AuthenticodeSignature -LiteralPath $windows } else { $null })
if ($other -and $other.Status -eq 'Valid' -and "$($other.SignerCertificate.Subject)" -notmatch $microsoft) {
    Test-Step -Title 'действительная подпись другого издателя - отказ' -Ok (Test-Throws { Assert-Publisher -Path $windows -Publisher $microsoft -What 'probe' }) -Note 'notepad.exe, Microsoft Windows'
} else {
    Write-Host 'ок    действительная подпись другого издателя - отказ      на этой машине нечем проверить: шаг пропущен'
}

# --- сумма ---------------------------------------------------------------------
$box = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-tool-trust-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][System.IO.Directory]::CreateDirectory($box)
try {
    $archive = Join-Path $box 'tool-v1.2.3-windows-amd64.zip'
    [System.IO.File]::WriteAllText($archive, 'an archive of the probe')
    $sum = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrong = ('0' * 64)
    $name = [System.IO.Path]::GetFileName($archive)
    $list = "{0}  tool-v1.2.3-linux-amd64.zip`n{1}  {2}`n{0}  {2}.sig`n" -f $wrong, $sum, $name
    # Сверка суммы написана дважды: в Update-Tools.ps1 (rclone) и в Install-Tools.ps1 (micro, PeaZip).
    $toolsPath = Join-Path $AppRoot 'Engine\Scripts\Install-Tools.ps1'
    $toolsAst = [System.Management.Automation.Language.Parser]::ParseFile($toolsPath, [ref]$null, [ref]$null)
    $second = @($toolsAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-PublisherSum' }, $false)) | Select-Object -First 1
    Test-Step -Title 'сверка суммы есть и в Install-Tools.ps1' -Ok ($null -ne $second) -Note 'Assert-PublisherSum: micro и PeaZip'
    foreach ($where in @(@{ Name = 'Update-Tools.ps1'; Text = $found['Assert-PublisherSum'] }, @{ Name = 'Install-Tools.ps1'; Text = $(if ($second) { $second.Extent.Text } else { '' }) })) {
        if (-not $where.Text) { continue }
        Invoke-Expression $where.Text
        # Свои слова сверки (Write-Host) здесь не нужны: поток сведений отведён.
        Test-Step -Title ('сумма издателя сошлась · ' + $where.Name) -Ok ((Assert-PublisherSum -File $archive -Sums $list -Name $name -What 'probe' 6>$null) -eq $true) -Note 'строка найдена среди соседних'
        Test-Step -Title ('и со звёздочкой, и прописными · ' + $where.Name) -Ok ((Assert-PublisherSum -File $archive -Sums ("{0} *{1}" -f $sum.ToUpperInvariant(), $name) -Name $name -What 'probe' 6>$null) -eq $true)
        Test-Step -Title ('сумма не сошлась - отказ · ' + $where.Name) -Ok (Test-Throws { Assert-PublisherSum -File $archive -Sums ("{0}  {1}" -f $wrong, $name) -Name $name -What 'probe' 6>$null })
        Test-Step -Title ('суммы нет - сказано, установка идёт · ' + $where.Name) -Ok ((Assert-PublisherSum -File $archive -Sums ("{0}  {1}.sig" -f $sum, $name) -Name $name -What 'probe' 6>$null) -eq $false -and (Assert-PublisherSum -File $archive -Sums '' -Name $name -What 'probe' 6>$null) -eq $false) -Note 'строка похожего имени и пустой ответ'
    }
} finally {
    try { [System.IO.Directory]::Delete($box, $true) } catch { }
}

# --- сверка стоит раньше первого запуска ---------------------------------------
function Test-Before { param([string]$Text, [string]$First, [string]$Then) $a = $Text.IndexOf($First); $b = $(if ($a -ge 0) { $Text.IndexOf($Then, $a) } else { -1 }); return ($a -ge 0 -and $b -gt $a) }
$rclonePart = $(if ($update.IndexOf('--- rclone ---') -ge 0 -and $update.IndexOf('--- terminal ---') -gt 0) { $update.Substring($update.IndexOf('--- rclone ---'), $update.IndexOf('--- terminal ---') - $update.IndexOf('--- rclone ---')) } else { '' })
Test-Step -Title 'клиент туннеля: подпись раньше запуска' -Ok (Test-Before $update 'Assert-Publisher -Path $fresh -Publisher' '& $fresh --version') -Note 'Update-Tools.ps1'
Test-Step -Title 'rclone: сумма раньше распаковки' -Ok (Test-Before $rclonePart 'Assert-PublisherSum -File $zip' 'Expand-Package -Zip $zip') -Note 'Update-Tools.ps1'
Test-Step -Title 'терминал: подпись раньше замены прежней копии' -Ok (Test-Before $update 'Assert-Publisher -Path @(Get-ChildItem -LiteralPath $source' 'Install-Fresh -Source $source') -Note 'Update-Tools.ps1'

$tunnel = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Tunnel\Install-TunnelClient.ps1'))
Test-Step -Title 'установщик клиента туннеля: подпись раньше запуска' `
    -Ok ((Test-Before $tunnel 'Assert-Cloudflared -Path $tmp' '& $tmp --version') -and $tunnel -match 'Invoke-WebRequest -Uri \$DownloadUrl -OutFile \$target -UseBasicParsing\r?\n\s*Assert-Cloudflared -Path \$target') `
    -Note 'Install-TunnelClient.ps1: и обновление, и первая закачка'

$tools = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Install-Tools.ps1'))
Test-Step -Title 'Microsoft Edit: подпись раньше запуска' -Ok (Test-Before $tools 'throw "Microsoft Edit is not genuine' '& $exe $versionArg[$Which]') -Note 'Install-Tools.ps1'
Test-Step -Title 'PeaZip: сумма раньше распаковки' -Ok (Test-Before $tools 'Assert-PublisherSum -File $zip -Sums (Get-PublisherSums "https://github.com/peazip/PeaZip/releases/download/$tag/SHA256.txt")' 'Install-Folder -Zip $zip -Marker "peazip.exe"') -Note 'Install-Tools.ps1: SHA256.txt выпуска'
Test-Step -Title 'micro: сумма раньше распаковки' -Ok (Test-Before $tools 'if ($Tool -eq "micro") { [void](Assert-PublisherSum -File $zip -Sums (Get-PublisherSums "$url.sha")' 'Install-Folder -Zip $zip -Marker "$Tool.exe"') -Note 'Install-Tools.ps1: <архив>.sha рядом с архивом'

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
