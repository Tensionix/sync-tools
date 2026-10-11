using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The first start. A release comes without the tools - the cleanup before it takes them out, the
/// program downloads them by itself - and without a pointer to the data folder. Both are asked in
/// one window as soon as the main one is up (Views\FirstStartDialog): the data folder found beside
/// the program is offered, and the missing tools are downloaded by the same script the UPDATE
/// button of SETTINGS runs. The window comes back at any later start while a tool is missing: a
/// program that cannot read a machine must say why, not stand with empty panels.
/// </summary>
public partial class MainWindow
{
    /// <summary>The tools the program carries: the name, the file that says it is there, what stops without it.</summary>
    static readonly (string Name, string File, string Stops)[] CarriedTools =
    {
        ("rclone", "Tools\\rclone\\rclone.exe", "панели не читают машины и R2, копирование и зеркала не идут"),
        ("cloudflared", "Tunnel\\Bin\\cloudflared.exe", "нет маршрута через Cloudflare"),
        ("Windows Terminal", "Tools\\terminal\\wt.exe", "не открывается терминал к машинам"),
        ("PeaZip", "Tools\\PeaZip\\res\\bin\\7z\\7z.exe", "нет упаковки и распаковки"),
        ("Microsoft Edit", "Tools\\edit\\edit.exe", ""),
        ("micro", "Tools\\micro\\micro.exe", ""),
    };

    static List<string> MissingTools() =>
        CarriedTools.Where(tool => !File.Exists(Paths.Script(tool.File))).Select(tool => tool.Name).ToList();

    /// <summary>What does not work without the missing ones, in words. One editor of the two is enough for F4; without both there is only Notepad.</summary>
    static string Stops(IReadOnlyList<string> missing)
    {
        var parts = CarriedTools.Where(tool => missing.Contains(tool.Name) && tool.Stops.Length > 0).Select(tool => Lang.T(tool.Stops)).ToList();
        if (missing.Contains("Microsoft Edit") && missing.Contains("micro")) parts.Add(Lang.T("F4 открывает файлы только в Блокноте"));
        return string.Join("; ", parts);
    }

    /// <summary>Asked once the window is up. Nothing is shown when the folder was chosen before and every tool is there.</summary>
    async void FirstStart()
    {
        bool askFolder = !DataRoot.Pointed;
        var missing = MissingTools();
        if (!askFolder && missing.Count == 0) return;
        await AskFirstStart(askFolder, missing, act: true);
    }

    async Task AskFirstStart(bool askFolder, IReadOnlyList<string> missing, bool act)
    {
        var answer = await FirstStartDialog.Ask(this, askFolder ? DataRoot.Near() : null, missing, Stops(missing));
        if (!act) return;
        if (answer is null)
        {
            // Cancelled: the journal says where each of the two is done later, and the place of the folder opens by itself.
            if (missing.Count > 0) Journal.Add(Lang.F("[окно] не хватает инструментов: {0} - SETTINGS → ОБНОВИТЬ", string.Join(", ", missing)));
            if (askFolder && !DataRoot.Chosen)
            {
                Journal.Add(Lang.T("[окно] папка данных не выбрана: SETTINGS → ПАПКА ДАННЫХ → ВЫБРАТЬ"));
                ToggleSettings(true);
            }
            return;
        }
        if (askFolder)
        {
            var folder = answer.Folder == "*"
                ? await PickFolder("Папка данных этой машины: Audion Backup <Машина>", Path.GetDirectoryName(Paths.Root) ?? "")
                : answer.Folder;
            if (folder is not null) await ChooseDataFolder(folder);
        }
        if (answer.Download) UpdateTools();
    }
}
