// The window of Audion Sync Tools driven without a screen and without a mouse: Avalonia.Headless
// over the built App\AudionSyncTools.dll, with Worker.exe in place of the PowerShell of the
// program and of rclone. Tests\Stand\Run-Stand.ps1 builds the stand in a temporary folder and
// runs this.
//
// What it is for. A step of the Debug copy (Source\Tools\dev-run.ps1) answers a question of the
// window at once, so nothing that happens between an await and its answer can be tried there -
// and that is where the audits of the move to Avalonia (06.10.2026, AST-M01 ... AST-M07) found
// what the checks of Tests\Test-*.ps1 could not see. Here a question is left open, the data
// folder is changed or a panel is sent elsewhere, and only then the question is answered; what
// the stub of rclone was called with is the verdict.
//
// The way of probing and the first six probes are the auditor's. Nothing real is touched: the
// data folders, the pointer, the settings and the journal are the stand's own, no machine and no
// cloud is called, the probe of the network is switched off.
using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using Avalonia.VisualTree;
using AudionSyncTools;
using AudionSyncTools.Core;
using AudionSyncTools.Views;
using SyncApp = AudionSyncTools.App;

static class Stand
{
    static BindingFlags Private => BindingFlags.NonPublic | BindingFlags.Instance;
    static object? Field(object target, string name) => target.GetType().GetField(name, Private)!.GetValue(target);
    static object? Call(object target, string name, params object?[] args) => target.GetType().GetMethod(name, Private)!.Invoke(target, args);

    static void Pump(int ms)
    {
        var timer = Stopwatch.StartNew();
        while (timer.ElapsedMilliseconds < ms) { Dispatcher.UIThread.RunJobs(); Thread.Sleep(15); }
    }

    static bool Until(Func<bool> done, int ms = 8000)
    {
        var timer = Stopwatch.StartNew();
        while (!done() && timer.ElapsedMilliseconds < ms) Pump(20);
        return done();
    }

    static int _failed;

    static void Verdict(string title, bool ok, object evidence)
    {
        Console.WriteLine($"{(ok ? "ок  " : "СБОЙ")}  {title}");
        if (!ok) { _failed++; Console.WriteLine("      " + JsonSerializer.Serialize(evidence)); }
    }

    /// <summary>A window as the program makes it, without its start: no probe of the network, no first-start question.</summary>
    static MainWindow Window(Settings? settings = null)
    {
        var window = new MainWindow(settings ?? new Settings { UiFont = "Inter", PanelFont = "Inter" });
        for (Type? type = window.GetType(); type != null; type = type.BaseType)
        {
            var opened = type.GetField("Opened", Private | BindingFlags.DeclaredOnly);
            if (opened == null) continue;
            opened.SetValue(window, null);
            break;
        }
        window.Show();
        window.GetType().GetField("_probing", Private)!.SetValue(window, true);
        Pump(60);
        return window;
    }

    static JobRunner Jobs(MainWindow window) => (JobRunner)Field(window, "_jobs")!;

    static bool Asked(MainWindow window) => window.OwnedWindows.OfType<Dialog>().Any();

    /// <summary>The question of the window is answered: null - cancel, "" - yes, a text - its field.</summary>
    static bool Answer(MainWindow window, string? value, int wait = 8000)
    {
        if (!Until(() => Asked(window), wait)) return false;
        var dialog = window.OwnedWindows.OfType<Dialog>().Single();
        dialog.GetType().GetField("_result", Private)!.SetValue(dialog, value);
        dialog.Close();
        Pump(120);
        return true;
    }

    static void Close(MainWindow window)
    {
        foreach (var owned in window.OwnedWindows.ToArray()) owned.Close();
        Until(() => !Jobs(window).Running, 5000);
        Call(window, "CloseClouds");
        window.Close();
        Pump(100);
    }

    static string _stand = "";
    static string InStand(params string[] parts) => Path.Combine(new[] { _stand }.Concat(parts).ToArray());

    /// <summary>
    /// The records of the calls are written by the stubs while a probe reads or empties them - a
    /// panel reads its folder in the background at any moment. A file held by the other side is
    /// tried again; once a probe fell on it before its verdict.
    /// </summary>
    static T Patient<T>(Func<T> work)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { return work(); }
            catch (IOException) when (attempt < 60) { Thread.Sleep(15); }
        }
    }

    static void Empty(string file) => Patient(() => { File.WriteAllText(InStand(file), ""); return true; });

    static string[][] RcloneCalls() =>
        Patient(() => File.ReadAllLines(InStand("rclone-calls.txt"))).Where(line => line.Length > 0).Select(line => JsonSerializer.Deserialize<string[]>(line)!).ToArray();

    static string[] WorkerCalls() => Patient(() => File.ReadAllLines(InStand("worker-calls.txt")));

    static string FolderOf(string? file) => file is null ? "(none)" : Path.GetFileName(Path.GetDirectoryName(file) ?? "");

    static string ConfigOf(string[]? call) => call is null ? "(no call)" : FolderOf(call[Array.IndexOf(call, "--config") + 1]);

    static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        _stand = Paths.Root;
        // The stubs find the stand by this; set before the first of them is started.
        Environment.SetEnvironmentVariable("AUDION_STAND", _stand);
        if (!File.Exists(InStand("stand.marker")))
        {
            Console.WriteLine("СБОЙ  это не стенд: рядом нет stand.marker - запускается Tests\\Stand\\Run-Stand.ps1");
            return 99;
        }

        AppBuilder.Configure<SyncApp>().UseHeadless(new AvaloniaHeadlessPlatformOptions()).WithInterFont()
            .ConfigureFonts(fonts => fonts.AddFontCollection(new Avalonia.Media.Fonts.EmbeddedFontCollection(new Uri("fonts:JetBrainsMono"), new Uri("avares://AudionSyncTools/Assets/Fonts/JetBrainsMono"))))
            .SetupWithoutStarting();
        Lang.Set("en");
        string a = InStand("Audion Backup A"), b = InStand("Audion Backup B");

        void Home()
        {
            DataRoot.Choose(a);
            Sources.Rebuild();
            Rclone.SessionConfig = null;
            Rclone.SessionEnv.Clear();
            Sources.SetClouds(Array.Empty<Source>());
            Sources.LanUp.Clear(); Sources.Picked.Clear(); Sources.RouteFail.Clear();
            foreach (var file in new[] { "slow-plan", "plan-started", "marker-after-close.txt", "queued-marker.txt", "descendant-pid.txt", "lsjson-answer.json", "lsjson-fail", "moveto-fail", "moveto-fail-second", "moveto-real", "cat-self", "cat-silent", "say-ssh-over-host", "then-first.txt", "then-second.txt", "left-pid.txt", "after-leave.txt" }) File.Delete(InStand(file));
            Empty("rclone-calls.txt");
            Empty("worker-calls.txt");
        }

        void Clouds(string left, string right)
        {
            Sources.SetClouds(new[]
            {
                new Source { Key = "cloud-alpha", Label = "ALPHA", Remote = "alpha:", Cloud = true, CloudType = left },
                new Source { Key = "cloud-beta", Label = "BETA", Remote = "beta:", Cloud = true, CloudType = right },
            });
        }

        void SessionOfA()
        {
            Rclone.SessionConfig = Path.Combine(a, "session.conf");
            Rclone.SessionEnv["RCLONE_CONFIG_PASS"] = "fixture-password";
        }

        // ------------------------------------------------------------ AST-M01
        // The config of a cloud session is encrypted: read as text it has no section. The routes
        // of the machines are read from the plain rclone.conf of the data folder all the same.
        {
            Home();
            Sources.LanUp["base"] = false; Sources.LanUp["direct"] = false; Sources.LanUp["cloud"] = false;
            var before = new { configured = Rclone.Configured("base-via:"), route = Sources.RouteName("base"), path = Sources.RemotePath("base", "/C:/probe") };
            Rclone.SessionConfig = InStand("encrypted-session.conf");
            Rclone.SessionEnv["RCLONE_CONFIG_PASS"] = "fixture-password";
            var after = new { configured = Rclone.Configured("base-via:"), route = Sources.RouteName("base"), path = Sources.RemotePath("base", "/C:/probe") };
            Verdict("маршруты машин читаются и при зашифрованной сессии облаков",
                before.configured && before.route == Sources.RouteVia && before.Equals(after), new { before, after });
        }

        // ------------------------------------------------------------ AST-M02
        // A job runs with a child of its own, another waits in the queue. The cross asks; "no"
        // keeps the window and the work; "yes" takes the job, its child and the queue.
        {
            Home();
            var window = Window();
            var jobs = Jobs(window);
            jobs.Enqueue(new Job { Title = "a job with a child", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--parent" } });
            var child = Process.GetProcessById(((Process)Field(jobs, "_current")!).Id);
            jobs.Enqueue(new Job { Title = "must not start", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--marker", "queued-marker.txt" } });
            // The stub is still writing the file when it first shows: read with patience, and only a whole number counts.
            int pid = 0;
            bool born = Until(() => File.Exists(InStand("descendant-pid.txt")) && int.TryParse(Patient(() => File.ReadAllText(InStand("descendant-pid.txt"))), out pid));
            var descendant = born ? Process.GetProcessById(pid) : null;

            Call(window, "ChooseDataFolder", b); Pump(120);
            bool folderKept = DataRoot.Path_ == a;

            window.Close(); Pump(60);
            bool asks = Asked(window);
            Answer(window, null);
            bool noKeeps = window.IsVisible && !child.HasExited && jobs.Waiting == 1;

            window.Close();
            Answer(window, ""); Pump(200);
            bool killed = child.HasExited && (descendant?.HasExited ?? false);
            Pump(2700);
            bool silent = !File.Exists(InStand("marker-after-close.txt")) && !File.Exists(InStand("queued-marker.txt"));
            Verdict("закрытие окна спрашивает и останавливает задание с очередью",
                born && folderKept && asks && noKeeps && killed && jobs.Waiting == 0 && silent,
                new { born, folderKept, asks, noKeeps, killed, waiting = jobs.Waiting, silent });
        }

        // ------------------------------------------------------------ the job that left a helper behind
        // A job ends and leaves a child that holds its output open for twelve seconds - a script
        // that started a helper and went. The job is over when its process is: the next of the
        // queue starts within a few seconds, and the helper is left alone - it may be a tunnel.
        // The runner used to wait for the end of the output with no limit: the job stayed
        // "running" for as long as the helper lived, and STOP found nothing to kill (10.10.2026).
        {
            Home();
            var window = Window();
            var jobs = Jobs(window);
            jobs.Enqueue(new Job { Title = "a job that leaves a helper", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--leave" } });
            jobs.Enqueue(new Job { Title = "the next of the queue", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--quick", "after-leave.txt" } });
            int pid = 0;
            bool left = Until(() => File.Exists(InStand("left-pid.txt")) && int.TryParse(Patient(() => File.ReadAllText(InStand("left-pid.txt"))), out pid));
            Process? helper = null;
            try { if (left) helper = Process.GetProcessById(pid); } catch { }
            var timer = Stopwatch.StartNew();
            bool went = Until(() => File.Exists(InStand("after-leave.txt")), 8000);
            long took = timer.ElapsedMilliseconds;
            bool idle = Until(() => !jobs.Running, 3000);
            bool spared = helper is { HasExited: false };
            Verdict("задание, оставившее помощника с открытым выводом, кончается само, и очередь идёт дальше",
                left && went && idle && spared, new { left, went, took, idle, spared });
            // The helper is the stand's own: ended by its handle, so nothing of the probe stays behind.
            try { if (helper is { HasExited: false }) helper.Kill(); } catch { }
            Until(() => !jobs.Running, 14000);
            Close(window);
        }

        // ------------------------------------------------------------ AST-M03
        // Two clouds of one kind copy between themselves on the side of the provider: the flag
        // goes to COPY (and to its count), MIRROR and BISYNC - and to none of them between kinds.
        {
            Home();
            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            var rounds = new List<object>();
            bool all = true;
            foreach (var (mode, from, to, wanted) in new[] { ("copy", "drive", "drive", true), ("mirror", "drive", "drive", true), ("bisync", "drive", "drive", true), ("mirror", "drive", "dropbox", false) })
            {
                Clouds(from, to);
                left.Open("cloud-alpha", "from"); right.Open("cloud-beta", "to"); Pump(120);
                Empty("rclone-calls.txt");
                Call(window, "Sync", mode);
                Answer(window, "");
                Until(() => !Jobs(window).Running, 6000); Pump(120);
                var calls = RcloneCalls().Where(call => call.Contains(mode == "mirror" ? "sync" : mode)).ToArray();
                bool ok = calls.Length > 0 && calls.All(call => call.Contains("--server-side-across-configs") == wanted);
                all &= ok;
                rounds.Add(new { mode, from, to, wanted, calls = calls.Length, ok });
            }
            Verdict("копия между облаками одного вида идёт на их стороне", all, rounds);
            Close(window);
        }

        // ------------------------------------------------------------ AST-M04
        // The clouds of DATA A are still being asked for (a slow answer) when DATA B is chosen.
        // At once nothing of A is left in the window; its late answer does not come back; what
        // its session refreshed is saved into A; a panel that stood in A does not stay there.
        {
            Home();
            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            Call(window, "SetSection", "mirror", true);
            left.Open("data", a); right.Open("data", a); Pump(120);
            SessionOfA();
            var clock = Stopwatch.StartNew();
            Call(window, "OpenClouds"); Thread.Sleep(120);
            var change = (Task)Call(window, "ChooseDataFolder", b)!;
            var atOnce = new
            {
                session = Rclone.SessionConfig is null, password = !Rclone.SessionEnv.ContainsKey("RCLONE_CONFIG_PASS"),
                clouds = !Sources.All.Values.Any(source => source.Cloud), panels = !left.Path.StartsWith(a) && !right.Path.StartsWith(a),
            };
            // The change is waited for by what it does, not by the clock: the script that makes the
            // new folder ready takes as long as a cold PowerShell does. Then the late answer of A
            // (2.6 s after it was asked) is given its time to arrive - and to be dropped.
            Until(() => change.IsCompleted, 40000);
            Until(() => Rclone.SessionConfig == Path.Combine(b, "session.conf"), 10000);
            Pump((int)Math.Max(300, 3600 - clock.ElapsedMilliseconds));
            var clouds = Sources.All.Values.Where(source => source.Cloud).Select(source => source.Key).ToArray();
            var saves = WorkerCalls().Where(line => line.Contains("Get-Clouds.ps1") && line.Contains("-Save")).ToArray();
            bool ok = atOnce.session && atOnce.password && atOnce.clouds && atOnce.panels
                && DataRoot.Path_ == b && Rclone.SessionConfig == Path.Combine(b, "session.conf")
                && clouds.SequenceEqual(new[] { "cloud-beta" }) && saves.Length == 1 && saves[0].Contains(a);
            Verdict("папка данных меняется вместе со своей сессией облаков и панелями", ok,
                new { atOnce, data = Path.GetFileName(DataRoot.Path_), session = FolderOf(Rclone.SessionConfig), clouds, savedIntoA = saves.Length == 1 && saves[0].Contains(a) });
            Close(window);
        }

        // ------------------------------------------------------------ AST-M05
        // A data folder with nothing in it gets the frame of its addresses from the real script;
        // a second run leaves the file byte for byte; with the file gone the ADDRESSES wizard
        // lays it out again and opens.
        {
            Home();
            var window = Window();
            var fresh = InStand("Audion Backup Fresh " + Guid.NewGuid().ToString("N")[..8]);
            Directory.CreateDirectory(fresh);
            var choose = (Task)Call(window, "ChooseDataFolder", fresh)!;
            Until(() => choose.IsCompleted, 20000); Pump(400);
            var targets = Path.Combine(fresh, "Tunnel", "RemoteDesktop", "config", "targets.json");
            bool laidOut = File.Exists(targets);
            bool kept = false, back = false, wizard = false;
            if (laidOut)
            {
                var original = File.ReadAllBytes(targets);
                var again = (Task<bool>)Call(window, "PrepareData", "")!;
                Until(() => again.IsCompleted, 20000);
                kept = again.IsCompleted && !again.Result && original.SequenceEqual(File.ReadAllBytes(targets));
                File.Delete(targets);
                Call(window, "SetupTargets");
                back = Until(() => File.Exists(targets), 20000);
                wizard = Until(() => window.OwnedWindows.Any(), 8000);
            }
            Verdict("пустая папка данных получает каркас адресов, мастер АДРЕСА открывается", laidOut && kept && back && wizard, new { laidOut, kept, back, wizard });
            Close(window);
        }

        // ------------------------------------------------------------ AST-M07
        // COPY counts what will go before it asks, and the count is not a job of the queue. While
        // it runs the data folder is not changed: the question comes for the folder it began in,
        // and its transfer goes with the config of that folder.
        {
            Home();
            var window = Window();
            Clouds("drive", "drive");
            window.FindControl<FilePanel>("LeftPanel")!.Open("cloud-alpha", "from-A");
            window.FindControl<FilePanel>("RightPanel")!.Open("cloud-beta", "to-A");
            Pump(120);
            SessionOfA();
            File.WriteAllText(InStand("slow-plan"), "on");
            Call(window, "Sync", "copy");
            bool counting = Until(() => File.Exists(InStand("plan-started")));
            bool notQueued = !Jobs(window).Running;
            var change = (Task)Call(window, "ChooseDataFolder", b)!;
            Until(() => change.IsCompleted, 12000);
            bool refused = DataRoot.Path_ == a;
            // Changed after all - the session of B is let to open: the worst case.
            if (!refused) Until(() => Rclone.SessionConfig == Path.Combine(b, "session.conf"), 6000);
            bool asked = Answer(window, "", 12000);
            Until(() => !Jobs(window).Running, 6000); Pump(200);
            var transfer = RcloneCalls().FirstOrDefault(call => call.Contains("copy") && !call.Contains("--dry-run"));
            bool own = transfer is not null && ConfigOf(transfer) == "Audion Backup A" && transfer.Contains("alpha:/from-A") && transfer.Contains("beta:/to-A");
            Verdict("пока COPY считает, папка данных не меняется", counting && notQueued && refused && asked && own,
                new { counting, notQueued, refused, asked, config = ConfigOf(transfer), paths = transfer?.Where(arg => arg.Contains(":/")).ToArray() });
            File.Delete(InStand("slow-plan"));
            Close(window);
        }

        // The same with a question on the screen: MIRROR asks, the data folder is changed, the answer comes after.
        {
            Home();
            var window = Window();
            Clouds("drive", "drive");
            window.FindControl<FilePanel>("LeftPanel")!.Open("cloud-alpha", "from-A");
            window.FindControl<FilePanel>("RightPanel")!.Open("cloud-beta", "to-A");
            Pump(120);
            SessionOfA();
            Call(window, "Sync", "mirror");
            bool asking = Until(() => Asked(window));
            var change = (Task)Call(window, "ChooseDataFolder", b)!;
            Until(() => change.IsCompleted, 12000);
            bool refused = DataRoot.Path_ == a;
            if (!refused) Until(() => Rclone.SessionConfig == Path.Combine(b, "session.conf"), 6000);
            Answer(window, "");
            Until(() => !Jobs(window).Running, 6000); Pump(200);
            var transfer = RcloneCalls().FirstOrDefault(call => call.Contains("sync"));
            bool own = transfer is not null && ConfigOf(transfer) == "Audion Backup A";
            Verdict("пока вопрос MIRROR на экране, папка данных не меняется", asking && refused && own, new { asking, refused, config = ConfigOf(transfer) });
            Close(window);
        }

        // ------------------------------------------------------------ the panel went elsewhere
        // A question of the main window does not block the search window, and GO TO FILE sends
        // the active panel to another folder while the question waits. The operation goes where
        // the question said: F8, F5, F2, F7.
        {
            Home();
            string work = InStand("work"), one = Path.Combine(work, "one"), two = Path.Combine(work, "two"), to1 = Path.Combine(work, "to1"), to2 = Path.Combine(work, "to2");
            foreach (var dir in new[] { one, two, to1, to2 }) Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(one, "same.txt"), "one");
            File.WriteAllText(Path.Combine(two, "same.txt"), "two");

            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            string Short(string arg) => arg.Replace('\\', '/').Replace(work.Replace('\\', '/') + "/", "");
            string[] Last(string verb)
            {
                // The call is waited for, not the clock: F2 reads the folder before it queues its job.
                Until(() => RcloneCalls().Any(one => one.Contains(verb)), 6000);
                Until(() => !Jobs(window).Running, 6000); Pump(200);
                var call = RcloneCalls().LastOrDefault(one => one.Contains(verb));
                return call is null ? Array.Empty<string>() : call.Where(arg => arg.Replace('\\', '/').Contains("/work/")).Select(Short).ToArray();
            }
            bool Ready()
            {
                left.Open("local", one); right.Open("local", to1);
                Call(window, "SetActive", left);
                Empty("rclone-calls.txt");
                return Until(() => left.Rows.Count == 1 && left.Path == one && right.Path == to1, 4000);
            }

            // F8 past the Recycle Bin (SHIFT+DEL): on a disk of this machine that is the road through rclone.
            bool ready = Ready();
            Call(window, "Delete", true);
            bool asked = Until(() => Asked(window));
            left.Go("local", two, null); Pump(250);
            Answer(window, "");
            var deleted = Last("deletefile");

            ready &= Ready();
            Call(window, "Copy", false);
            asked &= Until(() => Asked(window));
            right.Go("local", to2, null); left.Go("local", two, null); Pump(250);
            Answer(window, "");
            var copied = Last("copyto");

            ready &= Ready();
            Call(window, "Rename");
            asked &= Until(() => Asked(window));
            left.Go("local", two, null); Pump(250);
            Answer(window, "renamed.txt");
            var renamed = Last("moveto");

            ready &= Ready();
            Call(window, "Mkdir");
            asked &= Until(() => Asked(window));
            left.Go("local", two, null); Pump(250);
            Answer(window, "made");
            var made = Last("mkdir");

            bool Stays(string[] call) => call.Length > 0 && call.All(arg => arg.StartsWith("one/") || arg.StartsWith("to1/"));
            Verdict("F8, F5, F2 и F7 идут туда, что назвал вопрос, куда бы ни ушла панель",
                ready && asked && Stays(deleted) && Stays(copied) && Stays(renamed) && Stays(made), new { ready, asked, deleted, copied, renamed, made });
            Close(window);
        }

        // ------------------------------------------------------------ F2
        // rclone renames onto a taken name without a word - the file there is deleted - and over
        // ssh it deletes a file whose name changes by the case of a letter alone (the review of
        // 08.10.2026). The window reads the folder first: a taken name is refused, a free one goes
        // with the fuse, the case alone goes in two steps where one would lose the object - and
        // the second step never starts after a first one that failed.
        {
            Home();
            string dir = InStand("rename", "dir");
            if (Directory.Exists(InStand("rename"))) Directory.Delete(InStand("rename"), true);
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "a.txt"), "a");
            File.WriteAllText(Path.Combine(dir, "b.txt"), "b");
            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            bool Said(string part) { lock (said) return said.Any(line => line.Contains(part)); }

            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            string[][] Moves() => RcloneCalls().Where(call => call.Contains("moveto")).ToArray();
            string[] Ends(string[] call) => call.SkipWhile(arg => arg != "moveto").Skip(1).Take(2).Select(arg => arg.Replace('\\', '/')).Select(arg => arg[(arg.LastIndexOf('/') + 1)..]).ToArray();
            bool Fused(string[] call, bool file) => call.Contains("--ignore-existing") && call.Contains("--error-on-no-transfer") == file;
            bool On(string key, string path, string name, int rows)
            {
                left.Go(key, path, name);
                Call(window, "SetActive", left);
                bool there = Until(() => left.Rows.Count == rows && left.CursorRow?.Name == name, 5000);
                Empty("rclone-calls.txt");
                lock (said) said.Clear();
                return there;
            }
            bool Rename(string to)
            {
                Call(window, "Rename");
                return Answer(window, to);
            }

            bool ready = On("local", dir, "a.txt", 2) && Rename("b.txt");
            bool refused = Until(() => Said("is taken")) && Moves().Length == 0;

            ready &= On("local", dir, "a.txt", 2) && Rename("c.txt");
            bool free = Until(() => Moves().Length == 1) && Ends(Moves()[0]).SequenceEqual(new[] { "a.txt", "c.txt" }) && Fused(Moves()[0], file: true);
            Until(() => !Jobs(window).Running, 6000);

            ready &= On("local", dir, "a.txt", 2) && Rename("A.TXT");
            bool twoSteps = Until(() => Moves().Length == 2);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var steps = Moves().Select(Ends).ToArray();
            twoSteps &= steps.Length == 2 && steps[0][0] == "a.txt" && steps[0][1].StartsWith("a.txt.~f2-") && steps[1][0] == steps[0][1] && steps[1][1] == "A.TXT";

            ready &= On("local", dir, "a.txt", 2);
            File.WriteAllText(InStand("moveto-fail"), "on");
            ready &= Rename("A.TXT");
            Until(() => Moves().Length >= 1); Until(() => !Jobs(window).Running, 6000); Pump(400);
            bool halted = Moves().Length == 1;
            File.Delete(InStand("moveto-fail"));

            ready &= On("local", dir, "a.txt", 2);
            File.WriteAllText(InStand("lsjson-fail"), "on");
            ready &= Rename("d.txt");
            bool unread = Until(() => Said("could not be read")) && Moves().Length == 0;
            File.Delete(InStand("lsjson-fail"));

            // A machine over ssh and a cloud: what they hold is what the stub is told to answer.
            File.WriteAllText(InStand("lsjson-answer.json"), "[{\"Name\":\"name.txt\",\"IsDir\":false,\"Size\":1,\"ModTime\":\"2026-10-08T00:00:00Z\"}]");
            ready &= On("base", "/C:/x", "name.txt", 1) && Rename("NAME.txt");
            bool machine = Until(() => Moves().Length == 2);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var far = Moves().Select(call => call.SkipWhile(arg => arg != "moveto").Skip(1).Take(2).ToArray()).ToArray();
            machine &= far.Length == 2 && far[0][0] == "base:/C:/x/name.txt" && far[0][1].StartsWith("base:/C:/x/name.txt.~f2-") && far[1][0] == far[0][1] && far[1][1] == "base:/C:/x/NAME.txt";

            Clouds("drive", "drive");
            ready &= On("cloud-alpha", "x", "name.txt", 1) && Rename("NAME.txt");
            bool cloud = Until(() => Moves().Length == 1);
            Until(() => !Jobs(window).Running, 6000); Pump(400);
            cloud &= Moves().Length == 1 && Fused(Moves()[0], file: true);

            // The name was free at the press of F2 and is taken by the time the job has its turn: the queue
            // held it behind a transfer. The folder is read once more right before the start (the audit of
            // 08.10.2026), and the rename does not begin.
            ready &= On("local", dir, "a.txt", 2);
            Call(window, "Rename");
            ready &= Until(() => Asked(window));
            // The transfer ahead starts when the question is already on the screen: the answer, the reading of
            // the folder and the place in the queue all fit into its 2.3 seconds.
            Jobs(window).Enqueue(new Job { Title = "a transfer ahead", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--marker", "queued-marker.txt" } });
            ready &= Answer(window, "late.txt") && Until(() => Jobs(window).Waiting == 1, 5000);
            File.WriteAllText(Path.Combine(dir, "late.txt"), "taken meanwhile");
            Until(() => !Jobs(window).Running && Jobs(window).Waiting == 0, 9000); Pump(300);
            bool takenLater = Said("is taken") && Moves().Length == 0;
            File.Delete(Path.Combine(dir, "late.txt"));

            // A folder whose new name is taken in the last moment is poured into the folder that took it, and
            // rclone calls that a success. The stub renames nothing, so the folder is found where it was: the
            // job is a failure and says what became of the two.
            Directory.CreateDirectory(Path.Combine(dir, "one"));
            ready &= On("local", dir, "one", 3) && Rename("two");
            bool stayed = Until(() => Said("stayed where it was"), 6000) && Moves().Length == 1 && Fused(Moves()[0], file: false);
            Until(() => !Jobs(window).Running, 6000); Pump(200);
            // A folder that did move is a success without a word more.
            File.WriteAllText(InStand("moveto-real"), "on");
            ready &= On("local", dir, "one", 3) && Rename("two");
            Until(() => Moves().Length == 1); Until(() => !Jobs(window).Running, 6000); Pump(300);
            bool movedDir = Directory.Exists(Path.Combine(dir, "two")) && !Directory.Exists(Path.Combine(dir, "one")) && !Said("stayed where it was") && Said(": ready");
            File.Delete(InStand("moveto-real"));

            // The second step of a rename by the case of a letter fails: the object lies under the temporary
            // name, and the journal says which - the title of the job names only the old one.
            ready &= On("local", dir, "a.txt", 3);
            File.WriteAllText(InStand("moveto-fail-second"), "on");
            ready &= Rename("A.TXT");
            Until(() => Moves().Length == 2); Until(() => !Jobs(window).Running, 6000); Pump(300);
            bool leftAs = Said("left under the temporary name") && Said("a.txt.~f2-");
            File.Delete(InStand("moveto-fail-second"));

            Journal.Lines -= listen;
            Verdict("F2 на занятое имя не переименовывает, а один регистр меняет в два шага",
                ready && refused && free && twoSteps && halted && unread && machine && cloud,
                new { ready, refused, free, twoSteps, steps, halted, unread, machine, far, cloud });
            Verdict("F2: имя, занятое пока задание ждало, папка, оставшаяся на месте, и временное имя названы",
                ready && takenLater && stayed && movedDir && leftAs, new { ready, takenLater, stayed, movedDir, leftAs });
            Close(window);
        }

        // ------------------------------------------------------------ F8 and the Recycle Bin
        // On a disk of this machine F8 goes into the Recycle Bin of Windows and not through rclone,
        // and the question says which of the two it is. The bin of the owner is not touched: the
        // object is taken away before the answer, so the bin has nothing to take - and the same
        // name in the folder the panel went to meanwhile stays, which it would not if the place
        // were read after the answer.
        {
            Home();
            string one = InStand("bin", "one"), two = InStand("bin", "two");
            if (Directory.Exists(InStand("bin"))) Directory.Delete(InStand("bin"), true);
            foreach (var dir in new[] { one, two }) { Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "same.txt"), "text"); }
            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            bool Said(string part) { lock (said) return said.Any(line => line.Contains(part)); }

            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            string[] Words() => window.OwnedWindows.OfType<Dialog>().Single().GetVisualDescendants().OfType<TextBlock>().Select(text => text.Text ?? "").ToArray();
            string[][] Deletes() => RcloneCalls().Where(call => call.Contains("deletefile") || call.Contains("purge")).ToArray();
            bool On(string key, string path, string name)
            {
                left.Go(key, path, name);
                Call(window, "SetActive", left);
                bool there = Until(() => left.CursorRow?.Name == name, 5000);
                Empty("rclone-calls.txt");
                return there;
            }

            bool ready = On("local", one, "same.txt");
            Call(window, "Delete", false);
            bool asked = Until(() => Asked(window));
            var words = asked ? Words() : Array.Empty<string>();
            bool saysBin = words.Any(word => word.Contains("Windows Recycle Bin")) && !words.Any(word => word.Contains("Remote sources"));
            File.Delete(Path.Combine(one, "same.txt"));
            left.Go("local", two, null); Pump(250);
            Answer(window, "");
            bool toBin = Until(() => Said("no such object")) && Said(Path.Combine(one, "same.txt"));
            Until(() => !Jobs(window).Running, 6000); Pump(200);
            bool spared = File.Exists(Path.Combine(two, "same.txt")) && Deletes().Length == 0;

            // SHIFT+DEL on the same disk: the question says "for good", and rclone deletes.
            File.WriteAllText(Path.Combine(one, "same.txt"), "text");
            ready &= On("local", one, "same.txt");
            Call(window, "Delete", true);
            asked &= Until(() => Asked(window));
            words = Asked(window) ? Words() : Array.Empty<string>();
            bool saysForGood = words.Any(word => word.Contains("for good")) && words.Any(word => word.Contains("Past the Recycle Bin"));
            Answer(window, "");
            bool pastBin = Until(() => Deletes().Length == 1);
            Until(() => !Jobs(window).Running, 6000);

            // A machine over ssh has no bin: the question says so, and rclone deletes.
            File.WriteAllText(InStand("lsjson-answer.json"), "[{\"Name\":\"name.txt\",\"IsDir\":false,\"Size\":1,\"ModTime\":\"2026-10-08T00:00:00Z\"}]");
            ready &= On("base", "/C:/x", "name.txt");
            Call(window, "Delete", false);
            asked &= Until(() => Asked(window));
            words = Asked(window) ? Words() : Array.Empty<string>();
            bool saysNoBin = words.Any(word => word.Contains("Remote sources have no recycle bin"));
            Answer(window, "");
            bool farDeleted = Until(() => Deletes().Length == 1) && Deletes()[0].Contains("base:/C:/x/name.txt");
            Until(() => !Jobs(window).Running, 6000);

            Journal.Lines -= listen;
            Verdict("F8 на диске этой машины идёт в корзину Windows, SHIFT+DEL и машина - мимо, и вопрос это говорит",
                ready && asked && saysBin && toBin && spared && saysForGood && pastBin && saysNoBin && farDeleted,
                new { ready, asked, saysBin, toBin, spared, saysForGood, pastBin, saysNoBin, farDeleted });
            Close(window);
        }

        // ------------------------------------------------------------ one folder inside the other
        // rclone refuses a mirror of a folder into its own parent only when it sees that it is one:
        // not through a junction, and not when the same machine is named over ssh - there the
        // mirror deleted the neighbours and the source itself; and a copy of a folder into its own
        // subfolder it does not refuse at all (the review of 08.10.2026). The window refuses these
        // before its question, and does not refuse what only looks alike.
        {
            Home();
            string work = InStand("overlap"), data = Path.Combine(work, "Data"), proj = Path.Combine(data, "Proj"), sub = Path.Combine(proj, "sub"), link = Path.Combine(work, "Link");
            if (Directory.Exists(link)) Directory.Delete(link);
            if (Directory.Exists(work)) Directory.Delete(work, true);
            Directory.CreateDirectory(sub);
            File.WriteAllText(Path.Combine(proj, "p.txt"), "project file");
            File.WriteAllText(Path.Combine(data, "keep.txt"), "beside");
            using (var made = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{proj}\"") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true })!) made.WaitForExit();
            // The same folder as a machine over ssh names it: "/C:/..." for C:\...
            string Far(string path) => "/" + path[..2] + path[2..].Replace('\\', '/');
            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            bool Said(string part) { lock (said) return said.Any(line => line.Contains(part)); }

            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            bool Stand(string leftKey, string leftPath, string? cursor, string rightKey, string rightPath)
            {
                left.Go(leftKey, leftPath, cursor); right.Go(rightKey, rightPath, null);
                Call(window, "SetActive", left);
                bool there = Until(() => left.Path == leftPath && right.Path == rightPath && (cursor is null || left.CursorRow?.Name == cursor), 5000);
                Pump(150);
                Empty("rclone-calls.txt");
                lock (said) said.Clear();
                return there;
            }
            bool Refused(string why, params string[] verbs)
            {
                bool told = Until(() => Said(why), 3000);
                bool quiet = !Asked(window) && !RcloneCalls().Any(call => verbs.Any(call.Contains));
                // Asked after all - this build does not refuse. The question is closed, or the next step would open a second one.
                if (Asked(window)) Answer(window, null);
                return told && quiet;
            }

            bool ready = Directory.Exists(link) && Stand("local", link, null, "local", data);
            Call(window, "Sync", "mirror");
            bool junction = Refused("source inside target", "sync");

            ready &= Stand("local", data, "Proj", "local", sub);
            Call(window, "Copy", false);
            bool intoItself = Refused("target inside source", "copy");

            Clouds("drive", "drive");
            ready &= Stand("cloud-alpha", "a", null, "cloud-alpha", "a/b");
            Call(window, "Sync", "copy");
            bool oneStorage = Refused("target inside source", "copy");

            ready &= Stand("local", proj, null, "laptop", Far(data));
            Call(window, "Sync", "mirror");
            bool twoNames = Refused("source inside target", "sync");

            // A file into a subfolder of its own folder is an ordinary copy: the question comes, the copy goes.
            ready &= Stand("local", proj, "p.txt", "local", sub);
            Call(window, "Copy", false);
            bool lawful = Answer(window, "") && Until(() => RcloneCalls().Any(call => call.Contains("copyto")));
            Until(() => !Jobs(window).Running, 6000);

            // Another machine with the same path is another place: the mirror asks as it always did.
            ready &= Stand("local", proj, null, "base", Far(data));
            Call(window, "Sync", "mirror");
            bool otherMachine = Until(() => Asked(window), 4000);
            Answer(window, null);

            // The same machine by a far road. Its address says nothing there, and it was let through: a
            // button of the row ROUTE sends BASE to itself by a VPS, a laptop away from home reaches itself
            // through its own tunnel - and the mirror deleted (the audit of 08.10.2026). The machine is asked
            // which one it is: the mark of this computer is read through it.
            string[][] Marks() => RcloneCalls().Where(call => call.Contains("cat")).ToArray();
            Sources.Picked["base"] = "via";
            // No answer to that reading: the operation would get none either, and is not begun.
            File.WriteAllText(InStand("cat-silent"), "on");
            ready &= Stand("local", proj, null, "base", Far(data));
            Call(window, "Sync", "mirror");
            bool silent = Refused("did not answer", "sync");
            var asked = Marks();
            silent &= asked.Length == 1 && asked[0].Any(arg => arg.StartsWith("base-via:/") && arg.EndsWith("/._runtime/this-machine.id"));
            File.Delete(InStand("cat-silent"));
            // Another machine has no such file: the mirror asks as it always did.
            ready &= Stand("local", proj, null, "base", Far(data));
            Call(window, "Sync", "mirror");
            bool farOther = Until(() => Asked(window), 4000) && Marks().Length == 1;
            Answer(window, null);
            // This machine answers with its own mark: refused, and said why. What a machine answered is
            // remembered for five minutes; Rebuild forgets it, as a change of the data folder does.
            Sources.Rebuild();
            File.WriteAllText(InStand("cat-self"), "on");
            ready &= Stand("local", proj, null, "base", Far(data));
            Call(window, "Sync", "mirror");
            bool farSame = Refused("source inside target", "sync") && Said("is this very machine") && Marks().Length == 1;
            // The second mirror between the same two is refused by what is remembered: the machine is not asked again.
            Empty("rclone-calls.txt");
            lock (said) said.Clear();
            Call(window, "Sync", "mirror");
            bool remembered = Refused("source inside target", "sync") && Marks().Length == 0;
            // F5 of a folder into its own subfolder on "the other machine" is the same trap.
            ready &= Stand("local", data, "Proj", "base", Far(sub));
            Call(window, "Copy", false);
            bool farCopy = Refused("target inside source", "copy");
            // Paths that do not meet need no question to the machine at all.
            Sources.Rebuild();
            ready &= Stand("local", proj, null, "base", "/Z:/elsewhere");
            Call(window, "Sync", "mirror");
            bool unasked = Until(() => Asked(window), 4000) && Marks().Length == 0;
            Answer(window, null);
            File.Delete(InStand("cat-self"));
            Sources.Picked.Clear();

            Journal.Lines -= listen;
            Verdict("папка внутри другой: зеркало и копия отклоняются до вопроса, похожее - нет",
                ready && junction && intoItself && oneStorage && twoNames && lawful && otherMachine,
                new { ready, junction, intoItself, oneStorage, twoNames, lawful, otherMachine });
            Verdict("эта же машина дальним маршрутом: её спрашивают, и зеркало в саму себя отклоняется",
                ready && silent && farOther && farSame && remembered && farCopy && unasked,
                new { ready, silent, farOther, farSame, remembered, farCopy, unasked, asked = asked.Select(call => call.LastOrDefault(arg => arg.Contains(":/")) ?? "").ToArray() });
            Close(window);
            if (Directory.Exists(link)) Directory.Delete(link);
        }

        // ------------------------------------------------------------ Esc
        // Esc while a job runs is СТОП - from the panels. Typed into a text field it belongs to the
        // field: Esc in the quick filter used to stop the transfer and drop its queue, while the
        // cross of the window in the same state asks first.
        {
            Home();
            var window = Window();
            var jobs = Jobs(window);
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            left.Open("local", _stand); Pump(150);
            jobs.Enqueue(new Job { Title = "a job that runs", Exe = InStand("Worker", "Worker.exe"), Args = new() { "--parent" } });
            bool running = Until(() => jobs.Running);
            left.OpenQuickFilter(); Pump(100);
            var field = left.GetVisualDescendants().OfType<TextBox>().FirstOrDefault(box => box.IsVisible);
            var typed = new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Escape, Source = field };
            Call(window, "OnKey", window, typed);
            Pump(200);
            bool kept = field is not null && jobs.Running && !typed.Handled;
            var pressed = new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Escape, Source = left };
            Call(window, "OnKey", window, pressed);
            bool stopped = Until(() => !jobs.Running, 5000) && pressed.Handled;
            Verdict("Esc из поля ввода передачу не останавливает, из панели - останавливает", running && kept && stopped, new { running, field = field is not null, kept, stopped });
            Close(window);
        }

        // ------------------------------------------------------------ THROUGH MAIN VPS
        // The transfer between two clouds by MAIN VPS started at one press, and СТОП of the window
        // cannot reach it once it runs there. It asks first, says that, and goes with the two
        // addresses its question named; a cloud into its own subfolder is refused.
        {
            Home();
            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            Clouds("drive", "dropbox");
            left.Open("cloud-alpha", "from"); right.Open("cloud-beta", "to"); Pump(200);
            string[] Sent() => WorkerCalls().Where(line => line.Contains("Send-ViaServer.ps1")).ToArray();

            Empty("worker-calls.txt");
            Call(window, "CloudSend");
            bool asked = Until(() => Asked(window), 10000);
            var words = asked ? window.OwnedWindows.OfType<Dialog>().Single().GetVisualDescendants().OfType<TextBlock>().Select(text => text.Text ?? "").ToArray() : Array.Empty<string>();
            bool says = words.Any(word => word.Contains("STOP will not stop it")) && words.Any(word => word.Contains("alpha", StringComparison.OrdinalIgnoreCase)) && Sent().Length == 0;
            Answer(window, null); Pump(400);
            bool cancelled = Sent().Length == 0;

            Call(window, "CloudSend");
            left.Go("cloud-alpha", "elsewhere", null);
            bool sent = Answer(window, "", 10000) && Until(() => Sent().Length == 1) && Sent()[0].Contains("alpha:from") && Sent()[0].Contains("beta:to");
            Until(() => !Jobs(window).Running, 6000);

            left.Open("cloud-alpha", "from"); right.Open("cloud-alpha", "from/deeper"); Pump(200);
            Empty("worker-calls.txt");
            Call(window, "CloudSend");
            bool refused = Until(() => { lock (said) return said.Any(line => line.Contains("target inside source")); }, 4000) && !Asked(window) && Sent().Length == 0;
            if (Asked(window)) Answer(window, null);

            Journal.Lines -= listen;
            Verdict("ЧЕРЕЗ MAIN VPS спрашивает, говорит про СТОП и идёт по названным адресам", asked && says && cancelled && sent && refused, new { asked, says, cancelled, sent, refused, calls = Sent() });
            Close(window);
        }

        // ------------------------------------------------------------ BISYNC and the road
        // BISYNC keeps what it knows of a pair under the names of its two ends, and the name of a
        // machine's remote changed with the road to it: a pair made at home was a new pair from
        // afar and went with --resync - what had changed in the target was overwritten (the review
        // of 08.10.2026). The machine is named by its plain remote by any road now; the road goes
        // to rclone in variables of the process.
        {
            Home();
            string local = InStand("pair");
            Directory.CreateDirectory(local);
            foreach (var kept in Directory.Exists(Path.Combine(a, "config", "bisync")) ? new[] { Path.Combine(a, "config", "bisync") } : Array.Empty<string>()) Directory.Delete(kept, true);
            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            var right = window.FindControl<FilePanel>("RightPanel")!;
            string[] Last() => RcloneCalls().LastOrDefault(call => call.Contains("bisync")) ?? Array.Empty<string>();
            string State(string[] call) => call.SkipWhile(arg => arg != "--workdir").Skip(1).FirstOrDefault() ?? "";
            string[] Road(string[] call) => call.Where(arg => arg.StartsWith("env:RCLONE_CONFIG_")).ToArray();
            bool Stand(string machine)
            {
                left.Open("local", local); right.Open(machine, "/C:/pair");
                Call(window, "SetActive", left);
                bool there = Until(() => left.Path == local && right.SourceKey == machine, 4000);
                Pump(150);
                Empty("rclone-calls.txt");
                return there;
            }

            // At home, the first run: the question, --resync, the plain name, no variables.
            bool ready = Stand("base");
            Call(window, "Sync", "bisync");
            bool asked = Answer(window, "") && Until(() => Last().Length > 0);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var straight = Last();
            bool first = asked && straight.Contains("--resync") && straight.Contains("base:/C:/pair") && Road(straight).Length == 0;
            // The stub leaves no listings behind; rclone does, and by them the window knows the pair.
            if (State(straight).Length > 0) foreach (var side in new[] { "path1", "path2" }) File.WriteAllText(Path.Combine(State(straight), $"local..base_C_pair.{side}.lst"), "");

            // From afar: the straight road is silent, the pair is the same pair.
            Sources.LanUp["base"] = false; Sources.LanUp["direct"] = false; Sources.LanUp["cloud"] = false;
            Empty("rclone-calls.txt");
            Call(window, "Sync", "bisync");
            bool known = Until(() => Last().Length > 0, 5000) && !Asked(window);
            if (Asked(window)) Answer(window, null);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var far = Last();
            bool same = known && far.Contains("base:/C:/pair") && !far.Contains("--resync") && State(far) == State(straight)
                // The far remote names an ssh program and no host: the host of the straight one is taken away as well.
                && Road(far).SequenceEqual(new[] { "env:RCLONE_CONFIG_BASE_HOST=", "env:RCLONE_CONFIG_BASE_SSH=ssh base-far" });

            // A machine whose far road is an address and a port of its own, met from afar at once.
            Sources.LanUp["dad"] = false;
            ready &= Stand("dad");
            Call(window, "Sync", "bisync");
            bool other = Answer(window, "") && Until(() => Last().Length > 0);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var dad = Last();
            other &= dad.Contains("dad:/C:/pair") && dad.Contains("--resync") && State(dad) != State(straight)
                && Road(dad).SequenceEqual(new[] { "env:RCLONE_CONFIG_DAD_HOST=192.0.2.40", "env:RCLONE_CONFIG_DAD_PORT=2222" });

            // A machine whose straight road is an ssh program of its own, and whose far road says "ssh ="
            // and names a host. What the far road leaves empty must not be inherited from the straight
            // one: rclone started the ssh program of the straight road for a pair meant to go by the
            // host of the far one (the audit after the review of 08.10.2026). An empty variable takes it away.
            Sources.LanUp["home"] = false;
            ready &= Stand("home");
            Call(window, "Sync", "bisync");
            bool emptied = Answer(window, "") && Until(() => Last().Length > 0);
            Until(() => !Jobs(window).Running, 6000); Pump(150);
            var home = Last();
            emptied &= home.Contains("home:/C:/pair") && Road(home).SequenceEqual(new[] { "env:RCLONE_CONFIG_HOME_HOST=192.0.2.60", "env:RCLONE_CONFIG_HOME_SSH=" });

            // rclone warns of an ssh program laid over a host on every call. In BISYNC from afar the window
            // lays it there itself, and the line stays out of the journal of that job - of that job alone:
            // in any other it tells of a mistake in the working config, and it was hidden there as well
            // (the audit of 08.10.2026).
            var heard = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (heard) heard.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            bool Heard(string part) { lock (heard) return heard.Any(line => line.Contains(part)); }
            File.WriteAllText(InStand("say-ssh-over-host"), "on");
            ready &= Stand("base");
            Call(window, "Sync", "bisync");
            if (Until(() => Asked(window), 1500)) Answer(window, "");
            Until(() => Last().Length > 0, 5000); Until(() => !Jobs(window).Running, 6000); Pump(300);
            bool hushed = Road(Last()).Any(arg => arg.StartsWith("env:RCLONE_CONFIG_BASE_SSH=ssh")) && Heard("BISYNC") && !Heard("--sftp-ssh is in use");
            Call(window, "Mkdir");
            bool spoken = Answer(window, "made") && Until(() => RcloneCalls().Any(call => call.Contains("mkdir")), 5000);
            Until(() => !Jobs(window).Running, 6000); Pump(300);
            spoken &= Heard("--sftp-ssh is in use");
            File.Delete(InStand("say-ssh-over-host"));
            Journal.Lines -= listen;

            Verdict("пара BISYNC остаётся той же парой при смене дороги", ready && first && same && other && emptied,
                new { ready, first, known, same, other, emptied, far = far.Where(arg => arg.Contains("pair") || arg.StartsWith("env:") || arg == "--resync").ToArray(), dad = Road(dad), home = Road(home) });
            Verdict("предупреждение rclone об ssh поверх адреса молчит только в BISYNC издалека", ready && hushed && spoken, new { ready, hushed, spoken });
            Close(window);
        }

        // ------------------------------------------------------------ СТОП between the two halves
        // A rename by way of a temporary name is two jobs, the second following the first (Job.Then).
        // The process of the first may have ended a moment before СТОП, its verdict still waiting for
        // the thread of the window: СТОП found nothing to kill and emptied the queue - and the second
        // half was put into it afterwards and ran (the audit after the review of 08.10.2026). Here the
        // window is not let to take the verdict until СТОП is pressed: nothing is pumped in between.
        {
            Home();
            var window = Window();
            var jobs = Jobs(window);
            Job Quick(string file) => new Job { Title = "a half: " + file, Exe = InStand("Worker", "Worker.exe"), Args = new() { "--quick", file } };

            var first = Quick("then-first.txt");
            first.Then = Quick("then-second.txt");
            jobs.Enqueue(first);
            bool follows = Until(() => File.Exists(InStand("then-second.txt")), 8000);
            Until(() => !jobs.Running, 5000); Pump(150);
            foreach (var file in new[] { "then-first.txt", "then-second.txt" }) File.Delete(InStand(file));

            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            first = Quick("then-first.txt");
            var second = Quick("then-second.txt");
            // Where the half that did not run leaves the object: the journal names only the old name otherwise.
            // By its name, not by the member: the same probes are built against the window before the fix.
            typeof(Job).GetProperty("Undone")?.SetValue(second, "the object lies under a name of the stand");
            first.Then = second;
            jobs.Enqueue(first);
            var process = (Process?)Field(jobs, "_current");
            var clock = Stopwatch.StartNew();
            while (clock.ElapsedMilliseconds < 8000 && !(File.Exists(InStand("then-first.txt")) && (process?.HasExited ?? true))) Thread.Sleep(20);
            // The reader threads have posted the verdict by now; the window has not taken it.
            Thread.Sleep(500);
            bool waiting = jobs.Running && File.Exists(InStand("then-first.txt"));
            jobs.Stop();
            Pump(1500);
            bool held = !File.Exists(InStand("then-second.txt")) && !jobs.Running && jobs.Waiting == 0;
            Journal.Lines -= listen;
            bool told;
            lock (said) told = said.Any(line => line.Contains("the object lies under a name of the stand"));
            Verdict("СТОП между двумя шагами одного действия: второй шаг не начинается", follows && waiting && held, new { follows, waiting, held });
            Verdict("и журнал говорит, под каким именем остался объект", told, new { told });

            // A job may ask a question right before it starts (F2 reads the folder once more). СТОП pressed
            // while that question is out must leave the job unstarted, whatever the answer turns out to be.
            foreach (var file in new[] { "then-first.txt", "then-second.txt" }) File.Delete(InStand(file));
            var guarded = Quick("then-first.txt");
            typeof(Job).GetProperty("Before")?.SetValue(guarded, (Func<CancellationToken, List<string>>)(_ => { Thread.Sleep(1200); return new List<string>(); }));
            jobs.Enqueue(guarded);
            Pump(300);
            bool asking = jobs.Running && !File.Exists(InStand("then-first.txt"));
            jobs.Stop();
            Pump(2200);
            bool unstarted = !File.Exists(InStand("then-first.txt")) && !jobs.Running && jobs.Waiting == 0;
            Verdict("СТОП, пока задание спрашивает перед запуском: оно не начинается", asking && unstarted, new { asking, unstarted });
            Close(window);
        }

        // ------------------------------------------------------------ the rows of the folder just left
        // A panel that goes to another folder shows the path of the new one at once, and the rows come
        // when the folder is read. Until then the rows of the folder left stood under the new path on
        // a disk of this machine - a machine over ssh and a bucket were cleared at once - and F2, F8
        // and F5 took a name from the old rows and the path of the new folder (the audit of 08.10.2026).
        {
            Home();
            string first = InStand("stale", "first"), second = InStand("stale", "second");
            if (Directory.Exists(InStand("stale"))) Directory.Delete(InStand("stale"), true);
            Directory.CreateDirectory(first); Directory.CreateDirectory(second);
            File.WriteAllText(Path.Combine(first, "only-in-first.txt"), "first");
            File.WriteAllText(Path.Combine(second, "only-in-second.txt"), "second");
            var window = Window();
            var left = window.FindControl<FilePanel>("LeftPanel")!;
            left.Go("local", first, "only-in-first.txt");
            Call(window, "SetActive", left);
            bool ready = Until(() => left.CursorRow?.Name == "only-in-first.txt", 5000);
            // Nothing is pumped between the step and the look: the reading of the new folder has not come back.
            left.Go("local", second, null);
            bool moved = left.Path == second;
            var stale = left.Rows.Select(row => row.Name).ToArray();
            int taken = left.Selection().Count;
            bool arrives = Until(() => left.Rows.Count == 1 && left.Rows[0].Name == "only-in-second.txt", 5000);
            Verdict("панель не держит строки прежней папки под путём новой", ready && moved && stale.Length == 0 && taken == 0 && arrives, new { ready, moved, stale, taken, arrives });
            Close(window);
        }

        // ------------------------------------------------------------ a reading of the old folder
        // The summary of the state was asked of DATA A and is slow; the folder changes to B
        // meanwhile. Only the summary of the folder the window works with reaches the journal.
        {
            Home();
            var said = new List<string>();
            Action<IReadOnlyList<(string Text, LogTone Tone)>> listen = lines => { lock (said) said.AddRange(lines.Select(line => line.Text)); };
            Journal.Lines += listen;
            var window = Window();
            Call(window, "ShowState");
            Pump(200);
            var change = (Task)Call(window, "ChooseDataFolder", b)!;
            Until(() => change.IsCompleted, 12000);
            Pump(3500);
            Journal.Lines -= listen;
            int old = said.Count(line => line.Contains("of-A")), own = said.Count(line => line.Contains("of-other"));
            Verdict("сводка, спрошенная у прежней папки данных, в журнал новой не ложится", DataRoot.Path_ == b && old == 0 && own == 1, new { data = Path.GetFileName(DataRoot.Path_), old, own });
            Close(window);
        }

        // ------------------------------------------------------------ the first start
        // The window of the first start chooses the data folder by itself: its own question,
        // answered, is not an action in the way of the change.
        {
            Home();
            var near = Path.Combine(Path.GetDirectoryName(_stand)!, "Audion Backup Near");
            Directory.CreateDirectory(near);
            try
            {
                var window = Window();
                var asking = (Task)Call(window, "AskFirstStart", true, new List<string>(), true)!;
                bool shown = Until(() => window.OwnedWindows.Count == 1);
                bool offered = false;
                if (shown)
                {
                    var ok = window.OwnedWindows.Single().GetVisualDescendants().OfType<Button>().First(button => button.IsDefault);
                    offered = ok.IsEnabled;
                    ok.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
                Until(() => asking.IsCompleted, 20000); Pump(400);
                Verdict("окно первого запуска выбирает папку данных", shown && offered && DataRoot.Path_ == near, new { shown, offered, chosen = Path.GetFileName(DataRoot.Path_) });
                Close(window);
            }
            finally
            {
                Home();
                try { Directory.Delete(near, true); } catch { }
            }
        }

        // ------------------------------------------------------------ АВТО picks the VPS by its time (2.2.0)
        // From afar АВТО takes the VPS that answers faster: MAIN VPS by name or SECOND VPS. Times within a tenth
        // (or 5 ms) are equal - MAIN VPS then; a silent VPS is passed by; cloudflared, with no time of MAIN VPS
        // itself, goes after a road with a time; at home the home network all the same. Sources.RoadMs came
        // with 2.2.0: reached by its name, so the probes still build against an older window.
        {
            Home();
            var conf = Rclone.TransportPath;
            var kept = File.ReadAllText(conf);
            var times = typeof(Sources).GetProperty("RoadMs")?.GetValue(null) as Dictionary<string, double>;
            var picked = new Dictionary<string, string>(Sources.Picked);
            try
            {
                File.AppendAllText(conf, "\n[base-direct]\ntype = sftp\nhost = 192.0.2.11\n\n[base-cf]\ntype = sftp\nhost = 192.0.2.12\n");
                Sources.Picked.Clear(); Sources.RouteFail.Clear(); Sources.LanUp.Clear();
                Sources.LanUp["base"] = false; Sources.LanUp["direct"] = true; Sources.LanUp["cloud"] = true; Sources.LanUp["second"] = true;
                string Road(double? main, double? second)
                {
                    times?.Clear();
                    if (main is { } m) times?.Add("direct", m);
                    if (second is { } s) times?.Add("second", s);
                    return Sources.RouteName("base");
                }
                var secondFaster = Road(80, 30);
                var mainFaster = Road(20, 30);
                var nearlyEqual = Road(50, 47);
                Sources.LanUp["second"] = false;
                var secondSilent = Road(80, null);
                Sources.LanUp["second"] = true; Sources.LanUp["direct"] = false;
                var overCloud = Road(null, 30);
                Sources.LanUp["direct"] = true; Sources.LanUp["base"] = true;
                var atHome = Road(80, 30);
                Verdict("АВТО: VPS по задержке, разница в десятую - MAIN VPS, дома - домашняя сеть",
                    times is not null && secondFaster == Sources.RouteVia && mainFaster == Sources.RouteMain && nearlyEqual == Sources.RouteMain
                        && secondSilent == Sources.RouteMain && overCloud == Sources.RouteVia && atHome == "",
                    new { known = times is not null, secondFaster, mainFaster, nearlyEqual, secondSilent, overCloud, atHome });
            }
            finally
            {
                File.WriteAllText(conf, kept);
                times?.Clear();
                Sources.LanUp.Clear(); Sources.RouteFail.Clear(); Sources.Picked.Clear();
                foreach (var (key, value) in picked) Sources.Picked[key] = value;
                Home();
            }
        }

        // ------------------------------------------------------------ the board of routes: MAKE DEFAULT, RESET (2.2.0)
        // The roads of the board become the defaults the window starts with; СБРОСИТЬ gives every machine
        // АВТО and wipes the defaults - a program as it comes. The buttons are pressed in the real dialog.
        {
            Home();
            var settings = new Settings { UiFont = "Inter", PanelFont = "Inter" };
            var window = Window(settings);
            Sources.Picked["base"] = "via";
            bool Press(params string[] captions)
            {
                Call(window, "ShowRouteBoard");
                if (!Until(() => window.OwnedWindows.Count == 1, 5000)) return false;
                var dialog = window.OwnedWindows[0];
                var button = dialog.GetVisualDescendants().OfType<Button>().FirstOrDefault(b => b.Content is string text && captions.Contains(text));
                if (button is null) { dialog.Close(); Pump(200); return false; }
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Until(() => window.OwnedWindows.Count == 0, 5000);
                Pump(300);
                return true;
            }
            bool made = Press("СДЕЛАТЬ ПО УМОЛЧАНИЮ", "MAKE DEFAULT");
            bool saved = made && settings.Routes.GetValueOrDefault("base") == "via" && Sources.Picked.GetValueOrDefault("base") == "via";
            bool reset = Press("СБРОСИТЬ", "RESET");
            bool wiped = reset && settings.Routes.Count == 0 && Sources.Picked.GetValueOrDefault("base", "") == "";
            Verdict("доска маршрутов: СДЕЛАТЬ ПО УМОЛЧАНИЮ сохраняет, СБРОСИТЬ - всем АВТО без умолчаний", saved && wiped,
                new { made, saved, reset, wiped, defaults = string.Join(",", settings.Routes.Select(pair => pair.Key + "=" + pair.Value)), now = Sources.Picked.GetValueOrDefault("base") });
            Close(window);
            Sources.Picked.Clear();
            Home();
        }

        // ------------------------------------------------------------ the roads of a session and the defaults (2.1.0)
        // The ROUTE row and its board change the roads of this session only: the window starts with the
        // defaults of SETTINGS, and the settings keep them. Before 2.1.0 the row wrote its road into them.
        {
            Home();
            var settings = new Settings { UiFont = "Inter", PanelFont = "Inter", Routes = new() { ["base"] = "via" } };
            var window = Window(settings);
            bool started = Sources.Picked.GetValueOrDefault("base") == "via";
            Call(window, "SetRoute", "direct");
            Pump(200);
            bool session = Sources.Picked.GetValueOrDefault("base") == "direct";
            bool kept = settings.Routes.GetValueOrDefault("base") == "via";
            Verdict("маршрут кнопкой ряда - на сеанс, умолчание остаётся", started && session && kept,
                new { started, session, kept, now = Sources.Picked.GetValueOrDefault("base"), defaults = settings.Routes.GetValueOrDefault("base") });
            Close(window);
            Sources.Picked.Clear();
            Home();
        }

        // ------------------------------------------------------------ AST-M06
        // -Root names the data folder of one run: the pointer of the program is left alone, a
        // folder that is not there is not replaced by a guess, and the sets of masks an older
        // settings file holds are not carried into a folder of one run.
        {
            Home();
            var pointer = File.ReadAllBytes(Paths.ProfileFile);
            DataRoot.Name(b); Sources.Rebuild();
            bool named = DataRoot.Path_ == b && DataRoot.Pointed && pointer.SequenceEqual(File.ReadAllBytes(Paths.ProfileFile));
            DataRoot.Name(InStand("does-not-exist"));
            bool noGuess = !DataRoot.Chosen && pointer.SequenceEqual(File.ReadAllBytes(Paths.ProfileFile));

            DataRoot.Name(b); Sources.Rebuild();
            File.Delete(DataStore.MaskSetsFile);
            var settings = new Settings { UiFont = "Inter", PanelFont = "Inter", MaskSets = new() { new MaskSet { Name = "of-this-machine", Text = "*.local" } } };
            var window = Window(settings);
            Call(window, "Start"); Pump(2500);
            bool setsWait = settings.MaskSets?.Count == 1 && !File.Exists(DataStore.MaskSetsFile);
            Verdict("-Root называет папку одного запуска и не уносит в неё наборы масок", named && noGuess && setsWait, new { named, noGuess, setsWait });
            Close(window);
        }

        Home();
        Rclone.StopAll();
        Pump(150);
        Console.WriteLine();
        Console.WriteLine(_failed == 0 ? "всё сходится" : $"провалено проб: {_failed}");
        return _failed;
    }
}
