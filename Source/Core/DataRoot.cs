using System;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace AudionSyncTools.Core;

/// <summary>
/// The data folder of this machine ("Audion Backup Laptop"): every working file of the
/// connections and every secret lives there, the program keeps only a pointer to it. The search
/// is the one of Engine\DataRoot.ps1, so the window and the scripts always name the same folder:
///   1. config\profile.json - written when the folder is chosen;
///   2. the only "Audion Backup*" beside the program;
///   3. nothing chosen: several folders lie side by side (at home, while the kits of the other
///      machines are put together) and picking one for the owner is not allowed.
/// </summary>
public static class DataRoot
{
    public const string NotSelected = "__AUDION_DATA_FOLDER_NOT_SELECTED__";

    /// <summary>
    /// The data folder named on the command line of the window: Start.exe -Root "...\Audion Backup B".
    /// It is the folder of this run, as with the -Root of every wrapper: the pointer of the
    /// program stays as it was. A folder that is not there is not replaced by a guess - the
    /// window opens with no data folder and says which one it was told and did not find.
    /// Declared above Path_ on purpose: the fields of a static class are filled in the order
    /// they are written, and Path_ asks for this one while it is being filled.
    /// </summary>
    public static string Named { get; private set; } = "";

    /// <summary>The folder, or a path that does not exist when it is not chosen yet.</summary>
    public static string Path_ { get; private set; } = Find();

    /// <summary>The profile name of the pointer: the folder's own name.</summary>
    public static string Profile => Chosen ? Path.GetFileName(Path_) : "";

    public static bool Chosen => Directory.Exists(Path_);

    /// <summary>
    /// The pointer names a folder that exists: a person chose it before. Without it the folder is
    /// only a guess - the one neighbour whose name fits - and the first start asks.
    /// </summary>
    public static bool Pointed { get; private set; }

    /// <summary>The data folders beside the program, by name.</summary>
    public static string[] Near()
    {
        var near = Path.GetDirectoryName(Paths.Root);
        if (near is null || !Directory.Exists(near)) return Array.Empty<string>();
        var own = Path.GetFileName(Paths.Root);
        try
        {
            return Directory.GetDirectories(near, "Audion Backup*")
                .Where(d => !string.Equals(Path.GetFileName(d), own, StringComparison.OrdinalIgnoreCase))
                .OrderBy(d => d, StringComparer.OrdinalIgnoreCase).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }

    public static void Refresh() => Path_ = Find();

    public static void Name(string folder)
    {
        try { Named = Path.GetFullPath(folder.Trim().Trim('"')).TrimEnd('\\', '/'); }
        catch { Named = folder.Trim(); }
        Refresh();
    }

#if DEBUG
    /// <summary>A Debug copy on a stand (Tools\dev-run.ps1 -Data): it works with a throwaway folder and never writes the pointer of the project.</summary>
    public static bool OnStand => Environment.GetEnvironmentVariable("AUDION_DEV_DATA") is { Length: > 0 };

    public static bool ChooseOnStand(string folder)
    {
        Environment.SetEnvironmentVariable("AUDION_DEV_DATA", Resolve(folder));
        Refresh();
        return Chosen;
    }
#endif

    static string Find()
    {
        Pointed = false;
#if DEBUG
        // A check of the wizards writes addresses, keys and configs: a Debug copy may be pointed at
        // a throwaway data folder (Tools\dev-run.ps1 -Data), and then the owner's one is not read at all.
        if (Environment.GetEnvironmentVariable("AUDION_DEV_DATA") is { Length: > 0 } stand && Directory.Exists(stand))
        {
            Pointed = true;
            return stand;
        }
#endif
        if (Named is { Length: > 0 })
        {
            Pointed = Directory.Exists(Named);
            return Pointed ? Named : Path.Combine(Paths.Root, NotSelected);
        }
        try
        {
            if (File.Exists(Paths.ProfileFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(Paths.ProfileFile));
                if (doc.RootElement.TryGetProperty("dataRoot", out var said) && said.GetString() is { Length: > 0 } path && Directory.Exists(path))
                {
                    Pointed = true;
                    return path;
                }
            }
        }
        catch { }

        var near = Path.GetDirectoryName(Paths.Root);
        if (near is null || !Directory.Exists(near)) return Path.Combine(Paths.Root, NotSelected);
        var found = Near();
        if (found.Length == 1) return found[0];
        if (found.Length > 1) return Path.Combine(near, NotSelected);
        return Path.Combine(near, "Audion Backup");
    }

    /// <summary>A working file of the data folder by its path from it: config\rclone\rclone.conf.</summary>
    public static string File_(string relative) => Path.Combine(Path_, relative);

    /// <summary>
    /// A folder picked a step too deep (Tunnel inside the data folder looks no worse than its
    /// parent in a folder dialog) is brought back to the folder whose name starts with
    /// "Audion Backup" - the one sign a data folder is known by.
    /// </summary>
    public static string Resolve(string picked)
    {
        var here = picked.TrimEnd('\\', '/');
        for (int step = 0; step < 4; step++)
        {
            if (Path.GetFileName(here).StartsWith("Audion Backup", StringComparison.OrdinalIgnoreCase)) break;
            var up = Path.GetDirectoryName(here);
            if (string.IsNullOrEmpty(up)) break;
            here = up;
        }
        return here;
    }

    /// <summary>Writes the pointer: the folder and its name, no secret in either.</summary>
    public static bool Choose(string folder)
    {
        var root = Resolve(folder);
        var text = JsonSerializer.Serialize(new { dataRoot = root, profile = Path.GetFileName(root) },
            new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        if (!SafeFile.Write(Paths.ProfileFile, text)) return false;
        // A folder chosen in the window is the folder from now on, whatever the command line named.
        Named = "";
        Refresh();
        return true;
    }
}
