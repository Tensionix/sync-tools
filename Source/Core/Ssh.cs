using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace AudionSyncTools.Core;

/// <summary>
/// What ssh itself knows: the names of ~\.ssh\config. The routes of a machine (base-direct,
/// base-cf, laptop-ssh) are hosts of that file, written by the engine; the window only asks
/// whether a name is there before it sends a terminal by it.
/// </summary>
public static class Ssh
{
    public static string ConfigPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "config");

    static readonly Regex HostLine = new(@"^\s*Host\s+(.+?)\s*$", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    static readonly Regex IncludeLine = new(@"^\s*Include\s+(.+?)\s*$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>
    /// The names of the Host lines, with Include opened the way OpenSSH does it: a relative path
    /// counts from ~\.ssh, masks are expanded, the depth is limited. Without that a name written
    /// in an included file looked absent.
    /// </summary>
    public static HashSet<string> Names()
    {
        var names = new HashSet<string>(StringComparer.Ordinal);
        Collect(ConfigPath, names, 0);
        return names;
    }

    static void Collect(string path, HashSet<string> names, int depth)
    {
        // OpenSSH stops at the sixteenth level, and so does this: a file that includes itself would be read for ever.
        if (depth > 16 || !File.Exists(path)) return;
        string[] lines;
        try { lines = File.ReadAllLines(path); } catch { return; }
        var home = Path.GetDirectoryName(ConfigPath)!;
        foreach (var raw in lines)
        {
            if (raw.TrimStart().StartsWith('#')) continue;
            if (HostLine.Match(raw) is { Success: true } host)
            {
                // Several names may stand in one Host line: "Host work-ssh audion-work-ssh".
                foreach (var name in host.Groups[1].Value.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
                    if (!name.Contains('*') && !name.Contains('?') && !name.StartsWith('!')) names.Add(name.Trim('"'));
                continue;
            }
            if (IncludeLine.Match(raw) is { Success: true } include)
            {
                foreach (var one in include.Groups[1].Value.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var pattern = one.Trim('"').Replace('/', '\\');
                    if (pattern.StartsWith("~\\")) pattern = Path.Combine(Path.GetDirectoryName(home)!, pattern[2..]);
                    else if (!Path.IsPathRooted(pattern)) pattern = Path.Combine(home, pattern);
                    try
                    {
                        var dir = Path.GetDirectoryName(pattern);
                        if (dir is null || !Directory.Exists(dir)) continue;
                        foreach (var file in Directory.GetFiles(dir, Path.GetFileName(pattern)).OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
                            Collect(file, names, depth + 1);
                    }
                    catch { }
                }
            }
        }
    }

    /// <summary>
    /// Whether ssh knows a name - the way ssh itself understands it. The list of hosts answers
    /// the plain question; "ssh -G" adds what the list does not see: Match and patterns. A name
    /// counts as known when a Host line names it, or when ssh resolves it to another address or
    /// leads it through a jump.
    /// </summary>
    public static bool Knows(string name)
    {
        if (name.Length == 0) return false;
        if (Names().Contains(name)) return true;
        if (Resolve(name) is not { } options) return false;
        foreach (var jump in new[] { "proxyjump", "proxycommand" })
            if (options.TryGetValue(jump, out var value) && value.Length > 0 && value != "none") return true;
        return options.TryGetValue("hostname", out var resolved) && resolved.Length > 0 && resolved != name;
    }

    /// <summary>
    /// The address a host of ~\.ssh\config leads to ("ssh -G"); empty when ssh knows no other one.
    /// A machine set up before targets.json named MAIN VPS keeps its names here only.
    /// </summary>
    public static string HostNameOf(string name)
    {
        if (name.Length == 0 || Resolve(name) is not { } options) return "";
        return options.TryGetValue("hostname", out var resolved) && resolved != name ? resolved : "";
    }

    /// <summary>The options "ssh -G" gives for a name; null when ssh does not answer.</summary>
    static Dictionary<string, string>? Resolve(string name)
    {
        try
        {
            var info = new ProcessStartInfo("ssh.exe")
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            };
            info.ArgumentList.Add("-G");
            info.ArgumentList.Add(name);
            using var process = Process.Start(info);
            if (process is null) return null;
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            _ = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(5000)) { try { process.Kill(); } catch { } return null; }
            if (process.ExitCode != 0) return null;
            var options = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var row in output.Result.Split('\n'))
            {
                var parts = row.Trim().Split(new[] { ' ', '\t' }, 2, StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length == 2 && !options.ContainsKey(parts[0])) options[parts[0]] = parts[1];
            }
            return options;
        }
        catch { return null; }
    }
}
