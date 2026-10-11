using System;
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// REMOVE TASK. The program sets up no task of the Windows Scheduler - repeating work lives as a
/// timer on MAIN VPS - but a machine that ran a version before 09.09.2026 may still hold the
/// nightly "Audion Backup Sync". The button is shown only where that left-over is found and can
/// only remove it: on a clean machine it is not there at all.
/// </summary>
public partial class MainWindow
{
    const string LegacyTask = "Audion Backup Sync";
    bool _legacyTaskFound;

    static (int Code, string Output) Schtasks(params string[] args)
    {
        try
        {
            var info = new ProcessStartInfo("schtasks.exe")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.GetEncoding(Console.OutputEncoding.CodePage),
            };
            foreach (var arg in args) info.ArgumentList.Add(arg);
            using var process = Process.Start(info);
            if (process is null) return (-1, "");
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(8000)) { try { process.Kill(); } catch { } return (-1, ""); }
            return (process.ExitCode, (output.Result + errors.Result).Trim());
        }
        catch { return (-1, ""); }
    }

    /// <summary>Asked once at the start, off the window's thread; the row of SETUP is rebuilt when the answer differs.</summary>
    async void FindLegacyTask()
    {
        bool found = await Task.Run(() => Schtasks("/Query", "/TN", LegacyTask, "/FO", "LIST").Code == 0);
        if (found == _legacyTaskFound) return;
        _legacyTaskFound = found;
        PaintState();
        if (_section == "setup" && !_settingsOpen) SetSection(_section, openPanels: false);
    }

    /// <summary>Removes the nightly task. The mirror itself stays - only what woke it at night goes.</summary>
    async void RemoveSchedule()
    {
        Journal.Add("");
        Journal.Add("===== REMOVE TASK =====");
        var (query, _) = await Task.Run(() => Schtasks("/Query", "/TN", LegacyTask, "/FO", "LIST"));
        if (query != 0)
        {
            Journal.Add(Lang.T("[расписание] задания нет - удалять нечего"));
            SetStatus(Lang.T("расписание: задания нет"));
        }
        else
        {
            var (code, output) = await Task.Run(() => Schtasks("/Delete", "/TN", LegacyTask, "/F"));
            foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries)) Journal.Add(line.TrimEnd());
            SetStatus(code == 0 ? Lang.T("расписание: задание удалено") : Lang.F("расписание: код {0}", code));
        }
        FindLegacyTask();
    }
}
