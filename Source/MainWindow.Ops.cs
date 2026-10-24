using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The operations of the file panels: every one is rclone with the arguments the PowerShell
/// window gave it. On the other end there is someone else's machine, a server or a bucket: a
/// slip of a key is dear and cannot be undone, so each asks first and says everything that
/// decides the outcome - what is taken, from where, to where, and what it ends in for the source.
/// </summary>
public partial class MainWindow
{
    void WireActions()
    {
        RenameButton.Click += (_, _) => Rename();
        ShareLinkButton.Click += (_, _) => ShareLinks();
        CopyButton.Click += (_, _) => Copy(move: false);
        MoveButton.Click += (_, _) => Copy(move: true);
        MkdirButton.Click += (_, _) => Mkdir();
        DeleteButton.Click += (_, _) => Delete();
        SyncCopyButton.Click += (_, _) => Sync("copy");
        SyncMirrorButton.Click += (_, _) => Sync("mirror");
        SyncBiButton.Click += (_, _) => Sync("bisync");
    }

    static string Label(FilePanel panel) => Lang.T(Sources.Get(panel.SourceKey).Label);

    static string Where(FilePanel panel) => $"{Label(panel)} : {(panel.Path.Length > 0 ? panel.Path : "/")}";

    /// <summary>
    /// Where a panel stood when an action began. A question takes time, and a panel does not wait
    /// for the answer: the search window sends it to a found file, OPENVPN opens WORK in it. The
    /// action goes where its question said, not where the panel is by then - F8 asked about one
    /// folder and deleted the same name in another. So the address of an operation is asked of
    /// the place taken before the question, never of the panel after it.
    /// </summary>
    readonly record struct Place(string Key, string Path)
    {
        public static Place Of(FilePanel panel) => new(panel.SourceKey, panel.Path);

        /// <summary>The address of a child for rclone, by the route the machine is reached by now.</summary>
        public string Target(string name) => Sources.RemotePath(Key, Sources.Child(Path, name));

        public bool Machine => Sources.Get(Key).Probe.Length > 0;
    }

    /// <summary>The top of LOCAL is the list of disks: nothing is created, copied to or deleted there.</summary>
    static bool AtDisks(FilePanel panel) => !Sources.Get(panel.SourceKey).IsRemote && panel.Path.Length == 0;

    /// <summary>
    /// What stops an operation between two places, or null: a target inside its own source, and
    /// for a mirror a source inside its target as well (Core\PathGuard). Two folders of this
    /// machine are compared by where they really are, through junctions; this machine over ssh
    /// counts as its own disk; two addresses of one storage are compared as texts. Two different
    /// storages are never in each other's way. Asked before the question: there is no use in
    /// asking about what will not be done.
    ///
    /// The disk is asked off the window's thread: a mapped drive that fell silent held the window
    /// for as long as the network took to give up.
    ///
    /// A machine over ssh by a far road is not known by its address (Sources.IsThisMachine), so
    /// it is taken at its word: were it this computer, would the two paths be in each other's
    /// way? Only then is the machine asked which one it is - one reading of a small file, and
    /// only for paths that match disk for disk. A machine that gives no answer to that reading
    /// would give none to the operation either, and the operation is not begun.
    /// </summary>
    async Task<string?> Overlap(Place from, Place to, IReadOnlyList<(string Name, bool IsDir)> scope, bool mirror)
    {
        string? here = Sources.LocalPath(from.Key, from.Path), there = Sources.LocalPath(to.Key, to.Path);
        if (here is not null && there is not null) return await Task.Run(() => PathGuard.Problem(here, there, scope, mirror));
        if (here is null && there is null)
            return PathGuard.RemoteProblem(Sources.RemotePath(from.Key, from.Path), Sources.RemotePath(to.Key, to.Path), scope, mirror);

        var far = here is null ? from : to;
        if (!far.Machine || Sources.AsLocal(far.Path) is not { } guess) return null;
        string source = here ?? guess, target = there ?? guess;
        if (await Task.Run(() => PathGuard.Problem(source, target, scope, mirror)) is not { } problem) return null;

        var label = Lang.T(Sources.Get(far.Key).Label);
        SetStatus(Lang.F("спрашиваю {0}, не эта ли это машина…", label));
        var same = await Sources.SameMachine(far.Key, CancellationToken.None);
        SetStatus("");
        if (same == Sources.Same.Silent)
            return Lang.F("{0} не ответила, и не узнать, не эта ли машина под её именем: пути на обоих концах совпадают. Операция не начата", label);
        if (same != Sources.Same.Yes) return null;
        Journal.Add(Lang.F("[окно] {0} этим маршрутом — эта же машина: её диски и диски LOCAL — одни и те же", label));
        return problem;
    }

    /// <summary>
    /// F5 / F6: the marked rows go into the queue, not into one run - mark things in one folder,
    /// walk to another, add more, and all of it goes to one target. The target is remembered at
    /// the moment of adding: by the time the queue reaches a job the panel may show another place.
    /// </summary>
    async void Copy(bool move)
    {
        using var pending = Pending();
        FilePanel from = _active, to = Other;
        var selected = from.Selection();
        if (selected.Count == 0) { Journal.Add(Lang.T("[окно] в активной панели ничего не отмечено")); return; }
        if (AtDisks(from) || AtDisks(to)) { Journal.Add(Lang.T("[окно] обе панели должны стоять в папке, а не на списке дисков")); return; }
        // Both places as they are now: what the question names is what goes into the queue. All
        // that is asked of the panels is asked here, before the first wait: the check of the two
        // places may take a moment, and a panel does not stand still for it.
        Place source = Place.Of(from), target = Place.Of(to);
        string fromLine = Lang.F("ОТКУДА: {0} : {1}", Label(from), from.Path.Length > 0 ? from.Path : "/");
        string toLine = Lang.F("КУДА  : {0} : {1}", Label(to), to.Path.Length > 0 ? to.Path : "/");
        // rclone overwrites equal names in the target without a word: better said before than heard after.
        var taken = new HashSet<string>(selected.Select(r => r.Name), StringComparer.OrdinalIgnoreCase);
        var existing = to.Rows.Where(r => taken.Contains(r.Name)).Select(r => r.Name).ToList();
        // A folder into its own subfolder: rclone does not refuse such a copy and does not stop either.
        if (await Overlap(source, target, selected.Select(r => (r.Name, r.IsDir)).ToList(), mirror: false) is { } problem) { Say(problem); return; }

        var names = selected.Take(6).Select(r => r.IsDir ? $"[{r.Name}]" : r.Name).ToList();
        if (selected.Count > names.Count) names.Add(Lang.F("… и ещё {0}", selected.Count - names.Count));

        var lines = new List<string>
        {
            fromLine,
            toLine,
            "",
            Lang.F("ОБЪЕКТОВ: {0}", selected.Count),
            "  " + string.Join(", ", names),
        };
        if (move)
        {
            lines.Add("");
            lines.Add(Lang.T("После переноса в источнике этих объектов не останется."));
        }
        if (existing.Count > 0)
        {
            lines.Add("");
            lines.Add(Lang.F("В приёмнике уже есть: {0}", string.Join(", ", existing.Take(5))));
            lines.Add(Lang.T("Совпадающие имена будут перезаписаны."));
        }

        var go = await Dialog.Ask(this, move ? "Перенести?" : "Скопировать?", lines, move ? "ПЕРЕНЕСТИ" : "КОПИРОВАТЬ", move ? Tone.Warn : Tone.Plain);
        if (go is null) { Journal.Add(Lang.T("[окно] отменено")); return; }

        // A machine over ssh does not let the time of a folder be set - see Sync.
        var dirTime = source.Machine || target.Machine ? new[] { "--no-update-dir-modtime" } : Array.Empty<string>();
        var verb = move ? "move" : "copy";
        var title = move ? "ПЕРЕНОС" : "КОПИРОВАНИЕ";
        var jobs = new List<Job>();
        foreach (var item in selected)
        {
            string src = source.Target(item.Name), dst = target.Target(item.Name);
            // A folder is copied whole, a single file with its name: copy of rclone works by
            // folders, copyto by objects. An empty folder does not exist for rclone at all, so it
            // is asked to create those too; --metadata carries the times of creation, change and access.
            var operation = item.IsDir
                ? new List<string> { verb, src, dst, "--create-empty-src-dirs", "--metadata" }.Concat(dirTime)
                : new List<string> { verb + "to", src, dst, "--metadata" };
            jobs.Add(RcloneJob($"{Lang.T(title)}: {item.Name}", operation, transfer: true));
        }
        Journal.Add(Lang.F("в очередь добавлено: {0}", selected.Count));
        _jobs.Enqueue(jobs);
    }

    /// <summary>A path inside a source with one kind of slash and none at the end: two paths are compared as such.</summary>
    static string Flat(string path) => path.Replace('\\', '/').TrimEnd('/');

    /// <summary>The last name of a path inside a source.</summary>
    static string Leaf(string path)
    {
        var flat = Flat(path);
        return flat[(flat.LastIndexOf('/') + 1)..];
    }

    /// <summary>
    /// F2. rclone renames onto a taken name without a word: a file that lies there is deleted, a
    /// folder is merged into (the review of 08.10.2026). So the folder the new name goes into is
    /// read first, and a taken name is refused - at the press of the key, and once more when the
    /// turn of the job comes (Job.Before): the queue may hold it behind a long transfer. The
    /// flags are the fuse for the moment that is left. For a file --ignore-existing leaves both
    /// objects where they are, and --error-on-no-transfer makes that an error instead of a silent
    /// "done". A folder has no such fuse: no file of either folder is overwritten, but what only
    /// the old folder held is moved into the one that took the name, and rclone ends with success
    /// (a renamed folder is no transfer to it, so the second flag cries wolf there). A renamed
    /// folder is therefore looked at afterwards (Job.After), and one that stayed where it was is
    /// an error said in words (the audit of 08.10.2026).
    ///
    /// The case of a letter alone is a trap of its own. Over ssh a machine with Windows finds the
    /// old name when asked for the new one; rclone takes the source for a needless second copy
    /// and deletes it - a file is gone, a folder is left empty, and the job ends with "done". On
    /// a disk of this machine a folder is refused as overlapping. In both places the rename goes
    /// in two steps, by way of a name nobody has.
    /// </summary>
    async void Rename()
    {
        using var pending = Pending();
        var panel = _active;
        var item = panel.Selection().FirstOrDefault();
        if (item is null || AtDisks(panel)) { Journal.Add(Lang.T("[окно] нечего переименовывать")); return; }
        var place = Place.Of(panel);
        var name = await Dialog.Ask(this, "Новое имя", new[] { Lang.T("ЧТО: ") + item.Name }, "ПЕРЕИМЕНОВАТЬ", value: item.Name);
        if (string.IsNullOrEmpty(name) || name == item.Name) return;
        if (name.Split('/', '\\').Any(part => part.Length == 0 || part is "." or "..")) { Say("такое имя не годится: {0}", name); return; }

        string from = Sources.Child(place.Path, item.Name), to = Sources.Child(place.Path, name);
        string oldLeaf = Leaf(from), newLeaf = Leaf(to);
        bool caseOnly = string.Equals(Flat(from), Flat(to), StringComparison.OrdinalIgnoreCase);
        var folder = Sources.Parent(place.Key, to) ?? place.Path;

        // The folder the new name goes into, and the one the object lies in now: a name with a folder in it moves the object.
        string into = Sources.RemotePath(place.Key, folder), home = Sources.RemotePath(place.Key, place.Path);
        // What stands in the way of the new name in a folder just read, or null.
        string? Refusal(List<Rclone.Listed>? listed, Rclone.Answer read)
        {
            // Code 3 of rclone - no such folder yet: the name leads into a new one, and nothing is taken there.
            if (listed is null && read.Code != 3) return Lang.T("папка не прочиталась, имя не проверено: переименование не начато");
            // Another object under the new name, whatever the case of its letters. The object itself under its old name is not one.
            var holder = listed?.FirstOrDefault(row => string.Equals(row.Name, newLeaf, StringComparison.OrdinalIgnoreCase)
                && !(caseOnly && string.Equals(row.Name, oldLeaf, StringComparison.Ordinal)));
            return holder is null ? null : Lang.F("имя занято: здесь уже есть «{0}». F2 на занятое имя не переименовывает", holder.Name);
        }

        // The panel reads the same folder with the same patience: a folder it could show must not be one F2 refuses in.
        SetStatus(Lang.T("проверяю, свободно ли имя…"));
        var (rows, answer) = await Rclone.List(into, CancellationToken.None);
        SetStatus("");
        if (Refusal(rows, answer) is { } refusal) { Say(refusal); return; }

        // Asked once more when the turn of the job comes: the queue may have held it behind a long
        // transfer, and the name free at the press of F2 may be taken by then.
        List<string> StillFree(CancellationToken cancel)
        {
            var (now, said) = Rclone.List(into, cancel).GetAwaiter().GetResult();
            return Refusal(now, said) is { } taken ? new List<string> { taken } : new List<string>();
        }
        // And looked at afterwards, for a folder: the fuse keeps every file whole, but a folder whose
        // new name was taken in the last moment is poured into the one that took it - what only the
        // old folder held moves, what both hold stays, and rclone calls that a success.
        List<string> Stayed(string was, string became, CancellationToken cancel)
        {
            var (now, _) = Rclone.List(home, cancel).GetAwaiter().GetResult();
            return now is not null && now.Any(row => row.IsDir && string.Equals(row.Name, was, StringComparison.Ordinal))
                ? new List<string> { Lang.F("папка «{0}» осталась на месте: имя «{1}» заняли, пока переименование ждало своей очереди. Что было только в «{0}», теперь в «{1}»; одноимённое осталось в «{0}»", was, became) }
                : new List<string>();
        }

        var fuse = item.IsDir ? new[] { "--ignore-existing" } : new[] { "--ignore-existing", "--error-on-no-transfer" };
        Job Move(string source, string target) =>
            RcloneJob(Lang.F("ПЕРЕИМЕНОВАНИЕ: {0}", item.Name), new[] { "moveto", place.Target(source), place.Target(target) }.Concat(fuse), transfer: false);

        if (caseOnly && (place.Machine || !Sources.Get(place.Key).IsRemote))
        {
            var there = new HashSet<string>(rows?.Select(row => row.Name) ?? Enumerable.Empty<string>(), StringComparer.OrdinalIgnoreCase);
            string between;
            do between = $"{item.Name}.~f2-{Guid.NewGuid().ToString("N")[..6]}"; while (there.Contains(Leaf(between)));
            Journal.Add(Lang.F("[окно] регистр букв здесь меняется в два шага, через имя «{0}»", Leaf(between)));
            Job first = Move(item.Name, between), second = Move(between, name);
            first.Before = StillFree;
            // The title of the second step names the old name, and the object is under neither the old nor the new.
            second.Undone = Lang.F("объект остался под временным именем «{0}»: имя ему возвращает F2", Leaf(between));
            if (item.IsDir) second.After = cancel => Stayed(Leaf(between), newLeaf, cancel);
            first.Then = second;
            _jobs.Enqueue(first);
            return;
        }
        var job = Move(item.Name, name);
        job.Before = StillFree;
        if (item.IsDir) job.After = cancel => Stayed(oldLeaf, newLeaf, cancel);
        _jobs.Enqueue(job);
    }

    async void Mkdir()
    {
        using var pending = Pending();
        var panel = _active;
        if (AtDisks(panel)) { Journal.Add(Lang.T("[окно] обе панели должны стоять в папке, а не на списке дисков")); return; }
        var place = Place.Of(panel);
        var where = Where(panel);
        var name = await Dialog.Ask(this, "Имя новой папки", new[] { Lang.T("ГДЕ: ") + where }, "СОЗДАТЬ", value: Lang.T("Новая папка"));
        if (string.IsNullOrEmpty(name)) return;
        _jobs.Enqueue(RcloneJob(Lang.F("ПАПКА: {0}", name), new[] { "mkdir", place.Target(name) }, transfer: false));
    }

    /// <summary>
    /// F8 and DEL. On a disk of this machine the object goes into the Recycle Bin of Windows, by
    /// the guarded shell operation the archiver already used: a slip can be undone, and what the
    /// bin will not take stays where it is. SHIFT+DEL and SHIFT+F8 go past the bin, as in
    /// Explorer and Total Commander. A machine over ssh, a server and a bucket have no bin, and
    /// the question says so. Until the review of 08.10.2026 a disk of this machine was deleted
    /// from by rclone like the rest, for good, under a question that spoke of "remote sources".
    /// </summary>
    async void Delete(bool permanent = false)
    {
        using var pending = Pending();
        var panel = _active;
        // One object at a time, as the PowerShell window did: the first of the marked, or the row under the cursor.
        var item = panel.Selection().FirstOrDefault();
        if (item is null || AtDisks(panel)) { Journal.Add(Lang.T("[окно] нечего удалять")); return; }
        // The place the question names: what is deleted is asked of it, not of the panel after the answer.
        var place = Place.Of(panel);
        var where = Where(panel);
        bool local = !Sources.Get(place.Key).IsRemote, bin = local && !permanent;

        var go = await Dialog.Ask(this, Lang.F(local && permanent ? "Удалить насовсем «{0}»?" : "Удалить «{0}»?", item.Name), new[]
        {
            Lang.T("ГДЕ: ") + where,
            "",
            bin ? "Уйдёт в корзину Windows — оттуда можно вернуть."
                : local ? "Мимо корзины — вернуть будет нельзя."
                : "Корзины у удалённых источников нет — восстановить будет нечем.",
        }, local && permanent ? "УДАЛИТЬ НАСОВСЕМ" : "УДАЛИТЬ", Tone.Danger, badge: local && permanent ? "МИМО КОРЗИНЫ" : null);
        if (go is null) return;

        if (bin)
        {
            var full = Path.GetFullPath(Sources.Child(place.Path, item.Name));
            Journal.Add(Lang.F("[удаление] в корзину Windows: {0}", full));
            _jobs.Enqueue(BinJob(Lang.F("УДАЛЕНИЕ: {0}", item.Name), full));
            return;
        }

        var target = place.Target(item.Name);
        var verb = item.IsDir ? "purge" : "deletefile";
        // A freshly copied folder is not given up by Windows at once: its files are marked for
        // deletion but still held open, the folder does not count as empty and rmdir refuses.
        // Only time helps, so machines over ssh get more tries - with the pause up to half a minute.
        var retries = place.Machine ? new[] { "--retries", "6" } : Array.Empty<string>();
        Journal.Add($"[удаление] {verb} {target}");
        _jobs.Enqueue(RcloneJob(Lang.F("УДАЛЕНИЕ: {0}", item.Name), new[] { verb, target }.Concat(retries), transfer: false));
    }

    /// <summary>
    /// One object into the Recycle Bin as a job of the queue: СТОП, the bar and the journal are
    /// the same as for any other job. What the bin cannot take - a drive without a bin, an object
    /// too big for it - is left in place and said so; nothing is deleted for good from here.
    /// </summary>
    static Job BinJob(string title, string path) => new()
    {
        Title = title,
        Refresh = true,
        Work = (progress, cancel) =>
        {
            var result = RecycleBin.SendMany(new[] { path }, IntPtr.Zero, (name, percent) => progress(name, percent, -1), cancel);
            if (result.Cancelled) throw new OperationCanceledException(cancel);
            var bad = new List<string>();
            if (result.NoRoom.Count > 0) bad.Add(Lang.T("корзина Windows его не примет — оставлен на месте") + ". " + Lang.T("Насовсем удаляет SHIFT+DEL."));
            if (result.PastBin.Count > 0) bad.Add(Lang.T("удалён мимо корзины"));
            bad.AddRange(result.Failed);
            return bad;
        },
    };

    static readonly Regex FilterChars = new(@"([\\*?\[\]{}])", RegexOptions.Compiled);

    /// <summary>
    /// The synchronisation of the two open folders: the active panel is the source, the other one
    /// the target. The scope is set by the marks alone: none - the whole folder, some - those
    /// branches only. The highlighted row, unlike with F5, does not count: a mirror deletes, and
    /// its scope must be chosen on purpose, not by a stray click.
    /// </summary>
    async void Sync(string mode)
    {
        using var pending = Pending();
        if (mode == "bisync" && !NeedData()) return;
        FilePanel from = _active, to = Other;
        if (AtDisks(from) || AtDisks(to)) { Journal.Add(Lang.T("[окно] обе панели должны стоять в папке, а не на списке дисков")); return; }
        string src = Sources.RemotePath(from.SourceKey, from.Path), dst = Sources.RemotePath(to.SourceKey, to.Path);
        if (src == dst) { Journal.Add(Lang.T("[окно] источник и приёмник совпадают")); return; }
        // BISYNC alone: the two ends named so that the pair is the same pair by any road (Sources.SteadyPath).
        var (pairSrc, srcRoad) = Sources.SteadyPath(from.SourceKey, from.Path);
        var (pairDst, dstRoad) = Sources.SteadyPath(to.SourceKey, to.Path);

        string srcLabel = $"{Label(from)} : {from.Path}", dstLabel = $"{Label(to)} : {to.Path}";
        var marked = from.Rows.Where(r => r.Checked).ToList();
        // The last of what is asked of the panels: after the first wait they may stand elsewhere.
        Place source = Place.Of(from), target = Place.Of(to);
        var (fromSource, toSource) = (Sources.Get(source.Key), Sources.Get(target.Key));
        // One folder inside the other: the plain case rclone refuses itself, a junction and one
        // place under two names it does not see - and then a mirror deletes its own source.
        if (await Overlap(source, target, marked.Select(r => (r.Name, r.IsDir)).ToList(), mirror: mode != "copy") is { } problem) { Say(problem); return; }

        // The marks become filters: rclone applies them to both sides, so a mirror levels these
        // branches alone and the neighbouring folders of the target stay untouched.
        var filters = new List<string>();
        foreach (var row in marked)
        {
            var pattern = FilterChars.Replace(row.Name, @"\$1");
            filters.Add("--include");
            filters.Add(row.IsDir ? $"/{pattern}/**" : $"/{pattern}");
        }
        var scope = marked.Count > 0 ? Lang.F(" · отмечено: {0}", marked.Count) : "";

        // --create-empty-src-dirs: only files exist for rclone, and a folder without a single one
        // is not created unless asked. --metadata: a copy must remember when a file was created,
        // changed and opened; how much of that arrives is decided by the target.
        var carry = new List<string> { "--create-empty-src-dirs", "--metadata" };
        // The time of a folder cannot be set on a machine over ssh: rclone does it while files
        // are still written into the folder, and OpenSSH under Windows answers SSH_FX_FAILURE.
        // That is an I/O error to rclone, after which it refuses to delete the extra - the mirror
        // stays unfinished. The times of the files travel as usual.
        if (source.Machine || target.Machine) carry.Add("--no-update-dir-modtime");
        // A copy inside one provider. When both ends are the same kind of cloud - two accounts
        // of Google Drive, two of Dropbox - the provider moves a file on its own side and the
        // bytes never leave it: a terabyte travels in minutes and takes nothing of this
        // machine's channel. Between different clouds there is no such thing, whatever flag is
        // given, so the flag goes only where the kinds match: a command must say what will happen.
        if (fromSource.Cloud && toSource.Cloud && fromSource.CloudType.Length > 0
            && fromSource.CloudType == toSource.CloudType && fromSource.Key != toSource.Key)
            carry.Add("--server-side-across-configs");

        string What()
        {
            if (marked.Count == 0) return Lang.T("ВСЁ содержимое папки");
            var tail = marked.Count > 8 ? Lang.F(" и ещё {0}", marked.Count - 8) : "";
            return Lang.F("ТОЛЬКО ОТМЕЧЕННОЕ ({0}): {1}{2}", marked.Count, string.Join(", ", marked.Take(8).Select(r => r.Name)), tail);
        }

        switch (mode)
        {
            case "copy":
            {
                // COPY deletes nothing, and for long there was no question here. But F11 stands
                // beside F12 and is pressed by mistake: on 24.09.2026 16 754 files, 4.6 GB, left
                // in 25 seconds without a single question. It asks, and says how much will go.
                SetStatus("считаю, что поедет…");
                var plan = await MeasureCopy(src, dst, filters, carry);
                SetStatus("");
                string badge = plan is null ? Lang.T("СКОЛЬКО ПОЕДЕТ · сосчитать не успел")
                    : plan.Value.Files == 0 ? Lang.T("ПРИЁМНИК УЖЕ СВЕЖИЙ · копировать нечего")
                    : Lang.F("БУДЕТ СКОПИРОВАНО: {0} файл. · {1}", plan.Value.Files, Format.Size(plan.Value.Bytes));
                var go = await Dialog.Ask(this, "Долить новое в приёмник?", new[]
                {
                    Lang.T("ИСТОЧНИК: ") + srcLabel,
                    Lang.T("ПРИЁМНИК: ") + dstLabel,
                    Lang.T("ДОЛИВАЕМ: ") + What(),
                    "",
                    "Копируется то, чего в приёмнике нет или что там старее. Ничего не удаляется.",
                }, "COPY", Tone.Run, badge: badge);
                if (go is null) return;
                _jobs.Enqueue(RcloneJob(Lang.F("ОБНОВЛЕНИЕ: {0} -> {1}{2}", srcLabel, dstLabel, scope),
                    new[] { "copy", src, dst }.Concat(filters).Concat(carry), transfer: true));
                break;
            }
            case "mirror":
            {
                // A mirror deletes in the target everything the source does not have. It asks
                // plainly, naming both sides in words, with a fuse against a swapped direction.
                var note = marked.Count > 0
                    ? "Внутри этих веток из приёмника удалится всё, чего нет в источнике. Остальное в приёмнике не тронется."
                    : "Всё, чего нет в источнике, из приёмника будет удалено.";
                var go = await Dialog.Ask(this, "Сделать приёмник точной копией источника?", new[]
                {
                    Lang.T("ИСТОЧНИК: ") + srcLabel,
                    Lang.T("ПРИЁМНИК: ") + dstLabel,
                    Lang.T("РАВНЯЕМ: ") + What(),
                    "",
                    note,
                }, "SYNC", Tone.Warn);
                if (go is null) return;
                _jobs.Enqueue(RcloneJob(Lang.F("SYNC: {0} -> {1}{2}", srcLabel, dstLabel, scope),
                    new[] { "sync", src, dst, "--max-delete", "200" }.Concat(filters).Concat(carry), transfer: true));
                break;
            }
            case "bisync":
            {
                // bisync remembers the state of a pair; its first run must go with --resync - it
                // decides whose version counts as the right one.
                if (marked.Count > 0) { Journal.Add(Lang.T("[окно] BISYNC работает по папке целиком: снимите отметки или войдите в нужную папку")); return; }
                // The state of the pair - the listings rclone compares with - lies in the data folder, a
                // folder a pair, and the pair is known while they are there (Core\DataStore.cs). Both
                // the folder and the listings go by the names of the two ends, so the ends are named
                // the same by any road: a pair made at home is not a new pair from afar.
                var operation = new List<string> { "bisync", pairSrc, pairDst, "--max-delete", "50", "--workdir", DataStore.PairState(pairSrc, pairDst) };
                operation.AddRange(carry);
                Action? remember = null;
                if (!DataStore.PairKnown(pairSrc, pairDst))
                {
                    var go = await Dialog.Ask(this, "Эта пара папок синхронизируется впервые", new[]
                    {
                        Lang.T("ИСТОЧНИК: ") + srcLabel,
                        Lang.T("ПРИЁМНИК: ") + dstLabel,
                        "",
                        "Первый прогон принимает содержимое источника за верное и приводит приёмник к нему.",
                    }, "НАЧАТЬ", Tone.Warn);
                    if (go is null) return;
                    operation.Add("--resync");
                    // The pair is remembered after its run succeeded, not before it: a first run that
                    // failed must ask again and go with --resync again.
                    remember = () => DataStore.RememberPair(pairSrc, pairDst);
                }
                var job = RcloneJob(Lang.F("BISYNC: {0} <-> {1}", srcLabel, dstLabel), operation, transfer: true, onSuccess: remember);
                // The road of each end, for this run alone: variables of the child, above the file of the config.
                foreach (var (name, value) in srcRoad.Concat(dstRoad)) job.Env[name] = value;
                // An ssh program laid over a remote that names a host is what this run asks for, and rclone
                // says so on every call. In this job that is no news; in any other it is a mistake of the config.
                if (srcRoad.Concat(dstRoad).Any(road => road.Key.EndsWith("_SSH", StringComparison.Ordinal) && road.Value.Length > 0))
                    job.Hush = new[] { Journal.SshOverHost };
                _jobs.Enqueue(job);
                break;
            }
        }
    }

    /// <summary>
    /// How much COPY will take: files and bytes, by a dry run with the same switches and filters
    /// as the transfer itself - otherwise the number would answer a question nobody asked. The
    /// JSON log holds the size as a number; it is written to a file, not read from the stream.
    /// Null - not counted in time: the question is shown without the number, and is no weaker.
    /// </summary>
    async Task<(int Files, long Bytes)?> MeasureCopy(string src, string dst, IEnumerable<string> filters, IEnumerable<string> carry)
    {
        var log = Path.Combine(Path.GetTempPath(), $"audion-copy-plan-{Guid.NewGuid():N}.log");
        try
        {
            var operation = new List<string> { "copy", src, dst };
            operation.AddRange(filters);
            operation.AddRange(carry);
            operation.AddRange(new[] { "--dry-run", "--use-json-log", "--verbose", "--stats", "0", "--log-file", log });
            var answer = await Rclone.Run(operation, 120, CancellationToken.None);
            if (answer.Code != 0 || !File.Exists(log)) return null;
            int files = 0;
            long bytes = 0;
            foreach (var line in await File.ReadAllLinesAsync(log))
            {
                if (line.Trim().Length == 0) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    // Files only: rclone reports the times of folders the same way, and they are not copied.
                    if (!doc.RootElement.TryGetProperty("skipped", out var skipped) || skipped.GetString() != "copy") continue;
                    files++;
                    if (doc.RootElement.TryGetProperty("size", out var size) && size.TryGetInt64(out var n)) bytes += n;
                }
                catch { }
            }
            return (files, bytes);
        }
        catch { return null; }
        finally { try { File.Delete(log); } catch { } }
    }

}
