using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The window of the mark - the asterisk between the panels. The masks of Audion Disk Tools, its
/// MASKS section folded into one drop-down: the free field of masks with the same rules of text,
/// one's own sets as buttons, the time of the change, and the groups of extensions as chips
/// (include / exclude). Groups only - a single extension is typed into the field (the owner's
/// word, 04.10.2026). A picked group writes its masks into the field; masks typed by hand stay.
/// Here the masks mark the rows of the active panel - the operations then take what is marked.
/// </summary>
public partial class MainWindow
{
    Control? _maskWindow;
    TextBox _maskBox = new();
    string _maskText = "";
    readonly List<string> _include = new(), _exclude = new();
    List<string> _pickerGlobs = new();
    bool _excludeMode;
    AgeLimit _age = AgeLimit.None;
    Panel _maskSets = new StackPanel(), _maskChips = new StackPanel();
    Button _maskDrop = new();

    // Shown over the panels, in their middle, almost as wide as the window: a flyout hung on the
    // small button between the panels had no room for a line of chips.
    readonly Flyout _maskFlyout = new() { Placement = PlacementMode.Center };

    Flyout? MaskFlyout => _maskFlyout;

    /// <summary>
    /// The width of the window of the mark: as wide as its longest line of chips, so that every
    /// family of groups is one line and nothing is left empty after it - but never wider than the
    /// main window. The line is measured by its words in the font of the switches; what a chip
    /// adds around its word (the tick box, the padding, the rim, the gap to the next) is a constant.
    /// </summary>
    double MaskWidth()
    {
        const double Head = 150, Chip = 40, Air = 24;
        var res = Application.Current?.Resources;
        double size = res?.TryGetResource("FontSwitch", null, out var s) == true && s is double d ? d : 10.5;
        var family = res?.TryGetResource("FontUi", null, out var f) == true && f is FontFamily ff ? ff : FontFamily.Default;
        var face = new Typeface(family);
        double Wide(string text) => new FormattedText(text, System.Globalization.CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, size, null).WidthIncludingTrailingWhitespace;
        double longest = 0;
        foreach (var line in MaskGroups.Families)
            longest = Math.Max(longest, line.Groups.Sum(group => Wide(group.Title) + Chip));
        return Math.Clamp(Head + longest + Air, 560, Math.Max(560, Bounds.Width - 72));
    }

    /// <summary>
    /// The masks as the field holds them now. Read from the field itself: its change event comes
    /// a turn later, and a set put into the field and marked at once would mark by the old text.
    /// </summary>
    string MaskField
    {
        get => _maskBox.Text ?? "";
        set { _maskText = value; _maskBox.Text = value; }
    }

    static Dictionary<string, List<string>> GroupMasks() => MaskGroups.Families.SelectMany(f => f.Groups).ToDictionary(g => g.Id, g => g.Masks);

    void WireMasks()
    {
        if (MaskFlyout is not { } flyout) return;
        // Wider than a usual flyout and with no bar across: see FlyoutPresenter.masks in App.axaml.
        flyout.FlyoutPresenterClasses.Add("masks");
        flyout.Opening += (_, _) =>
        {
            flyout.Content = _maskWindow ??= BuildMaskWindow();
            // The main window may have been resized since the last time.
            if (_maskWindow is StackPanel body) body.Width = MaskWidth();
            FillMaskSets();
        };
        MidMask.Click += (_, _) => flyout.ShowAt(PanelsHost);
        flyout.Opened += (_, _) => { _maskBox.Focus(); _maskBox.SelectAll(); };
    }

    /// <summary>The language or the theme changed: the names of the groups and the colours of the chips are built anew at the next opening.</summary>
    void ResetMaskWindow() => _maskWindow = null;

    // ------------------------------------------------------------ the window

    Control BuildMaskWindow()
    {
        _maskBox = new TextBox { Text = _maskText, TextWrapping = TextWrapping.Wrap, MinHeight = 46, MaxHeight = 110, PlaceholderText = "*.docx, *.xlsx, pdf, 2026-*" };
        _maskBox[!TemplatedControl.FontSizeProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("FontHeader");
        _maskBox.TextChanged += (_, _) => { _maskText = _maskBox.Text ?? ""; UpdateMaskDrop(); };
        _maskBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            MarkByMasks(add: false);
            e.Handled = true;
        };

        Button Small(string text, string tip, Action run, string? tone = null)
        {
            var button = new Button { Content = Lang.T(text), Classes = { "small" } };
            if (tone is not null) button.Classes.Add(tone);
            ToolTip.SetTip(button, Lang.T(tip));
            button.Click += (_, _) => run();
            return button;
        }
        TextBlock Caption(string text) => new() { Text = Lang.T(text), Classes = { "caption" }, Margin = new Thickness(0, 6, 0, 0) };

        var body = new StackPanel { Spacing = 5, Width = MaskWidth() };
        body.Children.Add(new TextBlock { Text = Lang.T("МАСКА ОТМЕТКИ"), Classes = { "caption" } });
        body.Children.Add(_maskBox);
        body.Children.Add(new TextBlock { Text = Lang.T("Слово — часть имени (report → *report*), .PNG → *.png, readme.md — как есть."), Classes = { "note" }, TextWrapping = TextWrapping.Wrap });

        _maskDrop = Small("УБРАТЬ НАБОР", "Убрать сохранённый набор, который сейчас стоит в поле. Файлы и отметки не трогаются.", DropMaskSet);
        var run = new FlowRow { LineSpacing = 4 };
        run.Children.Add(Small("ОТМЕТИТЬ", "Отметить в активной панели строки, подходящие под маски и время. Прежние отметки снимаются.", () => MarkByMasks(add: false), "run"));
        run.Children.Add(Small("ДОБАВИТЬ", "Отметить подходящие строки, не снимая прежних отметок.", () => MarkByMasks(add: true)));
        run.Children.Add(Small("СНЯТЬ ВСЁ", "Снять все отметки в активной панели.", () => { _active.SetMarks(false); MaskFlyout?.Hide(); }));
        run.Children.Add(new Border { Width = 14 });
        run.Children.Add(Small("*.*", "Нормализовать: слово — часть имени (report → *report*), точка в начале — расширение (.PNG → *.png), имя с точкой — как есть; повторы убираются.",
            () => MaskField = MaskText.ToText(MaskText.NormalizeTokens(MaskField))));
        run.Children.Add(Small("СОХРАНИТЬ КАК…", "Сохранить маски из поля под своим именем: набор станет кнопкой в этом окне.", SaveMaskSet));
        run.Children.Add(_maskDrop);
        run.Children.Add(Small("ОЧИСТИТЬ", "Очистить поле, выбор групп и время.", ClearMasks));
        body.Children.Add(run);

        body.Children.Add(Caption("СВОИ НАБОРЫ"));
        _maskSets = new FlowRow { LineSpacing = 4 };
        body.Children.Add(_maskSets);

        body.Children.Add(Caption("ИЗМЕНЕНЫ"));
        var ages = new FlowRow { LineSpacing = 4 };
        var ageButtons = new List<(ToggleButton Button, AgeLimit Age)>();
        foreach (var (age, label, tip) in new[]
        {
            (AgeLimit.None, "КОГДА УГОДНО", "Время изменения не учитывается."),
            (AgeLimit.Hour, "ЗА ЧАС", "Не старше часа — как цвет «не старше 1 часа»."),
            (AgeLimit.Day, "ЗА СУТКИ", "Сегодня и вчера — как цвет «не старше 1 дня»."),
            (AgeLimit.Week, "ЗА НЕДЕЛЮ", "Последние семь дней — как цвет «не старше 1 недели»."),
        })
        {
            var button = new ToggleButton { Content = Lang.T(label), Classes = { "switch" }, IsChecked = _age == age };
            ToolTip.SetTip(button, Lang.T(tip));
            ageButtons.Add((button, age));
            ages.Children.Add(button);
        }
        foreach (var (button, age) in ageButtons)
            button.Click += (_, _) =>
            {
                _age = age;
                foreach (var (other, otherAge) in ageButtons) other.IsChecked = otherAge == age;
            };
        body.Children.Add(ages);

        // The picker: what is ticked goes into the field as masks; ИСКЛЮЧИТЬ takes masks back out of it.
        var head = new FlowRow { LineSpacing = 4, Margin = new Thickness(0, 6, 0, 0) };
        head.Children.Add(new TextBlock { Text = Lang.T("ГРУППЫ"), Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var include = new ToggleButton { Content = Lang.T("ВКЛЮЧИТЬ"), Classes = { "switch" }, IsChecked = !_excludeMode };
        var exclude = new ToggleButton { Content = Lang.T("ИСКЛЮЧИТЬ"), Classes = { "switch" }, IsChecked = _excludeMode };
        ToolTip.SetTip(include, Lang.T("Отмеченные группы добавляются в поле масок."));
        ToolTip.SetTip(exclude, Lang.T("Отмеченные группы вычитаются из набранного: «все документы, кроме PDF»."));
        void Mode(bool excluding)
        {
            _excludeMode = excluding;
            include.IsChecked = !excluding;
            exclude.IsChecked = excluding;
            FillMaskChips();
        }
        include.Click += (_, _) => Mode(false);
        exclude.Click += (_, _) => Mode(true);
        head.Children.Add(include);
        head.Children.Add(exclude);
        body.Children.Add(head);

        _maskChips = new StackPanel { Spacing = 4 };
        body.Children.Add(_maskChips);
        FillMaskChips();

        // A flyout is a window of its own: it does not inherit the font of the program. It scrolls
        // by itself when the groups do not fit the screen - no scroll viewer of ours inside it.
        body[!Avalonia.Controls.Documents.TextElement.FontFamilyProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("FontUi");
        body[!Avalonia.Controls.Documents.TextElement.FontSizeProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("FontHeader");
        return body;
    }

    // ------------------------------------------------------------ the mark

    void MarkByMasks(bool add)
    {
        _active.ApplyMasks(MaskText.NormalizeTokens(MaskField), _age, add);
        MaskFlyout?.Hide();
    }

    void ClearMasks()
    {
        _include.Clear();
        _exclude.Clear();
        _pickerGlobs.Clear();
        _age = AgeLimit.None;
        _maskText = "";
        // The switches of the time stand in the window as built: the simplest way to bring them back is to build it anew.
        _maskWindow = BuildMaskWindow();
        if (MaskFlyout is { } flyout) flyout.Content = _maskWindow;
        FillMaskSets();
        _maskBox.Focus();
    }

    // ------------------------------------------------------------ one's own sets

    static string SetText(string text) => MaskText.ToText(MaskText.NormalizeTokens(text));

    /// <summary>
    /// The sets saved under a name live in the data folder (config\mask-sets.json), not in the
    /// settings of the window: they are what a person made, and a cleanup of the program must
    /// not take them. Read when first asked for, read again when another data folder is chosen.
    /// </summary>
    List<MaskSet>? _savedSets;

    List<MaskSet> SavedSets => _savedSets ??= DataStore.LoadMaskSets();

    void ForgetSavedSets() => _savedSets = null;

    bool KeepSavedSets()
    {
        if (DataStore.SaveMaskSets(SavedSets)) return true;
        if (!DataRoot.Chosen) SetStatus(Lang.T("наборы масок хранятся в папке данных: выберите её в SETTINGS"));
        return false;
    }

    MaskSet? SetInField() => SetText(MaskField) is { Length: > 0 } text
        ? SavedSets.FirstOrDefault(set => string.Equals(SetText(set.Text), text, StringComparison.OrdinalIgnoreCase)) : null;

    void UpdateMaskDrop() => _maskDrop.IsEnabled = SetInField() is not null;

    void FillMaskSets()
    {
        _maskSets.Children.Clear();
        foreach (var set in SavedSets)
        {
            var button = new Button { Content = set.Name, Classes = { "small" } };
            ToolTip.SetTip(button, set.Text);
            button.Click += (_, _) =>
            {
                // A set is the whole question: what the picker held before does not mix into it.
                _include.Clear();
                _exclude.Clear();
                _pickerGlobs.Clear();
                MaskField = set.Text;
                FillMaskChips();
                MarkByMasks(add: false);
            };
            _maskSets.Children.Add(button);
        }
        if (SavedSets.Count == 0)
            _maskSets.Children.Add(new TextBlock { Text = Lang.T("Пока нет: наберите маски и нажмите «СОХРАНИТЬ КАК…» — набор станет кнопкой."), Classes = { "note" }, TextWrapping = TextWrapping.Wrap });
        UpdateMaskDrop();
    }

    async void SaveMaskSet()
    {
        // The sets live in the data folder: a set typed in one folder is not saved into another.
        using var pending = Pending();
        var text = SetText(MaskField);
        if (text.Length == 0) return;
        MaskFlyout?.Hide();
        var name = await Dialog.Ask(this, "Имя набора масок", new[] { text }, okText: "СОХРАНИТЬ", value: SetInField()?.Name ?? "");
        if (name is null || (name = name.Trim()).Length == 0) return;
        // One name - one set, and one text - one button: saved again under another name, a set is renamed.
        SavedSets.RemoveAll(set => string.Equals(set.Name, name, StringComparison.OrdinalIgnoreCase)
            || string.Equals(SetText(set.Text), text, StringComparison.OrdinalIgnoreCase));
        SavedSets.Add(new MaskSet { Name = name, Text = text });
        // Not kept - not shown as kept: the list is read from the disk again.
        if (!KeepSavedSets()) ForgetSavedSets();
    }

    void DropMaskSet()
    {
        if (SetInField() is not { } set) return;
        SavedSets.Remove(set);
        if (!KeepSavedSets()) ForgetSavedSets();
        FillMaskSets();
    }

    // ------------------------------------------------------------ the picker

    List<string> Picked => _excludeMode ? _exclude : _include;

    void TogglePick(string key, bool on)
    {
        var list = Picked;
        list.RemoveAll(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase));
        if (on) list.Add(key);
        SyncMaskText();
    }

    /// <summary>
    /// What the picker wrote into the field before is replaced by what it holds now; masks typed
    /// by hand stay, and what is excluded drops out of the field.
    /// </summary>
    void SyncMaskText()
    {
        var groups = GroupMasks();
        var excluded = new HashSet<string>(MaskText.Expand(_exclude, groups), StringComparer.OrdinalIgnoreCase);
        var next = MaskText.Expand(_include, groups).Where(m => !excluded.Contains(m)).ToList();
        var previous = new HashSet<string>(_pickerGlobs.Select(MaskText.NormalizeToken), StringComparer.OrdinalIgnoreCase);
        var custom = MaskText.NormalizeTokens(MaskField).Where(m => !previous.Contains(m) && !excluded.Contains(m));
        _pickerGlobs = next;
        MaskField = MaskText.ToText(MaskText.NormalizeTokens(custom.Concat(next)));
    }

    /// <summary>The colour of a chip: the colour the rows of its family are painted with; a family the theme gives no colour stays neutral.</summary>
    static Color AccentOf(MaskFamily family) =>
        FilePanel.Palette.FamilyColour(family.Id) is ISolidColorBrush brush ? brush.Color : Color.Parse("#6b7a84");

    /// <summary>
    /// A group as a chip: a switch of the program with a small tick box, the box in the colour of
    /// its family - the height and the font of every other switch, not a tall form check box.
    /// </summary>
    Control Chip(string key, string text, Color accent)
    {
        var box = new Border
        {
            Classes = { "tickbox" },
            BorderBrush = App.Rim(accent),
            Child = new Avalonia.Controls.Shapes.Path { Classes = { "tick" }, Data = Geometry.Parse("M 1.5,5 L 4,7.5 L 8.5,2.5") },
        };
        var chip = new ToggleButton
        {
            Classes = { "switch" },
            IsChecked = Picked.Any(k => string.Equals(k, key, StringComparison.OrdinalIgnoreCase)),
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { box, new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center } } },
        };
        chip.Click += (_, _) => TogglePick(key, chip.IsChecked == true);
        return chip;
    }

    /// <summary>Every group as one chip, by family.</summary>
    void FillMaskChips()
    {
        _maskChips.Children.Clear();
        foreach (var family in MaskGroups.Families)
        {
            var accent = AccentOf(family);
            // A family is one line: its name at the left, its chips in a row beside it.
            var line = new Grid { ColumnDefinitions = new ColumnDefinitions("150,*") };
            var head = new TextBlock { Text = family.ShortTitle.ToUpperInvariant(), Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 8, 0), TextTrimming = TextTrimming.CharacterEllipsis };
            ToolTip.SetTip(head, family.Title);
            var row = new FlowRow { LineSpacing = 4 };
            foreach (var group in family.Groups) row.Children.Add(Chip("@group:" + group.Id, group.Title, accent));
            Grid.SetColumn(row, 1);
            line.Children.Add(head);
            line.Children.Add(row);
            _maskChips.Children.Add(line);
        }
    }
}
