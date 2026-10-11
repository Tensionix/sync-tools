using System;
using System.IO;

namespace AudionSyncTools.Core;

/// <summary>
/// Where things live in the project:
///   Start.exe           the launcher at the root
///   App\                the window, the PowerShell 7 of the program (AudionPs.exe) and their read-only data
///   Engine\, Tunnel\    the scripts: keys, routes, routers, clouds, the mirror
///   Runs\               the wrappers - every button of the window is one of them
///   Tools\              rclone, the terminal
///   config\             gui-settings.json (the look and the choices), profile.json (where the data folder is)
///   logs\               the journal of the window, a file per day
///   ._runtime\          throwaway: the cache of rclone, build stages
/// The working files of the connections and every secret live in the data folder of the machine
/// ("Audion Backup Laptop"), never here - see DataRoot.
/// </summary>
public static class Paths
{
    /// <summary>The program folder: binaries and the data that ships with them.</summary>
    public static string App { get; } = AppContext.BaseDirectory.TrimEnd('\\', '/');

    /// <summary>
    /// The project root: the folder that holds Engine\DataRoot.ps1, found by walking up from the
    /// program - one level from App\, several from Source\bin\Debug\net10.0.
    /// </summary>
    public static string Root { get; } = FindRoot();

    /// <summary>Started from App\ under the root: the released layout, not a build run from bin\.</summary>
    public static bool Released { get; } =
        string.Equals(Path.GetDirectoryName(App), Root, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(Path.GetFileName(App), "App", StringComparison.OrdinalIgnoreCase);

    static string FindRoot()
    {
        for (var dir = new DirectoryInfo(App); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "Engine", "DataRoot.ps1"))) return dir.FullName;
        return App;
    }

    /// <summary>
    /// config\ of the window. A build run from bin\ keeps its own beside itself: a check must not
    /// rewrite the settings of the copy the owner works in (Disk Tools, 24.09.2026).
    /// </summary>
    public static string Config
    {
        get
        {
            var dir = Path.Combine(Released ? Root : App, "config");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>The pointer to the data folder: one owner for every copy of the window - the project's config\profile.json.</summary>
    public static string ProfileFile => Path.Combine(Root, "config", "profile.json");

    public static string Logs
    {
        get
        {
            var dir = Path.Combine(Released ? Root : App, "logs");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>Throwaway state; created again whenever it is gone.</summary>
    public static string State
    {
        get
        {
            var dir = Path.Combine(Root, "._runtime");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    /// <summary>Read-only data that ships with the program: App\config\...</summary>
    public static string Data(string name) => Path.Combine(App, "config", name);

    /// <summary>A script or a wrapper of the project by its path from the root.</summary>
    public static string Script(string relative) => Path.Combine(Root, relative);

    /// <summary>
    /// The PowerShell 7 of the program: beside the window in a release, the build of Source\Ps
    /// when the window itself runs from bin\. Null - not built yet.
    /// </summary>
    public static string? Ps
    {
        get
        {
            foreach (var candidate in new[]
            {
                Path.Combine(App, "AudionPs.exe"),
                Path.Combine(Root, "App", "AudionPs.exe"),
                Path.Combine(Root, "Source", "Ps", "bin", "Debug", "net10.0", "AudionPs.exe"),
                Path.Combine(Root, "Source", "Ps", "bin", "Release", "net10.0", "AudionPs.exe"),
            })
                if (File.Exists(candidate)) return candidate;
            return null;
        }
    }

    /// <summary>The program's own rclone; no other copy is ever used.</summary>
    public static string? Rclone
    {
        get
        {
            var own = Path.Combine(Root, "Tools", "rclone", "rclone.exe");
            return File.Exists(own) ? own : null;
        }
    }

    public static string Version
    {
        get
        {
            try
            {
                using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(Root, "config", "version.json")));
                return doc.RootElement.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
            }
            catch { return ""; }
        }
    }
}
