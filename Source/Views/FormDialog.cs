using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Shapes;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;

namespace AudionSyncTools.Views;

/// <summary>A field of a form: a caption over a box; a secret one shows dots.</summary>
public sealed record FormField(string Key, string Label, string Value = "", bool Secret = false);

/// <summary>A cell of a row of the table: a box of a fixed width with a hint inside while it is empty.</summary>
public sealed record FormCell(string Key, string Value, double Width, string Hint);

/// <summary>A row of the table: what it is about, a note under the name, its cells.</summary>
public sealed record FormRow(string Key, string Label, string Note, IReadOnlyList<FormCell> Cells);

/// <summary>A state shown before the question: a dot (ok, warn, bad, idle) and a few words.</summary>
public sealed record FormBadge(string Text, string State);

/// <summary>What a form was answered with: the fields, the cells of the table by row, the picked choice.</summary>
public sealed class FormAnswer
{
    public Dictionary<string, string> Fields { get; } = new();
    public Dictionary<string, Dictionary<string, string>> Table { get; } = new();
    public string Choice { get; set; } = "";
    /// <summary>The networks of the editor of routes, each as address/bits; empty lines are left out.</summary>
    public List<string> Routes { get; } = new();
}

/// <summary>
/// The dialog of the SETUP wizards - the confirmation in its fuller shapes:
/// lines of text, badges of state, a table (ADDRESSES: a machine a row), fields (a pair of keys,
/// an identifier), choices. Any of them may be absent. The texts of the lines come ready; captions
/// of fields, cells and choices are translated here.
/// </summary>
public static class FormDialog
{
    /// <summary>A check without a mouse (MainWindow.Dev): the next form is answered by this JSON, laid over what the form held; "cancel" closes it.</summary>
    public static string? DevAnswer { get; set; }

    public static async Task<FormAnswer?> Ask(Window owner, string head, string okText, IEnumerable<string>? lines = null,
        IReadOnlyList<FormBadge>? badges = null, IReadOnlyList<FormRow>? table = null, IReadOnlyList<FormField>? fields = null,
        IReadOnlyList<Choice>? choices = null, string? picked = null, IReadOnlyList<string>? routes = null)
    {
        FormAnswer? result = null;
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = Core.Lang.T(head), FontSize = 15, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });

        if (badges is { Count: > 0 })
        {
            var row = new FlowRow { LineSpacing = 4, Margin = new Thickness(0, 0, 0, 10) };
            foreach (var badge in badges)
            {
                var dot = new Ellipse { Width = 8, Height = 8, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
                dot[!Shape.FillProperty] = new DynamicResourceExtension(badge.State switch { "ok" => "DotOk", "warn" => "DotWarn", "bad" => "DotBad", _ => "DotIdle" });
                var chip = new Border
                {
                    Classes = { "probe" }, Margin = new Thickness(0, 0, 6, 0),
                    Child = new StackPanel { Orientation = Orientation.Horizontal, Children = { dot, new TextBlock { Text = badge.Text, Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center } } },
                };
                row.Children.Add(chip);
            }
            body.Children.Add(row);
        }

        foreach (var line in lines ?? System.Array.Empty<string>())
            body.Children.Add(new TextBlock { Text = line.Length == 0 ? " " : line, TextWrapping = TextWrapping.Wrap, Classes = { "plain" }, Margin = new Thickness(0, 0, 0, 3) });

        var cells = new List<(string Row, string Key, TextBox Box)>();
        if (table is { Count: > 0 })
        {
            var grid = new StackPanel { Spacing = 6, Margin = new Thickness(0, 10, 0, 0) };
            foreach (var row in table)
            {
                var line = new Grid { ColumnDefinitions = new ColumnDefinitions("150,*") };
                var name = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
                name.Children.Add(new TextBlock { Text = Core.Lang.T(row.Label), FontWeight = FontWeight.SemiBold });
                if (row.Note.Length > 0) ToolTip.SetTip(name, Core.Lang.T(row.Note));
                line.Children.Add(name);
                var boxes = new StackPanel { Orientation = Orientation.Horizontal };
                foreach (var cell in row.Cells)
                {
                    var box = new TextBox { Text = cell.Value, Width = cell.Width, PlaceholderText = Core.Lang.T(cell.Hint), Margin = new Thickness(0, 0, 6, 0) };
                    cells.Add((row.Key, cell.Key, box));
                    boxes.Children.Add(box);
                }
                Grid.SetColumn(boxes, 1);
                line.Children.Add(boxes);
                grid.Children.Add(line);
            }
            body.Children.Add(grid);
        }

        var inputs = new List<(string Key, TextBox Box)>();
        foreach (var field in fields ?? System.Array.Empty<FormField>())
        {
            body.Children.Add(new TextBlock { Text = Core.Lang.T(field.Label), Classes = { "caption" }, Margin = new Thickness(0, 10, 0, 3) });
            var box = new TextBox { Text = field.Value };
            if (field.Secret) box.PasswordChar = '•';
            inputs.Add((field.Key, box));
            body.Children.Add(box);
        }

        // ---- the networks of a tunnel (WG BASE-ROUTER): an address a line - four numbers, then how
        // many addresses it stands for. Buttons instead of a typed mask: "/24" says nothing to the
        // one who sets a tunnel up once a year, "254 addresses" does.
        var routeLines = new List<(TextBox[] Octets, ToggleButton[] Masks)>();
        var routesSaid = new TextBlock { Classes = { "caption" }, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12, 0, 0, 0) };
        List<string> ReadRoutes()
        {
            var found = new List<string>();
            foreach (var (octets, masks) in routeLines)
            {
                var parts = octets.Select(box => (box.Text ?? "").Trim()).ToList();
                if (parts.Any(part => part.Length == 0 || !part.All(char.IsAsciiDigit) || int.Parse(part) > 255)) continue;
                int bits = masks.FirstOrDefault(mask => mask.IsChecked == true)?.Tag is int picked ? picked : 32;
                var one = $"{string.Join(".", parts.Select(int.Parse))}/{bits}";
                if (!found.Contains(one)) found.Add(one);
            }
            return found;
        }
        void SayRoutes()
        {
            var list = ReadRoutes();
            routesSaid.Text = list.Count > 0 ? Core.Lang.F("в туннель: {0}", string.Join(", ", list)) : Core.Lang.T("в туннель: пока ничего");
        }
        if (routes is not null)
        {
            var box = new StackPanel { Margin = new Thickness(0, 2, 0, 0) };
            Control Line(string value)
            {
                var line = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
                string address = "";
                int bits = 32;
                var cut = value.Trim().Split('/');
                if (cut.Length > 0) address = cut[0].Trim();
                if (cut.Length > 1 && int.TryParse(cut[1].Trim(), out var typed)) bits = typed;
                if (bits is not (32 or 24 or 16 or 8)) bits = 32;
                var parts = address.Split('.');
                var octets = new TextBox[4];
                for (int i = 0; i < 4; i++)
                {
                    if (i > 0) line.Children.Add(new TextBlock { Text = ".", Classes = { "caption" }, FontSize = 15, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(3, 0) });
                    var cell = new TextBox
                    {
                        // As tall as the switches of the mask beside it, not as a form field: the line reads as one row.
                        Width = 46, MinWidth = 46, Height = 24, MinHeight = 24, Padding = new Thickness(2, 0), MaxLength = 3,
                        TextAlignment = TextAlignment.Center, VerticalAlignment = VerticalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
                        Text = i < parts.Length && parts[i].Length > 0 && parts[i].All(char.IsAsciiDigit) ? parts[i] : "",
                    };
                    int at = i;
                    // Digits only; a dot goes on to the next number, as an address is typed.
                    cell.AddHandler(InputElement.TextInputEvent, (_, e) => { if (e.Text is { } text && !text.All(char.IsAsciiDigit)) e.Handled = true; }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
                    cell.AddHandler(InputElement.KeyDownEvent, (_, e) =>
                    {
                        if (e.Key is Avalonia.Input.Key.OemPeriod or Avalonia.Input.Key.Decimal)
                        {
                            e.Handled = true;
                            if (at < 3) { octets[at + 1].Focus(); octets[at + 1].SelectAll(); }
                        }
                    }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
                    cell.TextChanged += (_, _) =>
                    {
                        var text = cell.Text ?? "";
                        if (int.TryParse(text, out var number) && number > 255) { cell.Text = "255"; cell.CaretIndex = 3; return; }
                        // Three digits are a whole number: the next one takes the typing.
                        if (text.Length >= 3 && cell.CaretIndex >= 3 && cell.IsFocused && at < 3) { octets[at + 1].Focus(); octets[at + 1].SelectAll(); }
                        SayRoutes();
                    };
                    octets[i] = cell;
                    line.Children.Add(cell);
                }
                line.Children.Add(new TextBlock { Text = "/", Classes = { "caption" }, FontSize = 15, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 8, 0) });
                var masks = new List<ToggleButton>();
                foreach (var (size, label, tip) in new[]
                {
                    (32, "ОДИН АДРЕС", "Только эта машина. Так ведут отдельный компьютер, принтер или сам роутер."),
                    (24, "254 АДРЕСА", "Все, у кого совпадают первые три числа: от .1 до .254. Обычная домашняя сеть."),
                    (16, "65 ТЫСЯЧ", "Все, у кого совпадают первые два числа. Так устроены большие сети на работе."),
                    (8, "16 МЛН", "Все, у кого совпадает первое число. Нужно очень редко."),
                })
                {
                    var mask = new ToggleButton { Content = Core.Lang.T(label), Classes = { "switch" }, Tag = size, IsChecked = size == bits, VerticalAlignment = VerticalAlignment.Center };
                    ToolTip.SetTip(mask, Core.Lang.T(tip));
                    masks.Add(mask);
                    line.Children.Add(mask);
                }
                foreach (var mask in masks)
                    mask.Click += (_, _) => { foreach (var other in masks) other.IsChecked = ReferenceEquals(other, mask); SayRoutes(); };
                var entry = (octets, masks.ToArray());
                var drop = new Button { Classes = { "tool" }, Content = Icons.Sign("x"), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
                ToolTip.SetTip(drop, Core.Lang.T("Убрать этот адрес из списка"));
                drop.Click += (_, _) => { routeLines.Remove(entry); box.Children.Remove(line); SayRoutes(); };
                line.Children.Add(drop);
                routeLines.Add(entry);
                return line;
            }
            body.Children.Add(new TextBlock { Text = Core.Lang.T("ЧТО ВЕСТИ В ТУННЕЛЬ"), Classes = { "caption" }, Margin = new Thickness(0, 10, 0, 6) });
            foreach (var route in routes) box.Children.Add(Line(route));
            body.Children.Add(box);
            var more = new Button { Content = Core.Lang.T("ЕЩЁ АДРЕС"), Classes = { "small" }, MinWidth = 110 };
            ToolTip.SetTip(more, Core.Lang.T("Добавить в список ещё одну строку"));
            more.Click += (_, _) =>
            {
                box.Children.Add(Line(""));
                routeLines[^1].Octets[0].Focus();
                SayRoutes();
            };
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { more, routesSaid } });
            SayRoutes();
        }

        var radios = new List<RadioButton>();
        if (choices is { Count: > 0 })
        {
            var rows = new StackPanel { Spacing = 8, Margin = new Thickness(0, 12, 0, 0) };
            foreach (var choice in choices)
            {
                var text = new StackPanel { Children = { new TextBlock { Text = Core.Lang.T(choice.Label), FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap } } };
                if (choice.Note.Length > 0) text.Children.Add(new TextBlock { Text = Core.Lang.T(choice.Note), Classes = { "caption" }, TextWrapping = TextWrapping.Wrap });
                var radio = new RadioButton { GroupName = "choice", Content = text, Tag = choice.Key, IsChecked = picked is null ? radios.Count == 0 : choice.Key == picked };
                radios.Add(radio);
                rows.Children.Add(radio);
            }
            body.Children.Add(rows);
        }

        FormAnswer Collect()
        {
            var answer = new FormAnswer();
            foreach (var (key, box) in inputs) answer.Fields[key] = box.Text ?? "";
            foreach (var (row, key, box) in cells)
            {
                if (!answer.Table.TryGetValue(row, out var held)) answer.Table[row] = held = new Dictionary<string, string>();
                held[key] = box.Text ?? "";
            }
            answer.Choice = radios.FirstOrDefault(radio => radio.IsChecked == true)?.Tag as string ?? "";
            answer.Routes.AddRange(ReadRoutes());
            return answer;
        }

#if DEBUG
        if (DevAnswer is { } dev)
        {
            DevAnswer = null;
            Core.Journal.Add($"[dev] {Core.Lang.T(head)} -> {(dev == "cancel" ? "cancel" : "answered")}");
            if (dev == "cancel") return null;
            var answer = Collect();
            using var doc = JsonDocument.Parse(dev);
            if (doc.RootElement.TryGetProperty("fields", out var f))
                foreach (var item in f.EnumerateObject()) answer.Fields[item.Name] = item.Value.GetString() ?? "";
            if (doc.RootElement.TryGetProperty("table", out var t))
                foreach (var row in t.EnumerateObject())
                {
                    if (!answer.Table.TryGetValue(row.Name, out var held)) answer.Table[row.Name] = held = new Dictionary<string, string>();
                    foreach (var cell in row.Value.EnumerateObject()) held[cell.Name] = cell.Value.GetString() ?? "";
                }
            if (doc.RootElement.TryGetProperty("choice", out var c)) answer.Choice = c.GetString() ?? "";
            if (doc.RootElement.TryGetProperty("routes", out var r))
            {
                answer.Routes.Clear();
                answer.Routes.AddRange(r.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0));
            }
            return answer;
        }
#endif

        var cancel = new Button { Content = Core.Lang.T("ОТМЕНА"), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0, 0, 9, 0), IsCancel = true };
        var ok = new Button { Content = Core.Lang.T(okText), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0), IsDefault = true, Classes = { "run" } };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0),
            Children = { cancel, ok },
        });

        var dialog = new Window
        {
            Title = "Audion Sync Tools",
            Width = table is { Count: > 0 } || routes is not null ? 760 : 620,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            ShowInTaskbar = false,
            Content = new Border
            {
                Margin = new Thickness(10), Padding = new Thickness(18, 15), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
                Child = body,
            },
        };
        dialog[!TemplatedControl.BackgroundProperty] = new DynamicResourceExtension("AppBg");
        dialog[!TemplatedControl.ForegroundProperty] = new DynamicResourceExtension("TextMain");
        dialog[!TemplatedControl.FontFamilyProperty] = new DynamicResourceExtension("FontUi");
        var frame = (Border)dialog.Content;
        frame[!Border.BackgroundProperty] = new DynamicResourceExtension("PanelBg");
        frame[!Border.BorderBrushProperty] = new DynamicResourceExtension("BorderSoft");

        cancel.Click += (_, _) => dialog.Close();
        ok.Click += (_, _) => { result = Collect(); dialog.Close(); };
        // The first box the eye meets: a cell of the table stands above the fields.
        dialog.Opened += (_, _) => (cells.Count > 0 ? cells[0].Box : inputs.Count > 0 ? inputs[0].Box : null)?.Focus();
        await dialog.ShowDialog(owner);
        return result;
    }
}
