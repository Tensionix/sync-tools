using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Data;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;
using Avalonia.Threading;
using AudionSyncTools.Core;

namespace AudionSyncTools.Views;

/// <summary>A found file as the table of the search window shows it.</summary>
public sealed class FoundRow
{
    public required Found File { get; init; }
    public string Rel => File.Rel;
    public long Size => File.Size;
    public DateTime Modified => File.Modified ?? DateTime.MinValue;
    public string SizeText => Format.Size(File.Size);
    public string DateText => Format.Date(File.Modified);
    public IBrush? Ink { get; init; }
}

/// <summary>
/// Ctrl+F, Alt+F7: the search window, a window of its own as in Total Commander and Audion Disk
/// Tools - the program stays free while it searches. On top the query: where (the place of the
/// active panel), one field for the typed keys, the time, the groups of extensions. The search
/// walks the tree by rclone and fills the table as it goes; СТОП ends it. ПЕРЕЙТИ К ФАЙЛУ (a
/// double click, Enter) opens the folder of the file in the active panel, on that file.
/// </summary>
public sealed class SearchWindow : Window
{
    readonly TextBlock _where = new() { TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBox _keys = new() { TextWrapping = TextWrapping.Wrap };
    readonly Dictionary<AgeLimit, ToggleButton> _ages = new();
    readonly Dictionary<string, ToggleButton> _groups = new();
    readonly ToggleButton _groupsToggle = new() { Classes = { "switch" } };
    readonly StackPanel _groupsPanel = new() { Spacing = 4, Margin = new Thickness(0, 4, 0, 0) };
    readonly Button _find = new() { Classes = { "run" }, MinWidth = 120, MinHeight = 30 };
    readonly Button _stop = new() { Classes = { "warn" }, MinWidth = 90, MinHeight = 30, IsEnabled = false };
    readonly Button _goTo = new() { MinWidth = 160, MinHeight = 30, IsEnabled = false };
    readonly Button _toPanel = new() { MinWidth = 130, MinHeight = 30, IsEnabled = false };
    readonly Button _clear = new() { MinWidth = 110, MinHeight = 30 };
    readonly TextBlock _status = new() { Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly ObservableCollection<FoundRow> _rows = new();
    readonly DataGrid _grid;

    CancellationTokenSource? _run;
    AgeLimit _age = AgeLimit.None;
    string _key = "", _path = "";
    // What the table was found in: the place may have changed in the panel since.
    string _foundKey = "", _foundPath = "";

    /// <summary>The place of the active panel now: its source and its folder.</summary>
    public Func<(string Key, string Path)>? Place;
    /// <summary>ПЕРЕЙТИ К ФАЙЛУ: the source and the folder searched, and the path of the file from it.</summary>
    public event Action<string, string, Found>? GoTo;
    /// <summary>В ПАНЕЛЬ: the source and the folder searched, the caption of the query and the files found - the active panel shows them as a flat list.</summary>
    public event Action<string, string, string, IReadOnlyList<Found>>? Feed;

    public bool Running => _run is not null;
    public string StatusText => _status.Text ?? "";
    public IReadOnlyList<FoundRow> Rows => _rows;

    readonly Settings _settings;

    public SearchWindow(WindowIcon? icon, Settings settings)
    {
        _settings = settings;
        Title = "Audion Sync Tools — " + Lang.T("Поиск");
        Icon = icon;
        MinWidth = 720;
        MinHeight = 480;
        // Where it was left; the first time - the size of the search window of Audion Disk Tools:
        // every family of groups fits one line and the table has room.
        if (settings.SearchBounds is { Length: 4 } b && b[2] >= MinWidth && b[3] >= MinHeight)
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Position = new PixelPoint((int)b[0], (int)b[1]);
            Width = b[2];
            Height = b[3];
        }
        else
        {
            WindowStartupLocation = WindowStartupLocation.CenterScreen;
            Width = 1226;
            Height = 762;
        }
        this[!BackgroundProperty] = new DynamicResourceExtension("AppBg");
        this[!ForegroundProperty] = new DynamicResourceExtension("TextMain");
        this[!FontFamilyProperty] = new DynamicResourceExtension("FontUi");
        this[!FontSizeProperty] = new DynamicResourceExtension("FontPanel");

        TextBlock Caption(string text) => new() { Text = Lang.T(text), Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };

        // ---- where
        var here = new Button { Content = Lang.T("ПАПКА ПАНЕЛИ"), Classes = { "small" }, Margin = new Thickness(8, 0, 0, 0) };
        ToolTip.SetTip(here, Lang.T("Искать в папке, где сейчас стоит активная панель."));
        here.Click += (_, _) => FollowPanel();
        var whereLine = new DockPanel();
        DockPanel.SetDock(here, Dock.Right);
        var whereCaption = Caption("ГДЕ");
        DockPanel.SetDock(whereCaption, Dock.Left);
        whereLine.Children.Add(here);
        whereLine.Children.Add(whereCaption);
        whereLine.Children.Add(_where);
        // Back in this window after walking the panels: the place is where the active panel stands now.
        Activated += (_, _) => { if (_run is null) FollowPanel(); };

        // ---- the keys
        _keys[!TemplatedControl.FontSizeProperty] = new DynamicResourceExtension("FontPanel");
        _keys.MinHeight = 30;
        _keys.PlaceholderText = Lang.T(@"отчёт, .dwg, 2026-*, /^IMG_\d{4}/");
        _keys.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Start(); e.Handled = true; } };
        var hint = new TextBlock
        {
            Text = Lang.T("Слово — часть имени, .dwg — расширение, 2026-* — маска, /выражение/ — регулярное. Через запятую; пусто — все файлы."),
            Classes = { "note" }, TextWrapping = TextWrapping.Wrap,
        };

        // ---- the time
        var ages = new FlowRow { LineSpacing = 4 };
        ages.Children.Add(Caption("ИЗМЕНЕНЫ"));
        foreach (var (age, label) in new[] { (AgeLimit.None, "КОГДА УГОДНО"), (AgeLimit.Hour, "ЗА ЧАС"), (AgeLimit.Day, "ЗА СУТКИ"), (AgeLimit.Week, "ЗА НЕДЕЛЮ") })
        {
            var button = new ToggleButton { Content = Lang.T(label), Classes = { "switch" }, IsChecked = age == _age };
            button.Click += (_, _) => { _age = age; foreach (var (other, toggle) in _ages) toggle.IsChecked = other == age; };
            _ages[age] = button;
            ages.Children.Add(button);
        }
        // The groups stay folded until asked for: thirty-six chips above the table would leave it no room.
        _groupsToggle.Margin = new Thickness(14, 0, 0, 0);
        _groupsToggle.IsChecked = true;
        _groupsToggle.Click += (_, _) => { _groupsPanel.IsVisible = _groupsToggle.IsChecked == true; };
        ToolTip.SetTip(_groupsToggle, Lang.T("Группы расширений: искать только файлы отмеченных групп."));
        ages.Children.Add(_groupsToggle);
        foreach (var family in MaskGroups.Families)
        {
            var accent = FilePanel.Palette.FamilyColour(family.Id) is ISolidColorBrush brush ? brush.Color : Color.Parse("#6b7a84");
            // A family is one line: its name at the left, its chips in a row beside it.
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("150,*") };
            var head = new TextBlock { Text = family.ShortTitle.ToUpperInvariant(), Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 8, 0), TextTrimming = TextTrimming.CharacterEllipsis };
            ToolTip.SetTip(head, family.Title);
            var row = new FlowRow { LineSpacing = 4 };
            Grid.SetColumn(row, 1);
            line.Children.Add(head);
            line.Children.Add(row);
            foreach (var group in family.Groups)
            {
                var box = new Border
                {
                    Classes = { "tickbox" }, BorderBrush = App.Rim(accent),
                    Child = new Avalonia.Controls.Shapes.Path { Classes = { "tick" }, Data = Geometry.Parse("M 1.5,5 L 4,7.5 L 8.5,2.5") },
                };
                var chip = new ToggleButton
                {
                    Classes = { "switch" },
                    Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { box, new TextBlock { Text = group.Title, VerticalAlignment = VerticalAlignment.Center } } },
                };
                chip.Click += (_, _) => GroupsCaption();
                _groups[group.Id] = chip;
                row.Children.Add(chip);
            }
            _groupsPanel.Children.Add(line);
        }
        GroupsCaption();

        // ---- the run
        _find.Content = Lang.T("ПОИСК");
        ToolTip.SetTip(_find, Lang.T("Искать (Enter в поле)."));
        ToolTip.SetTip(_stop, Lang.T("Остановить поиск (Esc): найденное остаётся в таблице."));
        _stop.Content = Lang.T("СТОП");
        _find.Click += (_, _) => Start();
        _stop.Click += (_, _) => Stop();
        // The line above the table says how the search goes; the buttons that run it stand at the bottom right, as in Audion Disk Tools.
        var runLine = new DockPanel { Margin = new Thickness(0, 4, 0, 0) };
        _status.Margin = new Thickness(2, 0, 0, 0);
        runLine.Children.Add(_status);

        // ---- the table
        _grid = new DataGrid
        {
            Classes = { "panel" }, ItemsSource = _rows, IsReadOnly = true, CanUserResizeColumns = true, CanUserSortColumns = true,
            SelectionMode = DataGridSelectionMode.Single, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        DataGridTemplateColumn Column(string title, string member, string text, DataGridLength width, bool name = false) => new()
        {
            Header = Lang.T(title), Width = width, SortMemberPath = member,
            CellTemplate = new FuncDataTemplate<FoundRow>((_, _) =>
            {
                var cell = new TextBlock { Classes = { name ? "name" : "muted" } };
                cell[!TextBlock.TextProperty] = new Binding(text);
                if (name) { cell[!TextBlock.ForegroundProperty] = new Binding(nameof(FoundRow.Ink)); cell.FontWeight = FontWeight.SemiBold; cell.Margin = new Thickness(10, 0, 8, 0); }
                return cell;
            }),
        };
        _grid.Columns.Add(Column("ИМЯ", nameof(FoundRow.Rel), nameof(FoundRow.Rel), new DataGridLength(1, DataGridLengthUnitType.Star), name: true));
        _grid.Columns.Add(Column("РАЗМЕР", nameof(FoundRow.Size), nameof(FoundRow.SizeText), new DataGridLength(Format.ExactBytes ? 130 : 90)));
        _grid.Columns.Add(Column("ДАТА", nameof(FoundRow.Modified), nameof(FoundRow.DateText), new DataGridLength(140)));
        _grid.DoubleTapped += (_, _) => Go();
        _grid.SelectionChanged += (_, _) => _goTo.IsEnabled = _grid.SelectedItem is FoundRow;
        _grid.AddHandler(KeyDownEvent, (_, e) => { if (e.Key == Key.Enter) { Go(); e.Handled = true; } }, Avalonia.Interactivity.RoutingStrategies.Tunnel);

        // ---- the bottom
        _goTo.Content = Lang.T("ПЕРЕЙТИ К ФАЙЛУ");
        _clear.Content = Lang.T("ОЧИСТИТЬ");
        ToolTip.SetTip(_goTo, Lang.T("Открыть папку файла в активной панели и встать на него. То же - двойной щелчок или Enter."));
        _goTo.Click += (_, _) => Go();
        _toPanel.Content = Lang.T("В ПАНЕЛЬ");
        ToolTip.SetTip(_toPanel, Lang.T("Показать найденное в активной панели плоским списком: оттуда F5 / F6 в соседнюю панель, F8 — удалить. Esc в панели возвращает папку."));
        _toPanel.Click += (_, _) => FeedPanel();
        _clear.Click += (_, _) =>
        {
            _run?.Cancel();
            _rows.Clear();
            _toPanel.IsEnabled = false;
            _status.Text = "";
            _keys.Text = "";
            foreach (var chip in _groups.Values) chip.IsChecked = false;
            _age = AgeLimit.None;
            foreach (var (age, toggle) in _ages) toggle.IsChecked = age == AgeLimit.None;
            GroupsCaption();
            // Back to making a query: the groups open again.
            _groupsToggle.IsChecked = true;
            _groupsPanel.IsVisible = true;
            _keys.Focus();
        };
        var close = new Button { Content = Lang.T("ЗАКРЫТЬ"), MinWidth = 110, MinHeight = 30 };
        close.Click += (_, _) => Close();
        // At the left what is done with the found, at the right what runs the search: ПОИСК is the last button of the window.
        var done = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _clear, close, new Border { Width = 16 }, _toPanel, _goTo } };
        var runs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { _stop, _find } };
        var bottom = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(done, Dock.Left);
        bottom.Children.Add(done);
        bottom.Children.Add(runs);

        var top = new StackPanel { Spacing = 6, Children = { whereLine, _keys, hint, ages, _groupsPanel, runLine } };
        var layout = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), Margin = new Thickness(14, 12) };
        Grid.SetRow(_grid, 1);
        Grid.SetRow(bottom, 2);
        _grid.Margin = new Thickness(0, 8, 0, 0);
        layout.Children.Add(top);
        layout.Children.Add(new Border { [Grid.RowProperty] = 1, Classes = { "listbg" }, Margin = new Thickness(0, 8, 0, 0) });
        layout.Children.Add(_grid);
        layout.Children.Add(bottom);
        Content = layout;

        KeyDown += (_, e) =>
        {
            // Esc: СТОП while it searches, else the window closes - as a dialog does.
            if (e.Key != Key.Escape) return;
            if (_run is not null) _run.Cancel(); else Close();
            e.Handled = true;
        };
        Opened += (_, _) => { _keys.Focus(); _keys.SelectAll(); };
        Closing += (_, _) =>
        {
            _run?.Cancel();
            if (WindowState == WindowState.Normal) _settings.SearchBounds = new[] { (double)Position.X, Position.Y, Width, Height };
            _settings.Save();
        };
    }

    void GroupsCaption()
    {
        int picked = _groups.Values.Count(chip => chip.IsChecked == true);
        _groupsToggle.Content = picked > 0 ? Lang.F("ГРУППЫ: {0}", picked) : Lang.T("ГРУППЫ");
    }

    /// <summary>The place to search is where the active panel stands; a running search keeps its own.</summary>
    public void FollowPanel()
    {
        if (_run is not null || Place?.Invoke() is not { } place) return;
        (_key, _path) = place;
        var source = Sources.Get(_key);
        bool nowhere = !source.IsRemote && _path.Length == 0;
        _where.Text = nowhere ? Lang.T("панель стоит на списке дисков - откройте папку") : $"{Lang.T(source.Label)} · {Sources.RemotePath(_key, _path)}";
        _find.IsEnabled = !nowhere;
    }

    public SearchQuery Query() => new()
    {
        Text = _keys.Text ?? "",
        Groups = _groups.Where(pair => pair.Value.IsChecked == true).Select(pair => pair.Key).ToList(),
        Age = _age,
    };

    /// <summary>The keys as typed - for a check without a mouse, and to bring the last query back.</summary>
    public void SetKeys(string text) => _keys.Text = text;

    public async void Start()
    {
        if (_run is not null || !_find.IsEnabled) return;
        var query = Query();
        foreach (var expression in SearchQuery.Keys(query.Text).Regexes)
            if (SearchQuery.RegexError(expression) is { } wrong) { _status.Text = Lang.F("выражение не читается: {0}", wrong); return; }
        // The table takes the height: the groups fold, ГРУППЫ opens them again.
        _groupsToggle.IsChecked = false;
        _groupsPanel.IsVisible = false;

        var run = _run = new CancellationTokenSource();
        _rows.Clear();
        _foundKey = _key;
        _foundPath = _path;
        _find.IsEnabled = false;
        _stop.IsEnabled = true;
        _status.Text = Lang.T("ищу…");
        var target = Sources.RemotePath(_key, _path);
        var palette = FilePanel.Palette;

        _toPanel.IsEnabled = false;
        _searched = query;
        void Found(IReadOnlyList<Found> batch) => Dispatcher.UIThread.Post(() =>
        {
            if (run != _run) return;
            foreach (var file in batch) _rows.Add(new FoundRow { File = file, Ink = palette.For(file.Name, false, file.Modified) });
        });
        void Progress(SearchProgress p) => Dispatcher.UIThread.Post(() =>
        {
            if (run != _run) return;
            var time = p.Elapsed.TotalSeconds < 60 ? Lang.F("{0:0.0} с", p.Elapsed.TotalSeconds) : Lang.F("{0} мин {1} с", (int)p.Elapsed.TotalMinutes, p.Elapsed.Seconds);
            var counts = Lang.F("найдено {0} · папок {1} · файлов {2} · {3}", p.Found, p.Folders, p.Files, time);
            _status.Text = !p.Done ? Lang.T("ищу…") + " " + counts
                : p.Trouble.Length > 0 ? Lang.F("не дочитано: {0}", p.Trouble) + " · " + counts
                : p.Cut ? Lang.F("показаны первые {0} - уточните запрос", SearchRun.Limit) + " · " + counts
                : run.IsCancellationRequested ? Lang.T("остановлено") + " · " + counts
                : counts;
        });

        // Off the window's thread: a tree of a hundred thousand files is a hundred thousand lines to read.
        try { await Task.Run(() => SearchRun.Run(target, query, Found, Progress, run.Token)); }
        catch (Exception ex) { _status.Text = Lang.F("не дочитано: {0}", ex.Message); }
        // The last batch and the last word are posted before this line runs: let them land first.
        await Dispatcher.UIThread.InvokeAsync(() => { }, DispatcherPriority.Background);
        if (run != _run) return;
        _run = null;
        run.Dispose();
        _stop.IsEnabled = false;
        _find.IsEnabled = true;
        _toPanel.IsEnabled = _rows.Count > 0;
        // The place follows the panel again - and the button goes off if the panel stands nowhere.
        FollowPanel();
    }

    SearchQuery? _searched;

    /// <summary>The caption of the found list in a panel: what was asked, short.</summary>
    string QueryTitle(SearchQuery query)
    {
        var parts = new List<string>();
        if (query.Text.Trim().Length > 0) parts.Add(query.Text.Trim());
        if (query.Groups.Count > 0) parts.Add(Lang.F("групп {0}", query.Groups.Count));
        if (query.Age != AgeLimit.None) parts.Add(Lang.T(query.Age switch { AgeLimit.Hour => "за час", AgeLimit.Day => "за сутки", _ => "за неделю" }));
        return Lang.T("ПОИСК") + ": " + (parts.Count > 0 ? string.Join(" · ", parts) : Lang.T("все файлы"));
    }

    /// <summary>В ПАНЕЛЬ: the very rows the table shows (after СТОП too) go into the active panel.</summary>
    public void FeedPanel()
    {
        if (_run is not null || _searched is null || _rows.Count == 0) return;
        Feed?.Invoke(_foundKey, _foundPath, QueryTitle(_searched), _rows.Select(row => row.File).ToList());
    }

    /// <summary>СТОП: rclone is ended, what was found stays in the table.</summary>
    public void Stop() => _run?.Cancel();

    void Go()
    {
        if (_grid.SelectedItem is FoundRow row) GoTo?.Invoke(_foundKey, _foundPath, row.File);
    }

    /// <summary>ПЕРЕЙТИ К ФАЙЛУ for a row by its number - for a check without a mouse.</summary>
    public void GoRow(int index)
    {
        if (index >= 0 && index < _rows.Count) GoTo?.Invoke(_foundKey, _foundPath, _rows[index].File);
    }
}
