using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AudionSyncTools.Core;

/// <summary>
/// config\gui-settings.json: the look and the choices of the window. It lives in the program
/// folder and goes with a cleanup, so nothing a fresh copy cannot do without is kept here. The
/// path of the data folder has one owner, config\profile.json (DataRoot); what a person made
/// in the window - the sets of masks, the pairs of BISYNC - lies in the data folder (DataStore).
/// </summary>
public sealed class Settings
{
    public string ArchiveRoot { get; set; } = "";
    public string TerminalApp { get; set; } = "";
    /// <summary>Kept here until 06.10.2026; read from an older file once more and never written again (DataStore.Adopt).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? BisyncPairs { get; set; }
    /// <summary>The theme of this window, one of Audion Disk Tools': "vault" (the default there too), "dark", "codedark", "light".</summary>
    public string Look { get; set; } = "vault";
    public string Lang { get; set; } = "en";
    public string ClientName { get; set; } = "";
    public int Streams { get; set; } = 8;
    public string PinnedMode { get; set; } = "";
    /// <summary>The route chosen by hand per machine; empty - the probe decides.</summary>
    public Dictionary<string, string> Routes { get; set; } = new();

    // The window on the screen.
    public int FontStep { get; set; }
    /// <summary>Sizes in exact bytes instead of KB, MB, GB.</summary>
    public bool ExactBytes { get; set; }
    /// <summary>The search window as it was left: x, y, width, height.</summary>
    public double[]? SearchBounds { get; set; }
    /// <summary>The sets of masks as an older file holds them: carried into the data folder once and never written again (DataStore.Adopt).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<MaskSet>? MaskSets { get; set; }
    /// <summary>The bottom row of buttons without the small second line.</summary>
    public bool HideHints { get; set; }
    /// <summary>The editor of F4: "" - Microsoft Edit, "micro", "notepad", or the path of one's own.</summary>
    public string Editor { get; set; } = "";
    /// <summary>What the dialogs of the archiver were left at: ALT+F5 and ALT+F9.</summary>
    public PackOptions Pack { get; set; } = new();
    public UnpackOptions Unpack { get; set; } = new();
    /// <summary>The font of the program and the font of the panels and the journal; both ship inside by default.</summary>
    public string UiFont { get; set; } = "JetBrains Mono";
    public string PanelFont { get; set; } = "JetBrains Mono";
    /// <summary>The backdrop of Windows 11: "" - a solid window, "acrylic", "mica".</summary>
    public string Backdrop { get; set; } = "";
    /// <summary>How much of the backdrop shows through: "light", "mid", "dense".</summary>
    public string BackdropDensity { get; set; } = "mid";
    /// <summary>With a backdrop on: only the file lists show it, the rest of the window stays solid.</summary>
    public bool BackdropPanelsOnly { get; set; }
    public double Width { get; set; }
    public double Height { get; set; }
    public double LogWidth { get; set; } = 0.28;

    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    static string File_ => Path.Combine(Paths.Config, "gui-settings.json");

    public static Settings Load()
    {
        var own = SafeFile.Read<Settings>(File_, Json);
        if (own is not null) return own.Clean();
        // A build run from bin\ starts from the choices of the project, read only: its own file
        // is written beside itself.
        if (!Paths.Released)
        {
            try
            {
                var shared = Path.Combine(Paths.Root, "config", "gui-settings.json");
                if (File.Exists(shared) && JsonSerializer.Deserialize<Settings>(File.ReadAllText(shared), Json) is { } kept) return kept.Clean();
            }
            catch { }
        }
        return new Settings();
    }

    Settings Clean()
    {
        Routes ??= new();
        if (Streams is < 1 or > 64) Streams = 8;
        if (LogWidth is < 0.1 or > 0.7) LogWidth = 0.28;
        return this;
    }

    public void Save() => SafeFile.Write(File_, JsonSerializer.Serialize(this, Json));
}
