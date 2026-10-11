using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AudionSyncTools.Core;

/// <summary>
/// The text of masks, by the rules of Audion Disk Tools (Core\MaskText.cs there). One rule
/// everywhere: a word is a part of the name ("example" - "*example*"), a leading dot is an
/// extension (".PNG" - "*.png"), a dot inside is the whole name ("readme.md"); anything with
/// wildcards or a slash is kept as written. Masks are separated by a comma, a semicolon or a
/// line break - a space is part of a name ("my *.txt").
/// </summary>
public static class MaskText
{
    public static List<string> Split(string? value)
    {
        var raw = value ?? "";
        foreach (var separator in new[] { "\r\n", "\n", "\r", ";" }) raw = raw.Replace(separator, ",");
        return raw.Split(',').Select(s => s.Trim()).Where(s => s.Length > 0).ToList();
    }

    public static string NormalizeToken(string? token)
    {
        var text = (token ?? "").Trim().Trim('"', '\'').Replace('\\', '/').ToLowerInvariant();
        if (text.Length == 0) return "";
        if (text.IndexOfAny(new[] { '*', '?', '[', ']' }) >= 0 || text.Contains('/')) return text;
        if (text.StartsWith('.')) return "*" + text;
        if (text.Contains('.')) return text;
        return "*" + text + "*";
    }

    public static List<string> NormalizeTokens(IEnumerable<string> items)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in items)
        {
            var pattern = NormalizeToken(item);
            if (pattern.Length > 0 && seen.Add(pattern)) result.Add(pattern);
        }
        return result;
    }

    public static List<string> NormalizeTokens(string? text) => NormalizeTokens(Split(text));

    public static string ToText(IEnumerable<string> masks) => string.Join(", ", masks);

    /// <summary>Groups ("@group:id") open into their masks; order kept, repeats dropped.</summary>
    public static List<string> Expand(IEnumerable<string> items, IReadOnlyDictionary<string, List<string>> groups)
    {
        var result = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(string pattern)
        {
            var normalized = NormalizeToken(pattern);
            if (normalized.Length > 0 && seen.Add(normalized)) result.Add(normalized);
        }
        foreach (var raw in items)
        {
            var text = (raw ?? "").Trim();
            if (text.Length == 0) continue;
            if (text.StartsWith("@group:"))
            {
                if (groups.TryGetValue(text[7..], out var masks)) foreach (var m in masks) Add(m);
                continue;
            }
            Add(text);
        }
        return result;
    }
}

/// <summary>The age of a file as the colours of the rows mean it: an hour is sixty minutes back, a day and a week are calendar days.</summary>
public enum AgeLimit { None, Hour, Day, Week }

public static class AgeFilter
{
    /// <summary>The same test as the row colours; a file dated in the future or before 1990 is not "fresh".</summary>
    public static bool Fits(AgeLimit age, DateTime? modified, DateTime now)
    {
        if (age == AgeLimit.None) return true;
        if (modified is not { } when || when.Year <= 1990) return false;
        double hours = (now - when).TotalHours;
        int days = (now.Date - when.Date).Days;
        return age switch
        {
            AgeLimit.Hour => hours >= 0 && hours < 1,
            AgeLimit.Day => days >= 0 && days <= 1,
            AgeLimit.Week => days >= 0 && days <= 7,
            _ => true,
        };
    }
}

public sealed class MaskGroup
{
    public string Id { get; set; } = "";
    public string Ru { get; set; } = "";
    public string En { get; set; } = "";
    /// <summary>The name in the interface language (names are mostly formats).</summary>
    [JsonIgnore] public string Title => Lang.Code == "ru" || En.Length == 0 ? Ru : En;
    public List<string> Masks { get; set; } = new();
}

public sealed class MaskFamily
{
    public string Id { get; set; } = "";
    public string Ru { get; set; } = "";
    public string En { get; set; } = "";
    [JsonIgnore] public string Title => Lang.Code == "ru" || En.Length == 0 ? Ru : En;
    /// <summary>A word or two for the head of a line of chips; a family without one shows its title.</summary>
    public string ShortRu { get; set; } = "";
    public string ShortEn { get; set; } = "";
    [JsonIgnore] public string ShortTitle => ShortRu.Length == 0 ? Title : Lang.Code == "ru" || ShortEn.Length == 0 ? ShortRu : ShortEn;
    public List<MaskGroup> Groups { get; set; } = new();
}

/// <summary>A set of masks saved under a name: a button in the window of the mark.</summary>
public sealed class MaskSet
{
    public string Name { get; set; } = "";
    public string Text { get; set; } = "";
}

/// <summary>The groups of extensions the program carries (config\mask-groups.json, the file of Audion Disk Tools): the same list that colours the rows.</summary>
public static class MaskGroups
{
    sealed class GroupsFile { public List<MaskFamily> Families { get; set; } = new(); }

    static List<MaskFamily>? _families;

    public static List<MaskFamily> Families
    {
        get
        {
            if (_families is not null) return _families;
            try
            {
                var file = Paths.Data("mask-groups.json");
                _families = JsonSerializer.Deserialize<GroupsFile>(File.ReadAllText(file), new JsonSerializerOptions { PropertyNameCaseInsensitive = true })?.Families ?? new();
            }
            catch { _families = new(); }
            return _families;
        }
    }
}
