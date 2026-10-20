using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using AudionSyncTools.Core;

namespace AudionSyncTools.Views;

/// <summary>
/// One file panel: a source (a button of the row above the list), a path in it and the rows.
/// Local folders are read by the program itself, everything else by rclone in a process of its
/// own - a far machine answers in ten seconds, and the window must stay alive meanwhile.
/// </summary>
public partial class FilePanel : UserControl
{
    public string SourceKey { get; private set; } = "local";
    public string Path { get; private set; } = "";

    /// <summary>The colours of the rows; one palette for both panels, replaced with the theme.</summary>
    public static RowPalette Palette { get; set; } = new();

    /// <summary>The panel got the focus: it is the active one now.</summary>
    public event Action<FilePanel>? Activated;
    /// <summary>The source or the folder changed.</summary>
    public event Action<FilePanel>? Moved;
    /// <summary>A panel read to the end, with rows: the road to its source is proven by deed.</summary>
    public event Action<FilePanel>? Proven;

    // _listed is what was read; _rows is what stands on the screen - the same, or narrowed by the quick filter.
    List<FileRow> _listed = new();
    List<FileRow> _rows = new();
    string _quick = "";
    readonly List<(string Key, string Path)> _back = new(), _forward = new();
    bool _travelling;

    /// <summary>Ctrl+Enter: a terminal for the place the panel stands in - the window knows how to open one.</summary>
    public event Action<FilePanel>? TerminalAsked;
    readonly Dictionary<string, ToggleButton> _sourceButtons = new();
    CancellationTokenSource? _reading;
    SortKey _sort = SortKey.Name;
    bool _desc;
    string _space = "";
    string _problem = "";
    // Space counts the folders it marks, two at a time: a far machine answers "rclone size" in seconds, and a run of
    // Spaces must not start a process for every folder at once. Rows read anew drop the counts of the rows they replace.
    readonly SemaphoreSlim _counters = new(2, 2);
    CancellationTokenSource _counts = new();

    static readonly SortKey?[] ColumnKeys = { null, SortKey.Name, SortKey.Size, SortKey.Date };
    static readonly string[] ColumnTitles = { "", "ИМЯ", "РАЗМЕР", "ДАТА" };

    public FilePanel()
    {
        InitializeComponent();
        Frame.LayoutUpdated += (_, _) => { if (_glass) CutHole(); };
        List.AddHandler(KeyDownEvent, OnListKey, RoutingStrategies.Tunnel);
        List.DoubleTapped += (_, _) => EnterCurrent();
        List.Sorting += OnSorting;
        List.GotFocus += (_, _) => Activated?.Invoke(this);
        AddHandler(PointerPressedEvent, (_, _) => Activated?.Invoke(this), RoutingStrategies.Tunnel, handledEventsToo: true);
        Lang.Follow(Status);
        UpdateSortHeaders();
        QuickBox.TextChanged += (_, _) => { _quick = QuickBox.Text ?? ""; Display(null); };
        QuickBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { CloseQuickFilter(); e.Handled = true; }
            else if (e.Key is Key.Enter or Key.Down) { FocusList(); e.Handled = true; }
        };
        FitColumns();
    }

    /// <summary>
    /// The columns of the size and of the date as wide as what they hold, in the font of the
    /// panel: exact bytes need room - "12 345 678 901" was cut to "12 345 6…" in the short column.
    /// </summary>
    public void FitColumns()
    {
        try
        {
            var res = Application.Current?.Resources;
            double size = res?.TryGetResource("FontPanel", null, out var s) == true && s is double d ? d : 12;
            var family = res?.TryGetResource("FontGrid", null, out var f) == true && f is FontFamily ff ? ff : FontFamily.Default;
            var face = new Typeface(family);
            double Wide(string text) => new FormattedText(text, System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, size, null).WidthIncludingTrailingWhitespace;
            // Cells: a margin on both sides and a hair of air. Headers: their own padding around the title and the sort arrow.
            double Column(string sample, int index) => Math.Ceiling(Math.Max(Wide(sample) + 20, Wide(Lang.T(ColumnTitles[index]) + " ▲") + 30));
            List.Columns[2].Width = new DataGridLength(Column(Format.ExactBytes ? "000 000 000 000" : "0 000,0 МБ", 2));
            List.Columns[3].Width = new DataGridLength(Column("00.00.0000 00:00", 3));
        }
        catch { }
    }

    // ------------------------------------------------------------ sources

    /// <summary>The buttons above the list: what the panel can show in the current section.</summary>
    public void SetSources(IEnumerable<string> keys)
    {
        SourceRow.Children.Clear();
        _sourceButtons.Clear();
        foreach (var key in keys)
        {
            var source = Sources.Get(key);
            // No dot of reachability here on purpose: a source that cannot be reached is still
            // seen and opens by an attempt - that says the truth better than a probe a minute old.
            var button = new ToggleButton { Classes = { "switch" }, Content = Lang.T(source.Label), Tag = key };
            ToolTip.SetTip(button, Lang.T(source.Tip));
            button.Click += (_, _) => Open(key);
            SourceRow.Children.Add(button);
            _sourceButtons[key] = button;
        }
        MarkSource();
    }

    void MarkSource()
    {
        foreach (var (key, button) in _sourceButtons) button.IsChecked = key == SourceKey;
    }

    /// <summary>The route of a machine in the caption of its button: "BASE · SSH SECOND VPS".</summary>
    public void UpdateSourceCaptions()
    {
        foreach (var (key, button) in _sourceButtons)
        {
            var source = Sources.Get(key);
            var route = Sources.RouteName(key);
            button.Content = route.Length > 0 ? $"{Lang.T(source.Label)} · {route}" : Lang.T(source.Label);
        }
    }

    public void Open(string key, string? path = null)
    {
        SourceKey = key;
        Path = path ?? Sources.Get(key).Root;
        MarkSource();
        Moved?.Invoke(this);
        Reload();
    }

    // ------------------------------------------------------------ reading

    public async void Reload(string? select = null)
    {
        _reading?.Cancel();
        var cancel = _reading = new CancellationTokenSource();
        string key = SourceKey, path = Path;
        // A found list stands until the panel goes elsewhere: a job that ended asks every panel to
        // read itself again, and that must not wipe what the search was run for.
        if (ShowingFound && key == _shownKey && path == _shownPath) return;
        _foundTitle = "";
        BuildCrumbs();
        _problem = "";
        if (key != _shownKey || path != _shownPath)
        {
            // Another place: the quick filter was about the names of the one left.
            if (_quick.Length > 0 || QuickBox.IsVisible) { QuickBox.IsVisible = false; QuickBox.Text = ""; _quick = ""; }
            // Alt+Left comes back to where the panel stood; a step back itself is not a new place.
            if (!_travelling && _shownKey.Length > 0)
            {
                _back.Add((_shownKey, _shownPath));
                if (_back.Count > 60) _back.RemoveAt(0);
                _forward.Clear();
            }
        }
        var remote = Sources.Get(key).IsRemote;
        // The rows of the place just left must not stand under the path of the new one, not for a
        // moment. A far machine answers in seconds, and BASE in the caption over the disks of this
        // laptop read as BASE's own. A disk of this machine answers at once as a rule - and when it
        // does not (asleep, a share, tens of thousands of files) F2, F8 and F5 took a name from the
        // old rows and the path of the new folder (the audit of 08.10.2026). The same folder read
        // again keeps its rows until the new ones come.
        if (key != _shownKey || path != _shownPath)
        {
            Show(new List<FileRow>(), null);
            Status.Text = "читаю…";
        }
        else if (remote) Status.Text = "читаю…";
        _shownKey = key;
        _shownPath = path;

        Listing.Result result;
        try { result = await Listing.Read(key, path, Palette, cancel.Token); }
        catch (OperationCanceledException) { return; }
        catch (Exception ex) { result = new Listing.Result(null, ex.Message, false); }
        // While it was read the panel may have gone elsewhere: this answer is about another folder.
        if (cancel.IsCancellationRequested || key != SourceKey || path != Path) return;

        if (result.Rows is null)
        {
            if (result.TimedOut)
            {
                // Remember which road was silent: the next reading will not start with it.
                var failed = Sources.RouteName(key);
                if (failed.Length > 0)
                {
                    Sources.RouteFail[key + "|" + failed] = DateTime.Now;
                    Journal.Add(Lang.F("[окно] маршрут {0} молчит, дальше идём другим", failed));
                }
                _problem = "нет ответа";
            }
            else _problem = "не открылось";
            Journal.TroubleOnce(result.Trouble);
            Show(new List<FileRow>(), select);
            return;
        }
        Show(Listing.Sort(result.Rows, _sort, _desc), select);
        if (remote) Proven?.Invoke(this);
        ReadSpace(key, path, cancel.Token);
    }

    // What the rows on the screen belong to: the source and the folder of the last reading that was started.
    string _shownKey = "", _shownPath = "";

    void Show(List<FileRow> rows, string? select)
    {
        StopCounts();
        _listed = rows;
        _space = "";
        Display(select);
    }

    /// <summary>What was read goes on the screen: whole, or only the names with the text of the quick filter (F).</summary>
    void Display(string? select)
    {
        var keep = select ?? (List.SelectedItem as FileRow)?.Name;
        _rows = _quick.Length > 0 ? _listed.Where(r => r.Name.Contains(_quick, StringComparison.OrdinalIgnoreCase)).ToList() : _listed;
        List.ItemsSource = _rows;
        if (_rows.Count > 0)
        {
            int at = keep is null ? 0 : Math.Max(0, _rows.FindIndex(r => r.Name == keep));
            List.SelectedIndex = at;
            List.ScrollIntoView(_rows[at], null);
        }
        UpdateStatus();
    }

    // ------------------------------------------------------------ the quick filter, the history, the sources

    /// <summary>F: a line beside the path; the list keeps the names with its text.</summary>
    public void OpenQuickFilter()
    {
        QuickBox.IsVisible = true;
        QuickBox.Focus();
        QuickBox.SelectAll();
    }

    public bool QuickOn => QuickBox.IsVisible;

    /// <summary>The status line as it stands - for a check without a mouse.</summary>
    public string StatusText => Status.Text ?? "";

    /// <summary>Types into the quick filter - for a check without a mouse.</summary>
    public void TypeQuick(string text) => QuickBox.Text = text;

    public void CloseQuickFilter()
    {
        QuickBox.IsVisible = false;
        QuickBox.Text = "";
        FocusList();
    }

    // Not empty - the panel shows the files a search found, as a flat list; the text is its caption.
    string _foundTitle = "";

    public bool ShowingFound => _foundTitle.Length > 0;

    /// <summary>
    /// В ПАНЕЛЬ of the search window: the found files as a flat list of the folder searched. A row
    /// is a path from that folder, so copying a row keeps its folders on the other side. The list
    /// stands while jobs run and end; Esc, Backspace or Ctrl+R bring the folder itself back.
    /// </summary>
    public void ShowFound(string key, string path, string title, IReadOnlyList<Found> files)
    {
        _reading?.Cancel();
        StopCounts();
        if (QuickBox.IsVisible) { QuickBox.IsVisible = false; QuickBox.Text = ""; _quick = ""; }
        SourceKey = key;
        Path = path;
        MarkSource();
        BuildCrumbs();
        _shownKey = key;
        _shownPath = path;
        _problem = "";
        _foundTitle = title;
        _listed = Listing.Sort(files.Select(f => new FileRow { Name = f.Rel, IsDir = false, Size = f.Size, Modified = f.Modified, Colour = Palette.For(f.Name, false, f.Modified) }).ToList(), _sort, _desc);
        _space = "";
        Display(null);
        Moved?.Invoke(this);
        FocusList();
    }

    /// <summary>Out of the found list, back to the folder it was found in.</summary>
    public void LeaveFound()
    {
        if (!ShowingFound) return;
        _foundTitle = "";
        Reload();
    }

    /// <summary>Read the folder again by the owner's own word (Ctrl+R, the button): a found list gives way to it.</summary>
    public void ReloadNow()
    {
        _foundTitle = "";
        Reload();
    }

    /// <summary>To a place and onto a name in it: the search window sends the panel to a found file.</summary>
    public void Go(string key, string path, string? select)
    {
        _foundTitle = "";
        SourceKey = key;
        Path = path;
        MarkSource();
        Moved?.Invoke(this);
        Reload(select);
    }

    /// <summary>Alt+Left / Alt+Right: the places the panel stood in before - a source and a folder each.</summary>
    public void GoBack() => Travel(_back, _forward);
    public void GoForward() => Travel(_forward, _back);

    void Travel(List<(string Key, string Path)> from, List<(string Key, string Path)> to)
    {
        if (from.Count == 0) return;
        var place = from[^1];
        from.RemoveAt(from.Count - 1);
        to.Add((SourceKey, Path));
        _travelling = true;
        try
        {
            SourceKey = place.Key;
            Path = place.Path;
            MarkSource();
            Moved?.Invoke(this);
            Reload();
        }
        finally { _travelling = false; }
    }

    /// <summary>Alt+F1 / Alt+F2: the sources of the panel as a list - the arrows and Enter pick one, as the drive list of Total Commander.</summary>
    public void OpenSourceMenu()
    {
        var menu = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        foreach (var (key, button) in _sourceButtons)
        {
            var item = new MenuItem { Header = (button.Content as string ?? key).Replace("_", "__") };
            item.Click += (_, _) => { Open(key); FocusList(); };
            menu.Items.Add(item);
        }
        if (menu.Items.Count > 0) menu.ShowAt(SourceRow);
    }

    /// <summary>
    /// Shift+Space: the exact bytes of the row under the cursor in the status line - no column is
    /// wide enough for them. A folder is counted first: the disk itself for this machine,
    /// "rclone size" for a far one. The line stands until the panel changes.
    /// </summary>
    async void ShowBytes()
    {
        if (List.SelectedItem is not FileRow row) return;
        string Said(long bytes) => $"{row.Name}: {Lang.F("{0} байт", Format.Exact(bytes))}";
        if (!row.IsDir) { Status.Text = Said(Math.Max(0, row.Size)); return; }
        string key = SourceKey, path = Path;
        Status.Text = Lang.F("{0}: считаю…", row.Name);
        long? bytes = null;
        try { bytes = await Listing.FolderSize(key, Sources.Child(path, row.Name), CancellationToken.None); } catch { }
        // The cursor may have gone on meanwhile: the number is shown only for its own row.
        if (key != SourceKey || path != Path || !ReferenceEquals(List.SelectedItem, row)) return;
        Status.Text = bytes is { } known ? Said(known) : Lang.F("{0}: не посчиталось", row.Name);
    }

    async void ReadSpace(string key, string path, CancellationToken cancel)
    {
        try
        {
            var space = await Listing.Space(key, path, cancel);
            if (cancel.IsCancellationRequested || key != SourceKey || path != Path) return;
            _space = space is { } s && s.Free >= 0
                ? (s.Total > 0 ? Lang.F("свободно {0} из {1}", Format.Short(s.Free), Format.Short(s.Total)) : Lang.F("свободно {0}", Format.Short(s.Free)))
                : "";
            UpdateStatus();
        }
        catch { }
    }

    void UpdateStatus()
    {
        if (_problem.Length > 0) { Status.Text = _problem; return; }
        var marked = _rows.Where(r => r.Checked).ToList();
        var parts = new List<string> { Lang.F("ОБЪЕКТОВ: {0}", _rows.Count) };
        if (ShowingFound) parts.Insert(0, _foundTitle);
        if (marked.Count > 0)
        {
            // The files and the folders Space counted; a folder not counted weighs nothing here.
            long bytes = marked.Sum(r => Math.Max(0, r.Bytes));
            parts.Add(Lang.F("ОТМЕЧЕНО: {0} · {1}", marked.Count, Format.ExactBytes ? Lang.F("{0} байт", Format.Exact(bytes)) : Format.Size(bytes)));
        }
        if (_rows.Any(r => r.Counting)) parts.Add(Lang.T("считаю…"));
        if (_space.Length > 0) parts.Add(_space);
        Status.Text = string.Join("   ", parts);
    }

    // ------------------------------------------------------------ the path

    void BuildCrumbs()
    {
        Crumbs.Children.Clear();
        var crumbs = Sources.Crumbs(SourceKey, Path);
        for (int i = 0; i < crumbs.Count; i++)
        {
            if (i > 0)
            {
                var arrow = Icons.Sign("chevron-right");
                arrow.Margin = new Avalonia.Thickness(2, 0);
                arrow.VerticalAlignment = Avalonia.Layout.VerticalAlignment.Center;
                arrow.Opacity = 0.7;
                Crumbs.Children.Add(arrow);
            }
            var (text, path) = crumbs[i];
            var button = new Button { Classes = { "crumb" }, Content = i == 0 ? Lang.T(text) : text };
            if (i == crumbs.Count - 1) button.Classes.Add("last");
            button.Click += (_, _) => { Path = path; Moved?.Invoke(this); Reload(); };
            Crumbs.Children.Add(button);
        }
        ToolTip.SetTip(Crumbs, Sources.RemotePath(SourceKey, Path));
        // A long path keeps its end in sight: the folder the panel stands in, not the road to it.
        Avalonia.Threading.Dispatcher.UIThread.Post(() => CrumbScroll.ScrollToEnd(), Avalonia.Threading.DispatcherPriority.Background);
    }

    public void Up()
    {
        // Out of a found list first: Backspace brings back the folder it was found in.
        if (ShowingFound) { LeaveFound(); return; }
        if (Sources.Parent(SourceKey, Path) is not { } up) return;
        // Back in the parent the cursor stands on the folder just left.
        var left = Path.TrimEnd('/', '\\');
        int cut = Math.Max(left.LastIndexOf('/'), left.LastIndexOf('\\'));
        var name = cut >= 0 ? left[(cut + 1)..] : left;
        Path = up;
        Moved?.Invoke(this);
        Reload(name);
    }

    void EnterCurrent()
    {
        if (List.SelectedItem is not FileRow { IsDir: true } row) return;
        Path = Sources.Child(Path, row.Name);
        Moved?.Invoke(this);
        Reload();
    }

    // ------------------------------------------------------------ marks and keys

    /// <summary>
    /// What an operation takes: the marked rows; with none marked - the highlighted ones. Click a
    /// row and press F5: the usual gesture.
    /// </summary>
    public List<FileRow> Selection()
    {
        var marked = _rows.Where(r => r.Checked).ToList();
        return marked.Count > 0 ? marked : List.SelectedItems.OfType<FileRow>().ToList();
    }

    public IReadOnlyList<FileRow> Rows => _rows;

    public FileRow? CursorRow => List.SelectedItem as FileRow;

    /// <summary>The file list itself - the one place "only the file panels" lets a backdrop through.</summary>
    public Control ListArea => List;

    bool _glass;
    string _glassAt = "";

    /// <summary>"Only the file panels": the frame stays solid, with a hole where the list is.</summary>
    public void SetGlassHole(bool on)
    {
        _glass = on;
        Frame.Classes.Set("glass", on);
        FrameFill.IsVisible = on;
        if (on) CutHole();
        else { FrameFill.Clip = null; _glassAt = ""; }
    }

    void CutHole()
    {
        if (List.TranslatePoint(new Point(0, 0), FrameFill) is not { } at) return;
        var whole = new Rect(FrameFill.Bounds.Size);
        var hole = new Rect(at, List.Bounds.Size);
        // Layout runs often; the clip is rebuilt only when the list really moved.
        var key = whole + "|" + hole;
        if (key == _glassAt) return;
        _glassAt = key;
        FrameFill.Clip = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(whole), new RectangleGeometry(hole));
    }

    public void SetActive(bool active)
    {
        Frame.Classes.Set("active", active);
        List.Classes.Set("idle", !active);
    }

    public void FocusList()
    {
        List.Focus();
        if (List.SelectedIndex < 0 && _rows.Count > 0) List.SelectedIndex = 0;
    }

    public void SetMarks(bool on)
    {
        foreach (var row in _rows) row.Checked = on;
        UpdateStatus();
    }

    /// <summary>Space and Insert: the mark goes on or off and the cursor down. Space on a folder it marks counts the folder too.</summary>
    void MarkAndStep(bool count)
    {
        if (List.SelectedItem is not FileRow row) return;
        row.Checked = !row.Checked;
        if (count && row.Checked) CountFolder(row);
        var next = Math.Min(List.SelectedIndex + 1, _rows.Count - 1);
        List.SelectedIndex = next;
        List.ScrollIntoView(_rows[next], null);
        UpdateStatus();
    }

    /// <summary>
    /// Space on a folder, as in Total Commander (the owner, 20.10.2026: «размер объекта (папки) по выделению пробелом»):
    /// the size is counted - the disk itself for this machine, "rclone size" for a far one - and stands in the column
    /// РАЗМЕР and in ОТМЕЧЕНО. A folder counted already is not counted again; a drive of the list of drives is not counted
    /// at all - that is the whole disk.
    /// </summary>
    async void CountFolder(FileRow row)
    {
        if (!row.IsDir || row.Counting || row.Counted >= 0) return;
        if (!Sources.Get(SourceKey).IsRemote && Path.Length == 0) return;
        string key = SourceKey, path = Sources.Child(Path, row.Name);
        var cancel = _counts.Token;
        row.Counting = true;
        long? bytes = null;
        try
        {
            await _counters.WaitAsync(cancel);
            try { bytes = await Listing.FolderSize(key, path, cancel); }
            finally { _counters.Release(); }
        }
        catch { }
        row.Counting = false;
        // The panel read its rows anew meanwhile: this row is not on the screen any more.
        if (cancel.IsCancellationRequested) return;
        row.Counted = bytes ?? FileRow.NoAnswer;
        UpdateStatus();
    }

    /// <summary>The counts of Space are about the rows on the screen: new rows stop them.</summary>
    void StopCounts()
    {
        _counts.Cancel();
        _counts = new CancellationTokenSource();
    }

    /// <summary>
    /// Marks the rows the masks fit and, when a time is named, only the fresh among them; a time
    /// alone marks everything fresh. Nothing asked - every mark comes off; ДОБАВИТЬ keeps what is
    /// marked already. Returns how many rows were hit.
    /// </summary>
    public int ApplyMasks(IReadOnlyList<string> masks, AgeLimit age, bool add)
    {
        var names = Mask.Compile(masks);
        bool asked = names.Length > 0 || age != AgeLimit.None;
        var now = DateTime.Now;
        int hits = 0;
        foreach (var row in _rows)
        {
            bool hit = asked && (names.Length == 0 || Mask.Matches(row.Name, names)) && AgeFilter.Fits(age, row.Modified, now);
            if (hit) hits++;
            row.Checked = add ? row.Checked || hit : hit;
        }
        UpdateStatus();
        FocusList();
        return hits;
    }

    void OnListKey(object? sender, KeyEventArgs e)
    {
        bool ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        bool alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        switch (e.Key)
        {
            case Key.Left when alt: GoBack(); e.Handled = true; break;
            case Key.Right when alt: GoForward(); e.Handled = true; break;
            case Key.Enter when ctrl: TerminalAsked?.Invoke(this); e.Handled = true; break;
            case Key.Enter: EnterCurrent(); e.Handled = true; break;
            case Key.Back: Up(); e.Handled = true; break;
            case Key.Space when e.KeyModifiers.HasFlag(KeyModifiers.Shift): ShowBytes(); e.Handled = true; break;
            // Space also counts a folder it marks; Insert only marks, as in Total Commander.
            case Key.Space: MarkAndStep(count: true); e.Handled = true; break;
            case Key.Insert: MarkAndStep(count: false); e.Handled = true; break;
            case Key.R when ctrl: ReloadNow(); e.Handled = true; break;
            // Ctrl+A marks everything; pressed again with everything marked, it takes the marks off.
            case Key.A when ctrl: SetMarks(_rows.Count == 0 || !_rows.All(r => r.Checked)); e.Handled = true; break;
            case Key.Multiply:
                foreach (var row in _rows) row.Checked = !row.Checked;
                UpdateStatus();
                e.Handled = true;
                break;
            // Home/End and Left/Right jump to the ends of the list, as in Total Commander.
            case Key.Home or Key.Left when _rows.Count > 0: List.SelectedIndex = 0; List.ScrollIntoView(_rows[0], null); e.Handled = true; break;
            case Key.End or Key.Right when _rows.Count > 0: List.SelectedIndex = _rows.Count - 1; List.ScrollIntoView(_rows[^1], null); e.Handled = true; break;
        }
    }

    void OnSorting(object? sender, DataGridColumnEventArgs e)
    {
        // Our own order: the grid's would mix folders with files.
        e.Handled = true;
        if (ColumnKeys[e.Column.DisplayIndex] is not { } key) return;
        if (_sort == key) _desc = !_desc; else { _sort = key; _desc = false; }
        UpdateSortHeaders();
        _listed = Listing.Sort(_listed, _sort, _desc);
        Display(null);
    }

    void UpdateSortHeaders()
    {
        for (int i = 0; i < List.Columns.Count && i < ColumnKeys.Length; i++)
        {
            if (ColumnKeys[i] is not { } key) continue;
            List.Columns[i].Header = key == _sort ? Lang.T(ColumnTitles[i]) + (_desc ? " ▼" : " ▲") : Lang.T(ColumnTitles[i]);
        }
    }

    /// <summary>After a change of the language or the theme: captions and colours are data of the panel.</summary>
    public void Refresh()
    {
        UpdateSortHeaders();
        foreach (var (key, button) in _sourceButtons) ToolTip.SetTip(button, Lang.T(Sources.Get(key).Tip));
        UpdateSourceCaptions();
        foreach (var row in _listed) row.Colour = Palette.For(row.Name, row.IsDir, row.Modified);
        FitColumns();
        _listed = _listed.ToList();
        Display(null);
        BuildCrumbs();
    }
}
