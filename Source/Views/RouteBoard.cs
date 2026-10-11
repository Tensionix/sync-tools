using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;

namespace AudionSyncTools.Views;

/// <summary>One road of a machine in the board: its key, a caption, the time to its nearest node, whether it answers now.</summary>
public sealed record RouteOption(string Key, string Label, string Tip, string Note = "", bool Live = true);

/// <summary>A machine of the board: where it goes, the road picked now, the roads it has.</summary>
public sealed record RouteRow(string Key, string Label, string Picked, string Note, IReadOnlyList<RouteOption> Options);

/// <summary>
/// Routes per machine: a line for a machine, in the line the roads it really has. The buttons of
/// the ROUTE row give one road to all at once, and that is right while the network is equally bad
/// for all. But the home network may reach BASE and not a machine elsewhere, and one choice then
/// breaks one of them: here each machine gets its own. Returns machine -> road, or null on cancel.
/// </summary>
public static class RouteBoard
{
    public static async Task<Dictionary<string, string>?> Ask(Window owner, IReadOnlyList<RouteRow> rows, IEnumerable<string> lines)
    {
        Dictionary<string, string>? result = null;
        var picked = new Dictionary<string, string>();
        var grid = new StackPanel { Spacing = 7 };
        foreach (var row in rows)
        {
            picked[row.Key] = row.Picked;
            var line = new StackPanel { Orientation = Orientation.Horizontal };
            var name = new TextBlock { Text = Core.Lang.T(row.Label), Width = 84, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center };
            ToolTip.SetTip(name, row.Note);
            line.Children.Add(name);
            var buttons = new List<(ToggleButton Button, string Key)>();
            foreach (var option in row.Options)
            {
                var text = Core.Lang.T(option.Label) + (option.Note.Length > 0 ? " · " + option.Note : "");
                var button = new ToggleButton { Classes = { "switch" }, Content = text, IsChecked = option.Key == row.Picked, Margin = new Thickness(0, 0, 4, 0) };
                // A road that is silent now is dimmed, not hidden: the owner may know more than the probe.
                if (!option.Live) button.Opacity = 0.5;
                ToolTip.SetTip(button, Core.Lang.T(option.Tip));
                buttons.Add((button, option.Key));
                line.Children.Add(button);
            }
            foreach (var (button, key) in buttons)
            {
                button.Click += (_, _) =>
                {
                    picked[row.Key] = key;
                    foreach (var (other, otherKey) in buttons) other.IsChecked = otherKey == key;
                };
            }
            grid.Children.Add(line);
        }

        var cancel = new Button { Content = Core.Lang.T("ОТМЕНА"), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0, 0, 9, 0), IsCancel = true };
        var ok = new Button { Content = Core.Lang.T("ПРИМЕНИТЬ"), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0), IsDefault = true, Classes = { "run" } };
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = Core.Lang.T("Маршруты по машинам"), FontSize = 15, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 0, 0, 12) });
        body.Children.Add(grid);
        var notes = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var text in lines) notes.Children.Add(new TextBlock { Text = Core.Lang.T(text), Classes = { "caption" }, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(notes);
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0),
            Children = { cancel, ok },
        });

        var frame = new Border { Margin = new Thickness(10), Padding = new Thickness(18, 15), CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Child = body };
        frame[!Border.BackgroundProperty] = new DynamicResourceExtension("PanelBg");
        frame[!Border.BorderBrushProperty] = new DynamicResourceExtension("BorderSoft");
        var dialog = new Window
        {
            Title = "Audion Sync Tools",
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            CanResize = false,
            ShowInTaskbar = false,
            Content = frame,
        };
        dialog[!TemplatedControl.BackgroundProperty] = new DynamicResourceExtension("AppBg");
        dialog[!TemplatedControl.ForegroundProperty] = new DynamicResourceExtension("TextMain");
        dialog[!TemplatedControl.FontFamilyProperty] = new DynamicResourceExtension("FontUi");

        cancel.Click += (_, _) => dialog.Close();
        ok.Click += (_, _) => { result = picked; dialog.Close(); };
        dialog.Opened += (_, _) => ok.Focus();
        await dialog.ShowDialog(owner);
        return result;
    }
}
