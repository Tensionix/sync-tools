// Audion Sync Tools - launcher.
//
// The program itself lives in App\ with its runtime and the PowerShell it carries; the root of
// the project keeps one Start.exe with the program's mark, as every Audion tool does. All it
// does is start App\AudionSyncTools.exe with the same arguments and step aside - no console.
// Administrator rights are asked for by the window itself, once, at its start (--no-admin
// passes through and skips the question).
//
// Until 05.10.2026 this launcher looked for a PowerShell of the system and started the WPF
// window (Engine\App.ps1). The window is Avalonia now and needs no PowerShell of the system.
//
// Compiled by Engine\Launcher\Build-StartExe.ps1 with the csc.exe of .NET Framework, so it
// needs nothing installed and stays C# 5.

using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Forms;

internal static class StartLauncher
{
    private const string AppName = "Audion Sync Tools";

    [STAThread]
    private static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(
            Path.DirectorySeparatorChar,
            Path.AltDirectorySeparatorChar);
        string program = Path.Combine(Path.Combine(root, "App"), "AudionSyncTools.exe");

        // Called by the build to prove the pieces are in place without opening a window.
        if (args.Length == 1 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
        {
            return File.Exists(program) ? 0 : 2;
        }

        if (!File.Exists(program))
        {
            ShowError("App\\AudionSyncTools.exe was not found next to Start.exe.\r\n" +
                      "Unpack the program whole, or build it: builder_main.cmd build_app\r\n\r\n" +
                      "Рядом со Start.exe нет App\\AudionSyncTools.exe.\r\n" +
                      "Распакуйте программу целиком или соберите её: builder_main.cmd build_app");
            return 2;
        }

        // Everything given to the launcher goes on to the window as it is.
        StringBuilder arguments = new StringBuilder();
        foreach (string argument in args)
        {
            if (arguments.Length > 0) arguments.Append(' ');
            arguments.Append(Quote(argument));
        }

        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo(program, arguments.ToString());
            startInfo.UseShellExecute = false;
            startInfo.WorkingDirectory = root;
            using (Process.Start(startInfo))
            {
            }
            return 0;
        }
        catch (Exception exception)
        {
            ShowError(AppName + " did not start.\r\n\r\n" + exception.Message);
            return 1;
        }
    }

    // The rules of CommandLineToArgvW: a backslash before a quote is doubled, one at the end too -
    // or a path that ends with "\" would swallow the closing quote.
    private static string Quote(string value)
    {
        if (value == null) value = string.Empty;
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;

        StringBuilder quoted = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                quoted.Append('\\', (backslashes * 2) + 1);
                quoted.Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes > 0)
            {
                quoted.Append('\\', backslashes);
                backslashes = 0;
            }
            quoted.Append(character);
        }
        if (backslashes > 0) quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
