using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// REMOTE: a terminal to a machine. It goes by the same route the panel does - the panel went
/// over cloudflared once while the terminal knocked at home and was silent. The straight road
/// opens ssh by the address; a jump cannot be passed that way - ProxyJump lives in ~\.ssh\config
/// and is known to ssh alone - so the far roads go by a host name of that file.
/// </summary>
public partial class MainWindow
{
    /// <summary>
    /// What sessions are opened with. The owner's choice is the strongest; with none, the
    /// program's own portable Windows Terminal (Tools\terminal) - it travels with the program;
    /// without that the console of the system, which is everywhere.
    /// </summary>
    string? FindTerminal()
    {
        if (_settings.TerminalApp.Length > 0 && File.Exists(_settings.TerminalApp)) return _settings.TerminalApp;
        var own = Paths.Script(Path.Combine("Tools", "terminal", "wt.exe"));
        return File.Exists(own) ? own : null;
    }

    /// <summary>The caption says what the machines open with now: the button is a setting, not an action.</summary>
    void UpdateTerminalCaption()
    {
        if (!_barButtons.TryGetValue("TerminalAppButton", out var button)) return;
        var app = FindTerminal();
        var name = app is null ? Lang.T("системный")
            : app.StartsWith(Paths.Script(Path.Combine("Tools", "terminal")), StringComparison.OrdinalIgnoreCase) ? Lang.T("свой")
            : Path.GetFileNameWithoutExtension(app);
        // The whole caption is translated, not the value at its end: an English window showed "ТЕРМИНАЛ: own" otherwise.
        if (button.Content is StackPanel { Children.Count: > 0 } stack && stack.Children[0] is TextBlock caption)
            caption.Text = Lang.F("ТЕРМИНАЛ: {0}", name);
    }

    /// <summary>TABBY: found by the program itself - beside it, in the neighbouring Audion folders, where it is usually installed - and asked for only when it is nowhere.</summary>
    async void SelectTabby()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var guesses = new[]
        {
            Path.Combine(Path.GetDirectoryName(Paths.Root) ?? "", "Audion Tabby", "Tabby.exe"),
            Paths.Script(Path.Combine("Tools", "tabby", "Tabby.exe")),
            Path.Combine(local, "Programs", "Tabby", "Tabby.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Tabby", "Tabby.exe"),
        };
        var found = guesses.FirstOrDefault(File.Exists);
        if (found is null)
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = Lang.T("Где лежит Tabby.exe"),
                AllowMultiple = false,
                FileTypeFilter = new[]
                {
                    new FilePickerFileType("Tabby (Tabby.exe)") { Patterns = new[] { "Tabby.exe" } },
                    new FilePickerFileType(Lang.T("Программы (*.exe)")) { Patterns = new[] { "*.exe" } },
                },
            });
            if (files.Count > 0) found = files[0].TryGetLocalPath();
        }
        if (found is null) return;
        _settings.TerminalApp = found;
        _settings.Save();
        UpdateTerminalCaption();
        Journal.Add("");
        Journal.Add(Lang.T("терминал: ") + found);
    }

    void OpenTerminal(Target target)
    {
        var caption = target.Caption;
        // A target may have a host of its own in ~\.ssh\config: MAIN VPS goes that way - it has no home address at all.
        if (target.SshHost.Length > 0)
        {
            if (StartConsole("ssh", target.SshHost)) SetStatus(Lang.F("терминал {0}: ssh {1}", target.Key, target.SshHost));
            return;
        }
        // HOME and WORK were set up beforehand without addresses: until they are written in, the button says so instead of dropping ssh into the void.
        if (!target.HasAddress)
        {
            SetStatus(Lang.F("{0}: адреса нет - заводим", caption));
            Act("SetupTargetsButton", "АДРЕСА");
            return;
        }

        var route = Sources.All.ContainsKey(target.Key) ? Sources.RouteName(target.Key) : "";
        // The names of the routes in ~\.ssh\config: base-direct, base-cf, laptop-ssh. Through SECOND VPS
        // the name is the machine's own - the jump is described there, in the config.
        var hostName = route switch
        {
            // The same choice the panel makes: the machine's own forward first, if the config has it, else the jump through MAIN VPS.
            Sources.RouteMain => Ssh.Knows(target.Key + "-ssh") ? target.Key + "-ssh" : target.Key + "-direct",
            Sources.RouteCf => target.Key + "-cf",
            Sources.RouteVia => target.Key,
            _ => "",
        };

        bool direct = Sources.LanUp.TryGetValue(target.Key, out var up) && up;
        if (hostName.Length == 0)
        {
            if (direct)
            {
                string address = target.Lan, user = target.User, keyFile = "", knownHosts = "";
                int port = target.SshPort;
                // The endpoint rclone really uses, when the transport describes it: the same address, key and known hosts.
                if (Sources.All.TryGetValue(target.Key, out var source) && Rclone.Configured(source.Remote)
                    && Rclone.Transports().TryGetValue(source.Remote.Split(':', 2)[0], out var config)
                    && config.GetValueOrDefault("type", "") == "sftp" && !config.ContainsKey("ssh") && config.GetValueOrDefault("host", "").Length > 0)
                {
                    address = config["host"];
                    user = config.GetValueOrDefault("user", user);
                    keyFile = config.GetValueOrDefault("key_file", "");
                    knownHosts = config.GetValueOrDefault("known_hosts_file", "");
                    if (int.TryParse(config.GetValueOrDefault("port", ""), out var p) && p is > 0 and < 65536) port = p;
                }
                var (file, arguments) = TerminalLaunch(FindTerminal(), address, user, port, keyFile, knownHosts);
                try
                {
                    Process.Start(new ProcessStartInfo(file) { UseShellExecute = true, Arguments = arguments });
                    SetStatus(Lang.F("терминал {0}: домашний путь", target.Key));
                }
                catch (Exception ex) { Journal.Add(Lang.T("[окно] ") + ex.Message); }
                return;
            }
            hostName = target.Key;
        }
        else if (!Ssh.Knows(hostName))
        {
            // A route is chosen and ssh has no name for it: better said than going the wrong way in silence.
            SetStatus(Lang.F("{0}: маршрута {1} нет в ~\\.ssh\\config", caption, hostName));
            return;
        }
        if (StartConsole("ssh", hostName)) SetStatus(Lang.F("терминал {0}: ssh {1}", target.Key, hostName));
    }

    /// <summary>A program in a console window of its own: cmd /c start "" ssh name.</summary>
    static bool StartConsole(string program, string argument)
    {
        try
        {
            var info = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true };
            foreach (var arg in new[] { "/c", "start", "", program, argument }) info.ArgumentList.Add(arg);
            Process.Start(info)?.Dispose();
            return true;
        }
        catch (Exception ex)
        {
            Journal.Add(Lang.T("[окно] ") + ex.Message);
            return false;
        }
    }

    static readonly Regex QuoteRun = new(@"(\\*)""", RegexOptions.Compiled);
    static readonly Regex TailSlashes = new(@"(\\+)$", RegexOptions.Compiled);

    /// <summary>Windows argv quoting; an option may itself hold the quotes of an SSH config.</summary>
    static string Quote(string value, bool forWindowsTerminal = false)
    {
        var escaped = QuoteRun.Replace(value, "$1$1\\\"");
        if (!forWindowsTerminal || value.Contains(' ')) escaped = TailSlashes.Replace(escaped, "$1$1");
        // wt rebuilds the child command line, adding quotes only around spaces: the child's escaped
        // quotes are kept through wt's own parsing, and its command separator is special even in quotes.
        if (forWindowsTerminal) return Quote(escaped.Replace(";", "\\;"));
        return "\"" + escaped + "\"";
    }

    /// <summary>Tabby takes ssh://; any other terminal gets ssh.exe with the address, the key and the known hosts of the transport.</summary>
    static (string File, string Arguments) TerminalLaunch(string? terminal, string address, string user, int port, string keyFile, string knownHosts)
    {
        var name = terminal is null ? "" : Path.GetFileName(terminal);
        if (terminal is not null && name.Equals("Tabby.exe", StringComparison.OrdinalIgnoreCase))
        {
            var host = address.Contains(':') ? "[" + address + "]" : address;
            return (terminal, Quote($"ssh://{Uri.EscapeDataString(user)}@{host}:{port}"));
        }
        var args = new List<string> { "-p", port.ToString(), "-l", user, "-o", "StrictHostKeyChecking=yes" };
        if (keyFile.Length > 0) args.AddRange(new[] { "-i", keyFile, "-o", "IdentitiesOnly=yes" });
        if (knownHosts.Length > 0) args.AddRange(new[] { "-o", $"UserKnownHostsFile=\"{knownHosts}\"" });
        args.Add(address);
        var file = "ssh.exe";
        bool viaWt = terminal is not null && (name.Equals("wt.exe", StringComparison.OrdinalIgnoreCase) || name.Equals("WindowsTerminal.exe", StringComparison.OrdinalIgnoreCase));
        if (viaWt)
        {
            file = terminal!;
            args.InsertRange(0, new[] { "new-tab", "ssh.exe" });
        }
        return (file, string.Join(" ", args.Select(a => Quote(a, viaWt))));
    }
}
