using Avalonia.Controls.Shapes;
using Avalonia.Media;

namespace AudionSyncTools;

/// <summary>
/// How the signs of Icons.cs get onto the screen. A Lucide sign is strokes on a 24 grid, shown on
/// the 10 grid of the style "Path.icon" (the shell of Audion Disk Tools: centred by App.CenterIcon,
/// the line as thick as there); a brand mark is one filled path in the same box.
/// </summary>
public static partial class Icons
{
    /// <summary>The geometry of a Lucide sign on the 10 grid; null when the set has no such name.</summary>
    public static Geometry? Glyph(string name)
    {
        if (!Lucide.TryGetValue(name, out var data)) return null;
        var geometry = Geometry.Parse(data);
        // Scaled in the geometry, not by a Viewbox: the pen keeps the thickness of the style.
        geometry.Transform = new ScaleTransform(10 / 24.0, 10 / 24.0);
        return geometry;
    }

    /// <summary>A Lucide sign ready for a button.</summary>
    public static Path Sign(string name) => new() { Classes = { "icon" }, Data = Glyph(name) };

    /// <summary>A brand mark in the 10 box: in its own colour, or in the ink of the text around it.</summary>
    public static Path? Mark(string name, bool colour = false)
    {
        if (!Brand.TryGetValue(name, out var brand)) return null;
        var geometry = Geometry.Parse(brand.Path);
        geometry.Transform = new ScaleTransform(10 / brand.Box, 10 / brand.Box);
        var path = new Path { Classes = { "iconfill" }, Data = geometry };
        if (colour && brand.Hex.Length > 0 && Color.TryParse(brand.Hex, out var ink)) path.Fill = new SolidColorBrush(ink);
        return path;
    }
}
