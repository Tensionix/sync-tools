using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

/// <summary>
/// rclone of the program: its own binary (Tools\rclone), the config of the data folder and a
/// cache of its own - never the machine's. The keys of R2 reach a child through its environment,
/// not through the command line and not through the window's own variables.
/// Engine\BackupRclone.psm1 says the same for the scripts.
/// </summary>
public static class Rclone
{
    /// <summary>The config rclone is run with: the one of the session when clouds are attached, the plain one otherwise.</summary>
    public static string ConfigPath => SessionConfig ?? TransportPath;

    /// <summary>
    /// The plain config of the data folder: what a machine can be reached by is read from here,
    /// always. The config of a session is encrypted - read as a text it has no section in it,
    /// and with a cloud attached every machine looked as if it had the straight road alone.
    /// </summary>
    public static string TransportPath => DataRoot.File_(Path.Combine("config", "rclone", "rclone.conf"));

    /// <summary>
    /// The working config of the window when clouds are attached: the transport together with
    /// them, encrypted. rclone writes a refreshed OAuth token back into the file a remote came
    /// from - with the plain config active the tokens landed there, in the open.
    /// </summary>
    public static string? SessionConfig { get; set; }

    /// <summary>Variables every rclone of the window gets on top of the two of R2 (the password of the clouds' config).</summary>
    public static Dictionary<string, string> SessionEnv { get; } = new();

    public static string CredentialsPath => DataRoot.File_(Path.Combine("config", "rclone", "r2.credentials"));

    public static List<string> BaseArgs()
    {
        var cache = Path.Combine(Paths.State, "rclone-cache");
        try { Directory.CreateDirectory(cache); } catch { }
        return new List<string> { "--config", ConfigPath, "--cache-dir", cache };
    }

    /// <summary>The bucket is not probed: the token is issued for objects, and a check of the bucket itself is refused.</summary>
    public static Dictionary<string, string> Env()
    {
        var env = new Dictionary<string, string>
        {
            ["AWS_SHARED_CREDENTIALS_FILE"] = CredentialsPath,
            ["RCLONE_S3_NO_CHECK_BUCKET"] = "true",
        };
        foreach (var (name, value) in SessionEnv) env[name] = value;
        return env;
    }

    /// <summary>A job of the queue: the base arguments, the operation, and a progress line for the status every five seconds.</summary>
    public static Job Job(string title, IEnumerable<string> operation, bool refresh = true, Action? onSuccess = null)
    {
        var args = BaseArgs();
        args.AddRange(operation);
        // Retries without a pause are pointless: rclone fits all three into one second, and the
        // usual reason of a refusal is a file the other side's indexer or antivirus still holds.
        args.AddRange(new[] { "--retries-sleep", "5s", "--stats", "5s", "--stats-one-line", "--stats-log-level", "NOTICE" });
        return new Job { Title = title, Exe = Paths.Rclone ?? "rclone", Args = args, Env = Env(), Refresh = refresh, OnSuccess = onSuccess };
    }

    public sealed record Answer(int Code, string Output, string Errors, bool TimedOut);

    /// <summary>The questions still waiting for an answer: a listing, the free space of a machine that is silent.</summary>
    static readonly System.Collections.Concurrent.ConcurrentDictionary<int, Process> Live = new();

    /// <summary>
    /// The window is closing: a question to a silent machine must not outlive it. Left alone,
    /// rclone waited out its timeouts for minutes with nobody to answer to - and its ssh and
    /// cloudflared with it.
    /// </summary>
    public static void StopAll()
    {
        foreach (var process in Live.Values)
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    /// <summary>
    /// One call that returns its output: a listing, the free space. The input is taken and closed
    /// at once - ssh inside rclone waits for an answer to a question nobody will see otherwise -
    /// and both streams are read while the process runs: a redirected stream left unread fills
    /// its buffer and the process stands still for ever.
    /// </summary>
    public static async Task<Answer> Run(IEnumerable<string> operation, int timeoutSeconds, CancellationToken cancel)
    {
        if (Paths.Rclone is not { } exe) return new Answer(-1, "", Lang.T("rclone не найден"), false);
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.Root,
        };
        foreach (var arg in BaseArgs()) info.ArgumentList.Add(arg);
        foreach (var arg in operation) info.ArgumentList.Add(arg);
        foreach (var (name, value) in Env()) info.Environment[name] = value;

        Process process;
        try { process = Process.Start(info) ?? throw new InvalidOperationException("no process"); }
        catch (Exception ex) { return new Answer(-1, "", ex.Message, false); }
        using (process)
        {
            int id = process.Id;
            Live[id] = process;
            using var forget = new Forget(id);
            try { process.StandardInput.Close(); } catch { }
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            limit.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
            try
            {
                await process.WaitForExitAsync(limit.Token);
                return new Answer(process.ExitCode, await output, await errors, false);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                // Asked to stop is not a timeout: the panel went elsewhere and this answer is no longer wanted.
                cancel.ThrowIfCancellationRequested();
                string said = "";
                try { said = await errors.WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
                return new Answer(-1, "", said, true);
            }
        }
    }

    /// <summary>Takes a finished question out of the list of the waiting ones, whichever way Run ends.</summary>
    readonly struct Forget(int id) : IDisposable
    {
        public void Dispose() => Live.TryRemove(id, out _);
    }

    static readonly Regex LogLine = new(@"^\d{4}/\d{2}/\d{2} ", RegexOptions.Compiled);

    /// <summary>
    /// The rows of one folder by "lsjson". The modification time comes in the same answer from
    /// a bucket and from a machine over ssh alike - no second request. Null rows - no answer.
    /// </summary>
    public static async Task<(List<Listed>? Rows, Answer Answer)> List(string target, CancellationToken cancel, int timeoutSeconds = 60)
    {
        var answer = await Run(new[] { "lsjson", target }, timeoutSeconds, cancel);
        if (answer.Code != 0) return (null, answer);
        var rows = new List<Listed>();
        // A notice of rclone may sit in front of the JSON: its lines start with a date.
        var json = new StringBuilder();
        foreach (var line in answer.Output.Split('\n'))
            if (!LogLine.IsMatch(line)) json.AppendLine(line);
        var text = json.ToString().Trim();
        if (text.Length == 0) return (rows, answer);
        try
        {
            using var doc = JsonDocument.Parse(text);
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                DateTime? when = null;
                if (item.TryGetProperty("ModTime", out var m) && m.GetString() is { Length: > 0 } stamp && DateTimeOffset.TryParse(stamp, out var parsed))
                    when = parsed.LocalDateTime;
                rows.Add(new Listed(
                    item.GetProperty("Name").GetString() ?? "",
                    item.TryGetProperty("IsDir", out var d) && d.GetBoolean(),
                    item.TryGetProperty("Size", out var s) ? s.GetInt64() : -1,
                    when));
            }
        }
        catch (Exception ex) { return (null, answer with { Errors = ex.Message }); }
        return (rows, answer);
    }

    public sealed record Listed(string Name, bool IsDir, long Size, DateTime? Modified);

    /// <summary>Free and total bytes of a remote ("about --json"); null when the remote does not tell.</summary>
    public static async Task<(long Free, long Total)?> About(string target, CancellationToken cancel)
    {
        var answer = await Run(new[] { "about", target, "--json" }, 30, cancel);
        if (answer.Code != 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(answer.Output);
            long free = doc.RootElement.TryGetProperty("free", out var f) ? f.GetInt64() : -1;
            long total = doc.RootElement.TryGetProperty("total", out var t) ? t.GetInt64() : -1;
            return free < 0 && total < 0 ? null : (free, total);
        }
        catch { return null; }
    }

    /// <summary>
    /// What the config of the data folder really has: section -> its keys. What a machine can be
    /// reached by is read from here, not guessed from a VPS that answers.
    /// </summary>
    public static Dictionary<string, Dictionary<string, string>> Transports()
    {
        var path = TransportPath;
        try
        {
            var file = new FileInfo(path);
            var stamp = file.Exists ? $"{file.FullName}|{file.LastWriteTimeUtc.Ticks}|{file.Length}" : path;
            if (stamp == _transportsStamp) return _transports;
            var routes = new Dictionary<string, Dictionary<string, string>>(StringComparer.OrdinalIgnoreCase);
            if (file.Exists)
            {
                string section = "";
                foreach (var line in File.ReadAllLines(path))
                {
                    var head = SectionLine.Match(line);
                    if (head.Success) { section = head.Groups[1].Value.Trim(); routes[section] = new(StringComparer.OrdinalIgnoreCase); continue; }
                    var pair = KeyLine.Match(line);
                    if (section.Length > 0 && pair.Success) routes[section][pair.Groups[1].Value] = pair.Groups[2].Value;
                }
            }
            _transports = routes;
            _transportsStamp = stamp;
        }
        catch { }
        return _transports;
    }

    static Dictionary<string, Dictionary<string, string>> _transports = new(StringComparer.OrdinalIgnoreCase);
    static string _transportsStamp = "?";
    static readonly Regex SectionLine = new(@"^\s*\[([^\]]+)\]\s*$", RegexOptions.Compiled);
    static readonly Regex KeyLine = new(@"^\s*(type|host|port|ssh|user|key_file|known_hosts_file)\s*=\s*(.*?)\s*$", RegexOptions.Compiled);

    /// <summary>A remote ("base-via:") that the config really describes, with no placeholder left in it.</summary>
    public static bool Configured(string remote)
    {
        if (remote.Length == 0) return false;
        var name = remote.Split(':', 2)[0];
        if (!Transports().TryGetValue(name, out var config)) return false;
        if (!config.TryGetValue("type", out var type) || type.Length == 0 || type.Contains("{{")) return false;
        if (type == "sftp")
        {
            var endpoint = config.TryGetValue("ssh", out var ssh) && ssh.Length > 0 ? ssh : config.GetValueOrDefault("host", "");
            return endpoint.Length > 0 && !endpoint.Contains("{{");
        }
        return true;
    }
}
