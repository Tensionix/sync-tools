using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

namespace AudionSyncTools.Core;

/// <summary>
/// The scripts of the engine (Engine\Scripts, Tunnel\, Tunnel\RemoteDesktop) run by the program's
/// own PowerShell 7 - App\AudionPs.exe. A button of the window does nothing a console cannot: it
/// starts the same script a wrapper of Runs\ starts.
/// </summary>
public static class Scripts
{
    static string Quote(string s) => "'" + s.Replace("'", "''") + "'";

    /// <summary>
    /// A job of the queue with the output in the journal. Through -Command with a preamble: the
    /// output of a redirected PowerShell is in the OEM code page otherwise, and Russian arrives
    /// in the journal as rubbish. An argument that starts with "-" is a switch or a parameter
    /// name and goes as it is; anything else is a value and is quoted.
    /// </summary>
    public static Job? Job(string title, string scriptRelative, IEnumerable<string>? args = null, bool refresh = false, bool dataRoot = true)
    {
        var path = Paths.Script(scriptRelative);
        if (Paths.Ps is not { } ps)
        {
            Journal.Add(Lang.T("[окно] нет PowerShell программы: App\\AudionPs.exe не собран"));
            return null;
        }
        if (!File.Exists(path))
        {
            Journal.Add(Lang.F("[окно] нет файла: {0}", path));
            return null;
        }
        return new Job
        {
            Title = title,
            Exe = ps,
            Args = new List<string> { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", Inner(path, args, dataRoot) },
            Refresh = refresh,
        };
    }

    /// <summary>
    /// The command a script is run by: its output in UTF-8, the data folder named, its exit code
    /// passed on. A script that stops on an error is a failure - without the catch its error was
    /// printed and the run ended with 0, "ready" in the journal over a red line.
    ///
    /// The code is the one "-File" gives, the way every wrapper and every check starts a script:
    /// the number of its own "exit", and 0 when it ran to its end. "exit $LASTEXITCODE" stood
    /// here, and that variable also holds the code of the last program a script started: a script
    /// that dealt with a refusal of ssh or robocopy and ended without an exit of its own was
    /// "code 3" in the window and 0 everywhere else. The success of the call tells the two
    /// apart - it is false only after an exit that is not zero (tried on twelve kinds of endings).
    /// </summary>
    static string Inner(string path, IEnumerable<string>? args, bool dataRoot)
    {
        var inner = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); try { & " + Quote(path);
        var all = new List<string>(args ?? Enumerable.Empty<string>());
        // The script works with the same data folder the window does - never with a guess of its own.
        if (dataRoot && DataRoot.Chosen && !all.Contains("-Root") && !all.Contains("-DataRoot"))
        {
            all.Add("-Root");
            all.Add(DataRoot.Path_);
        }
        foreach (var item in all) inner += " " + (item.StartsWith('-') ? item : Quote(item));
        return inner + "; $ran = $? } catch { Write-Host ('[script] stopped: ' + $_.Exception.Message); exit 1 }; if ($ran) { exit 0 }; exit $(if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 })";
    }

    /// <summary>
    /// A script asked a question - what a wizard shows before it asks (-Describe): run quietly,
    /// its output returned, nothing in the journal. It starts a process: call it off the window's thread.
    /// </summary>
    public static (int Code, string Output) Capture(string scriptRelative, IEnumerable<string>? args = null, bool dataRoot = true)
    {
        var path = Paths.Script(scriptRelative);
        if (Paths.Ps is not { } ps || !File.Exists(path)) return (-1, "");
        var info = new ProcessStartInfo(ps)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8, WorkingDirectory = Paths.Root,
        };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", Inner(path, args, dataRoot) }) info.ArgumentList.Add(arg);
        try
        {
            using var process = Process.Start(info);
            if (process is null) return (-1, "");
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(30000)) { try { process.Kill(entireProcessTree: true); } catch { } return (-1, ""); }
            return (process.ExitCode, output.Result + errors.Result);
        }
        catch { return (-1, ""); }
    }

    /// <summary>
    /// A script that talks to the owner - asks for a password, shows a wizard in the console -
    /// opens in a console window of its own and is not waited for.
    /// </summary>
    public static bool Console(string scriptRelative, IEnumerable<string>? args = null, bool dataRoot = true)
    {
        var path = Paths.Script(scriptRelative);
        if (Paths.Ps is not { } ps || !File.Exists(path))
        {
            Journal.Add(Lang.F("[окно] нет файла: {0}", File.Exists(path) ? "App\\AudionPs.exe" : path));
            return false;
        }
        var info = new ProcessStartInfo(ps) { UseShellExecute = true, WorkingDirectory = Paths.Root };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path }) info.ArgumentList.Add(arg);
        var all = new List<string>(args ?? Enumerable.Empty<string>());
        if (dataRoot && DataRoot.Chosen && !all.Contains("-Root") && !all.Contains("-DataRoot"))
        {
            all.Add("-Root");
            all.Add(DataRoot.Path_);
        }
        foreach (var item in all) info.ArgumentList.Add(item);
        try
        {
            Process.Start(info);
            return true;
        }
        catch (Exception ex)
        {
            Journal.Add(Lang.F("[окно] не запустилось: {0}", ex.Message));
            return false;
        }
    }

    /// <summary>
    /// A wrapper (.cmd) in a console window of its own: a script that is a conversation - rclone
    /// asking for a kind, a name, a login, a wizard of the router - needs a real console where
    /// the owner answers. The quotes are put here: a folder like "Audion Backup Laptop" must
    /// arrive as one argument. The process is returned so the window may wait for its end.
    /// </summary>
    public static Process? Wrapper(string relative, IEnumerable<string>? args = null, bool dataRoot = false)
    {
        var path = Paths.Script(relative);
        if (!File.Exists(path))
        {
            Journal.Add(Lang.F("[окно] нет файла: {0}", path));
            return null;
        }
        var all = new List<string>(args ?? Enumerable.Empty<string>());
        if (dataRoot && DataRoot.Chosen && !all.Contains("-Root"))
        {
            all.Add("-Root");
            all.Add(DataRoot.Path_);
        }
        var quoted = all.Select(one => one.Any(c => char.IsWhiteSpace(c) || c == '"') ? "\"" + one.Replace("\"", "\\\"") + "\"" : one);
        var info = new ProcessStartInfo(path)
        {
            UseShellExecute = true,
            Arguments = string.Join(" ", quoted),
            WorkingDirectory = Path.GetDirectoryName(path)!,
        };
        try { return Process.Start(info); }
        catch (Exception ex)
        {
            Journal.Add(Lang.F("[окно] не запустилось: {0}", ex.Message));
            return null;
        }
    }
}
