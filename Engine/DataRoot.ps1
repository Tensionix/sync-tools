<#
    Где папка данных этой машины.

    Зовётся она по машине - `Audion Backup Laptop`, `Audion Backup Work`, - и
    угадывать имя нельзя: раньше здесь стояло жёсткое `Audion Backup`, и после
    переименования папки сценарии перестали видеть свои же конфиги. Туннель не
    поднимался с сообщением «нет конфига от роутера», хотя конфиг лежал рядом.

    Порядок поиска:

        1. Указатель программы `config\profile.json` - его пишет окно, когда
           человек выбирает папку. Это единственный надёжный ответ, когда папок
           рядом несколько: дома лежат комплекты для всех машин сразу.
        2. Единственная соседняя `Audion Backup*` - на самой машине она одна.
        3. Прежнее имя `Audion Backup` - чтобы старая раскладка работала как
           работала.

    Файл дот-сорсится сценариями: они лежат в разных папках и модуль окна не
    грузят, а знать ответ должны одинаково.
#>

function Get-AbkDataRootPath {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        # Явно названная папка старше любых догадок: её передают окно и
        # врапперы, чтобы сценарий работал с тем же комплектом, что и они.
        [string]$Root
    )

    if ($Root) {
        if (-not (Test-Path -LiteralPath $Root)) {
            throw "папка данных не найдена: $Root"
        }
        return (Resolve-Path -LiteralPath $Root).Path
    }

    $file = Join-Path $AppRoot 'config\profile.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $kept = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $said = [string]$kept.dataRoot
            if ($said -and (Test-Path -LiteralPath $said)) { return $said }
        } catch { }
    }

    $near = Split-Path -Parent $AppRoot
    if ($near -and (Test-Path -LiteralPath $near)) {
        $found = @(Get-ChildItem -LiteralPath $near -Directory -Filter 'Audion Backup*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne (Split-Path -Leaf $AppRoot) } | Sort-Object Name)
        if ($found.Count -eq 1) { return $found[0].FullName }

        # Несколько папок и ни указателя, ни явного ключа - работать нельзя.
        # Прежде здесь бралась первая по алфавиту с предупреждением, и это была
        # дыра: дома рядом лежат комплекты всех машин, и установщик туннеля
        # брал из чужого ключи и конфиги. Машина получала чужую личность, а
        # правки уходили в чужой комплект - и никто об этом не узнавал, потому
        # что предупреждение тонуло в выводе.
        #
        # Теперь выбор делает человек: ключом -Root или записью в
        # config\profile.json, которую пишет окно.
        if ($found.Count -gt 1) {
            $names = ($found | ForEach-Object { $_.Name }) -join ', '
            throw ("рядом несколько папок данных ($names) - выберите нужную: " +
                   "ключом -Root или кнопкой ПАПКА ДАННЫХ в окне")
        }
    }

    Join-Path $near 'Audion Backup'
}

function Resolve-AbkWorkRoot {
    <#
        Папка данных для рабочих файлов - не бросая исключений.

        Рабочие файлы соединений (адреса, rclone.conf, ключи R2, отпечатки
        хостов, план зеркала, облака) живут только в папке машины; в программе
        остаются шаблоны и указатель. Читателю нужен ответ всегда: когда папок
        рядом несколько и указателя нет, отвечаем несуществующим путём - файлы
        окажутся «нет», окно попросит выбрать папку кнопкой ПАПКА ДАННЫХ.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot
    )
    if ($DataRoot) { return $DataRoot }
    try { return (Get-AbkDataRootPath -AppRoot $AppRoot) }
    catch { return (Join-Path (Split-Path -Parent $AppRoot) '__AUDION_DATA_FOLDER_NOT_SELECTED__') }
}

function Get-AbkWorkPath {
    <# Полный путь рабочего файла в папке данных: та же раскладка, что была в программе. #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$Rel,
        [string]$DataRoot
    )
    Join-Path (Resolve-AbkWorkRoot -AppRoot $AppRoot -DataRoot $DataRoot) $Rel
}
