# UTF-8 with BOM
<#
.SYNOPSIS
    Собирает Start.exe — значок запуска в корне проекта.

.DESCRIPTION
    Компилятор берётся тот, что стоит в Windows вместе с .NET Framework:
    ставить ничего не нужно, и собранный exe запускается на любой машине без
    рантаймов. Значок приезжает из Assets\SyncTools.ico; если его нет, рядом
    лежит Build-IconFromImage.ps1, который раскладывает его из картинки.

    После сборки exe спрашивают самого себя: --self-test проверяет, что рядом
    лежит App\AudionSyncTools.exe - окно, которое он запускает (его собирает
    builder_main.cmd build_app). До 05.10.2026 лаунчер запускал прежнее окно
    через PowerShell системы.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$AppRoot = [System.IO.Path]::GetFullPath($AppRoot)

$sourcePath = Join-Path $PSScriptRoot 'Start.cs'
$iconPath = Join-Path $AppRoot 'Assets\SyncTools.ico'
$outputPath = Join-Path $AppRoot 'Start.exe'

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Исходник лаунчера не найден: $sourcePath"
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Значок не найден: $iconPath — соберите его через Build-IconFromImage.ps1"
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $compiler) {
    throw 'Компилятор C# из состава .NET Framework не найден.'
}

$compilerArguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/platform:anycpu',
    '/codepage:65001',
    "/win32icon:$iconPath",
    '/reference:System.dll',
    '/reference:System.Core.dll',
    '/reference:System.Windows.Forms.dll',
    "/out:$outputPath",
    $sourcePath
)
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
    throw "Сборка Start.exe не удалась, код $LASTEXITCODE."
}

& $outputPath '--self-test' | Out-Null
$selfTest = $LASTEXITCODE

Write-Output "Собрано : $outputPath"
Write-Output "Значок  : $iconPath"
Write-Output "Проверка: $(if ($selfTest -eq 0) { 'прошла' } else { "код $selfTest" })"
