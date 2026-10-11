using System.Collections.Generic;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.MarkupExtensions;
using Avalonia.Media;

namespace AudionSyncTools.Views;

/// <summary>What the first start was answered with: the data folder ("*" - another one, to be picked) and whether to download the tools.</summary>
public sealed record FirstStartAnswer(string? Folder, bool Download);

/// <summary>
/// The window of the first start: the two things the program cannot work without, asked at once.
/// The data folder - the one found beside the program is offered, the choice is the person's (it
/// holds the keys and the addresses of the machine; the program never sits down in it by a guess).
/// The tools - the program carries them outside itself, a release comes without them: what is
/// missing is named, what stops without it is said in so many words, and one button downloads it.
/// Either part is shown only when it is needed; with neither the window is not shown at all.
/// </summary>
public static class FirstStartDialog
{
    public static async Task<FirstStartAnswer?> Ask(Window owner, IReadOnlyList<string>? folders, IReadOnlyList<string> missing, string stops)
    {
        FirstStartAnswer? result = null;
        bool askFolder = folders is not null;
        bool askTools = missing.Count > 0;
        var body = new StackPanel();
        body.Children.Add(new TextBlock
        {
            Text = Core.Lang.T(askFolder ? "Первый запуск" : "Не хватает инструментов"), FontSize = 15, FontWeight = FontWeight.SemiBold,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12),
        });

        TextBlock Caption(string text) => new() { Text = Core.Lang.T(text), Classes = { "caption" }, Margin = new Thickness(0, 0, 0, 6) };
        TextBlock Line(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Classes = { "plain" }, Margin = new Thickness(0, 0, 0, 4) };

        var radios = new List<RadioButton>();
        if (askFolder)
        {
            body.Children.Add(Caption("ПАПКА ДАННЫХ"));
            body.Children.Add(Line(Core.Lang.T("В ней лежит всё, чем машина отличается от других: адреса, ключи, отпечатки хостов, пароль роутера. Настройки окна остаются в самой программе.")));
            body.Children.Add(Line(Core.Lang.T("Зовётся она по машине: Audion Backup Laptop, Audion Backup Work. Рядом их бывает несколько - дома, пока собираются папки для остальных машин.")));
            var rows = new StackPanel { Spacing = 8, Margin = new Thickness(0, 6, 0, 0) };
            void Row(string key, string label, string note)
            {
                var text = new StackPanel
                {
                    Children =
                    {
                        new TextBlock { Text = label, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap },
                        new TextBlock { Text = note, Classes = { "caption" }, TextWrapping = TextWrapping.Wrap },
                    },
                };
                // One folder beside the program is the found one: offered, the dot stands on it. Of several none is
                // picked for the person - a wrong one taken by Enter would make this machine another.
                var radio = new RadioButton { GroupName = "folder", Content = text, Tag = key, IsChecked = folders!.Count == 1 && radios.Count == 0 };
                radios.Add(radio);
                rows.Children.Add(radio);
            }
            foreach (var folder in folders!) Row(folder, System.IO.Path.GetFileName(folder), folder);
            Row("*", Core.Lang.T(folders!.Count > 0 ? "УКАЗАТЬ ДРУГУЮ" : "УКАЗАТЬ ПАПКУ"),
                Core.Lang.T("Выбрать папку в обзоре: она может лежать где угодно, не только рядом с программой."));
            body.Children.Add(rows);
        }

        if (askTools)
        {
            var caption = Caption("ИНСТРУМЕНТЫ");
            if (askFolder) caption.Margin = new Thickness(0, 18, 0, 6);
            body.Children.Add(caption);
            body.Children.Add(Line(Core.Lang.F("В папке программы нет: {0}.", string.Join(", ", missing))));
            if (stops.Length > 0)
            {
                // The one line that must not be read past: said in the accent of the program, not in red.
                var strong = Line(Core.Lang.F("Без них программа НЕ работает: {0}.", stops));
                strong.FontWeight = FontWeight.SemiBold;
                strong[!TextBlock.ForegroundProperty] = new DynamicResourceExtension("Tangerine");
                body.Children.Add(strong);
            }
            body.Children.Add(Line(Core.Lang.T("Кнопка ниже скачает их сейчас, около 100 МБ, в папку программы. Позже то же делает SETTINGS → ОБНОВИТЬ.")));
        }

        var cancel = new Button { Content = Core.Lang.T("ОТМЕНА"), MinWidth = 118, MinHeight = 30, Margin = new Thickness(0, 0, 9, 0), IsCancel = true };
        var ok = new Button
        {
            Content = Core.Lang.T(askFolder && askTools ? "ВЫБРАТЬ И СКАЧАТЬ" : askTools ? "СКАЧАТЬ" : "ВЫБРАТЬ"),
            MinWidth = 118, MinHeight = 30, Margin = new Thickness(0), IsDefault = true, Classes = { "run" },
        };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0),
            Children = { cancel, ok },
        });

        var dialog = new Window
        {
            Title = "Audion Sync Tools",
            Width = 640,
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

        // Nothing to confirm until a folder is picked.
        void Ready() => ok.IsEnabled = !askFolder || radios.Exists(radio => radio.IsChecked == true);
        foreach (var radio in radios) radio.IsCheckedChanged += (_, _) => Ready();
        Ready();
        cancel.Click += (_, _) => dialog.Close();
        ok.Click += (_, _) =>
        {
            string? folder = null;
            foreach (var radio in radios)
                if (radio.IsChecked == true) folder = radio.Tag as string;
            result = new FirstStartAnswer(folder, askTools);
            dialog.Close();
        };
        await dialog.ShowDialog(owner);
        return result;
    }
}
