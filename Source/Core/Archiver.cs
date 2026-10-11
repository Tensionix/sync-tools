using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

/// <summary>One archive format of the ARCHIVE section (ARCHIVE_FORMATS of the Python Disk Tools).</summary>
public sealed record ArchiveFormat(string Id, string Label, string Type, string Ext, string Mode);

/// <summary>Packing choices, kept between runs. The password is never written to disk.</summary>
public sealed class PackOptions
{
    public List<string> Formats { get; set; } = new() { "zip" };
    public string Encryption { get; set; } = "none";   // none | password | names
    [JsonIgnore] public string Password { get; set; } = "";
    public string Level { get; set; } = "1";
    public string Layout { get; set; } = "flat";       // flat | per_folder
    public string Scope { get; set; } = "each";        // each | one
    public string Prefix { get; set; } = "";
    public string Suffix { get; set; } = "";
    public bool Underscore { get; set; }
    public bool Verify { get; set; } = true;
    public bool DeleteSource { get; set; }
    public string SfxEnv { get; set; } = "";
    public string SfxPath { get; set; } = "{name}";
    public List<string> SfxWrappers { get; set; } = new();

    /// <summary>A queued job keeps its own copy: the next dialog must not change it under its feet.</summary>
    public PackOptions Copy()
    {
        var copy = (PackOptions)MemberwiseClone();
        copy.Formats = new List<string>(Formats);
        copy.SfxWrappers = new List<string>(SfxWrappers);
        return copy;
    }
}

/// <summary>Unpacking choices, kept between runs.</summary>
public sealed class UnpackOptions
{
    public string Target { get; set; } = "other";      // other | here
    public string Mode { get; set; } = "smart";        // smart | folder | flat
    public string Overwrite { get; set; } = "rename";  // rename | overwrite | skip
    public bool DeleteArchives { get; set; }
    [JsonIgnore] public string Password { get; set; } = "";

    public UnpackOptions Copy() => (UnpackOptions)MemberwiseClone();
}

/// <summary>
/// The ARCHIVE section of the Python Disk Tools, carried over as it was:
/// 7-Zip does the containers, zstd and lz4 their streams, PeaZip portable
/// brings all of them in Tools\PeaZip. Unpacking is new: many archives at
/// once, each into its own folder or "smart" - an archive that already holds
/// one folder is not wrapped in a second one.
/// </summary>
public static partial class Archiver
{
    public static readonly ArchiveFormat[] Formats =
    {
        new("zip", "ZIP", "zip", ".zip", "direct"),
        new("7z", "7Z", "7z", ".7z", "direct"),
        new("sfx", "SFX", "7z", ".exe", "sfx"),
        new("lz4", "TAR.LZ4", "lz4", ".tar.lz4", "tar_compress"),
        new("tar", "TAR", "tar", ".tar", "direct_tar"),
        new("gz", "TAR.GZ", "gzip", ".tar.gz", "tar_compress"),
        new("zstd", "TAR.ZSTD", "zstd", ".tar.zst", "tar_compress"),
    };

    public static readonly string[] Levels = { "0", "1", "3", "5", "7", "9" };

    public static readonly (string Id, string Label, string Ext)[] SfxWrappers =
    {
        ("zip", "ZIP", ".zip"), ("7z", "7Z", ".7z"), ("zstd", "ZSTD", ".zst"), ("tar", "TAR", ".tar"), ("gz", "GZ", ".gz"),
    };

    /// <summary>Where a self-extractor offers to unpack: the key shown, the variable the SFX module reads.</summary>
    public static readonly (string Key, string Label, string Install)[] SfxEnvs =
    {
        ("", "—", ""),
        ("%LOCALDATA%", "LOCALDATA", "%LOCALAPPDATA%"),
        ("%USERDATA%", "USERDATA", "%APPDATA%"),
        ("%USERPROFILE%", "USERPROFILE", "%USERPROFILE%"),
        ("%PROGRAMDATA%", "PROGRAMDATA", "%PROGRAMDATA%"),
        ("%PROGRAMFILES%", "PROGRAMFILES 64", "%ProgramFiles%"),
        ("%PROGRAMFILES_X86%", "PROGRAMFILES x86", "%ProgramFiles(x86)%"),
        ("%COMMONPROGRAMFILES%", "COMMONFILES 64", "%CommonProgramFiles%"),
        ("%COMMONPROGRAMFILES_X86%", "COMMONFILES x86", "%CommonProgramFiles(x86)%"),
        ("%PUBLIC%", "PUBLIC", "%PUBLIC%"),
        ("%SYSTEMDRIVE%", "SYSTEMDRIVE", "%SYSTEMDRIVE%"),
        ("%TEMP%", "TEMP", "%TEMP%"),
        ("%DOCUMENTS%", "DOCUMENTS", "%USERPROFILE%\\Documents"),
        ("%DOWNLOADS%", "DOWNLOADS", "%USERPROFILE%\\Downloads"),
        ("%DESKTOP%", "DESKTOP", "%USERPROFILE%\\Desktop"),
    };

    // ZIP is left out on purpose: 7-Zip encrypts ZIP with ZipCrypto, the
    // broken PKZIP scheme; AES-256 lives in 7Z and SFX.
    static readonly HashSet<string> PasswordFormats = new() { "7z", "sfx" };

    // Multi-dot endings this tool makes or meets; longest first, so ".tar.gz"
    // wins over ".gz" and "Проект v1.2" keeps its ".2" in the name.
    static readonly string[] Compound =
    {
        ".sha256.txt", ".tar.zstd", ".tar.lz4", ".tar.zst", ".tar.bz2", ".tar.gz", ".tar.xz",
    };

    const string InvalidNameChars = "<>:\"/\\|?*";

    // ------------------------------------------------------------ tools

    static string Exe(string name) => OperatingSystem.IsWindows() ? name + ".exe" : name;

    /// <summary>A tool next to the program or up the tree (Tools\...), then PATH. The editors of F4 are found the same way.</summary>
    internal static string? Find(IEnumerable<string> relative, IEnumerable<string> onPath)
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
            foreach (var rel in relative)
            {
                var candidate = Path.Combine(dir.FullName, rel);
                if (File.Exists(candidate)) return candidate;
            }
        foreach (var part in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            foreach (var name in onPath)
                try { var p = Path.Combine(part, name); if (File.Exists(p)) return p; } catch { }
        return null;
    }

    public static string? SevenZip => Find(new[]
    {
        Path.Combine("Tools", "PeaZip", "res", "bin", "7z", Exe("7z")),
        Path.Combine("Tools", "PeaZip", "res", "7z", Exe("7z")),
        Path.Combine("Tools", "7zip", "bin", Exe("7z")),
        Path.Combine("Tools", "7zip", "bin", Exe("7za")),
    }, new[] { Exe("7z"), Exe("7za"), Exe("7zz") });

    public static string? Zstd => Find(new[]
    {
        Path.Combine("Tools", "PeaZip", "res", "bin", "zstd", Exe("zstd")),
        Path.Combine("Tools", "zstd", Exe("zstd")),
    }, new[] { Exe("zstd") });

    public static string? Lz4 => Find(new[]
    {
        Path.Combine("Tools", "PeaZip", "res", "bin", "lz4", Exe("lz4")),
        Path.Combine("Tools", "lz4", Exe("lz4")),
    }, new[] { Exe("lz4") });

    static string? SfxModule(string sevenZip)
    {
        var dir = Path.GetDirectoryName(sevenZip)!;
        foreach (var name in new[] { "7z.sfx", "7zCon.sfx", "7zSD.sfx", "7zS.sfx" })
            if (File.Exists(Path.Combine(dir, name))) return Path.Combine(dir, name);
        return null;
    }

    public static bool Available(string formatId) => formatId switch
    {
        "zstd" => Zstd is not null,
        "lz4" => Lz4 is not null,
        "sfx" => OperatingSystem.IsWindows() && SevenZip is { } s && SfxModule(s) is not null,
        _ => SevenZip is not null,
    };

    public static bool Encrypts(string formatId, string encryption) => encryption == "none" || PasswordFormats.Contains(formatId);

    /// <summary>Why a format chip is off, or "" when it is on offer.</summary>
    public static string DisabledReason(string formatId, string encryption)
    {
        var label = Formats.First(f => f.Id == formatId).Label;
        if (!Encrypts(formatId, encryption))
            return formatId == "zip"
                ? "ZIP не шифруем: для ZIP остался бы только старый ZipCrypto, его взламывают. AES-256 — в 7Z и SFX."
                : Lang.F("{0} не умеет шифрование: в этом формате его нет.", label);
        if (!Available(formatId))
            return formatId switch
            {
                "lz4" => "TAR.LZ4 недоступен: нет lz4.exe (Tools\\lz4).",
                "zstd" => "TAR.ZSTD недоступен: нет zstd.exe (PeaZip или Tools\\zstd).",
                "sfx" => "SFX недоступен: нет модуля 7z.sfx рядом с 7z.exe.",
                _ => Lang.F("{0} недоступен: PeaZip не найден.", label),
            };
        return "";
    }

    // ------------------------------------------------------------ names

    static (string Stem, string Ext) SplitName(string name)
    {
        foreach (var c in Compound)
            if (name.EndsWith(c, StringComparison.OrdinalIgnoreCase) && name.Length > c.Length)
                return (name[..^c.Length], name[^c.Length..]);
        var ext = Path.GetExtension(name);
        return ext.Length == 0 ? (name, "") : (name[..^ext.Length], ext);
    }

    static string Unique(string path)
    {
        if (!File.Exists(path) && !Directory.Exists(path)) return path;
        var (stem, ext) = SplitName(Path.GetFileName(path));
        var dir = Path.GetDirectoryName(path)!;
        for (int i = 2; i < 10000; i++)
        {
            var candidate = Path.Combine(dir, $"{stem}_{i:000}{ext}");
            if (!File.Exists(candidate) && !Directory.Exists(candidate)) return candidate;
        }
        throw new IOException(Lang.F("не удалось подобрать свободное имя: {0}", path));
    }

    public static string BaseName(string fullPath) =>
        Directory.Exists(fullPath) ? Path.GetFileName(fullPath) : (Path.GetFileNameWithoutExtension(fullPath) is { Length: > 0 } s ? s : Path.GetFileName(fullPath));

    static string Clean(string text) =>
        new(text.Select(c => InvalidNameChars.Contains(c) || c < 32 ? '_' : c).ToArray());

    /// <summary>"N" standing alone between separators becomes the running number.</summary>
    static string Sequence(string text, int number)
    {
        if (text.Length == 0) return text;
        var sb = new StringBuilder();
        const string separators = "._- ";
        for (int i = 0; i < text.Length; i++)
        {
            bool alone = text[i] == 'N' && (i == 0 || separators.Contains(text[i - 1])) && (i == text.Length - 1 || separators.Contains(text[i + 1]));
            sb.Append(alone ? number.ToString() : text[i].ToString());
        }
        return sb.ToString();
    }

    public static string DisplayName(string baseName, PackOptions o, int number)
    {
        var name = $"{Clean(Sequence(o.Prefix, number))}{baseName}{Clean(Sequence(o.Suffix, number))}".Trim(' ', '.');
        if (o.Underscore) name = name.Replace(' ', '_');
        return name.Length > 0 ? name : baseName;
    }

    // ------------------------------------------------------------ running tools

    sealed class Run
    {
        public readonly List<string> Tail = new();
        public Action<double, string>? Percent;
        /// <summary>Every line to the caller instead of the log (a listing, not a progress).</summary>
        public Action<string>? Raw;
    }

    // "45% 12 + dir\file": the percent 7-Zip prints with -bsp1, and the file.
    static readonly Regex SevenPercent = new(@"(\d{1,3})%(?:\s+\d+)?(?:\s+[+=U\-T]\s+(.+))?\s*$");

    static string Redact(IEnumerable<string> args) =>
        string.Join(" ", args.Select(a => a.StartsWith("-p", StringComparison.Ordinal) && a.Length > 2 ? "-p[REDACTED]" : a.Contains(' ') ? $"\"{a}\"" : a));

    /// <summary>Runs a tool to the end; Stop kills it. Lines go to the log, the percent to the bar.</summary>
    static int Exec(string exe, IReadOnlyList<string> args, string cwd, Run run, CancellationToken cancel)
    {
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = cwd,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        JobRunner.Log("RUN: " + Path.GetFileName(exe) + " " + Redact(args));
        using var p = Process.Start(info) ?? throw new InvalidOperationException(Lang.F("процесс не создан: {0}", exe));
        // No prompts: a password question would hang the run forever.
        p.StandardInput.Close();
        var gate = new object();
        void Line(string line)
        {
            if (run.Raw is { } raw)
            {
                lock (gate) raw(line);
                return;
            }
            var m = SevenPercent.Match(line);
            if (m.Success && line.TrimStart().StartsWith(m.Groups[1].Value, StringComparison.Ordinal))
            {
                if (double.TryParse(m.Groups[1].Value, out var pct)) run.Percent?.Invoke(pct, m.Groups[2].Value.Trim());
                return;
            }
            if (string.IsNullOrWhiteSpace(line)) return;
            lock (gate)
            {
                JobRunner.Log(line.TrimEnd());
                run.Tail.Add(line.TrimEnd());
                if (run.Tail.Count > 30) run.Tail.RemoveAt(0);
            }
        }
        var pumps = new[] { Task.Run(() => Pump(p.StandardOutput, Line)), Task.Run(() => Pump(p.StandardError, Line)) };
        while (!p.WaitForExit(200))
        {
            if (!cancel.IsCancellationRequested) continue;
            try { p.Kill(entireProcessTree: true); } catch { }
            p.WaitForExit();
            break;
        }
        Task.WaitAll(pumps, 2000);
        cancel.ThrowIfCancellationRequested();
        return p.ExitCode;
    }

    // 7-Zip redraws its progress with backspaces and carriage returns: they
    // end a line as well as a newline does.
    static void Pump(StreamReader reader, Action<string> line)
    {
        var sb = new StringBuilder();
        var buffer = new char[4096];
        int n;
        while ((n = reader.Read(buffer, 0, buffer.Length)) > 0)
        {
            for (int i = 0; i < n; i++)
            {
                char c = buffer[i];
                if (c is '\r' or '\n' or '\b')
                {
                    if (sb.Length > 0) { line(sb.ToString()); sb.Clear(); }
                }
                else sb.Append(c);
            }
        }
        if (sb.Length > 0) line(sb.ToString());
    }

    static void Must(int code, string what, Run run)
    {
        if (code == 0) return;
        var last = run.Tail.LastOrDefault(l => l.Contains("ERROR", StringComparison.OrdinalIgnoreCase) || l.Contains("Wrong password", StringComparison.OrdinalIgnoreCase))
                   ?? run.Tail.LastOrDefault() ?? "";
        throw new IOException($"{what} [{code}] {last}".Trim());
    }

    static string[] Progress7 => new[] { "-bsp1", "-bso1", "-bse1" };

    /// <summary>
    /// 7-Zip command line: the command, the switches, "--" and only then the
    /// names. After "--" nothing is read as a switch, and every relative name
    /// gets ".\" in front, so a file called "@list.txt" or "-x.txt" is that
    /// file - not a list of other files, not a switch (audit 06).
    /// </summary>
    static List<string> Seven(string command, IEnumerable<string> switches, string archive, IEnumerable<string>? names = null)
    {
        var args = new List<string> { command };
        args.AddRange(switches);
        args.AddRange(Progress7);
        args.Add("--");
        args.Add(Literal(archive));
        if (names is not null) args.AddRange(names.Select(Literal));
        return args;
    }

    static string Literal(string name) => Path.IsPathRooted(name) ? name : ".\\" + name;

    // ------------------------------------------------------------ packing

    /// <summary>
    /// ALT+F5: every item into its own archive in each chosen format, or all
    /// of them into one; tested after, sources removed only when every
    /// archive of theirs was made (and tested, if asked).
    /// </summary>
    public static Job PackJob(string fromDir, IReadOnlyList<string> names, string outRoot, PackOptions o)
    {
        var formats = Formats.Where(f => o.Formats.Contains(f.Id)).ToList();
        var title = Lang.T("УПАКОВКА") + $": {(names.Count == 1 ? names[0] : Lang.F("объектов {0}", names.Count))}";
        return new Job
        {
            Title = title,
            Work = (progress, cancel) =>
            {
                var bad = new List<string>();
                var seven = SevenZip ?? throw new IOException("PeaZip не найден: ни в Tools\\PeaZip, ни в Tools\\7zip, ни в PATH");
                var groups = o.Scope == "one" && names.Count > 1
                    ? new List<(string Base, List<string> Items)> { (Path.GetFileName(fromDir.TrimEnd('\\', '/')) is { Length: > 0 } d ? d : "archive", names.ToList()) }
                    : names.Select(n => (BaseName(Path.Combine(fromDir, n)), new List<string> { n })).ToList();
                int total = Math.Max(1, groups.Count * formats.Count), done = 0, number = 0;
                var temp = Path.Combine(outRoot, ".audion-pack-" + DateTime.Now.ToString("yyyyMMdd_HHmmss"));
                try
                {
                    foreach (var (baseName, items) in groups)
                    {
                        number++;
                        bool all = true;
                        var madeHere = new List<string>();
                        foreach (var f in formats)
                        {
                            cancel.ThrowIfCancellationRequested();
                            var run = new Run();
                            int step = done;
                            run.Percent = (pct, file) => progress($"{f.Label} · {baseName}" + (file.Length > 0 ? " · " + Path.GetFileName(file) : ""), (step + pct / 100) * 100 / total, -1);
                            progress($"{f.Label} · {baseName}", step * 100.0 / total, -1);
                            try
                            {
                                var made = Create(seven, f, fromDir, items, baseName, number, outRoot, temp, o, run, cancel);
                                madeHere.AddRange(made);
                                foreach (var archive in made)
                                {
                                    JobRunner.Log("OK -> " + archive);
                                    if (!o.Verify) continue;
                                    progress(Lang.F("проверка · {0}", Path.GetFileName(archive)), (step + 0.99) * 100 / total, -1);
                                    Test(seven, archive, o.Encryption == "none" ? "" : o.Password, run, cancel);
                                    JobRunner.Log("TEST OK -> " + archive);
                                }
                            }
                            catch (OperationCanceledException) { throw; }
                            catch (Exception ex)
                            {
                                all = false;
                                bad.Add($"{f.Label}: {baseName}: {ex.Message}");
                                JobRunner.Log($"[{Lang.T("УПАКОВКА")}] {f.Label}: {baseName}: {ex.Message}");
                            }
                            done++;
                        }
                        if (o.DeleteSource && all && formats.Count > 0)
                            foreach (var item in items)
                            {
                                var path = Path.Combine(fromDir, item);
                                // Never a source that holds one of its own archives (audit 07).
                                if (Directory.Exists(path) && madeHere.Any(a => PathGuard.Inside(a, path)))
                                {
                                    bad.Add(Lang.F("архив лежит внутри источника, источник не удалён: {0}", item));
                                    continue;
                                }
                                try
                                {
                                    JobRunner.Log("DELETE SOURCE -> " + path);
                                    Remove(path, cancel);
                                }
                                catch (OperationCanceledException) { throw; }
                                catch (Exception ex) { bad.Add(Lang.F("архив готов, источник не удалился: {0}", item) + " · " + ex.Message); }
                            }
                    }
                }
                finally
                {
                    try { if (Directory.Exists(temp)) Directory.Delete(temp, true); } catch { }
                }
                progress("", 100, -1);
                return bad;
            },
        };
    }

    /// <summary>
    /// Sources after packing and archives after unpacking go the way of F8 - the same guarded
    /// shell operation: an object the Recycle Bin cannot take (a share, too big for the bin) stays
    /// where it is and the job says so; it is never deleted for good in silence (audit N17).
    /// </summary>
    static void Remove(string path, CancellationToken cancel)
    {
        if (!OperatingSystem.IsWindows())
        {
            if (Directory.Exists(path)) Directory.Delete(path, true); else File.Delete(path);
            return;
        }
        var result = RecycleBin.SendMany(new[] { path }, IntPtr.Zero, (_, _) => { }, cancel);
        if (result.Cancelled) throw new OperationCanceledException(cancel);
        if (result.NoRoom.Count > 0) throw new IOException(Lang.T("корзина Windows его не примет — оставлен на месте"));
        if (result.PastBin.Count > 0) throw new IOException(Lang.T("удалён мимо корзины"));
        if (result.Failed.Count > 0) throw new IOException(string.Join("; ", result.Failed));
    }

    static string[] Encryption(string type, PackOptions o)
    {
        if (o.Encryption == "none") return Array.Empty<string>();
        if (o.Password.Length == 0) throw new IOException("нужен пароль для шифрования");
        return o.Encryption == "names" && type == "7z" ? new[] { "-p" + o.Password, "-mhe=on" } : new[] { "-p" + o.Password };
    }

    static List<string> Create(string seven, ArchiveFormat f, string fromDir, List<string> items, string baseName, int number,
                               string outRoot, string temp, PackOptions o, Run run, CancellationToken cancel)
    {
        if (!Encrypts(f.Id, o.Encryption)) throw new IOException(DisabledReason(f.Id, o.Encryption));
        var root = o.Layout == "per_folder" ? Path.Combine(outRoot, baseName) : outRoot;
        Directory.CreateDirectory(root);
        var target = Unique(Path.Combine(root, DisplayName(baseName, o, number) + f.Ext));

        switch (f.Mode)
        {
            case "direct":
                Must(Exec(seven, Seven("a", new[] { "-t" + f.Type, "-mx=" + o.Level, "-mmt=on", "-sccUTF-8" }.Concat(Encryption(f.Type, o)), target, items),
                    fromDir, run, cancel), f.Label, run);
                return new List<string> { target };

            case "direct_tar":
                Must(Exec(seven, Seven("a", new[] { "-ttar", "-sccUTF-8" }, target, items), fromDir, run, cancel), f.Label, run);
                return new List<string> { target };

            case "sfx":
                return CreateSfx(seven, fromDir, items, baseName, target, temp, o, run, cancel);

            default:
            {
                // TAR first, then the stream compressor over it.
                var stage = Path.Combine(temp, Guid.NewGuid().ToString("N")[..8]);
                Directory.CreateDirectory(stage);
                var tar = Path.Combine(stage, baseName + ".tar");
                Must(Exec(seven, Seven("a", new[] { "-ttar", "-sccUTF-8" }, tar, items), fromDir, run, cancel), "TAR", run);
                if (f.Id == "zstd")
                    Must(Exec(Zstd ?? throw new IOException(DisabledReason("zstd", "none")), new[] { "-f", "-T0", ZstdLevel(o.Level), "-o", target, tar }, stage, run, cancel), f.Label, run);
                else if (f.Id == "lz4")
                    Must(Exec(Lz4 ?? throw new IOException(DisabledReason("lz4", "none")), new[] { "-f", Lz4Level(o.Level), tar, target }, stage, run, cancel), f.Label, run);
                else
                    Must(Exec(seven, Seven("a", new[] { "-t" + f.Type, "-mx=" + o.Level, "-mmt=on", "-sccUTF-8" }, target, new[] { tar }), stage, run, cancel), f.Label, run);
                try { Directory.Delete(stage, true); } catch { }
                return new List<string> { target };
            }
        }
    }

    static string ZstdLevel(string level) => int.TryParse(level, out var n) && n > 0 ? "-" + Math.Min(19, n) : "--fast=1";
    static string Lz4Level(string level) => int.TryParse(level, out var n) && n > 0 ? "-" + Math.Min(12, n) : "--fast";

    static string SfxTail(string template, string name)
    {
        var tail = (template ?? "").Trim().Replace("{name}", name).Replace("{NAME}", name)
            .Replace("<name>", name).Replace("<NAME>", name).Replace("<имя>", name).Replace('/', '\\');
        return tail.Trim('\\');
    }

    public static string SfxInstallPath(string env, string template, string name)
    {
        var baseDir = SfxEnvs.FirstOrDefault(e => e.Key == env).Install ?? "";
        var tail = SfxTail(template, name);
        return baseDir.Length == 0 ? tail : tail.Length == 0 ? baseDir : baseDir + "\\" + tail;
    }

    static List<string> CreateSfx(string seven, string fromDir, List<string> items, string baseName, string target, string temp,
                                  PackOptions o, Run run, CancellationToken cancel)
    {
        var module = SfxModule(seven) ?? throw new IOException(DisabledReason("sfx", "none"));
        var stage = Path.Combine(temp, Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(stage);
        var payload = Path.Combine(stage, baseName + ".7z");
        Must(Exec(seven, Seven("a", new[] { "-t7z", "-mx=" + o.Level, "-mmt=on", "-sccUTF-8" }.Concat(Encryption("7z", o)), payload, items),
            fromDir, run, cancel), "SFX", run);

        var install = SfxInstallPath(o.SfxEnv, o.SfxPath, baseName);
        var config = new StringBuilder();
        config.Append(";!@Install@!UTF-8!\r\n");
        config.Append($"Title=\"{baseName.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"\r\n");
        if (install.Length > 0) config.Append($"InstallPath=\"{install.Replace("\\", "\\\\").Replace("\"", "\\\"")}\"\r\n");
        config.Append("GUIMode=\"2\"\r\n;!@InstallEnd@!\r\n");
        using (var output = File.Create(target))
        {
            output.Write(File.ReadAllBytes(module));
            output.Write(new UTF8Encoding(true).GetPreamble());
            output.Write(Encoding.UTF8.GetBytes(config.ToString()));
            using var body = File.OpenRead(payload);
            body.CopyTo(output);
        }
        JobRunner.Log("SFX INSTALL PATH -> " + install);

        var made = new List<string> { target };
        foreach (var w in SfxWrappers.Where(w => o.SfxWrappers.Contains(w.Id)))
        {
            var wrapped = Unique(target + w.Ext);
            if (w.Id == "zstd")
                Must(Exec(Zstd ?? throw new IOException(DisabledReason("zstd", "none")), new[] { "-f", "-T0", "--fast=1", "-o", wrapped, target }, Path.GetDirectoryName(target)!, run, cancel), "SFX ZSTD", run);
            else
            {
                var switches = new List<string> { "-t" + (w.Id == "gz" ? "gzip" : w.Id), "-sccUTF-8" };
                if (w.Id != "tar") switches.AddRange(new[] { "-mx=0", "-mmt=on" });
                Must(Exec(seven, Seven("a", switches, wrapped, new[] { target }), Path.GetDirectoryName(target)!, run, cancel), "SFX " + w.Label, run);
            }
            made.Add(wrapped);
        }
        return made;
    }

    /// <summary>The check after packing: 7-Zip's own test, zstd -t and lz4 -t for their streams.</summary>
    static void Test(string seven, string archive, string password, Run run, CancellationToken cancel)
    {
        var lower = archive.ToLowerInvariant();
        if (lower.EndsWith(".zst") || lower.EndsWith(".zstd"))
            Must(Exec(Zstd!, new[] { "-t", archive }, Path.GetDirectoryName(archive)!, run, cancel), "ZSTD TEST", run);
        else if (lower.EndsWith(".lz4"))
            Must(Exec(Lz4!, new[] { "-t", archive }, Path.GetDirectoryName(archive)!, run, cancel), "LZ4 TEST", run);
        else
            Must(Exec(seven, Seven("t", new[] { "-sccUTF-8", "-p" + password }, archive), Path.GetDirectoryName(archive)!, run, cancel), "TEST", run);
    }

    // ------------------------------------------------------------ unpacking

    static readonly string[] OuterStreams = { ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".tar.zst", ".tar.zstd", ".tzst", ".tar.lz4" };

    static readonly HashSet<string> ArchiveExts = new(StringComparer.OrdinalIgnoreCase)
    {
        ".7z", ".zip", ".rar", ".tar", ".gz", ".tgz", ".bz2", ".tbz2", ".tbz", ".xz", ".txz", ".zst", ".zstd", ".tzst", ".lz4",
        ".cab", ".iso", ".wim", ".001", ".zipx", ".arj", ".lzh", ".lha", ".z", ".cpio", ".rpm", ".deb", ".dmg", ".vhd", ".vhdx",
    };

    static readonly Regex RarPart = new(@"\.part(\d+)\.rar$", RegexOptions.IgnoreCase);
    static readonly Regex Volume = new(@"\.(\d{3})$");

    /// <summary>
    /// Is this the file to open: an archive, and the first volume of a split
    /// set (".001", ".part1.rar") - the others are read through it.
    /// </summary>
    public static bool IsArchive(string name)
    {
        if (RarPart.Match(name) is { Success: true } rp) return int.Parse(rp.Groups[1].Value) == 1;
        if (Volume.Match(name) is { Success: true } v) return v.Groups[1].Value == "001";
        return ArchiveExts.Contains(Path.GetExtension(name));
    }

    /// <summary>The name of the folder an archive unpacks into: without every archive ending.</summary>
    public static string StemOf(string name)
    {
        var s = name;
        if (RarPart.Match(s) is { Success: true } rp) s = s[..rp.Index];
        else if (Volume.Match(s) is { Success: true } v) s = s[..v.Index];
        foreach (var outer in OuterStreams)
            if (s.EndsWith(outer, StringComparison.OrdinalIgnoreCase)) return s[..^outer.Length];
        var ext = Path.GetExtension(s);
        return ext.Length > 0 && ArchiveExts.Contains(ext) ? s[..^ext.Length] : s;
    }

    /// <summary>
    /// Every file of a split set, for deleting after a good unpack - by the
    /// exact base name and a volume number, never by a wildcard that would
    /// also take "a.part-backup.part1.rar" for the set of "a.part1.rar" (audit 05).
    /// Taken before unpacking, so a file appearing meanwhile is not included.
    /// </summary>
    static List<string> Volumes(string first)
    {
        var dir = Path.GetDirectoryName(first)!;
        var name = Path.GetFileName(first);
        Regex? set = null;
        if (RarPart.Match(name) is { Success: true } rp)
            set = new Regex("^" + Regex.Escape(name[..rp.Index]) + @"\.part\d+\.rar$", RegexOptions.IgnoreCase);
        else if (Volume.Match(name) is { Success: true } v)
            set = new Regex("^" + Regex.Escape(name[..v.Index]) + @"\.\d{3}$", RegexOptions.IgnoreCase);
        else if (name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            set = new Regex("^" + Regex.Escape(name[..^4]) + @"\.(zip|z\d{2})$", RegexOptions.IgnoreCase);
        if (set is null) return new List<string> { first };
        return Directory.EnumerateFiles(dir).Where(f => set.IsMatch(Path.GetFileName(f))).ToList();
    }

    /// <summary>
    /// The first-level names inside an archive (7z l -slt). Runs through Exec
    /// like every other 7-Zip call, so СТОП ends it and its process (audit 11).
    /// </summary>
    static HashSet<string> TopLevel(string seven, string archive, string password, Run run, CancellationToken cancel)
    {
        var top = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var errors = new List<string>();
        var listing = new Run
        {
            Raw = line =>
            {
                if (line.StartsWith("Path = ", StringComparison.Ordinal))
                {
                    var path = line[7..].Replace('/', '\\').Trim('\\');
                    if (path.Length == 0) return;
                    int cut = path.IndexOf('\\');
                    top.Add(cut < 0 ? path : path[..cut]);
                }
                else if (line.Contains("ERROR", StringComparison.OrdinalIgnoreCase) || line.Contains("Wrong password", StringComparison.OrdinalIgnoreCase))
                    errors.Add(line.Trim());
            },
        };
        int code = Exec(seven, Seven("l", new[] { "-slt", "-ba", "-sccUTF-8", "-p" + password }, archive), Path.GetDirectoryName(archive)!, listing, cancel);
        if (code != 0)
        {
            run.Tail.AddRange(errors);
            throw new IOException(Lang.F("архив не читается [{0}] {1}", code, errors.FirstOrDefault() ?? ""));
        }
        return top;
    }

    /// <summary>
    /// ALT+F9: many archives at once. Smart: an archive holding one folder
    /// (or one file) lands as it is; one with a loose heap of files gets a
    /// folder of its own name. TAR inside GZ/XZ/BZ2/ZSTD/LZ4 opens through.
    /// </summary>
    public static Job UnpackJob(IReadOnlyList<string> archives, string? otherRoot, UnpackOptions o)
    {
        var title = Lang.T("РАСПАКОВКА") + $": {(archives.Count == 1 ? Path.GetFileName(archives[0]) : Lang.F("архивов {0}", archives.Count))}";
        return new Job
        {
            Title = title,
            Work = (progress, cancel) =>
            {
                var bad = new List<string>();
                var seven = SevenZip ?? throw new IOException("PeaZip не найден: ни в Tools\\PeaZip, ни в Tools\\7zip, ни в PATH");
                var overwrite = o.Overwrite switch { "overwrite" => "-aoa", "skip" => "-aos", _ => "-aou" };
                for (int i = 0; i < archives.Count; i++)
                {
                    cancel.ThrowIfCancellationRequested();
                    var archive = archives[i];
                    var name = Path.GetFileName(archive);
                    var root = o.Target == "here" || otherRoot is null ? Path.GetDirectoryName(archive)! : otherRoot;
                    var run = new Run();
                    int step = i;
                    run.Percent = (pct, file) => progress(name + (file.Length > 0 ? " · " + Path.GetFileName(file) : ""), (step + pct / 100) * 100 / archives.Count, -1);
                    progress(name, step * 100.0 / archives.Count, -1);
                    string? stage = null;
                    var parts = o.DeleteArchives ? Volumes(archive) : new List<string>();
                    try
                    {
                        var inner = archive;
                        var lower = name.ToLowerInvariant();
                        if (OuterStreams.Any(lower.EndsWith))
                        {
                            // Two layers: the stream first, into a hidden stage next to the target.
                            stage = Path.Combine(root, ".audion-unpack-" + Guid.NewGuid().ToString("N")[..8]);
                            Directory.CreateDirectory(stage);
                            if (lower.EndsWith(".lz4"))
                            {
                                var tarOut = Path.Combine(stage, StemOf(name) + ".tar");
                                Must(Exec(Lz4 ?? throw new IOException(DisabledReason("lz4", "none")), new[] { "-d", "-f", archive, tarOut }, stage, run, cancel), "LZ4", run);
                            }
                            else
                                Must(Exec(seven, Seven("x", new[] { "-sccUTF-8", "-y", "-o" + stage }, archive), stage, run, cancel), "7Z", run);
                            inner = Directory.EnumerateFiles(stage).FirstOrDefault(f => f.EndsWith(".tar", StringComparison.OrdinalIgnoreCase))
                                    ?? Directory.EnumerateFiles(stage).First();
                        }

                        string dest;
                        if (o.Mode == "flat") dest = root;
                        else
                        {
                            // Smart: one folder (or file) inside lands as it is - unless that
                            // name is already taken here; then it gets a folder of its own
                            // rather than mixing with what is there under renamed names.
                            var top = o.Mode == "folder" ? null : TopLevel(seven, inner, o.Password, run, cancel);
                            bool wrap = top is null || top.Count != 1
                                        || (o.Overwrite == "rename" && (Directory.Exists(Path.Combine(root, top.First())) || File.Exists(Path.Combine(root, top.First()))));
                            dest = wrap ? Path.Combine(root, StemOf(name)) : root;
                            if (wrap && o.Overwrite == "rename" && (Directory.Exists(dest) || File.Exists(dest))) dest = UniqueFolder(dest);
                        }
                        Directory.CreateDirectory(dest);
                        JobRunner.Log($"UNPACK {archive} -> {dest}");
                        int code = Exec(seven, Seven("x", new[] { "-sccUTF-8", overwrite, "-p" + o.Password, "-o" + dest }, inner), dest, run, cancel);
                        // 1 is a warning (a locked file, a skipped name); 2 and up failed.
                        if (code >= 2) Must(code, "7Z", run);
                        if (code == 1) bad.Add(Lang.F("с предупреждениями: {0}", name));
                        else if (o.DeleteArchives && o.Overwrite == "skip")
                            // Skipped names were not taken out: the archive may be their only copy.
                            JobRunner.Log("KEEP ARCHIVE (skip) -> " + archive);
                        else if (o.DeleteArchives)
                            foreach (var part in parts)
                            {
                                JobRunner.Log("DELETE ARCHIVE -> " + part);
                                try { Remove(part, cancel); }
                                catch (OperationCanceledException) { throw; }
                                catch (Exception ex) { bad.Add(Lang.F("распаковано, архив не удалился: {0}", Path.GetFileName(part)) + " · " + ex.Message); }
                            }
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (Exception ex)
                    {
                        bad.Add($"{name}: {ex.Message}");
                        JobRunner.Log($"[{Lang.T("РАСПАКОВКА")}] {name}: {ex.Message}");
                    }
                    finally
                    {
                        if (stage is not null) try { Directory.Delete(stage, true); } catch { }
                    }
                }
                progress("", 100, -1);
                return bad;
            },
        };
    }

    static string UniqueFolder(string path)
    {
        for (int i = 2; i < 10000; i++)
        {
            var candidate = $"{path} ({i})";
            if (!Directory.Exists(candidate) && !File.Exists(candidate)) return candidate;
        }
        return path;
    }
}
