using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;

namespace AudionSyncTools.Views;

/// <summary>One way to go of a choice: its key, a short caption and a line of what it means.</summary>
public sealed record Choice(string Key, string Label, string Note = "");

/// <summary>
/// A question with several answers (RESTORE, OPENVPN): each a row with a caption and a note, one
/// of them picked, then one button. The key of the picked row, or null on cancel.
/// </summary>
public static class ChoiceDialog
{
#if DEBUG
    /// <summary>A check without a mouse (MainWindow.Dev): the next choice is answered by this key, or "cancel".</summary>
    public static string? DevAnswer { get; set; }
#endif

    public static async Task<string?> Ask(Window owner, string head, IReadOnlyList<Choice> choices, string okText = "ВЫПОЛНИТЬ", IEnumerable<string>? lines = null)
    {
#if DEBUG
        if (DevAnswer is { } dev)
        {
            DevAnswer = null;
            Core.Journal.Add($"[dev] {Core.Lang.T(head)} -> {dev}");
            return dev == "cancel" ? null : dev;
        }
#endif
        string? result = null;
        var rows = new StackPanel { Spacing = 8 };
        var buttons = new List<RadioButton>();
        foreach (var choice in choices)
        {
            var text = new StackPanel
            {
                Children = { new TextBlock { Text = Core.Lang.T(choice.Label), FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap } },
            };
            if (choice.Note.Length > 0)
                text.Children.Add(new TextBlock { Text = Core.Lang.T(choice.Note), Classes = { "caption" }, TextWrapping = TextWrapping.Wrap });
            var radio = new RadioButton { GroupName = "choice", Content = text, Tag = choice.Key, IsChecked = buttons.Count == 0 };
            buttons.Add(radio);
            rows.Children.Add(radio);
        }

        var cancel = new Button { Content = Core.Lang.T("ОТМЕНА"), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0, 0, 9, 0), IsCancel = true };
        var ok = new Button { Content = Core.Lang.T(okText), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0), IsDefault = true, Classes = { "run" } };
        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = Core.Lang.T(head), FontSize = 15, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) });
        foreach (var line in lines ?? System.Array.Empty<string>())
            body.Children.Add(new TextBlock { Text = line.Length == 0 ? " " : Core.Lang.T(line), TextWrapping = TextWrapping.Wrap, Classes = { "plain" } });
        body.Children.Add(rows);
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0),
            Children = { cancel, ok },
        });

        var dialog = new Window
        {
            Title = "Audion Sync Tools",
            Width = 600,
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
        dialog[!TemplatedControl.BackgroundProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("AppBg");
        dialog[!TemplatedControl.ForegroundProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("TextMain");
        dialog[!TemplatedControl.FontFamilyProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("FontUi");
        var frame = (Border)dialog.Content;
        frame[!Border.BackgroundProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("PanelBg");
        frame[!Border.BorderBrushProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("BorderSoft");

        cancel.Click += (_, _) => dialog.Close();
        ok.Click += (_, _) =>
        {
            foreach (var radio in buttons)
                if (radio.IsChecked == true) result = radio.Tag as string;
            dialog.Close();
        };
        dialog.Opened += (_, _) => ok.Focus();
        await dialog.ShowDialog(owner);
        return result;
    }
}
