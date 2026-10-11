using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;

namespace AudionSyncTools.Views;

/// <summary>
/// The look of the confirmation dialog with rows of choices: a caption on the
/// left, switches on the right - buttons, not drop-downs, so every option is
/// in sight. Groups are parted by a thin line; a hint is its own muted line
/// under its row, so nothing runs together.
/// </summary>
public class ChoiceWindow : Window
{
    const double CaptionWidth = 150;

    protected readonly StackPanel Body = new();
    protected readonly Button Ok = new() { MinWidth = 140, MinHeight = 30 };
    readonly Button _cancel = new() { Content = "ОТМЕНА", MinWidth = 118, MinHeight = 30, Margin = new Thickness(0, 0, 9, 0), IsCancel = true };
    protected bool Accepted;

    protected ChoiceWindow(string head, double width)
    {
        Title = "Audion Sync Tools";
        Width = width;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        CanResize = false;
        ShowInTaskbar = false;
        this[!BackgroundProperty] = new DynamicResourceExtension("AppBg");
        this[!ForegroundProperty] = new DynamicResourceExtension("TextMain");
        FontSize = 13;
        this[!FontFamilyProperty] = new DynamicResourceExtension("FontUi");

        Body.Children.Add(new TextBlock { Text = head, FontSize = 15, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 14) });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 20, 0, 0) };
        buttons.Children.Add(_cancel);
        buttons.Children.Add(Ok);
        Ok.IsDefault = true;
        _cancel.Click += (_, _) => Close();
        Ok.Click += (_, _) => { Accepted = true; Close(); };

        var frame = new Border
        {
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Margin = new Thickness(10), Padding = new Thickness(22, 18),
            Child = new StackPanel { Children = { Body, buttons } },
        };
        frame[!Border.BackgroundProperty] = new DynamicResourceExtension("PanelBg");
        frame[!Border.BorderBrushProperty] = new DynamicResourceExtension("BorderSoft");
        Content = frame;
        Opened += (_, _) => { Lang.Walk(this); Ok.Focus(); };
    }

    /// <summary>Shows the window, never wider than the program window it opens over.</summary>
    protected Task ShowOver(Window owner)
    {
        if (!owner.IsVisible && owner is IReveal hidden) hidden.Reveal();
        if (owner.Bounds.Width > 200) Width = Math.Min(Width, owner.Bounds.Width - 40);
        return ShowDialog(owner);
    }

    /// <summary>A row: caption on the left, the choice on the right, an optional hint under the choice.</summary>
    protected Grid Row(string caption, Control content, TextBlock? hint = null)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions($"{CaptionWidth},*"), RowDefinitions = new RowDefinitions("Auto,Auto"), Margin = new Thickness(0, 4) };
        // Captions sit level with the first line of their choice, not in the middle of three.
        row.Children.Add(new TextBlock { Text = caption, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, content is TextBox ? 11 : 7, 0, 0) });
        Grid.SetColumn(content, 1);
        row.Children.Add(content);
        if (hint is not null)
        {
            hint.Margin = new Thickness(2, 7, 0, 2);
            Grid.SetColumn(hint, 1);
            Grid.SetRow(hint, 1);
            row.Children.Add(hint);
        }
        Body.Children.Add(row);
        return row;
    }

    protected static TextBlock Hint(string text = "") => new()
    {
        Text = text, Classes = { "caption" }, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Top, LineHeight = 18,
    };

    /// <summary>What the operation works on: caption left, the path or list right, wrapped; a muted line under it.</summary>
    protected void Info(string caption, string value, string? below = null)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions($"{CaptionWidth},*"), RowDefinitions = new RowDefinitions("Auto,Auto"), Margin = new Thickness(0, 3) };
        row.Children.Add(new TextBlock { Text = caption, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) });
        var text = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap, LineHeight = 19 };
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        if (below is not null)
        {
            var more = Hint(below);
            more.Margin = new Thickness(0, 4, 0, 0);
            Grid.SetColumn(more, 1);
            Grid.SetRow(more, 1);
            row.Children.Add(more);
        }
        Body.Children.Add(row);
    }

    /// <summary>A thin line between groups of choices.</summary>
    protected Border Divider()
    {
        var line = new Border { Height = 1, Margin = new Thickness(0, 8) };
        line[!Border.BackgroundProperty] = new DynamicResourceExtension("BorderSoft");
        Body.Children.Add(line);
        return line;
    }

    /// <summary>A caption inside a line of switches: the second group of a shared row.</summary>
    protected static TextBlock Inline(string caption) => new()
    {
        Text = caption, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 4, 0),
    };

    protected static ToggleButton Switch(string label, string? tip = null)
    {
        var button = new ToggleButton { Content = label, Classes = { "switch", "pick" } };
        if (tip is not null) ToolTip.SetTip(button, tip);
        return button;
    }

    protected static WrapPanel Chips(params Control[] items)
    {
        var panel = new WrapPanel { Orientation = Orientation.Horizontal, ItemSpacing = 6, LineSpacing = 6 };
        foreach (var item in items) panel.Children.Add(item);
        return panel;
    }

    protected static TextBox Box(string text, double width, string? placeholder = null, bool secret = false) => new()
    {
        Text = text, Width = width, Classes = { "masks" }, PlaceholderText = placeholder, PasswordChar = secret ? '•' : default,
        HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>Six names, then "… и ещё N".</summary>
    protected static string Names(IReadOnlyList<string> names)
    {
        var shown = names.Take(6).ToList();
        var text = string.Join(", ", shown);
        if (names.Count > shown.Count) text += ", " + Lang.F("… и ещё {0}", names.Count - shown.Count);
        return text;
    }
}

/// <summary>ALT+F5: the ARCHIVE section of the Python Disk Tools as one window.</summary>
public sealed class PackDialog : ChoiceWindow
{
    readonly PackOptions _o;
    readonly Dictionary<string, ToggleButton> _formats = new();
    readonly Dictionary<string, ToggleButton> _levels = new();
    readonly Dictionary<string, ToggleButton> _enc = new();
    readonly Dictionary<string, ToggleButton> _scope = new();
    readonly Dictionary<string, ToggleButton> _layout = new();
    readonly Dictionary<string, ToggleButton> _envs = new();
    readonly Dictionary<string, ToggleButton> _wraps = new();
    readonly TextBox _password, _prefix, _suffix, _sfxPath;
    readonly ToggleButton _underscore, _verify, _delete;
    readonly TextBlock _sample = Hint(), _sfxWhere = Hint();
    readonly TextBlock _passwordCaption = Inline("ПАРОЛЬ");
    readonly Grid _sfxEnvRow, _sfxPathRow;
    readonly Border _sfxLine;
    readonly string _firstBase;
    bool _quiet;

    // Wide rather than tall: a 900 px high screen must hold it with SFX open,
    // so short groups share a line and paths take one line each.
    PackDialog(string fromDir, IReadOnlyList<string> names, string toDir, PackOptions o) : base("Упаковать", 1180)
    {
        _o = o;
        _firstBase = Archiver.BaseName(Path.Combine(fromDir, names[0]));
        Info("ОТКУДА", fromDir);
        Info("КУДА", toDir);
        Info("ОБЪЕКТЫ", $"{names.Count} · {Names(names.Select(n => Directory.Exists(Path.Combine(fromDir, n)) ? $"[{n}]" : n).ToList())}");
        Divider();

        var formats = Archiver.Formats.Select(f => (Control)(_formats[f.Id] = Switch(f.Label))).ToList();
        formats.Add(Inline("СЖАТИЕ"));
        formats.AddRange(Archiver.Levels.Select(l => (Control)(_levels[l] = Switch(l, l == "0" ? "0 — без сжатия, только упаковка." : l == "9" ? "9 — сильнее всего и дольше всего." : null))));
        Row("ФОРМАТЫ", Chips(formats.ToArray()));

        var placing = new List<Control>();
        if (names.Count > 1)
        {
            placing.Add(_scope["each"] = Switch("КАЖДЫЙ ОТДЕЛЬНО", "Каждый отмеченный объект — в свой архив; N в приставке или окончании станет его номером."));
            placing.Add(_scope["one"] = Switch("ВСЁ В ОДИН", "Всё отмеченное — в один архив с именем текущей папки."));
            placing.Add(Inline("РАСКЛАДКА"));
        }
        placing.Add(_layout["flat"] = Switch("В ОБЩУЮ ПАПКУ", "Все архивы ложатся прямо в папку соседней панели."));
        placing.Add(_layout["per_folder"] = Switch("КАЖДЫЙ В СВОЮ ПАПКУ", "Для каждого архива — своя папка с именем источника."));
        Row(names.Count > 1 ? "АРХИВЫ" : "РАСКЛАДКА", Chips(placing.ToArray()));

        _password = Box(o.Password, 220, "пароль", secret: true);
        Row("ШИФРОВАНИЕ", Chips(
            _enc["none"] = Switch("НЕ ШИФРОВАТЬ"),
            _enc["password"] = Switch("ЗАШИФРОВАТЬ", "AES-256, только 7Z и SFX: содержимое закрыто паролем, список файлов виден."),
            _enc["names"] = Switch("С ИМЕНАМИ", "AES-256, только 7Z и SFX: закрыт и список файлов — без пароля не видно даже имён."),
            _passwordCaption, _password));

        _prefix = Box(o.Prefix, 170, "приставка");
        _suffix = Box(o.Suffix, 170, "окончание");
        _underscore = Switch("ПРОБЕЛЫ → _", "Пробелы в имени архива заменить подчёркиванием.");
        ToolTip.SetTip(_prefix, "Перед именем источника. N отдельным словом — номер объекта: N_ → 1_, 2_ …");
        ToolTip.SetTip(_suffix, "После имени источника. N отдельным словом — номер объекта: _vN → _v1, _v2 …");
        _sample.VerticalAlignment = VerticalAlignment.Center;
        _sample.Margin = new Thickness(14, 0, 0, 0);
        Row("ИМЯ", Chips(_prefix, _suffix, _underscore, _sample));

        _sfxLine = Divider();
        _sfxEnvRow = Row("SFX: КУДА", Chips(Archiver.SfxEnvs.Select(e => (Control)(_envs[e.Key] = Switch(e.Label, e.Install.Length > 0 ? e.Install : "Без переменной: путь ниже как есть или папка по умолчанию."))).ToArray()));
        _sfxPath = Box(o.SfxPath, 220, "{name}");
        ToolTip.SetTip(_sfxPath, "Путь, куда SFX-архив предложит распаковку. {name} заменяется именем источника.");
        var sfxLine = new List<Control> { _sfxPath, Inline("ОБЁРТКА") };
        sfxLine.AddRange(Archiver.SfxWrappers.Select(w => (Control)(_wraps[w.Id] = Switch(w.Label, "Готовый SFX дополнительно упаковать без сжатия — почта и облака не режут .exe."))));
        _sfxWhere.VerticalAlignment = VerticalAlignment.Center;
        _sfxWhere.Margin = new Thickness(14, 0, 0, 0);
        sfxLine.Add(_sfxWhere);
        _sfxPathRow = Row("SFX: ПУТЬ", Chips(sfxLine.ToArray()));
        Divider();

        _verify = Switch("ПРОВЕРИТЬ АРХИВ", "После создания: 7z t — архив читается целиком, контрольные суммы сверяются; для ZSTD и LZ4 — их собственный тест.");
        _delete = Switch("УДАЛИТЬ ИСХОДНИКИ", "Источник уходит в корзину только когда все его архивы созданы (и проверены, если включено).");
        Row("ПОСЛЕ", Chips(_verify, _delete));

        Ok.Content = "УПАКОВАТЬ";
        Ok.Classes.Add("run");

        foreach (var (id, b) in _formats) b.Click += (_, _) => { Toggle(_o.Formats, id, b.IsChecked == true); Sync(); };
        foreach (var (id, b) in _levels) b.Click += (_, _) => { _o.Level = id; Sync(); };
        foreach (var (id, b) in _enc) b.Click += (_, _) => { _o.Encryption = id; Sync(); };
        foreach (var (id, b) in _scope) b.Click += (_, _) => { _o.Scope = id; Sync(); };
        foreach (var (id, b) in _layout) b.Click += (_, _) => { _o.Layout = id; Sync(); };
        foreach (var (id, b) in _envs) b.Click += (_, _) => { _o.SfxEnv = id; Sync(); };
        foreach (var (id, b) in _wraps) b.Click += (_, _) => { Toggle(_o.SfxWrappers, id, b.IsChecked == true); Sync(); };
        _underscore.Click += (_, _) => { _o.Underscore = _underscore.IsChecked == true; Sync(); };
        _verify.Click += (_, _) => { _o.Verify = _verify.IsChecked == true; Sync(); };
        _delete.Click += (_, _) => { _o.DeleteSource = _delete.IsChecked == true; Sync(); };
        foreach (var box in new[] { _password, _prefix, _suffix, _sfxPath })
            box.TextChanged += (_, _) => { if (!_quiet) Sync(); };
        Sync();
    }

    static void Toggle(List<string> list, string id, bool on)
    {
        list.Remove(id);
        if (on) list.Add(id);
    }

    /// <summary>Everything follows the choices: formats that cannot carry them go off, with the reason in the tip.</summary>
    void Sync()
    {
        _quiet = true;
        _o.Password = _password.Text ?? "";
        _o.Prefix = _prefix.Text ?? "";
        _o.Suffix = _suffix.Text ?? "";
        _o.SfxPath = _sfxPath.Text ?? "";
        if (!Archiver.Levels.Contains(_o.Level)) _o.Level = "1";
        foreach (var f in Archiver.Formats)
        {
            var reason = Archiver.DisabledReason(f.Id, _o.Encryption);
            var b = _formats[f.Id];
            // TAR.LZ4 needs lz4.exe, which PeaZip does not bring: shown only when someone added it.
            b.IsVisible = f.Id != "lz4" || Archiver.Lz4 is not null;
            b.IsEnabled = reason.Length == 0;
            if (reason.Length > 0) _o.Formats.Remove(f.Id);
            b.IsChecked = _o.Formats.Contains(f.Id);
            ToolTip.SetTip(b, reason.Length > 0 ? Lang.T(reason) : null);
        }
        foreach (var (id, b) in _levels) b.IsChecked = _o.Level == id;
        foreach (var (id, b) in _enc) b.IsChecked = _o.Encryption == id;
        foreach (var (id, b) in _scope) b.IsChecked = _o.Scope == id;
        foreach (var (id, b) in _layout) b.IsChecked = _o.Layout == id;
        foreach (var (id, b) in _envs) b.IsChecked = _o.SfxEnv == id;
        foreach (var (id, b) in _wraps)
        {
            b.IsEnabled = id != "zstd" || Archiver.Zstd is not null;
            b.IsChecked = _o.SfxWrappers.Contains(id);
        }
        _underscore.IsChecked = _o.Underscore;
        _verify.IsChecked = _o.Verify;
        _delete.IsChecked = _o.DeleteSource;
        _delete.Classes.Set("warn", _o.DeleteSource);
        _passwordCaption.IsVisible = _password.IsVisible = _o.Encryption != "none";
        bool sfx = _o.Formats.Contains("sfx");
        _sfxLine.IsVisible = _sfxEnvRow.IsVisible = _sfxPathRow.IsVisible = sfx;

        var first = _o.Formats.Select(id => Archiver.Formats.First(f => f.Id == id)).FirstOrDefault();
        var sample = Archiver.DisplayName(_scope.Count > 0 && _o.Scope == "one" ? "…" : _firstBase, _o, 1) + (first?.Ext ?? "");
        _sample.Text = Lang.F("Пример: {0}", sample);
        _sfxWhere.Text = Lang.F("SFX распакует в: {0}", Archiver.SfxInstallPath(_o.SfxEnv, _o.SfxPath, _firstBase) is { Length: > 0 } p ? p : "—");
        Ok.IsEnabled = _o.Formats.Count > 0 && (_o.Encryption == "none" || _o.Password.Length > 0);
        _quiet = false;
    }

    public static async Task<bool> Ask(Window owner, string fromDir, IReadOnlyList<string> names, string toDir, PackOptions o)
    {
        var dialog = new PackDialog(fromDir, names, toDir, o);
        await dialog.ShowOver(owner);
        return dialog.Accepted;
    }
}

/// <summary>ALT+F9: many archives at once - next door, here, smart, each in its own folder.</summary>
public sealed class UnpackDialog : ChoiceWindow
{
    readonly UnpackOptions _o;
    readonly Dictionary<string, ToggleButton> _target = new();
    readonly Dictionary<string, ToggleButton> _mode = new();
    readonly Dictionary<string, ToggleButton> _over = new();
    readonly ToggleButton _delete;
    readonly TextBox _password;
    readonly TextBlock _explain = Hint();

    UnpackDialog(IReadOnlyList<string> archives, string fromDir, string? otherDir, int skipped, UnpackOptions o) : base("Распаковать", 740)
    {
        _o = o;
        if (otherDir is null) _o.Target = "here";
        Info("ОТКУДА", fromDir);
        var list = Names(archives.Select(a => Path.GetFileName(a)).ToList());
        if (skipped > 0) list += "\n" + Lang.F("не архивы и следующие тома пропущены: {0}", skipped);
        Info("АРХИВЫ", archives.Count.ToString(), list);
        Divider();

        Row("КУДА", Chips(
            _target["other"] = Switch("В СОСЕДНЮЮ ПАНЕЛЬ", otherDir ?? "Соседняя панель стоит не в папке."),
            _target["here"] = Switch("ЗДЕСЬ", "Рядом с архивом, в той же папке.")));
        _target["other"].IsEnabled = otherDir is not null;
        Row("КАК", Chips(
            _mode["smart"] = Switch("УМНО", "Архив с одной папкой (или одним файлом) внутри ложится как есть; архив с россыпью файлов получает свою папку по имени архива."),
            _mode["folder"] = Switch("КАЖДЫЙ В СВОЮ ПАПКУ", "Всегда папка по имени архива, даже если внутри уже одна папка."),
            _mode["flat"] = Switch("ВСЁ В ОДНО МЕСТО", "Содержимое всех архивов — прямо в выбранную папку, без своих папок.")), _explain);
        Row("СОВПАДЕНИЯ", Chips(
            _over["rename"] = Switch("ПЕРЕИМЕНОВАТЬ", "Файл с тем же именем уже есть — новый получит имя с номером; папка архива — «имя (2)»."),
            _over["overwrite"] = Switch("ЗАМЕНИТЬ", "Файлы с тем же именем перезаписываются."),
            _over["skip"] = Switch("ПРОПУСТИТЬ", "Файлы с тем же именем не трогаются.")));
        Divider();

        _password = Box(o.Password, 260, "пароль, если архивы закрыты", secret: true);
        Row("ПАРОЛЬ", _password);
        _delete = Switch("УДАЛИТЬ АРХИВЫ", "После удачной распаковки архив (и все его тома) уходит в корзину. С предупреждениями или ошибкой — остаётся.");
        Row("ПОСЛЕ", Chips(_delete), Hint("Целостность проверяется при распаковке: PeaZip сверяет контрольную сумму каждого файла."));

        Ok.Content = "РАСПАКОВАТЬ";
        Ok.Classes.Add("run");
        foreach (var (id, b) in _target) b.Click += (_, _) => { _o.Target = id; Sync(); };
        foreach (var (id, b) in _mode) b.Click += (_, _) => { _o.Mode = id; Sync(); };
        foreach (var (id, b) in _over) b.Click += (_, _) => { _o.Overwrite = id; Sync(); };
        _delete.Click += (_, _) => { _o.DeleteArchives = _delete.IsChecked == true; Sync(); };
        _password.TextChanged += (_, _) => _o.Password = _password.Text ?? "";
        Sync();
    }

    void Sync()
    {
        foreach (var (id, b) in _target) b.IsChecked = _o.Target == id;
        foreach (var (id, b) in _mode) b.IsChecked = _o.Mode == id;
        foreach (var (id, b) in _over) b.IsChecked = _o.Overwrite == id;
        // "Skip" leaves names inside the archive untaken: it may be their only copy.
        if (_o.Overwrite == "skip") _o.DeleteArchives = false;
        _delete.IsEnabled = _o.Overwrite != "skip";
        ToolTip.SetTip(_delete, Lang.T(_o.Overwrite == "skip"
            ? "При «ПРОПУСТИТЬ» архивы не удаляются: пропущенные файлы остались только в них."
            : "После удачной распаковки архив (и все его тома) уходит в корзину. С предупреждениями или ошибкой — остаётся."));
        _delete.IsChecked = _o.DeleteArchives;
        _delete.Classes.Set("warn", _o.DeleteArchives);
        _explain.Text = Lang.T(_o.Mode switch
        {
            "folder" => "Каждый архив — в папку со своим именем.",
            "flat" => "Всё содержимое — в одну папку; совпадающие имена решает строка ниже.",
            _ => "Одна папка внутри — ляжет как есть; россыпь файлов — получит папку по имени архива. Если такое имя уже занято — тоже своя папка.",
        });
    }

    public static async Task<bool> Ask(Window owner, IReadOnlyList<string> archives, string fromDir, string? otherDir, int skipped, UnpackOptions o)
    {
        var dialog = new UnpackDialog(archives, fromDir, otherDir, skipped, o);
        await dialog.ShowOver(owner);
        return dialog.Accepted;
    }
}
