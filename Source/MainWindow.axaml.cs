using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The window of Audion Sync Tools: six sections, each a row of buttons over the same two file
/// panels and the journal. The window decides nothing about keys, routes or routers - every
/// button starts a script of the engine or rclone; what it owns is the panels and the look.
/// </summary>
public partial class MainWindow : Window
{
    readonly Settings _settings;
    readonly JobRunner _jobs = new();
    readonly Dictionary<string, ToggleButton> _sectionButtons = new();
    readonly Dictionary<string, Ellipse> _dots = new();
    readonly Dictionary<string, TextBlock> _dotWords = new();
    readonly Dictionary<string, Button> _barButtons = new();
    string _section = "transport";
    FilePanel _active;
    int _logLines;
    bool _routeBusy;

    public MainWindow() : this(Settings.Load()) { }

    public MainWindow(Settings settings)
    {
        _settings = settings;
        InitializeComponent();
        _active = LeftPanel;

        if (settings.Width >= MinWidth && settings.Height >= MinHeight) { Width = settings.Width; Height = settings.Height; }
        Sources.Picked = settings.Routes;
        FilePanel.Palette = RowPalette.Load(settings.Look);
        App.SetFontStep(settings.FontStep);

        BuildSections();
        WireTop();
        ApplyLook();
        WireRoutes();
        WirePanels();
        WireJobs();
        WireActions();
        WireFiles();

        Journal.Lines += OnJournal;
        SafeFile.Problem += text => SetStatus(text);
        Lang.Follow(StatusText);

        VersionText.Text = "v" + Paths.Version;
        StreamsValue.Text = settings.Streams.ToString();
        UpdateDataBadge();
        Title = BaseTitle;

        Opened += (_, _) => Start();
        Closing += OnClosing;
        AddHandler(KeyDownEvent, OnKey, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        AddHandler(PointerPressedEvent, (_, e) => _mods = e.KeyModifiers, Avalonia.Interactivity.RoutingStrategies.Tunnel, handledEventsToo: true);
    }

    /// <summary>
    /// The window closes. A transfer does not outlive it under any circumstances: an orphaned
    /// rclone goes on pouring files, and a folder removed by hand comes back. So a running job is
    /// asked about - closing kills it, and that has to be a decision, not a discovery by half a
    /// file on the other side - and on a "yes" the job goes with its children and the queue with
    /// it. Windows shutting down is not asked: there is nobody to wait for an answer.
    /// </summary>
    void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_jobs.Running && !_closeConfirmed && e.CloseReason == WindowCloseReason.WindowClosing)
        {
            e.Cancel = true;
            AskToClose();
            return;
        }
        SaveWindow();
        _search?.Close();
        _jobs.StopForClose();
        Rclone.StopAll();
        SaveClouds();
    }

    bool _closeConfirmed, _closeAsking;

    async void AskToClose()
    {
        if (_closeAsking) return;
        _closeAsking = true;
        try
        {
            int left = _jobs.Waiting;
            var go = await Dialog.Ask(this, "Закрыть окно и прервать передачу?",
                new[] { left > 0 ? Lang.F("Идёт передача, и в очереди ещё {0}.", left) : Lang.T("Идёт передача.") }, "ПРЕРВАТЬ", Tone.Danger);
            if (go is null) return;
            _closeConfirmed = true;
            Close();
        }
        finally { _closeAsking = false; }
    }

    /// <summary>The data folder is made ready at the start as well: a fresh one gets the frame of its addresses before the first press of a button.</summary>
    async void PrepareAtStart()
    {
        try
        {
            if (!await PrepareData()) return;
            // The frame of the addresses appeared, or the working files an old version left came
            // into the data folder: what was read and shown before them is read again.
            Sources.Rebuild();
            bool settings = _settingsOpen;
            SetSection(_section, openPanels: false);
            if (settings) ToggleSettings(true);
            LeftPanel.ReloadNow();
            RightPanel.ReloadNow();
            RefreshState();
        }
        catch { }
    }

    void Start()
    {
        var first = _settings.PinnedMode.Length > 0 && Sources.Sections.Any(s => s.Key == _settings.PinnedMode) ? _settings.PinnedMode : "transport";
        SetSection(first, openPanels: true);
        Lang.Walk(this);
        Journal.Add(Lang.F("программа: {0}", Paths.Root));
        if (DataRoot.Chosen) Journal.Add(Lang.F("данные: {0}", DataRoot.Path_));
        else if (DataRoot.Named.Length > 0) Journal.Add(Lang.F("[окно] папка данных из -Root не найдена: {0}", DataRoot.Named));
        // What an older settings file still holds of the sets of masks and the pairs of BISYNC goes
        // where it lives now - into the data folder of this machine. A folder named by -Root is the
        // folder of one run: carried there, the sets would be gone from the machine they belong to.
        if (DataRoot.Named.Length == 0 && DataStore.Adopt(_settings)) _settings.Save();
        if (Paths.Ps is null) Journal.Add(Lang.T("[окно] нет PowerShell программы: App\\AudionPs.exe не собран"));
        foreach (var problem in SafeFile.Pending) SetStatus(problem);
        SafeFile.Pending.Clear();
        _active.FocusList();
        StartProbe(quiet: true);
        FindLegacyTask();
        OpenClouds();
        RefreshState();
        ShowState();
        PrepareAtStart();
#if DEBUG
        // A check without a mouse: a modal question would hold every script of steps. The step
        // "firststart" shows the window on demand; without a script the Debug copy asks as a release does.
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("AUDION_DEV_SCRIPT")))
        {
            if (!DataRoot.Chosen) ToggleSettings(true);
            RunDevScript();
            return;
        }
#endif
        // The data folder and the tools: what the program cannot work without is asked at once.
        FirstStart();
    }

    void SaveWindow()
    {
        if (WindowState == WindowState.Normal) { _settings.Width = Width; _settings.Height = Height; }
        _settings.Routes = Sources.Picked;
        _settings.Save();
    }

    // ------------------------------------------------------------ sections

    void BuildSections()
    {
        foreach (var section in Sources.Sections)
        {
            var button = new ToggleButton
            {
                Classes = { "switch", "section" },
                Tag = section.Key,
                Content = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = section.Title, HorizontalAlignment = HorizontalAlignment.Center },
                        new TextBlock { Text = section.Hint, Classes = { "hint" } },
                    },
                },
            };
            button.Click += (_, _) => SetSection(section.Key, openPanels: true);
            SectionRow.Children.Add(button);
            _sectionButtons[section.Key] = button;
        }
        // SETTINGS closes the row, the rightmost: no section of work - what is set once and left alone.
        _settingsButton = new ToggleButton
        {
            Classes = { "switch", "section" },
            Content = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = "SETTINGS", HorizontalAlignment = HorizontalAlignment.Center },
                    new TextBlock { Text = "окно и инструменты", Classes = { "hint" } },
                },
            },
        };
        _settingsButton.Click += (_, _) => ToggleSettings();
        SectionRow.Children.Add(_settingsButton);
    }

    sealed class BarItem
    {
        public string Name { get; set; } = "";
        public string Text { get; set; } = "";
        public string Hint { get; set; } = "";
        public string Tip { get; set; } = "";
        public string Style { get; set; } = "";
        public string Dot { get; set; } = "";
        public string Host { get; set; } = "";
    }

    sealed class BarGroup
    {
        public string Name { get; set; } = "";
        public string Kind { get; set; } = "";
        public string Title { get; set; } = "";
        public List<BarItem> Items { get; set; } = new();
    }

    static readonly Lazy<Dictionary<string, List<BarGroup>>> Bars = new(() =>
    {
        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, List<BarGroup>>>(File.ReadAllText(Paths.Data("bars.json")),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? new();
        }
        catch { return new(); }
    });

    static string BarOf(string section) => section switch
    {
        "tunnel" => "BarTunnel", "transport" => "BarTransport", "keys" => "BarKeys",
        "setup" => "BarSetup", "clouds" => "BarClouds", _ => "BarMirror",
    };

    /// <summary>
    /// The row of buttons of a section, group by group: a thin bar in the colour of the kind, a
    /// one-word caption, the buttons. A group moves to the next line whole.
    /// </summary>
    void BuildBar(string section)
    {
        Bar.Children.Clear();
        _dots.Clear();
        _dotWords.Clear();
        _barButtons.Clear();
        if (!Bars.Value.TryGetValue(BarOf(section), out var groups)) return;
        foreach (var group in groups)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 6) };
            row.Children.Add(new Border { Width = 2, Background = App.Ink(group.Kind.Length > 0 ? group.Kind : "KindData"), Margin = new Thickness(0, 1, 7, 1) });
            if (group.Title.Length > 0)
                row.Children.Add(new TextBlock { Text = group.Title, Classes = { "caption" }, Margin = new Thickness(0, 0, 9, 0) });
            foreach (var item in group.Items)
            {
                if (item.Host.Length > 0) { BuildHosts(row, routers: item.Host == "RouterHosts"); continue; }
                // REMOVE TASK: only where the left-over of the Scheduler is really there.
                if (item.Name == "SetupScheduleButton" && !_legacyTaskFound) continue;
                row.Children.Add(BarButton(item));
            }
            Bar.Children.Add(row);
        }
    }

    Button BarButton(BarItem item)
    {
        var button = new Button { Tag = item.Name };
        switch (item.Style)
        {
            case "WarnButton": button.Classes.Add("warn"); break;
            case "RunButton" or "SetupRun": button.Classes.Add("run"); break;
            case "DangerButton" or "SetupDanger": button.Classes.Add("danger"); break;
        }
        Control caption = new TextBlock { Text = item.Text, HorizontalAlignment = HorizontalAlignment.Center };
        if (item.Dot.Length > 0)
        {
            var dot = new Ellipse { Width = 7, Height = 7, Fill = App.Ink("DotIdle"), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            _dots[item.Dot] = dot;
            // The word beside a dot may say more than the name: SSH TUN names the VPS its channel goes through.
            var word = new TextBlock { Text = item.Text, Tag = item.Text };
            _dotWords[item.Dot] = word;
            caption = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Children = { dot, word } };
        }
        var stack = new StackPanel { Children = { caption } };
        if (item.Hint.Length > 0) stack.Children.Add(new TextBlock { Text = item.Hint, Classes = { "hint" } });
        button.Content = stack;
        if (item.Tip.Length > 0) ToolTip.SetTip(button, item.Tip);
        button.Click += (_, _) => Act(item.Name, item.Text);
        _barButtons[item.Name] = button;
        return button;
    }

    /// <summary>
    /// The buttons of the machines and of the routers come from the targets file: a key with
    /// "router-" goes to the routers, the rest to the machines, in the order of the file. What is
    /// written in targets.json is what stands over a button.
    /// </summary>
    void BuildHosts(StackPanel row, bool routers)
    {
        foreach (var target in Targets.Read())
        {
            // SECOND VPS is no machine of a terminal row here: its route is described apart.
            if (target.Key == "second" || target.IsRouter != routers) continue;
            var tip = Lang.F("Открыть терминал: {0}", target.Desc);
            if (!target.HasAddress) tip += " " + Lang.T("Адрес не заполнен: впиши его в targets.json, и кнопка заработает.");
            if (!target.KeyAuth) tip += " " + Lang.T("Пускает только по паролю: ключ ему не предлагается.");
            if (target.Hint.Length > 0) tip += " " + Lang.T(target.Hint);

            var dot = new Ellipse { Width = 7, Height = 7, Fill = App.Ink("DotIdle"), Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
            _dots["host:" + target.Key] = dot;
            var button = new Button
            {
                Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, new TextBlock { Text = target.Caption, VerticalAlignment = VerticalAlignment.Center } } },
                MinHeight = 30,
            };
            ToolTip.SetTip(button, tip);
            button.Click += (_, _) => OpenTerminal(target);
            row.Children.Add(button);
        }
    }

    void SetSection(string key, bool openPanels)
    {
        var before = Sources.SectionOf(_section);
        var section = Sources.SectionOf(key);
        _section = section.Key;
        if (_settingsOpen) ToggleSettings(false);
        foreach (var (name, button) in _sectionButtons) button.IsChecked = name == _section;
        PinButton.Classes.Set("on", _settings.PinnedMode == _section);
        BuildBar(_section);
        Lang.Walk(Bar);
        UpdateTerminalCaption();

        LeftPanel.SetSources(Sources.Of(section));
        RightPanel.SetSources(Sources.Of(section));
        // The panels move only when the section shows other things: TUNNEL and REMOTE share
        // theirs, and switching between them must not undo what is open.
        bool same = before.Sources.SequenceEqual(section.Sources);
        if (openPanels && (!same || !_opened))
        {
            LeftPanel.Open(section.Left);
            RightPanel.Open(section.Right);
        }
        _opened = true;
        LeftPanel.UpdateSourceCaptions();
        RightPanel.UpdateSourceCaptions();
        UpdateDots();
        PaintState();
    }

    bool _opened;

    // ------------------------------------------------------------ the top row

    void WireTop()
    {
        DataBadge.Click += (_, _) => { if (DataRoot.Chosen) Shell(DataRoot.Path_); };
        PinButton.Click += (_, _) =>
        {
            // A second click on the pinned section lets it go.
            _settings.PinnedMode = _settings.PinnedMode == _section ? "" : _section;
            _settings.Save();
            PinButton.Classes.Set("on", _settings.PinnedMode == _section);
        };

        SettingsClose.Click += (_, _) => ToggleSettings(false);
        Format.ExactBytes = _settings.ExactBytes;
        // The panels were built before the settings were read: their columns take the width of the mode now.
        LeftPanel.FitColumns();
        RightPanel.FitColumns();
        ApplyButtonRow();

        LangButton.Content = Lang.Code == "ru" ? "EN" : "RU";
        LangButton.Click += (_, _) => SwitchLanguage();

        ThemeDark.Click += (_, _) => SetTheme("dark");
        ThemeVault.Click += (_, _) => SetTheme("vault");
        ThemeCode.Click += (_, _) => SetTheme("codedark");
        ThemeLight.Click += (_, _) => SetTheme("light");
        MarkTheme();

        StreamsUp.Click += (_, _) => SetStreams(_settings.Streams * 2);
        StreamsDown.Click += (_, _) => SetStreams(_settings.Streams / 2);

        ClearLogButton.Click += (_, _) =>
        {
            LogBox.Inlines?.Clear();
            _logRuns.Clear();
            _logLines = 0;
            SetStatus("панель очищена");
        };
        CopyLogButton.Click += async (_, _) =>
        {
            // What the panel holds - its last three thousand lines. A copy of everything since the start was
            // kept beside it and never cut: it only grew, for as long as the window stood open.
            var text = string.Join(Environment.NewLine, _logRuns.Select(line => (line.Run.Text ?? "").TrimEnd('\n'))) + Environment.NewLine;
            if (Clipboard is { } clipboard) await Avalonia.Input.Platform.ClipboardExtensions.SetTextAsync(clipboard, text);
            SetStatus("журнал в буфере обмена");
        };
        RefreshButton.Click += (_, _) => { LeftPanel.Reload(); RightPanel.Reload(); UpdateDots(); RefreshState(); ShowState(); StartProbe(quiet: false); };
        StopButton.Click += (_, _) => _jobs.Stop();
    }

    void UpdateDataBadge()
    {
        DataBadge.Content = DataRoot.Chosen ? "DATA: " + System.IO.Path.GetFileName(DataRoot.Path_) : Lang.T("DATA: не выбрана");
        DataBadge.Classes.Set("warn", !DataRoot.Chosen);
    }

    void SetFont(int step, bool save = true)
    {
        _settings.FontStep = step;
        App.SetFontStep(step);
        LeftPanel.FitColumns();
        RightPanel.FitColumns();
        if (save) _settings.Save();
    }

    void SetStreams(int count)
    {
        count = Math.Clamp(count, 1, 64);
        if (count == _settings.Streams) return;
        _settings.Streams = count;
        _settings.Save();
        StreamsValue.Text = count.ToString();
        Journal.Add(Lang.F("[окно] потоков: {0}", count));
    }

    void SwitchLanguage()
    {
        var next = Lang.Code == "ru" ? "en" : "ru";
        Lang.Set(next);
        _settings.Lang = next;
        _settings.Save();
        LangButton.Content = next == "ru" ? "EN" : "RU";
        // What is built by code is built again in the new language; what the markup holds is walked.
        bool settings = _settingsOpen;
        SetSection(_section, openPanels: false);
        Lang.Walk(this);
        ResetMaskWindow();
        // The hints of the dots are words too.
        PaintState();
        LeftPanel.Refresh();
        RightPanel.Refresh();
        UpdateDataBadge();
        if (settings) ToggleSettings(true);
        Title = BaseTitle;
        ShowProbeSummary();
    }

    void SetTheme(string theme)
    {
        _settings.Look = theme;
        _settings.Save();
        if (Application.Current is { } app) app.RequestedThemeVariant = App.Variant(theme);
        FilePanel.Palette = RowPalette.Load(theme);
        ResetMaskWindow();
        MarkTheme();
        // Brushes taken by code (the bars of the groups, the dots) belong to the old theme.
        Dispatcher.UIThread.Post(() =>
        {
            SetSection(_section, openPanels: false);
            Lang.Walk(Bar);
            LeftPanel.Refresh();
            RightPanel.Refresh();
            Recolour();
        }, DispatcherPriority.Background);
    }

    void MarkTheme()
    {
        ThemeDark.IsChecked = _settings.Look == "dark";
        ThemeVault.IsChecked = _settings.Look == "vault";
        ThemeCode.IsChecked = _settings.Look == "codedark";
        ThemeLight.IsChecked = _settings.Look == "light";
        ThemeButton.IsChecked = false;
    }

    // ------------------------------------------------------------ the journal

    static string ToneKey(LogTone tone) => tone switch
    {
        LogTone.Muted => "LogMuted", LogTone.Head => "LogHead", LogTone.Good => "LogGood",
        LogTone.Warn => "LogWarn", LogTone.Bad => "LogBad", _ => "LogPlain",
    };

    void OnJournal(IReadOnlyList<(string Text, LogTone Tone)> lines)
    {
        if (!Dispatcher.UIThread.CheckAccess()) { Dispatcher.UIThread.Post(() => OnJournal(lines)); return; }
        var inlines = LogBox.Inlines ??= new InlineCollection();
        foreach (var (text, tone) in lines)
        {
            var run = new Run(text + "\n") { Foreground = App.Ink(ToneKey(tone)) };
            inlines.Add(run);
            _logRuns.Add((run, tone));
            _logLines++;
        }
        // A long day of work must not grow the panel without end: the file keeps everything.
        while (_logLines > 3000 && inlines.Count > 0) { inlines.RemoveAt(0); _logRuns.RemoveAt(0); _logLines--; }
        Dispatcher.UIThread.Post(() => LogScroll.ScrollToEnd(), DispatcherPriority.Background);
    }

    // What every line of the panel means: a Run has nowhere to keep it, and a theme change needs it.
    readonly List<(Run Run, LogTone Tone)> _logRuns = new();

    /// <summary>After a theme change the lines already written keep their meaning and take the new colours.</summary>
    void Recolour()
    {
        foreach (var (run, tone) in _logRuns) run.Foreground = App.Ink(ToneKey(tone));
    }

    void SetStatus(string text) => StatusText.Text = text;

    /// <summary>
    /// The title of the window. Started without administrator rights, the program says so right
    /// there, beside the buttons of the window: the tunnels and sshd are out of reach, the rest works.
    /// </summary>
    static string BaseTitle => Program.IsAdmin ? "Audion Sync Tools" : "Audion Sync Tools  ·  " + Lang.T("БЕЗ ПРАВ АДМИНИСТРАТОРА");

    // ------------------------------------------------------------ jobs

    void WireJobs()
    {
        _jobs.Status += SetStatus;
        _jobs.Progress += pct =>
        {
            ProgressBar.IsVisible = pct is not null;
            ProgressBar.IsIndeterminate = pct is { } p && double.IsNaN(p);
            if (pct is { } value && !double.IsNaN(value)) ProgressBar.Value = value;
        };
        _jobs.RunningChanged += running =>
        {
            StopButton.IsEnabled = running;
            Title = running ? BaseTitle + " — " + StatusText.Text : BaseTitle;
        };
        _jobs.Finished += (job, ok, _) =>
        {
            if (!job.Refresh) return;
            LeftPanel.Reload();
            RightPanel.Reload();
        };
        _jobs.Idle += UpdateDots;
        // A job may have changed what the dots tell: a key was made, a service installed, the tunnel switched.
        _jobs.Idle += RefreshState;
    }

    /// <summary>The transfers of the queue get the streams of the window: one place for every job.</summary>
    Job RcloneJob(string title, IEnumerable<string> operation, bool transfer, Action? onSuccess = null)
    {
        var args = operation.ToList();
        // The defaults of rclone do not fit: it splits a file into streams only from 256 MB, and
        // on a fast channel the gain shows earlier. The threshold is 16 MB, the count is the window's.
        if (transfer)
        {
            var streams = Math.Max(1, _settings.Streams).ToString();
            args.AddRange(new[] { "--transfers", streams, "--multi-thread-streams", streams, "--multi-thread-cutoff", "16M" });
        }
        return Rclone.Job(title, args, refresh: true, onSuccess: onSuccess);
    }

    // ------------------------------------------------------------ panels and keys

    void WirePanels()
    {
        MidUp.Click += (_, _) => { _active.Up(); _active.FocusList(); };
        MidReload.Click += (_, _) => { _active.ReloadNow(); _active.FocusList(); };
        WireMasks();
        MidSearch.Click += (_, _) => OpenSearch();
        MidSwap.Click += (_, _) => SwapPanels();
        MidNames.Click += (_, _) => CopyNames(full: false);
        MidPaths.Click += (_, _) => CopyNames(full: true);
        MidRoutes.Click += (_, _) => ShowRouteBoard();
        MidPower.Click += (_, _) => Act("VpnPowerButton", "WG BASE-ROUTER");
        foreach (var panel in new[] { LeftPanel, RightPanel })
        {
            panel.Activated += p => SetActive(p);
            panel.TerminalAsked += TerminalHere;
            panel.Proven += p => { Prove(p.SourceKey); UpdateDots(); };
        }
        SetActive(LeftPanel);
    }

    readonly Dictionary<string, DateTime> _proven = new();

    void SetActive(FilePanel panel)
    {
        _active = panel;
        LeftPanel.SetActive(panel == LeftPanel);
        RightPanel.SetActive(panel == RightPanel);
    }

    FilePanel Other => _active == LeftPanel ? RightPanel : LeftPanel;

    /// <summary>The panels change places: what each shows - the source and the folder. Nothing else is kept in a panel.</summary>
    void SwapPanels()
    {
        string leftKey = LeftPanel.SourceKey, leftPath = LeftPanel.Path, rightKey = RightPanel.SourceKey, rightPath = RightPanel.Path;
        LeftPanel.Open(rightKey, rightPath);
        RightPanel.Open(leftKey, leftPath);
        _active.FocusList();
    }

    /// <summary>The names, or the full addresses as rclone reads them, of what is marked - one per line.</summary>
    async void CopyNames(bool full)
    {
        var rows = _active.Selection();
        if (rows.Count == 0 || Clipboard is not { } clipboard) return;
        var lines = rows.Select(r => full ? Sources.RemotePath(_active.SourceKey, Sources.Child(_active.Path, r.Name)) : r.Name);
        await Avalonia.Input.Platform.ClipboardExtensions.SetTextAsync(clipboard, string.Join(Environment.NewLine, lines));
        SetStatus(Lang.F(full ? "адресов в буфере обмена: {0}" : "имён в буфере обмена: {0}", rows.Count));
    }

    void OnKey(object? sender, KeyEventArgs e)
    {
        // A text field keeps its keys: F2 in the mask box is not a rename, and Esc there belongs to
        // the field. It stood below the next check, and Esc in the quick filter or in the box of
        // masks stopped a running transfer and dropped its queue without a word - while closing
        // the window in the same state asks first.
        if (e.Source is TextBox) return;
        // Esc while a job runs is СТОП - before any other use of Esc in the panels, as in Audion Disk Tools.
        if (e.Key == Key.Escape && _jobs.Running)
        {
            _jobs.Stop();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && _settingsOpen) { ToggleSettings(false); e.Handled = true; return; }
        if (_settingsOpen) return;
        bool ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control), shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift), alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        // ALT+F1 / ALT+F2: the list of sources of the left / right panel, as the drive list of Total Commander.
        if (alt && e.Key is Key.F1 or Key.F2)
        {
            var panel = e.Key == Key.F1 ? LeftPanel : RightPanel;
            SetActive(panel);
            panel.OpenSourceMenu();
            e.Handled = true;
            return;
        }
        if (e.Key == Key.Escape && _active.QuickOn) { _active.CloseQuickFilter(); e.Handled = true; return; }
        // Esc takes the found list of a search off the panel: the folder itself comes back.
        if (e.Key == Key.Escape && _active.ShowingFound) { _active.LeaveFound(); e.Handled = true; return; }
        // Ctrl+F and Alt+F7 - the search window; F alone - the quick line that narrows the list of the active panel.
        if ((ctrl && e.Key == Key.F) || (alt && e.Key == Key.F7)) { OpenSearch(); e.Handled = true; return; }
        if (e.Key == Key.F && e.KeyModifiers == KeyModifiers.None) { _active.OpenQuickFilter(); e.Handled = true; return; }
        // SHIFT+F4 - a new file, before F4 edits. Names and full paths into the clipboard: Ctrl+Shift+N, Ctrl+Shift+P.
        if (shift && e.Key == Key.F4) { NewFile(); e.Handled = true; return; }
        if (ctrl && shift && e.Key == Key.N) { CopyNames(full: false); e.Handled = true; return; }
        if (ctrl && shift && e.Key == Key.P) { CopyNames(full: true); e.Handled = true; return; }
        // ALT+F5 and ALT+F9 before the plain keys: F5 alone is the copy.
        if (e.KeyModifiers.HasFlag(KeyModifiers.Alt) && e.Key is Key.F5 or Key.F9)
        {
            _ = e.Key == Key.F5 ? Pack() : Unpack();
            e.Handled = true;
            return;
        }
        switch (e.Key)
        {
            case Key.Tab:
                SetActive(Other);
                _active.FocusList();
                e.Handled = true;
                break;
            case Key.U when e.KeyModifiers.HasFlag(KeyModifiers.Control): SwapPanels(); e.Handled = true; break;
            case Key.F2: Rename(); e.Handled = true; break;
            case Key.F3: ShareLinks(); e.Handled = true; break;
            case Key.F4 when !e.KeyModifiers.HasFlag(KeyModifiers.Alt): Edit(); e.Handled = true; break;
            case Key.F5: Copy(move: false); e.Handled = true; break;
            case Key.F6: Copy(move: true); e.Handled = true; break;
            case Key.F7 when !alt: Mkdir(); e.Handled = true; break;
            // SHIFT+DEL and SHIFT+F8: past the Recycle Bin, as in Explorer and Total Commander.
            case Key.F8 or Key.Delete: Delete(permanent: shift); e.Handled = true; break;
            case Key.F11: Sync("copy"); e.Handled = true; break;
            case Key.F12: Sync("mirror"); e.Handled = true; break;
        }
    }

    static void Shell(string path)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { Journal.Add(Lang.F("[окно] не открылось: {0}", ex.Message)); }
    }
}
