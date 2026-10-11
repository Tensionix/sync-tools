using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;

namespace AudionSyncTools.Core;

/// <summary>
/// Ctrl+Enter: a terminal for the row under the cursor. A folder - a terminal
/// in it; a script or a program - run in a terminal that stays open after it
/// ends; any other file - a terminal in its folder. Windows Terminal when it
/// is here, otherwise a console window of its own.
///
/// No path of the user ever reaches a command line: both cmd and Windows
/// Terminal expand %NAME% there, even inside quotes, and would run a
/// neighbouring file (audit 5.4.1 N1). Each launch writes a small script in
/// ._runtime\terminal and starts only that; the path lives inside the script,
/// written by the rules of its language - %% in a .cmd, '' in a .ps1. Not even
/// the script's own path is on the command line - the program's folder may
/// carry a % too: the process starts in the scripts' folder (Plan.Start) and
/// names the script alone, a name made of digits; Windows Terminal gets "-d .".
/// cmd starts with /v:off: delayed expansion switched on in the registry would
/// read !NAME! in a path as a variable (audit 5.4.1, second pass). Not setlocal
/// in the script - its end would take the window back out of the file's folder.
/// </summary>
public static class Terminal
{
    /// <summary>What to start: the program, its command line, the target's folder, the script, the folder to start in.</summary>
    public sealed record Plan(string File, string Args, string Dir, bool Runs, string Script, string Start);

    static readonly string[] CmdKinds = { ".cmd", ".bat", ".exe", ".com" };
    static int _count;

    /// <summary>The kinds Ctrl+Enter runs rather than just opening a terminal beside.</summary>
    public static bool Runnable(string path) =>
        Path.GetExtension(path).ToLowerInvariant() is var ext && (ext is ".ps1" or ".py" || CmdKinds.Contains(ext));

    // In a batch file everything inside double quotes is literal except %: doubled, it stays one.
    static string Cmd(string s) => s.Replace("%", "%%");

    // In single quotes PowerShell expands nothing; a quote itself is doubled.
    static string Ps(string s) => s.Replace("'", "''");

    /// <summary>
    /// The script of one launch. A .cmd is read line by line: its first line
    /// switches the console to UTF-8 so a Cyrillic path stays intact; lines
    /// start with @ instead of "echo off", which would hide the prompt of the
    /// terminal left open. Scripts older than a day go.
    /// </summary>
    static string Script(string scratch, string ext, string body)
    {
        Directory.CreateDirectory(scratch);
        foreach (var old in Directory.EnumerateFiles(scratch, "run-*"))
            try { if (File.GetLastWriteTime(old) < DateTime.Now.AddDays(-1)) File.Delete(old); } catch { }
        // Two copies of the program launching at once: the process number keeps the names apart.
        var path = Path.Combine(scratch, $"run-{Environment.ProcessId}-{DateTime.Now:yyyyMMdd-HHmmss-fff}-{Interlocked.Increment(ref _count)}{ext}");
        // Windows PowerShell 5.1 reads a script without BOM in the ANSI code page.
        File.WriteAllText(path, body, new UTF8Encoding(encoderShouldEmitUTF8Identifier: ext == ".ps1"));
        return path;
    }

    /// <summary>The terminal starts the command; without one the command gets its own console.</summary>
    static Plan Via(string? wt, string file, string args, string dir, bool runs, string script)
    {
        var start = Path.GetDirectoryName(script)!;
        return wt is null ? new Plan(file, args, dir, runs, script, start) : new Plan(wt, $"-d . {file} {args}", dir, runs, script, start);
    }

    public static Plan For(string path, bool isDir, string? wt, string shell, string scratch)
    {
        var dir = isDir ? path : Path.GetDirectoryName(path) ?? path;
        var ext = isDir ? "" : Path.GetExtension(path).ToLowerInvariant();
        if (CmdKinds.Contains(ext) || ext == ".py")
        {
            // cmd /k keeps the window after the file ends, in its folder: its output stays to be read.
            var run = ext == ".py" ? $"@py \"{Cmd(path)}\"" : $"@\"{Cmd(path)}\"";
            var script = Script(scratch, ".cmd", $"@chcp 65001 >nul\r\n@cd /d \"{Cmd(dir)}\"\r\n{run}\r\n");
            // ".\" names the current folder outright: a bare name is looked up in a folder whose path cmd reads anew and would break on a %.
            return Via(wt, "cmd.exe", $"/v:off /k .\\{Path.GetFileName(script)}", dir, true, script);
        }
        var body = $"Set-Location -LiteralPath '{Ps(dir)}'\r\n" + (ext == ".ps1" ? $"& '{Ps(path)}'\r\n" : "");
        var ps = Script(scratch, ".ps1", body);
        return Via(wt, shell, $"-NoLogo -NoExit -ExecutionPolicy Bypass -File {Path.GetFileName(ps)}", dir, ext == ".ps1", ps);
    }

    /// <summary>The project's own portable Windows Terminal (Tools\terminal, MIT) first, then the installed one.</summary>
    public static string? WindowsTerminal()
    {
        if (!OperatingSystem.IsWindows()) return null;
        if (Archiver.Find(new[] { Path.Combine("Tools", "terminal", "wt.exe") }, new[] { "wt.exe" }) is { } found) return found;
        var alias = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "wt.exe");
        return File.Exists(alias) ? alias : null;
    }

    /// <summary>
    /// F4 with a console editor (Edit, micro). Inside the terminal - through a
    /// script, as Ctrl+Enter; the window closes with the editor. Without a
    /// terminal the editor starts straight, its file as a plain argument: no
    /// shell reads it.
    /// </summary>
    public static Plan ForEditor(string editor, string file, string? wt, string scratch)
    {
        var dir = Path.GetDirectoryName(file) ?? "";
        if (wt is null) return new Plan(editor, $"\"{file}\"", dir, true, "", dir);
        var script = Script(scratch, ".cmd", $"@chcp 65001 >nul\r\n@cd /d \"{Cmd(dir)}\"\r\n@\"{Cmd(editor)}\" \"{Cmd(file)}\"\r\n");
        return new Plan(wt, $"-d . cmd.exe /v:off /c .\\{Path.GetFileName(script)}", dir, true, script, scratch);
    }

    /// <summary>PowerShell 7 when installed, Windows PowerShell otherwise.</summary>
    public static string Shell() => OnPath("pwsh.exe") ? "pwsh.exe" : "powershell.exe";

    public static bool OnPath(string exe) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Any(dir => { try { return File.Exists(Path.Combine(dir.Trim(), exe)); } catch { return false; } });
}
