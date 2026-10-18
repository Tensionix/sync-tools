using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using AudionSyncTools.Core;
using Ellipse = Avalonia.Controls.Shapes.Ellipse;

namespace AudionSyncTools;

/// <summary>
/// SETTINGS and ABOUT: buttons at the top right, opened in place of the panels, as in Audion Disk
/// Tools - the journal stays beside them, so what a check of the versions says is seen at once.
/// Here lives what is set once and left alone: the data folder (it is chosen at the first start
/// anyway), the tools the program carries with their versions and their update, the fonts and the
/// look of the window, the folders. The same button, another section or Esc brings the panels back.
/// </summary>
public partial class MainWindow
{
    bool _settingsOpen;
    ToggleButton? _settingsButton;
    Panel? _into;

    /// <summary>Which page stands in place of the panels while one is open: "settings" or "about".</summary>
    string _page = "settings";

    void ToggleSettings(bool? open = null) => ShowPage("settings", open);

    void ToggleAbout(bool? open = null) => ShowPage("about", open);

    /// <summary>
    /// SETTINGS and ABOUT stand in place of the panels, one at a time: the button of the page that
    /// stands closes it, the other one changes the page. Closing leaves the page as it was, so a
    /// window built anew (another language, another data folder) brings back the same one.
    /// </summary>
    void ShowPage(string page, bool? open)
    {
        bool show = open ?? !(_settingsOpen && _page == page);
        if (show) _page = page;
        _settingsOpen = show;
        if (_settingsButton is not null) _settingsButton.IsChecked = _settingsOpen && _page == "settings";
        AboutButton.IsChecked = _settingsOpen && _page == "about";
        foreach (var (name, button) in _sectionButtons) button.IsChecked = !_settingsOpen && name == _section;
        LeftPanel.IsVisible = RightPanel.IsVisible = MidScroll.IsVisible = MidSplitter.IsVisible = !_settingsOpen;
        // The row of big buttons belongs to a section of work; over the settings it would promise actions on panels that are not there.
        BarFrame.IsVisible = ActionRow.IsVisible = !_settingsOpen;
        SettingsHost.IsVisible = _settingsOpen;
        if (!_settingsOpen) _active.FocusList();
        else if (_page == "about") FillAbout();
        else FillSettings();
    }

    // ------------------------------------------------------------ blocks, as Disk Tools builds them

    void Add(Control control) => (_into ?? SettingsBody).Children.Add(control);

    /// <summary>A titled card in a column; what follows goes into it until the next one.</summary>
    void Open(Panel column, string title, params Control[] actions)
    {
        var body = new StackPanel { Spacing = 2 };
        var caption = new TextBlock { Text = title, Classes = { "caption" }, Margin = new Thickness(0, 0, 0, 4), VerticalAlignment = VerticalAlignment.Center };
        if (actions.Length == 0) body.Children.Add(caption);
        else
        {
            // The buttons of a block stand in the line of its title, on the right: a row of their own made the column a row too tall.
            var head = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal };
            foreach (var action in actions) buttons.Children.Add(action);
            Grid.SetColumn(buttons, 1);
            head.Children.Add(caption);
            head.Children.Add(buttons);
            body.Children.Add(head);
        }
        column.Children.Add(new Border { Classes = { "subcard" }, Child = body });
        _into = body;
    }

    /// <summary>An explanation under a switch: smaller and quieter than the switch.</summary>
    void Note(string text) => Add(new TextBlock { Text = text, Classes = { "note" }, TextWrapping = TextWrapping.Wrap });

    void Pair(string key, string value, int keyWidth = 150)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions($"{keyWidth},*") };
        row.Children.Add(new TextBlock { Text = key, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 8, 2) });
        var val = new SelectableTextBlock { Text = value, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2) };
        Grid.SetColumn(val, 1);
        row.Children.Add(val);
        Add(row);
    }

    /// <summary>A row of switches of which one is on: buttons, never a drop-down.</summary>
    void Choice<T>(IEnumerable<(T Value, string Label, string Tip)> options, T current, Action<T> choose, Control? after = null) where T : notnull
    {
        var row = new Views.FlowRow { Margin = new Thickness(0, 2, 0, 4), LineSpacing = 4 };
        var buttons = new List<(ToggleButton Button, T Value)>();
        foreach (var (value, label, tip) in options)
        {
            var button = new ToggleButton { Content = label, Classes = { "switch" }, IsChecked = Equals(value, current) };
            ToolTip.SetTip(button, tip);
            buttons.Add((button, value));
            row.Children.Add(button);
        }
        foreach (var (button, value) in buttons)
        {
            button.Click += (_, _) =>
            {
                foreach (var (other, otherValue) in buttons) other.IsChecked = Equals(otherValue, value);
                choose(value);
            };
        }
        if (after is not null) row.Children.Add(after);
        Add(row);
    }

    Button Action(string label, string tip, Action run, string? tone = null)
    {
        var button = new Button { Content = label, Classes = { "small" } };
        if (tone is not null) button.Classes.Add(tone);
        ToolTip.SetTip(button, tip);
        button.Click += (_, _) => run();
        return button;
    }

    void Row(params Control[] controls)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 2) };
        foreach (var control in controls) row.Children.Add(control);
        Add(row);
    }

    // ------------------------------------------------------------ the section

    void FillSettings()
    {
        SettingsBody.Children.Clear();
        _into = null;
        Add(new TextBlock { Text = "SETTINGS", FontWeight = FontWeight.SemiBold, FontSize = 16, Margin = new Thickness(0, 0, 0, 8) });

        // Two columns of blocks: the data and the tools on the left, the look of the window on the right.
        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,16,*") };
        var left = new StackPanel { Spacing = 10 };
        var right = new StackPanel { Spacing = 10 };
        Grid.SetColumn(right, 2);
        columns.Children.Add(left);
        columns.Children.Add(right);
        SettingsBody.Children.Add(columns);

        // ---------------- the data folder
        Open(left, "ПАПКА ДАННЫХ");
        Pair("Сейчас", DataRoot.Chosen ? DataRoot.Path_ : Lang.T("не выбрана"));
        Row(
            Action("ВЫБРАТЬ", "Выбрать папку данных этой машины: Audion Backup <Машина>. Программа запоминает только путь к ней - указатель config\\profile.json.", PickDataFolder, DataRoot.Chosen ? null : "warn"),
            Action("ОТКРЫТЬ", "Открыть папку данных в проводнике.", () => { if (DataRoot.Chosen) Shell(DataRoot.Path_); }));
        Note("Ключи, адреса, конфиги соединений и зеркала лежат в папке данных, а не в программе: программу можно снести и распаковать заново - она прочитает указатель и найдёт своё.");

        // ---------------- the tools and their versions
        Open(left, "ИНСТРУМЕНТЫ И ВЕРСИИ",
            Action("ПРОВЕРИТЬ ВЕРСИИ", "Ничего не качать: спросить заново, какие версии доступны. Кружки перекрасятся, ответ - и в журнале.",
                () => CheckVersions(force: true, say: true)),
            Action("ОБНОВИТЬ", "Обновить инструменты, которые программа возит с собой: rclone, cloudflared, терминал, архиватор PeaZip и редакторы Edit и micro. Чего нет - поставить. Настройки, ключи и конфиги остаются.",
                UpdateTools, "run"));
        FillVersions();


        // ---------------- the editor of F4
        Open(left, "РЕДАКТОР F4");
        FillEditors();

        // ---------------- the font
        Open(right, "ШРИФТ");
        Choice(new[]
        {
            (-1, "МЕЛЬЧЕ", "Шрифт: мельче."),
            (0, "ОБЫЧНЫЙ", "Шрифт: обычный - удобно при масштабе экрана 125% и выше."),
            (1, "КРУПНЕЕ", "Шрифт: крупнее - для экранов с масштабом 100%."),
        }, _settings.FontStep, step => SetFont(step));
        FillFonts();

        // ---------------- the backdrop of Windows 11
        Open(right, "ПРОЗРАЧНОСТЬ");
        Choice(new[]
        {
            ("", "НЕТ", "Сплошное окно."),
            ("acrylic", "ACRYLIC", "Прозрачность Windows 11: сквозь окно видно то, что лежит под ним, размытым."),
            ("mica", "MICA", "Прозрачность Windows 11: окно подкрашено обоями рабочего стола, размытыми."),
        }, _settings.Backdrop, backdrop =>
        {
            _settings.Backdrop = backdrop;
            _settings.Save();
            ApplyBackdrop();
        }, BackdropPanelsBox());
        Choice(new[]
        {
            ("light", "ЛЁГКАЯ", "Фон окна прозрачнее: обои и окна под программой видны сильнее."),
            ("mid", "СРЕДНЯЯ", "Средняя плотность фона."),
            ("dense", "ПЛОТНАЯ", "Фон окна плотнее: прозрачность едва заметна, текст читается как на сплошном."),
        }, _settings.BackdropDensity, density =>
        {
            _settings.BackdropDensity = density;
            _settings.Save();
            UpdateGlass();
        });
        Note("Прозрачность рисует сама Windows 11. Если эффекты прозрачности в системе выключены, окно остаётся сплошным.");

        // ---------------- sizes
        Open(right, "РАЗМЕРЫ");
        Choice(new[]
        {
            (false, "КОРОТКО", "КБ, МБ, ГБ — быстро читать."),
            (true, "В БАЙТАХ", "Точные числа: несколько байт разницы между двумя папками показывают другую версию. Колонка размера становится шире."),
        }, _settings.ExactBytes, exact =>
        {
            _settings.ExactBytes = exact;
            _settings.Save();
            Format.ExactBytes = exact;
            // Refresh fits the columns too: exact bytes need a wider one.
            LeftPanel.Refresh();
            RightPanel.Refresh();
        });

        // ---------------- the bottom row
        Open(right, "НИЖНИЙ РЯД КНОПОК");
        Choice(new[]
        {
            (false, "С ПОДПИСЯМИ", "Под каждой кнопкой ряда - строка в два-три слова."),
            (true, "БЕЗ ПОДПИСЕЙ", "Без мелкой второй строки: остаются клавиша и действие, ряд ниже."),
        }, _settings.HideHints, hide =>
        {
            _settings.HideHints = hide;
            _settings.Save();
            ApplyButtonRow();
        });

        Lang.Walk(SettingsHost);
    }

    /// <summary>
    /// The editor F4 opens a file in, as Audion Disk Tools has it: Microsoft Edit and micro ride in
    /// Tools\ (both MIT, both console programs - they open in the terminal the program carries),
    /// Notepad is always in Windows, or a program of one's own.
    /// </summary>
    void FillEditors()
    {
        var row = new Views.FlowRow { LineSpacing = 4, Margin = new Thickness(0, 2, 0, 4) };
        bool own = _settings.Editor is { Length: > 0 } chosen && chosen is not ("notepad" or "micro") && File.Exists(chosen);
        var current = own ? "own" : _settings.Editor switch { "notepad" => "notepad", "micro" when Editors.Micro is not null => "micro", _ => Editors.Edit is null ? "notepad" : "" };
        foreach (var (key, label, found, tip) in new (string, string, string?, string)[]
        {
            ("", "EDIT", Editors.Edit, "Microsoft Edit — простой консольный редактор, лицензия MIT. Открывается в своём окне терминала."),
            ("micro", "MICRO", Editors.Micro, "micro — консольный редактор с подсветкой синтаксиса и привычными Ctrl+S, Ctrl+Z, Ctrl+C, лицензия MIT. Открывается в своём окне терминала."),
            ("notepad", "БЛОКНОТ", "notepad.exe", "Блокнот Windows: есть всегда."),
        })
        {
            var chip = new ToggleButton { Content = Lang.T(label), Classes = { "switch" }, IsChecked = current == key, IsEnabled = found is not null };
            ToolTip.SetTip(chip, found is null ? Lang.T("Не найден ни в Tools, ни в PATH.") : Lang.T(tip) + (key == "notepad" ? "" : "\n" + found));
            chip.Click += (_, _) => { _settings.Editor = key; _settings.Save(); FillSettings(); };
            row.Children.Add(chip);
        }
        // The chosen program by its name only - a long path would not fit the block.
        var mine = new ToggleButton
        {
            Content = own ? Path.GetFileNameWithoutExtension(_settings.Editor).ToUpperInvariant() : Lang.T("СВОЙ…"),
            Classes = { "switch" },
            IsChecked = own,
        };
        ToolTip.SetTip(mine, own ? _settings.Editor + "\n" + Lang.T("Щелчок — выбрать другую программу.") : Lang.T("Выбрать программу-редактор: Notepad++, VS Code, Sublime…"));
        mine.Click += async (_, _) =>
        {
            mine.IsChecked = own;
            var files = await StorageProvider.OpenFilePickerAsync(new Avalonia.Platform.Storage.FilePickerOpenOptions
            {
                Title = Lang.T("Редактор для F4"),
                AllowMultiple = false,
                FileTypeFilter = new[] { new Avalonia.Platform.Storage.FilePickerFileType(Lang.T("Программы")) { Patterns = new[] { "*.exe" } } },
            });
            if (files.Count == 0 || Avalonia.Platform.Storage.StorageProviderExtensions.TryGetLocalPath(files[0]) is not { } exe) return;
            _settings.Editor = exe;
            _settings.Save();
            FillSettings();
        };
        row.Children.Add(mine);
        Add(row);
    }

    // ------------------------------------------------------------ the tools and their versions

    sealed record ToolRow(string Id, string Name, Ellipse Dot, SelectableTextBlock Value, Grid Row);

    readonly List<ToolRow> _toolRows = new();

    /// <summary>
    /// A row of the block: a dot, the name, the number that stands. The dot is drawn only where a
    /// newer one can come by the UPDATE button; what rides inside the program keeps its place empty.
    /// </summary>
    void VersionRow(string name, string value, string? id = null, string? tip = null)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("16,150,*"), Background = Brushes.Transparent };
        var dot = new Ellipse
        {
            Width = 9, Height = 9, Fill = App.Ink("DotIdle"), IsVisible = id is not null,
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(dot);
        var caption = new TextBlock { Text = name, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 8, 2) };
        Grid.SetColumn(caption, 1);
        row.Children.Add(caption);
        var said = new SelectableTextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2) };
        // A checked row is written in pieces - the number to come has its own colour - and so never as plain text.
        if (id is null) said.Text = value;
        else said.Inlines!.Add(new Run(value));
        Grid.SetColumn(said, 2);
        row.Children.Add(said);
        if (tip is not null) ToolTip.SetTip(row, tip);
        Add(row);
        if (id is not null) _toolRows.Add(new ToolRow(id, name, dot, said, row));
    }

    /// <summary>The program and what rides inside it, then the tools it carries - each of those with its dot.</summary>
    void FillVersions()
    {
        _toolRows.Clear();
        VersionRow("Audion Sync Tools", Paths.Version);
        VersionRow("Окно", typeof(MainWindow).Assembly.GetName().Version?.ToString(3) + " · Avalonia " + typeof(Application).Assembly.GetName().Version?.ToString(3));
        VersionRow("PowerShell", PowerShellVersion(), tip: PsNote);
        VersionRow(".NET", Environment.Version.ToString());
        foreach (var (id, name) in Updates.Known) VersionRow(name, "…", id);
        VersionRow("Windows", Environment.OSVersion.Version.ToString());
        VersionRow("Права", Program.IsAdmin ? Lang.T("администратор") : Lang.T("без прав администратора"));
        CheckVersions(force: false, say: false);
    }

    const string PsNote = "PowerShell 7 едет внутри программы (App\\AudionPs.exe): сценарии запускаются им, системный PowerShell не участвует.";

    /// <summary>The engine of the program's PowerShell: the version of its own library, no process started.</summary>
    static string PowerShellVersion()
    {
        if (Paths.Ps is not { } ps) return Lang.F("нет: {0}", "App\\AudionPs.exe");
        var library = Path.Combine(Path.GetDirectoryName(ps)!, "System.Management.Automation.dll");
        var version = File.Exists(library) ? FileVersionInfo.GetVersionInfo(library).ProductVersion ?? "" : "";
        int cut = version.IndexOfAny(new[] { '+', ' ' });
        return (cut > 0 ? version[..cut] : version) + " · " + Lang.T("встроенный");
    }

    /// <summary>
    /// The numbers that stand are shown at once, with grey dots; the dots take their colour when the
    /// makers answer - from the cache of six hours, or anew when the button asks.
    /// </summary>
    async void CheckVersions(bool force, bool say)
    {
        var rows = _toolRows.ToList();
        var have = await Task.Run(Updates.Installed);
        foreach (var row in rows) ShowTool(row, new UpdateItem(row.Id, row.Name, have.GetValueOrDefault(row.Id), null), asking: true);

        Dictionary<string, string> latest;
        try { latest = await Updates.LatestAsync(force); }
        catch { latest = new Dictionary<string, string>(); }
        var items = rows.Select(row => new UpdateItem(row.Id, row.Name, have.GetValueOrDefault(row.Id), latest.GetValueOrDefault(row.Id))).ToList();
        for (int i = 0; i < rows.Count; i++) ShowTool(rows[i], items[i], asking: false);
        ShowUpdateDot(items);
        if (!say) return;

        Journal.Add("");
        Journal.Add("===== " + Lang.T("ПРОВЕРКА ВЕРСИЙ") + " =====");
        foreach (var item in items)
            Journal.Add("  " + item.Name.PadRight(18) + (item.Installed ?? Lang.T("нет")).PadRight(16) + (item.Newer switch
            {
                true => Lang.F("доступна {0}", item.Latest!),
                false => Lang.T("свежая"),
                _ => Lang.T("свежую узнать не удалось"),
            }));
        var behind = items.Where(item => item.Newer == true).Select(item => item.Name).ToList();
        SetStatus(behind.Count > 0 ? Lang.F("версии: есть новее - {0}", string.Join(", ", behind))
            : items.Any(item => item.Newer is null) ? Lang.T("версии: источник не ответил")
            : Lang.T("версии: всё свежее"));
    }

    /// <summary>Green - the latest stands; tangerine - a newer one is out, its number beside; grey - not known.</summary>
    static void ShowTool(ToolRow row, UpdateItem item, bool asking)
    {
        var inlines = row.Value.Inlines!;
        inlines.Clear();
        inlines.Add(new Run(item.Installed ?? Lang.T("нет")));
        string tip;
        if (item.Newer == true)
        {
            var tangerine = App.Ink("Tangerine");
            row.Dot.Fill = tangerine;
            inlines.Add(new Run("  →  " + item.Latest) { Foreground = tangerine });
            tip = item.Installed is null
                ? Lang.F("Не установлен. Кнопка ОБНОВИТЬ поставит версию {0}.", item.Latest!)
                : Lang.F("Доступна версия {0}. Кнопка ОБНОВИТЬ поставит её.", item.Latest!);
        }
        else if (item.Newer == false)
        {
            row.Dot.Fill = App.Ink("DotOk");
            tip = Lang.T("Стоит свежая версия.");
        }
        else
        {
            row.Dot.Fill = App.Ink("DotIdle");
            tip = Lang.T(asking ? "Узнаю, какая версия доступна." : "Какая версия доступна, узнать не удалось: источник не ответил.");
        }
        ToolTip.SetTip(row.Row, tip);
    }

    IReadOnlyList<UpdateItem> _lastUpdates = Array.Empty<UpdateItem>();

    /// <summary>
    /// At the start: whether a tool the program carries has a newer version out. The dot on SETTINGS
    /// says so without opening it; the makers are asked at most once in six hours (Core\Updates).
    /// </summary>
    async void CheckUpdatesQuietly()
    {
        try
        {
            var have = await Task.Run(Updates.Installed);
            var latest = await Updates.LatestAsync(force: false);
            ShowUpdateDot(Updates.Known.Select(known => new UpdateItem(known.Id, known.Name, have.GetValueOrDefault(known.Id), latest.GetValueOrDefault(known.Id))).ToList());
        }
        catch { }
    }

    /// <summary>The tangerine dot on SETTINGS and the hint of the button: which tools have a newer version out.</summary>
    void ShowUpdateDot(IReadOnlyList<UpdateItem> items)
    {
        _lastUpdates = items;
        var behind = items.Where(item => item.Newer == true)
            .Select(item => item.Installed is null ? item.Name : $"{item.Name} {item.Installed} → {item.Latest}").ToList();
        UpdateDot.IsVisible = behind.Count > 0;
        ToolTip.SetTip(SettingsButton, behind.Count > 0
            ? Lang.F("Есть новее: {0}. SETTINGS → ИНСТРУМЕНТЫ И ВЕРСИИ → ОБНОВИТЬ.", string.Join(", ", behind))
            : Lang.T("Папка данных, инструменты и их обновление, редактор F4, вид окна."));
    }

    // ------------------------------------------------------------ ABOUT

    /// <summary>ABOUT: the program, its folders, its documents and the page of its releases.</summary>
    void FillAbout()
    {
        SettingsBody.Children.Clear();
        _into = null;
        Add(new TextBlock { Text = "ABOUT", FontWeight = FontWeight.SemiBold, FontSize = 16, Margin = new Thickness(0, 0, 0, 8) });

        var columns = new Grid { ColumnDefinitions = new ColumnDefinitions("*,16,*") };
        var left = new StackPanel { Spacing = 10 };
        var right = new StackPanel { Spacing = 10 };
        Grid.SetColumn(right, 2);
        columns.Children.Add(left);
        columns.Children.Add(right);
        SettingsBody.Children.Add(columns);

        Open(left, "AUDION SYNC TOOLS");
        Note("Копия MAIN VPS на этой машине и всё, без чего она бесполезна: ключи, клиент туннеля, доступ к домашним машинам. Плюс снимок приватных архивов Build-стека в R2.");
        Pair("Версия", Paths.Version);
        Pair("Программа", Paths.Root);
        Pair("Папка данных", DataRoot.Chosen ? DataRoot.Path_ : Lang.T("не выбрана"));
        Row(
            Action("ПАПКА ПРОГРАММЫ", "Открыть папку программы в проводнике.", () => Shell(Paths.Root)),
            Action("ЛИЦЕНЗИИ", "Лицензии программы и того, что она везёт с собой: папка licenses.", () => Shell(Path.Combine(Paths.Root, "licenses"))));

        Open(right, "ДОКУМЕНТЫ");
        Row(
            Action("РУКОВОДСТВО", "Руководство пользователя: Docs\\USER_GUIDE_RU.md или USER_GUIDE_EN.md - по языку окна.", () => OpenDoc("USER_GUIDE")),
            Action("ИЗМЕНЕНИЯ", "Журнал изменений по версиям.", () => OpenDoc("CHANGELOG")),
            Action("ВОССТАНОВЛЕНИЕ", "Как поднять машину после переустановки Windows.", () => OpenDoc("RESTORE")),
            Action("README", "Что это за программа и с чего начать.", () => OpenDoc("README")));

        Open(right, "ССЫЛКИ");
        Row(Action("GITHUB", "Выпуски программы: github.com/Tensionix/sync-tools.", () => Shell("https://github.com/Tensionix/sync-tools/releases")));

        Lang.Walk(SettingsHost);
    }

    /// <summary>A document of Docs in the language of the window.</summary>
    static void OpenDoc(string name)
    {
        var file = Path.Combine(Paths.Root, "Docs", $"{name}_{(Lang.Code == "ru" ? "RU" : "EN")}.md");
        if (File.Exists(file)) Shell(file);
        else Journal.Add(Lang.F("[окно] нет файла: {0}", file));
    }

    /// <summary>UPDATE: the script of the engine, its output in the journal; the dots are read again when it ends.</summary>
    void UpdateTools()
    {
        if (Scripts.Job("ОБНОВЛЕНИЕ ИНСТРУМЕНТОВ", Path.Combine("Engine", "Scripts", "Update-Tools.ps1"), new[] { "-NoPause" }, refresh: true) is not { } job) return;
        void Done(Job finished, bool ok, IReadOnlyList<string> tail)
        {
            if (finished != job) return;
            _jobs.Finished -= Done;
            if (_settingsOpen) CheckVersions(force: false, say: false);
            // cloudflared may have just arrived: the route over Cloudflare was counted silent without it.
            StartProbe(quiet: true);
        }
        _jobs.Finished += Done;
        _jobs.Enqueue(job);
    }

    /// <summary>The bottom row with or without the small second line of its buttons.</summary>
    void ApplyButtonRow()
    {
        foreach (var button in ActionRow.Children.OfType<Button>())
            if (button.Content is StackPanel { Children.Count: > 1 } stack) stack.Children[1].IsVisible = !_settings.HideHints;
    }
}
