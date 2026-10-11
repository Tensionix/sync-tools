using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

/// <summary>A found file: its path from the folder searched, its size and time.</summary>
public sealed record Found(string Rel, long Size, DateTime? Modified)
{
    public string Name => Rel[(Rel.LastIndexOf('/') + 1)..];
    /// <summary>The folders between the place searched and the file; empty - it lies in the place itself.</summary>
    public string Folder => Rel.LastIndexOf('/') is var cut and >= 0 ? Rel[..cut] : "";
}

/// <summary>
/// How far the search has come: files looked at, found, whether it ended. Cut - the limit of finds
/// was reached and the rest of the tree was not looked at; Trouble - what rclone said when it failed.
/// </summary>
public sealed record SearchProgress(int Folders, long Files, int Found, string Folder, bool Done, TimeSpan Elapsed, bool Cut = false, string Trouble = "");

/// <summary>The keys typed into the search field, sorted by what they do.</summary>
public sealed record SearchKeys(List<string> Types, List<string> Names, List<string> Regexes);

/// <summary>
/// What the search window asks, by the rules of Audion Disk Tools: the groups of extensions and
/// the keys typed in one field, and the time. Typed keys: an extension (".dwg", "*.dwg", "*." -
/// no extension) adds a type to the groups, any of them; "/…/" is a regular expression that must
/// hold; anything else is a word or a mask of the name, any of them - a word without a wildcard
/// is found anywhere in the name. Types, names, expressions and the time must all hold together.
/// </summary>
public sealed class SearchQuery
{
    public string Text { get; set; } = "";
    public List<string> Groups { get; set; } = new();
    public AgeLimit Age { get; set; }

    // "/…/" as a whole key: at the start of the text or after a separator, up to the next separator.
    static readonly Regex RegexKey = new(@"(?<=^|[,;\r\n])\s*/(?<re>(?:\\.|[^/\\\r\n])+)/\s*(?=$|[,;\r\n])", RegexOptions.CultureInvariant);

    // An extension alone: ".dwg", "*.dwg", "*." (no extension).
    static readonly Regex TypeKey = new(@"^\*?\.[^.*?\\/\s]*$", RegexOptions.CultureInvariant);

    /// <summary>"отчёт, *.pdf" - "*отчёт*", "*.pdf": a word without a wildcard is found anywhere in the name.</summary>
    public static List<string> NameMasks(IEnumerable<string> names) =>
        names.Select(t => t.IndexOfAny(new[] { '*', '?' }) >= 0 ? t : "*" + t + "*").ToList();

    /// <summary>The typed keys, sorted: types, name words and masks as typed, expressions.</summary>
    public static SearchKeys Keys(string? text)
    {
        var regexes = new List<string>();
        var rest = RegexKey.Replace(text ?? "", m => { regexes.Add(m.Groups["re"].Value); return ""; });
        var types = new List<string>();
        var names = new List<string>();
        foreach (var key in MaskText.Split(rest))
        {
            if (TypeKey.IsMatch(key) && key != ".") types.Add(key.StartsWith('*') ? key : "*" + key);
            else names.Add(key);
        }
        return new SearchKeys(types, names, regexes);
    }

    /// <summary>The expression is read without regard to case and gives up after a quarter of a second on one name.</summary>
    public static Regex Expression(string pattern) => new(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));

    /// <summary>Why the expression cannot be used; null - it can.</summary>
    public static string? RegexError(string pattern)
    {
        if (pattern.Trim().Length == 0) return null;
        try { Expression(pattern); return null; }
        catch (ArgumentException ex) { return ex.Message; }
    }
}

/// <summary>A query as the search tests a file by its name and time.</summary>
public sealed class SearchFilter
{
    readonly Regex[] _types, _names, _expressions;
    readonly AgeLimit _age;
    readonly DateTime _now = DateTime.Now;

    public SearchFilter(SearchQuery query)
    {
        var keys = SearchQuery.Keys(query.Text);
        var groups = MaskGroups.Families.SelectMany(f => f.Groups).ToDictionary(g => g.Id, g => g.Masks);
        _types = Mask.Compile(query.Groups.Where(groups.ContainsKey).SelectMany(id => groups[id]).Concat(keys.Types));
        _names = Mask.Compile(SearchQuery.NameMasks(keys.Names));
        _expressions = keys.Regexes.Select(SearchQuery.Expression).ToArray();
        _age = query.Age;
    }

    static bool Hit(Regex regex, string name)
    {
        try { return regex.IsMatch(name); }
        catch (RegexMatchTimeoutException) { return false; }
    }

    public bool Passes(string name, DateTime? modified) =>
        (_types.Length == 0 || Mask.Matches(name, _types))
        && (_names.Length == 0 || Mask.Matches(name, _names))
        && _expressions.All(expression => Hit(expression, name))
        && AgeFilter.Fits(_age, modified, _now);
}

/// <summary>
/// The search of the search window. A panel here stands on a far machine or a bucket as often as on
/// a disk, so the tree is walked by rclone itself - one "lsjson -R" from the place of the panel -
/// and its answer is read as it comes, a file a line: each is judged by the filter, the finds are
/// handed on in batches while the walk goes, СТОП ends rclone. The time narrows the answer on the
/// side of rclone already (--max-age); everything else is judged here, by the one mask language of
/// the program.
/// </summary>
public static class SearchRun
{
    /// <summary>More finds than this is not an answer to read: the walk stops and says so.</summary>
    public const int Limit = 50000;

    public static async Task Run(string target, SearchQuery query, Action<IReadOnlyList<Found>> found, Action<SearchProgress> progress, CancellationToken cancel)
    {
        var clock = Stopwatch.StartNew();
        if (Paths.Rclone is not { } exe) { progress(new SearchProgress(0, 0, 0, "", true, clock.Elapsed, Trouble: Lang.T("rclone не найден"))); return; }
        var filter = new SearchFilter(query);
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Paths.Root,
        };
        foreach (var arg in Rclone.BaseArgs()) info.ArgumentList.Add(arg);
        foreach (var arg in new[] { "lsjson", "-R", "--files-only", "--no-mimetype" }) info.ArgumentList.Add(arg);
        // The window of the time starts an hour ago, or at midnight of its first calendar day - as the colours of the rows count it.
        if (query.Age != AgeLimit.None)
        {
            var now = DateTime.Now;
            var since = query.Age switch { AgeLimit.Hour => now.AddHours(-1), AgeLimit.Day => now.Date.AddDays(-1), _ => now.Date.AddDays(-7) };
            info.ArgumentList.Add("--max-age");
            info.ArgumentList.Add($"{(long)Math.Ceiling((now - since).TotalSeconds)}s");
        }
        info.ArgumentList.Add(target);
        foreach (var (name, value) in Rclone.Env()) info.Environment[name] = value;

        Process process;
        try { process = Process.Start(info) ?? throw new InvalidOperationException("no process"); }
        catch (Exception ex) { progress(new SearchProgress(0, 0, 0, "", true, clock.Elapsed, Trouble: ex.Message)); return; }

        using (process)
        using (cancel.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { } }))
        {
            try { process.StandardInput.Close(); } catch { }
            var errors = process.StandardError.ReadToEndAsync();
            long files = 0;
            int hits = 0;
            bool cut = false;
            // rclone tells files, not folders: a folder is counted when its first file comes.
            var folders = new HashSet<string>(StringComparer.Ordinal);
            string folder = "";
            var batch = new List<Found>();
            var told = Stopwatch.StartNew();
            void Hand(bool done, string trouble = "")
            {
                if (batch.Count > 0) { found(batch.ToArray()); batch.Clear(); }
                progress(new SearchProgress(folders.Count, files, hits, folder, done, clock.Elapsed, cut, trouble));
                told.Restart();
            }
            try
            {
                while (await process.StandardOutput.ReadLineAsync(cancel) is { } line)
                {
                    // A file a line: {"Path":"a/b.txt","Name":"b.txt","Size":3,"ModTime":"…","IsDir":false},
                    var text = line.Trim().TrimEnd(',');
                    if (text.Length < 2 || text[0] != '{') continue;
                    files++;
                    try
                    {
                        using var doc = JsonDocument.Parse(text);
                        var item = doc.RootElement;
                        var rel = item.GetProperty("Path").GetString() ?? "";
                        DateTime? when = null;
                        if (item.TryGetProperty("ModTime", out var m) && m.GetString() is { Length: > 0 } stamp && DateTimeOffset.TryParse(stamp, out var parsed))
                            when = parsed.LocalDateTime;
                        var one = new Found(rel, item.TryGetProperty("Size", out var s) ? s.GetInt64() : -1, when);
                        folder = one.Folder;
                        folders.Add(folder);
                        if (rel.Length > 0 && filter.Passes(one.Name, when)) { batch.Add(one); hits++; }
                    }
                    catch (JsonException) { }
                    if (hits >= Limit) { cut = true; break; }
                    if (told.ElapsedMilliseconds >= 200) Hand(done: false);
                }
            }
            catch (OperationCanceledException) { }
            if (cut) { try { process.Kill(entireProcessTree: true); } catch { } }
            try { await process.WaitForExitAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5)); } catch { }
            string said = "";
            // Stopped by hand or by the limit is not a failure; a walk that ended by itself with a code is.
            if (!cancel.IsCancellationRequested && !cut && process.HasExited && process.ExitCode != 0)
            {
                try { said = (await errors.WaitAsync(TimeSpan.FromSeconds(2))).Trim(); } catch { }
                said = said.Split('\n').LastOrDefault(l => l.Trim().Length > 0)?.Trim() ?? Lang.F("rclone: код {0}", process.ExitCode);
                // "2026/10/04 20:17:52 NOTICE: Failed to lsjson with 18 errors: last error was: …" - the date and the level are not the news.
                said = Regex.Replace(said, @"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} [A-Z]+\s*:\s*", "");
            }
            Hand(done: true, said);
        }
    }
}
