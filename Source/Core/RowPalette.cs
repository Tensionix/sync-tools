using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using Avalonia.Media;

namespace AudionSyncTools.Core;

/// <summary>
/// Row colours of the panels: config\colors\themes.json and config\mask-groups.json of Audion
/// Disk Tools, read the same way. The first matching rule wins, as in Total Commander, so the age
/// rules above the type rules colour a fresh file by its age - that is intended. A type rule
/// paints the masks of its family: one list of what is video, documents, archives.
/// </summary>
public sealed class RowPalette
{
    enum Kind { Hour, Day, Week, Month, Dir, Mask }

    sealed record Rule(Kind Kind, IBrush Colour, Regex[] Masks);

    readonly List<Rule> _rules = new();
    readonly Dictionary<string, IBrush> _families = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The colour the rows of a family are painted with: the chips of the mask window wear it too. Null - the theme gives the family none.</summary>
    public IBrush? FamilyColour(string id) => _families.GetValueOrDefault(id);

    public IBrush Plain { get; private set; } = new SolidColorBrush(Color.Parse("#c9d6de"));

    sealed class Group { public List<string> Masks { get; set; } = new(); }
    sealed class Family { public string Id { get; set; } = ""; public List<Group> Groups { get; set; } = new(); }
    sealed class Families_ { public List<Family> Families { get; set; } = new(); }

    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    /// <summary>The palette of a theme of the settings; a missing or broken file leaves plain rows, never a broken window.</summary>
    public static RowPalette Load(string theme)
    {
        var palette = new RowPalette();
        try
        {
            var side = ColourThemes.Load(Paths.Data(Path.Combine("colors", "themes.json"))).Side(theme);
            var families = new List<Family>();
            var file = Paths.Data("mask-groups.json");
            if (File.Exists(file)) families = JsonSerializer.Deserialize<Families_>(File.ReadAllText(file), Json)?.Families ?? families;

            if (Color.TryParse(side.Plain, out var plain)) palette.Plain = new SolidColorBrush(plain);
            foreach (var rule in side.Rules)
            {
                if (!Color.TryParse(rule.Colour, out var colour)) continue;
                var kind = rule.Kind.ToLowerInvariant() switch
                {
                    "hour" => Kind.Hour, "day" => Kind.Day, "week" => Kind.Week, "month" => Kind.Month,
                    "folders" => Kind.Dir, "system" => (Kind?)null, _ => Kind.Mask,
                };
                // "system" is an attribute of a local file; a remote has none, and the panels here are one kind.
                if (kind is not { } k) continue;
                var masks = Array.Empty<Regex>();
                if (k == Kind.Mask)
                {
                    var family = families.FirstOrDefault(f => string.Equals(f.Id, rule.Family, StringComparison.OrdinalIgnoreCase));
                    if (family is null) continue;
                    masks = Mask.Compile(family.Groups.SelectMany(g => g.Masks));
                    palette._families.TryAdd(family.Id, new SolidColorBrush(colour));
                }
                palette._rules.Add(new Rule(k, new SolidColorBrush(colour), masks));
            }
        }
        catch { }
        return palette;
    }

    public IBrush For(string name, bool isDir, DateTime? modified)
    {
        var now = DateTime.Now;
        foreach (var rule in _rules)
        {
            bool hit = rule.Kind switch
            {
                // An hour is sixty minutes back from now; a day, a week and a month are calendar
                // days, as in TC - yesterday's file is "not older than a day" at thirty hours too.
                Kind.Hour => modified is { } h && h.Year > 1990 && (now - h).TotalHours is >= 0 and < 1,
                Kind.Day => modified is { } d && d.Year > 1990 && (now.Date - d.Date).Days is >= 0 and <= 1,
                Kind.Week => modified is { } w && w.Year > 1990 && (now.Date - w.Date).Days is >= 0 and <= 7,
                Kind.Month => modified is { } m && m.Year > 1990 && (now.Date - m.Date).Days is >= 0 and <= 31,
                Kind.Dir => isDir,
                Kind.Mask => !isDir && Mask.Matches(name, rule.Masks),
                _ => false,
            };
            if (hit) return rule.Colour;
        }
        return Plain;
    }
}
