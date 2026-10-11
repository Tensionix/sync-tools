using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// What Audion Disk Tools does with the files of this machine, taken as it is there: F4 - the file
/// under the cursor in the editor (Core\Editors: Microsoft Edit, micro, Notepad or one's own),
/// ALT+F5 - the dialog of the archiver, ALT+F9 - unpacking (Core\Archiver, Views\ArchiveDialogs;
/// 7-Zip and zstd come from Tools\PeaZip). All three work on the disks of this machine: an editor
/// and an archiver read files, not a remote of rclone - on another machine or in a bucket they
/// say so and do nothing.
/// </summary>
public partial class MainWindow
{
    void WireFiles()
    {
        EditButton.Click += (_, _) => Edit();
        PackButton.Click += (_, _) => _ = Pack();
        UnpackButton.Click += (_, _) => _ = Unpack();
    }

    void Say(string text)
    {
        Journal.Add("[окно] " + Lang.T(text));
        SetStatus(Lang.T(text));
    }

    /// <summary>The same with what the words are about put into them.</summary>
    void Say(string text, params object[] args)
    {
        var said = Lang.F(text, args);
        Journal.Add("[окно] " + said);
        SetStatus(said);
    }

    /// <summary>The folder of this machine a panel stands in; null on another machine, in a bucket and on the list of disks.</summary>
    static string? LocalDir(FilePanel panel) =>
        Sources.Get(panel.SourceKey).IsRemote || panel.Path.Length == 0 ? null : panel.Path;

    const string NotLocal = "панель стоит не на диске этой машины: редактор и архиватор работают с файлами этой машины";

    /// <summary>F4: the file under the cursor in the editor of SETTINGS. The cursor row, not the marks - as in Total Commander.</summary>
    void Edit()
    {
        if (LocalDir(_active) is not { } dir) { Say(NotLocal); return; }
        if (_active.CursorRow is not { } row) { Say("F4: встаньте курсором на файл"); return; }
        if (row.IsDir) { Say("F4 открывает файл, а не папку"); return; }
        EditPath(Path.Combine(dir, row.Name));
    }

    /// <summary>SHIFT+F4: a new empty file in the folder of the active panel, opened in the editor at once. A disk of this machine only - the editor works with its files.</summary>
    async void NewFile()
    {
        using var pending = Pending();
        var panel = _active;
        if (LocalDir(panel) is not { } dir) { Say(NotLocal); return; }
        var name = await Dialog.Ask(this, "Имя нового файла", new[] { Lang.T("ГДЕ: ") + dir }, "СОЗДАТЬ", value: Lang.T("Новый файл.txt"));
        if (name is null || (name = name.Trim()).Length == 0) return;
        var file = Path.Combine(dir, name);
        try
        {
            // An existing file is not emptied: the same name just opens it.
            if (!File.Exists(file)) File.WriteAllBytes(file, Array.Empty<byte>());
        }
        catch (Exception ex) { Say(Lang.F("файл не создан: {0}", ex.Message)); return; }
        // The panel the file was asked from, if it still shows that folder: elsewhere there is no such row to stand on.
        if (LocalDir(panel) == dir) panel.Reload(name);
        EditPath(file);
    }

    /// <summary>CTRL+ENTER: a terminal where the panel stands - the folder of this machine in the terminal the program carries, a machine by ssh the way the panel goes to it.</summary>
    void TerminalHere(FilePanel panel)
    {
        if (LocalDir(panel) is { } dir)
        {
            try
            {
                var plan = Terminal.For(dir, true, Terminal.WindowsTerminal(), Terminal.Shell(), Path.Combine(Paths.State, "terminal"));
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(plan.File, plan.Args) { UseShellExecute = false, WorkingDirectory = plan.Start });
            }
            catch (Exception ex) { Say(Lang.F("терминал не запустился: {0}", ex.Message)); }
            return;
        }
        if (Targets.Read().FirstOrDefault(target => target.Key == panel.SourceKey) is { } machine) OpenTerminal(machine);
        else Say("терминал открывается на диске этой машины или на машине; у этого источника терминала нет");
    }

    /// <summary>Edit and micro are console programs: they open inside the terminal the program carries, the rest start straight.</summary>
    void EditPath(string file)
    {
        var editor = Editors.For(_settings.Editor);
        try
        {
            if (Editors.InConsole(editor))
            {
                var plan = Terminal.ForEditor(editor, file, Terminal.WindowsTerminal(), Path.Combine(Paths.State, "terminal"));
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(plan.File, plan.Args) { UseShellExecute = false, WorkingDirectory = plan.Start });
            }
            else
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(editor) { ArgumentList = { file }, UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(file) ?? "" });
        }
        catch (Exception ex)
        {
            Say(Lang.F("редактор не запустился: {0}", ex.Message));
        }
    }

    /// <summary>ALT+F5: the marked (or the row under the cursor) into archives in the other panel; the dialog of Audion Disk Tools.</summary>
    async Task Pack()
    {
        using var pending = Pending();
        if (_jobs.Running) return;
        if (LocalDir(_active) is not { } from) { Say(NotLocal); return; }
        var names = _active.Selection().Select(r => r.Name).ToList();
        if (names.Count == 0) { Say("нечего упаковывать"); return; }
        if (Archiver.SevenZip is null) { Say("PeaZip не найден: SETTINGS · ОБНОВИТЬ"); return; }
        // Into the other panel, as F5 copies; where that one is not a folder of this machine - next to the source.
        var to = LocalDir(Other) ?? from;
        if (!await PackDialog.Ask(this, from, names, to, _settings.Pack)) { Say("отменено"); return; }
        _settings.Save();
        // Archives made inside a folder that is then deleted would go with it.
        if (_settings.Pack.DeleteSource &&
            names.Select(n => Path.Combine(from, n)).FirstOrDefault(p => Directory.Exists(p) && PathGuard.Inside(to, p)) is { } holder)
        {
            Say(Lang.F("архивы легли бы внутрь {0}, а он удаляется после упаковки: выберите другое место или снимите «удалить исходники»", Path.GetFileName(holder)));
            return;
        }
        var job = Archiver.PackJob(from, names, to, _settings.Pack.Copy());
        job.Refresh = true;
        _jobs.Enqueue(job);
    }

    /// <summary>ALT+F9: the marked archives (first volumes only), into the other panel or here.</summary>
    async Task Unpack()
    {
        using var pending = Pending();
        if (_jobs.Running) return;
        if (LocalDir(_active) is not { } here) { Say(NotLocal); return; }
        var rows = _active.Selection();
        var archives = rows.Where(r => !r.IsDir && Archiver.IsArchive(r.Name)).Select(r => Path.Combine(here, r.Name)).ToList();
        if (archives.Count == 0) { Say("среди отмеченного нет архивов"); return; }
        if (Archiver.SevenZip is null) { Say("PeaZip не найден: SETTINGS · ОБНОВИТЬ"); return; }
        var other = LocalDir(Other);
        if (!await UnpackDialog.Ask(this, archives, here, other, rows.Count - archives.Count, _settings.Unpack)) { Say("отменено"); return; }
        _settings.Save();
        var job = Archiver.UnpackJob(archives, other, _settings.Unpack.Copy());
        job.Refresh = true;
        _jobs.Enqueue(job);
    }
}
