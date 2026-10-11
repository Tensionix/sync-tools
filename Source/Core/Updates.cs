using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

/// <summary>One tool the program carries: the number that stands and the number its maker has out.</summary>
public sealed record UpdateItem(string Id, string Name, string? Installed, string? Latest)
{
    /// <summary>true - a newer one is out (or the tool is not there at all), false - the latest stands, null - not known.</summary>
    public bool? Newer => Latest is null ? null : Installed is null || Updates.IsNewer(Latest, Installed);
}

/// <summary>
/// The green and tangerine dots of SETTINGS: rclone, cloudflared and Windows Terminal against
/// what their makers have out. The numbers come from where Engine\Scripts\Update-Tools.ps1 takes
/// them - the dot and the UPDATE button must not disagree: rclone from its own version.txt, the
/// other two from the releases/latest redirect of GitHub, which does not spend the API's sixty
/// calls an hour. The answer is kept in ._runtime\updates.json for six hours; a check that got
/// no answer is not kept as if it were one and is asked again a quarter of an hour later.
/// The program itself, its PowerShell and .NET have no dot: they come with the program.
/// </summary>
public static class Updates
{
    public static readonly (string Id, string Name)[] Known =
    {
        ("rclone", "rclone"),
        ("cloudflared", "cloudflared"),
        ("terminal", "Windows Terminal"),
        ("peazip", "PeaZip"),
        ("edit", "Microsoft Edit"),
        ("micro", "micro"),
    };

    /// <summary>The archiver and the editors: the folder in Tools\ and the place of their releases. Engine\Scripts\Install-Tools.ps1 puts them in.</summary>
    static readonly Dictionary<string, (string Folder, string Repo)> Carried = new()
    {
        ["peazip"] = ("PeaZip", "peazip/PeaZip"),
        ["edit"] = ("edit", "microsoft/edit"),
        ["micro"] = ("micro", "micro-editor/micro"),
    };

    static readonly TimeSpan Fresh = TimeSpan.FromHours(6);
    static readonly TimeSpan Retry = TimeSpan.FromMinutes(15);
    static string CacheFile => Path.Combine(Paths.State, "updates.json");

    sealed class Cache
    {
        public DateTime Checked { get; set; }
        /// <summary>Every source answered at that check.</summary>
        public bool Answered { get; set; }
        public Dictionary<string, string> Latest { get; set; } = new();
    }

    static readonly Regex Digits = new(@"\d+(?:\.\d+)+", RegexOptions.Compiled);

    /// <summary>"rclone v1.75.1", "cloudflared version 2026.8.3 (built …)", "v1.24.11911.0" - the number alone.</summary>
    public static string? Number(string? said) => said is not null && Digits.Match(said) is { Success: true } found ? found.Value : null;

    /// <summary>What stands now, by tool; null where the tool is not there. Starts processes: call it off the window's thread.</summary>
    public static Dictionary<string, string?> Installed() => Known.ToDictionary(k => k.Id, k => Installed(k.Id));

    static string? Installed(string id)
    {
        try
        {
            // What Install-Tools.ps1 puts in carries a version.txt beside it.
            if (Carried.TryGetValue(id, out var carried))
            {
                var stamp = Path.Combine(Paths.Script(Path.Combine("Tools", carried.Folder)), "version.txt");
                return File.Exists(stamp) ? Number(File.ReadAllText(stamp)) : null;
            }
            switch (id)
            {
                case "rclone":
                    return Paths.Rclone is { } rclone ? Number(FirstLine(rclone, "version")) : null;
                case "cloudflared":
                    var cloudflared = Paths.Script(Path.Combine("Tunnel", "Bin", "cloudflared.exe"));
                    return File.Exists(cloudflared) ? Number(FirstLine(cloudflared, "--version")) : null;
                case "terminal":
                    // The mark beside the program, not the version of the file: Microsoft leaves the
                    // number of the base branch in wt.exe, and after an update the file says the old one.
                    var dir = Paths.Script(Path.Combine("Tools", "terminal"));
                    var mark = Path.Combine(dir, ".version");
                    if (File.Exists(mark) && Number(File.ReadAllText(mark)) is { } marked) return marked;
                    var exe = Path.Combine(dir, "wt.exe");
                    return File.Exists(exe) ? Number(FileVersionInfo.GetVersionInfo(exe).FileVersion) : null;
            }
        }
        catch { }
        return null;
    }

    static string FirstLine(string exe, string argument)
    {
        try
        {
            var info = new ProcessStartInfo(exe, argument) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            using var process = Process.Start(info);
            if (process is null) return "";
            var output = process.StandardOutput.ReadToEndAsync();
            _ = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(6000)) { try { process.Kill(); } catch { } return ""; }
            return output.Result.Split('\n').FirstOrDefault()?.Trim() ?? "";
        }
        catch { return ""; }
    }

    /// <summary>What the makers have out, by tool: from the cache while it is fresh, from the network otherwise.</summary>
    public static async Task<Dictionary<string, string>> LatestAsync(bool force = false)
    {
        Cache? cache = null;
        try { if (File.Exists(CacheFile)) cache = JsonSerializer.Deserialize<Cache>(File.ReadAllText(CacheFile)); } catch { }
        // A cache written before a tool was known has no number for it: it is not an answer for that tool.
        if (!force && cache is not null && Known.All(k => cache.Latest.ContainsKey(k.Id))
            && DateTime.Now - cache.Checked <= (cache.Answered ? Fresh : Retry)) return cache.Latest;

        var fresh = new Cache { Checked = DateTime.Now, Answered = true };
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(8) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Audion-Sync-Tools");
        var asked = Known.Select(async k => (k.Id, Number: await AskAsync(client, k.Id))).ToList();
        foreach (var (id, number) in await Task.WhenAll(asked))
            if (number is not null) fresh.Latest[id] = number;
            else fresh.Answered = false;
        // A check that got no answer keeps the last known numbers rather than showing nothing.
        if (cache is not null)
            foreach (var (id, number) in cache.Latest) fresh.Latest.TryAdd(id, number);
        try { File.WriteAllText(CacheFile, JsonSerializer.Serialize(fresh, new JsonSerializerOptions { WriteIndented = true })); } catch { }
        return fresh.Latest;
    }

    static async Task<string?> AskAsync(HttpClient client, string id)
    {
        try
        {
            if (id == "rclone")
            {
                // rclone keeps a file with the number alone: thirty bytes.
                using var answer = await client.GetAsync("https://downloads.rclone.org/version.txt");
                return answer.IsSuccessStatusCode ? Number(await answer.Content.ReadAsStringAsync()) : null;
            }
            var repo = Carried.TryGetValue(id, out var carried) ? carried.Repo : id == "cloudflared" ? "cloudflare/cloudflared" : "microsoft/terminal";
            using var moved = await client.GetAsync($"https://github.com/{repo}/releases/latest");
            var location = moved.Headers.Location?.ToString() ?? "";
            var cut = location.LastIndexOf("/tag/", StringComparison.Ordinal);
            return cut >= 0 ? Number(location[(cut + 5)..]) : null;
        }
        catch { return null; }
    }

    /// <summary>By the numbers where both read as versions; otherwise any difference counts.</summary>
    public static bool IsNewer(string latest, string installed) =>
        Version.TryParse(latest, out var l) && Version.TryParse(installed, out var i) ? l > i : latest != installed;
}
