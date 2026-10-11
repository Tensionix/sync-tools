using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

namespace AudionSyncTools.Core;

public enum LogTone { Plain, Muted, Head, Good, Warn, Bad }

/// <summary>
/// The journal of the window: every line goes to the panel on the right, coloured by what it
/// says, and to a file of the day (logs\gui-DATE.log) with its time - a machine far away is
/// taken apart by that file, the panel cannot be sent.
/// </summary>
public static class Journal
{
    /// <summary>Lines for the panel, in the order they came; raised on the thread that wrote them.</summary>
    public static event Action<IReadOnlyList<(string Text, LogTone Tone)>>? Lines;

    static string LogFile => Path.Combine(Paths.Logs, $"gui-{DateTime.Now:yyyyMMdd}.log");

    public static void Add(string line) => AddMany(new[] { line });

    public static void AddMany(IReadOnlyList<string> lines)
    {
        if (lines.Count == 0) return;
        var shown = new List<(string, LogTone)>(lines.Count);
        var file = new StringBuilder();
        var stamp = DateTime.Now.ToString("HH:mm:ss");
        foreach (var raw in lines)
        {
            var line = Lang.T(raw);
            shown.Add((line, Tone(line)));
            file.Append(stamp).Append("  ").AppendLine(line);
        }
        try { File.AppendAllText(LogFile, file.ToString(), Encoding.UTF8); } catch { }
        Lines?.Invoke(shown);
    }

    // The label [окно] alone says nothing: breakages, refusals and plain notes all wear it.
    // Red is only for what really broke, or the journal frightens for no reason.
    static readonly Regex Bad = new("ERROR|CRITICAL|Failed|отказ|не сошл|не найден|не запустилось|не скачался|ОШИБКА|не сохранил|не вышло|не прочитал|not found|did not start|did not work|did not open|not saved|not written|unreadable|failed|did not answer", RegexOptions.Compiled);
    static readonly Regex Warn = new("проба|WARN|NOTICE|not in Export Keys|уже на месте|public key only|нечем починить|dry run|missing from|no such file", RegexOptions.Compiled);
    // The window did not do what was asked and says what was missing.
    static readonly Regex Asked = new("нечего|не выбран|снимите отметки|отметьте |ничего не отмечено|должны стоять|совпадают|прерван|не выполнены|nothing to|nothing is ticked|no address|no task|is the same|run stopped|not done|not accepted|nothing to remove|no machine answered|no answer", RegexOptions.Compiled);
    static readonly Regex Good = new(@"^\s*(положено|взято|поправлено|починено|сумма сошлась|права сведены|Готово|готово|written|stored|collected|done|ready)", RegexOptions.Compiled);
    static readonly Regex GoodEnd = new("(отмечено|без отметок|очищена|ticked|unticked|cleared|accepted|re-read)$", RegexOptions.Compiled);
    static readonly Regex Muted = new(@"^\s*(папка|MAIN VPS|SECOND VPS|источник|профиль|программа|режим|данные|folder|bucket|source|profile|program|export|mode|data|terminal|schedule|snapshot|cloudflared|sshd|R2 keys|host keys)\s*:", RegexOptions.Compiled);
    static readonly Regex HeadDone = new(": (готово|done|ready)$", RegexOptions.Compiled);
    static readonly Regex HeadCode = new(@": (код|code) -?\d+", RegexOptions.Compiled);

    /// <summary>What colour a line is written in: Get-AbkLogColor of the PowerShell window, rule for rule.</summary>
    public static LogTone Tone(string line)
    {
        var t = line.Trim();
        if (t.Length == 0) return LogTone.Plain;
        if (t.StartsWith("====="))
        {
            if (HeadDone.IsMatch(t)) return LogTone.Good;
            if (HeadCode.IsMatch(t)) return LogTone.Bad;
            return LogTone.Head;
        }
        if (Bad.IsMatch(t)) return LogTone.Bad;
        if (Warn.IsMatch(t) || Asked.IsMatch(t)) return LogTone.Warn;
        if (Good.IsMatch(t) || GoodEnd.IsMatch(t)) return LogTone.Good;
        if (Muted.IsMatch(t)) return LogTone.Muted;
        if (t.StartsWith("[окно]") || t.StartsWith("[window]")) return LogTone.Muted;
        return LogTone.Plain;
    }

    // rclone prints its whole help on a wrong path - dozens of flag lines that hide the error -
    // and repeats the host key notice on every call: known_hosts is kept by the program itself.
    static readonly Regex Noise = new(@"^(Usage:|Flags|rclone lsjson|rclone \[|Use ""rclone|-{1,2}[a-zA-Z])", RegexOptions.Compiled);

    public static bool IsNoise(string line)
    {
        var t = line.Trim();
        return t.Length == 0 || Noise.IsMatch(t) || t.Contains("No host key validation is being performed");
    }

    /// <summary>
    /// What rclone says when a remote has both an ssh program and a host. In the working config
    /// of the data folder that is a mistake worth a line. For BISYNC from afar it is the very
    /// thing asked for - the window lays the ssh program of the far road over the plain remote
    /// of a machine (Sources.SteadyPath) - and that job alone keeps it out of its journal
    /// (Job.Hush). Hidden for every job, as it was at first, it hid the mistake too.
    /// </summary>
    public const string SshOverHost = "--sftp-ssh is in use - ignoring user/host/port from config";

    static readonly (Regex Match, string Say)[] Known =
    {
        (new Regex("connectex|connection refused|actively refused", RegexOptions.IgnoreCase), "не отвечает"),
        (new Regex("i/o timeout|deadline exceeded|context deadline", RegexOptions.IgnoreCase), "молчит - вышло время"),
        (new Regex("no such host|server misbehaving", RegexOptions.IgnoreCase), "имя не разрешается"),
        (new Regex("didn't find section", RegexOptions.IgnoreCase), "нет такого маршрута в конфиге"),
        (new Regex("unauthorized_client|invalid_grant|couldn.t fetch token", RegexOptions.IgnoreCase), "нужен повторный вход"),
        (new Regex("directory not found|no such file", RegexOptions.IgnoreCase), "папки нет"),
        (new Regex("Failed to create file system|couldn.t parse known_hosts", RegexOptions.IgnoreCase), "транспорт не собран - нажмите RCLONE.CONF"),
        (new Regex("permission denied|denied by", RegexOptions.IgnoreCase), "доступ закрыт"),
        (new Regex("handshake failed|unable to authenticate", RegexOptions.IgnoreCase), "ключ не принят"),
    };

    static readonly Regex RcloneStamp = new(@"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}\s+", RegexOptions.Compiled);

    /// <summary>
    /// The complaints of rclone folded into one plain line. A machine that is not there - at home
    /// it is, at work it is not - is an everyday thing and must read as a line, not as a crash.
    /// Empty when there is nothing to say.
    /// </summary>
    public static string ShortTrouble(string text, string who)
    {
        var joined = text.Replace('\r', ' ').Replace('\n', ' ');
        if (joined.Trim().Length == 0) return "";
        foreach (var (match, say) in Known)
            if (match.IsMatch(joined)) return $"{who}: {Lang.T(say)}";
        foreach (var raw in text.Split('\n'))
        {
            if (IsNoise(raw)) continue;
            var line = RcloneStamp.Replace(raw.Trim(), "");
            if (line.Length > 160) line = line[..157] + "...";
            return $"{who}: {line}";
        }
        return "";
    }

    static readonly Dictionary<string, DateTime> Said = new();

    /// <summary>
    /// A complaint written once and kept quiet until it changes: a panel is read again and again,
    /// and the same line every few seconds buried everything else. After a quarter of an hour it
    /// is said again - an hour of silence reads as "all is well".
    /// </summary>
    public static void TroubleOnce(string text)
    {
        if (text.Length == 0) return;
        var now = DateTime.Now;
        if (Said.TryGetValue(text, out var seen) && (now - seen).TotalMinutes < 15) return;
        Said[text] = now;
        Add(Lang.T("[чтение] ") + text);
    }
}
