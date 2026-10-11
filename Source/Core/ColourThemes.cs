using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace AudionSyncTools.Core;

/// <summary>One colour rule of a theme: the first rule that fits a row paints it.</summary>
public sealed class ThemeRule
{
    public string Title { get; set; } = "";

    /// <summary>hour | day | week | month | folders | system | family.</summary>
    public string Kind { get; set; } = "family";

    /// <summary>For kind "family": the id of the MASKS family whose masks this rule paints.</summary>
    public string Family { get; set; } = "";

    public string Colour { get; set; } = "";
}

public sealed class ThemeSide
{
    public string Plain { get; set; } = "#c9d6de";
    public List<ThemeRule> Rules { get; set; } = new();
}

/// <summary>
/// config\colors\themes.json: the row colours of the dark and the light theme. What a rule paints
/// is a family of MASKS - the one source of what is video, documents, archives; the theme holds
/// only colours and the order of the rules. Converted once from the owner's TC themes (28.09.2026);
/// no INI, no code page of the nineties.
/// </summary>
public sealed class ColourThemes
{
    public string Program { get; set; } = "";
    public string About { get; set; } = "";
    public ThemeSide Dark { get; set; } = new();
    public ThemeSide Light { get; set; } = new();

    /// <summary>The rows of a theme of the settings: the light side for Audion Light, the dark one for every dark theme.</summary>
    public ThemeSide Side(string theme) => theme == "light" ? Light : Dark;

    static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

    /// <summary>A missing or broken file leaves plain rows, never a broken window.</summary>
    public static ColourThemes Load(string file)
    {
        try
        {
            if (File.Exists(file)) return JsonSerializer.Deserialize<ColourThemes>(File.ReadAllText(file), Json) ?? new();
        }
        catch { }
        return new();
    }
}
