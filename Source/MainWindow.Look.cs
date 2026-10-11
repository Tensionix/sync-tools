using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// The look of the window, as Audion Disk Tools has it: the font of the program and the font of
/// the panels apart, and the translucency of Windows 11. Mica shows the wallpaper, blurred and
/// tinted; Acrylic whatever lies under the window. Both are drawn by Windows itself - the program
/// only makes its own backgrounds see-through, and only while Windows really gives the backdrop.
/// </summary>
public partial class MainWindow
{
    static readonly string[] UiFonts = { "JetBrains Mono", "Inter", "Segoe UI", "Segoe UI Variable Text", "Arial", "Tahoma", "Verdana", "Calibri", "Noto Sans", "Roboto", "Open Sans" };
    static readonly string[] PanelFonts = { "JetBrains Mono", "Inter", "Segoe UI", "Segoe UI Variable Text", "Arial", "Tahoma", "Verdana", "Calibri", "Consolas", "Cascadia Mono" };

    /// <summary>At start: the fonts and the backdrop of the settings.</summary>
    void ApplyLook()
    {
        App.SetFonts(_settings.UiFont, _settings.PanelFont);
        ApplyBackdrop();
        // Windows may give the backdrop later, or take it away (transparency effects switched
        // off): the backgrounds follow what is really there.
        PropertyChanged += (_, e) =>
        {
            if (e.Property == TopLevel.ActualTransparencyLevelProperty) UpdateGlass();
        };
        // The holes follow the lists: resizing, the splitter, SETTINGS opening in place of the panels.
        LayoutUpdated += (_, _) => { if (_holes) CutHoles(); };
    }

    void ApplyBackdrop()
    {
        TransparencyLevelHint = _settings.Backdrop switch
        {
            "mica" => new[] { WindowTransparencyLevel.Mica, WindowTransparencyLevel.AcrylicBlur, WindowTransparencyLevel.None },
            "acrylic" => new[] { WindowTransparencyLevel.AcrylicBlur, WindowTransparencyLevel.None },
            _ => new[] { WindowTransparencyLevel.None },
        };
        UpdateGlass();
    }

    bool _holes;
    string _holesAt = "";

    void UpdateGlass()
    {
        bool on = _settings.Backdrop.Length > 0 && ActualTransparencyLevel != WindowTransparencyLevel.None;
        _holes = on && _settings.BackdropPanelsOnly;
        App.Glass(list: on, frame: on && !_holes, window: on && !_holes, _settings.BackdropDensity);
        LeftPanel.SetGlassHole(_holes);
        RightPanel.SetGlassHole(_holes);
        if (_holes) CutHoles();
        else { ChromeBg.Clip = null; _holesAt = ""; }
    }

    /// <summary>"Only the file panels": the solid window colour with holes where the file lists are; open SETTINGS stay solid.</summary>
    void CutHoles()
    {
        var whole = new Rect(ChromeBg.Bounds.Size);
        var shown = _settingsOpen ? Array.Empty<Control>() : new[] { LeftPanel.ListArea, RightPanel.ListArea };
        var rects = new List<Rect>();
        foreach (var list in shown)
            if (list.TranslatePoint(new Point(0, 0), ChromeBg) is { } at)
                rects.Add(new Rect(at, list.Bounds.Size));
        // Layout runs often; the clip is rebuilt only when a list really moved.
        var key = whole + "|" + string.Join("|", rects);
        if (key == _holesAt) return;
        _holesAt = key;
        var holes = new GeometryGroup();
        foreach (var rect in rects) holes.Children.Add(new RectangleGeometry(rect));
        ChromeBg.Clip = new CombinedGeometry(GeometryCombineMode.Exclude, new RectangleGeometry(whole), holes);
    }

    /// <summary>SETTINGS: with a backdrop on - only the file lists show it, the rest of the window stays solid.</summary>
    CheckBox BackdropPanelsBox()
    {
        // Fluent draws the square in the middle of a strip of 32, whatever the height of the control:
        // cut to the 24 of the switches beside it, the square sat four lower and lost its bottom edge.
        // So the box keeps its 32 and gives 4 back above and under: the row keeps its height and the
        // square stands in the line of the switches. The letters are of their size.
        var box = new CheckBox
        {
            Content = "Только файловые панели", IsChecked = _settings.BackdropPanelsOnly,
            Margin = new Thickness(10, -4, 0, -4), MinHeight = 32, Height = 32, Padding = new Thickness(6, 0, 0, 0),
            VerticalAlignment = Avalonia.Layout.VerticalAlignment.Top, VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center,
        };
        box[!TemplatedControl.FontSizeProperty] = new Avalonia.Markup.Xaml.MarkupExtensions.DynamicResourceExtension("FontSwitch");
        ToolTip.SetTip(box, "При MICA или ACRYLIC размываются только панели с файлами; верхняя строка, кнопки и промежутки остаются плотными.");
        box.IsCheckedChanged += (_, _) =>
        {
            _settings.BackdropPanelsOnly = box.IsChecked == true;
            UpdateGlass();
            _settings.Save();
        };
        return box;
    }

    /// <summary>SETTINGS: the family of the program and of the panels - the installed ones of a short list, and the two that ship inside.</summary>
    void FillFonts()
    {
        // Inter and JetBrains Mono ship inside the program: always there.
        var installed = new HashSet<string>(FontManager.Current.SystemFonts.Select(f => f.Name), StringComparer.OrdinalIgnoreCase) { "Inter", "JetBrains Mono" };
        FontRow("Программа", UiFonts.Where(installed.Contains), _settings.UiFont, family => _settings.UiFont = family);
        FontRow("Панели и журнал", PanelFonts.Where(installed.Contains), _settings.PanelFont, family => _settings.PanelFont = family);
    }

    void FontRow(string caption, IEnumerable<string> families, string chosen, Action<string> set)
    {
        Add(new TextBlock { Text = caption, Classes = { "caption" }, Margin = new Thickness(0, 8, 0, 2) });
        var row = new Views.FlowRow { LineSpacing = 4, Margin = new Thickness(0, 0, 0, 2) };
        var shown = families.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (chosen.Length > 0 && !shown.Contains(chosen, StringComparer.OrdinalIgnoreCase)) shown.Add(chosen);
        var buttons = new List<(ToggleButton Button, string Family)>();
        foreach (var family in shown)
        {
            // Each name is written in its own face: the choice is seen before it is made.
            var button = new ToggleButton
            {
                Content = family, Classes = { "switch" }, FontFamily = App.Family(family),
                IsChecked = string.Equals(family, chosen, StringComparison.OrdinalIgnoreCase),
            };
            buttons.Add((button, family));
            row.Children.Add(button);
        }
        foreach (var (button, family) in buttons)
        {
            button.Click += (_, _) =>
            {
                foreach (var (other, name) in buttons) other.IsChecked = name == family;
                set(family);
                App.SetFonts(_settings.UiFont, _settings.PanelFont);
                _settings.Save();
            };
        }
        Add(row);
    }
}
