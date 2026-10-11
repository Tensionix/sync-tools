using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Controls;

namespace AudionSyncTools.Views;

/// <summary>
/// A row of buttons that goes on to the next line when it runs out of width - the sources of a
/// panel, the groups of a section. WrapPanel breaks the row twice, once while measuring and once
/// while arranging, and at 150 % the two widths differ by a fraction of a pixel: on the edge it
/// measured one line and arranged two, and the second line was cut off (or the other way round,
/// an empty line stayed under the buttons). Here the breaks are found once, while measuring, and
/// the arrangement follows them.
/// </summary>
public sealed class FlowRow : Panel
{
    public static readonly StyledProperty<double> LineSpacingProperty = AvaloniaProperty.Register<FlowRow, double>(nameof(LineSpacing));

    /// <summary>Space between the lines; the items bring their own margins.</summary>
    public double LineSpacing
    {
        get => GetValue(LineSpacingProperty);
        set => SetValue(LineSpacingProperty, value);
    }

    public static readonly StyledProperty<bool> CenterLinesProperty = AvaloniaProperty.Register<FlowRow, bool>(nameof(CenterLines));

    /// <summary>
    /// The lines stand in the middle of the width as one block: all of them start under one
    /// another, at the left edge of the widest. Each line centred on its own made a ragged
    /// stair of the group captions of SETUP.
    /// </summary>
    public bool CenterLines
    {
        get => GetValue(CenterLinesProperty);
        set => SetValue(CenterLinesProperty, value);
    }

    static FlowRow() => AffectsMeasure<FlowRow>(LineSpacingProperty, CenterLinesProperty);

    // The first item of every line and the height of the line, as the last measure found them.
    readonly List<(int First, double Width, double Height)> _lines = new();

    protected override Size MeasureOverride(Size availableSize)
    {
        _lines.Clear();
        double limit = double.IsInfinity(availableSize.Width) ? double.MaxValue : availableSize.Width;
        double lineWidth = 0, lineHeight = 0, widest = 0;
        int first = 0;
        for (int i = 0; i < Children.Count; i++)
        {
            var child = Children[i];
            child.Measure(new Size(double.PositiveInfinity, availableSize.Height));
            if (!child.IsVisible) continue;
            var size = child.DesiredSize;
            // Half a unit of grace: the same sum of widths must not fit in one pass and overflow in the next.
            if (lineWidth > 0 && lineWidth + size.Width > limit + 0.5)
            {
                _lines.Add((first, lineWidth, lineHeight));
                widest = Math.Max(widest, lineWidth);
                first = i;
                lineWidth = lineHeight = 0;
            }
            lineWidth += size.Width;
            lineHeight = Math.Max(lineHeight, size.Height);
        }
        if (Children.Count > 0)
        {
            _lines.Add((first, lineWidth, lineHeight));
            widest = Math.Max(widest, lineWidth);
        }
        double height = 0;
        foreach (var line in _lines) height += line.Height;
        height += Math.Max(0, _lines.Count - 1) * LineSpacing;
        return new Size(Math.Min(widest, limit), height);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double y = 0, widest = 0;
        foreach (var line in _lines) widest = Math.Max(widest, line.Width);
        double left = CenterLines ? Math.Max(0, Math.Round((finalSize.Width - widest) / 2)) : 0;
        for (int n = 0; n < _lines.Count; n++)
        {
            var (first, _, height) = _lines[n];
            int end = n + 1 < _lines.Count ? _lines[n + 1].First : Children.Count;
            double x = left;
            for (int i = first; i < end; i++)
            {
                var child = Children[i];
                if (!child.IsVisible) continue;
                var size = child.DesiredSize;
                child.Arrange(new Rect(x, y, size.Width, height));
                x += size.Width;
            }
            y += height + LineSpacing;
        }
        return finalSize;
    }
}
