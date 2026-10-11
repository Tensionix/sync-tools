using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Security.Principal;
using Avalonia;

namespace AudionSyncTools;

class Program
{
    /// <summary>The start was refused administrator rights once: it is not asked again.</summary>
    public static bool NoAdmin { get; private set; }

    public static bool IsAdmin { get; private set; }

    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static void Main(string[] args)
    {
        // Before anything that can fail: an end of the program at its very start leaves logs\gui-crash-*.log too.
        Core.CrashGuard.Early();
        NoAdmin = args.Any(a => string.Equals(a, "--no-admin", StringComparison.OrdinalIgnoreCase));
        // -Root "<folder>" - the data folder of this run, as Start.exe took it before and as every
        // wrapper takes it. Read before anything asks where the data is; the relaunch with the
        // rights of an administrator passes it on with the other arguments.
        for (int i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            string? named = null;
            if (string.Equals(arg, "-Root", StringComparison.OrdinalIgnoreCase) || string.Equals(arg, "--root", StringComparison.OrdinalIgnoreCase))
                named = i + 1 < args.Length ? args[i + 1] : "";
            else if (arg.StartsWith("--root=", StringComparison.OrdinalIgnoreCase) || arg.StartsWith("-Root:", StringComparison.OrdinalIgnoreCase))
                named = arg[(arg.IndexOfAny(new[] { '=', ':' }) + 1)..];
            if (named is null) continue;
            if (named.Trim().Length > 0) Core.DataRoot.Name(named);
            break;
        }
        IsAdmin = OperatingSystem.IsWindows() && new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
        if (Elevate(args)) return;
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
    }

    /// <summary>
    /// The program is an administrative one: it manages the services of the tunnels and sshd, and
    /// asking for the rights piece by piece at the wrong moment is worse than once at the start.
    /// A refusal does not stop it - the mirror, the keys and the panels work without the rights -
    /// and is remembered by "--no-admin", so the question never comes in a loop. A build run
    /// straight from bin\ (Debug) starts as it is: it is the one checked from a plain session.
    /// </summary>
    static bool Elevate(string[] args)
    {
#if DEBUG
        return false;
#else
        if (IsAdmin || NoAdmin || !OperatingSystem.IsWindows() || Environment.ProcessPath is not { } exe) return false;
        var info = new ProcessStartInfo(exe) { UseShellExecute = true, Verb = "runas" };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        try
        {
            Process.Start(info);
            return true;
        }
        catch (Win32Exception)
        {
            // Refused at the prompt: go on as the user, and say so in the window.
            NoAdmin = true;
            return false;
        }
#endif
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            // JetBrains Mono (SIL OFL, Assets\Fonts\JetBrainsMono) ships inside the program like Inter:
            // the panels' font by default, with Cyrillic, nothing to fetch or install.
            .ConfigureFonts(fonts => fonts.AddFontCollection(new Avalonia.Media.Fonts.EmbeddedFontCollection(
                new Uri("fonts:JetBrainsMono"), new Uri("avares://AudionSyncTools/Assets/Fonts/JetBrainsMono"))))
            // Drop-downs and tooltips are drawn inside the window, not as separate native windows:
            // a window capture shows them too.
            .With(new Win32PlatformOptions { OverlayPopups = true })
            .LogToTrace();
}
