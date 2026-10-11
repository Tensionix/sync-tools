using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Input;
using Avalonia.Platform.Storage;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// What the buttons of the six sections do. A button never works by itself: it starts a script
/// of Engine\Scripts with its output in the journal, or a wrapper of Runs\ and
/// Tunnel\RemoteDesktop\ in a console of its own when the script is a conversation.
/// </summary>
public partial class MainWindow
{
    /// <summary>Held keys at the last press of the mouse: Ctrl turns a few buttons into their careful twin.</summary>
    KeyModifiers _mods;

    bool Ctrl => _mods.HasFlag(KeyModifiers.Control);

    /// <summary>A script of Engine\Scripts with the data folder named, its output in the journal.</summary>
    void Engine(string name, string title, params string[] args)
    {
        if (Scripts.Job(title, Path.Combine("Engine", "Scripts", name), args, refresh: true) is { } job) _jobs.Enqueue(job);
    }

    /// <summary>A wrapper of Runs\ in its own console; the panels are read again when it closes.</summary>
    void Wrapper(string name, params string[] args)
    {
        if (Scripts.Wrapper(Path.Combine("Runs", name), args) is not { } process) return;
        Journal.Add(Lang.F("[окно] открыто окно: {0}", name));
        WaitThenRefresh(process);
    }

    /// <summary>A wrapper of Tunnel\RemoteDesktop\ in its own console, with the data folder the window works with.</summary>
    Process? External(string name, string title, params string[] args)
    {
        var process = Scripts.Wrapper(Path.Combine("Tunnel", "RemoteDesktop", name), args, dataRoot: true);
        if (process is null) return null;
        Journal.Add("");
        Journal.Add($"===== {Lang.T(title)} =====");
        Journal.Add(Lang.T("открыто своим окном: сессия интерактивная"));
        // When its console closes, what it set up shows in the dots: a service, a tunnel, a key.
        try
        {
            process.EnableRaisingEvents = true;
            process.Exited += (_, _) => Avalonia.Threading.Dispatcher.UIThread.Post(RefreshState);
        }
        catch { }
        return process;
    }

    /// <summary>The console of a wizard closed: the list of clouds is read again, or what was attached shows only after the section is entered anew.</summary>
    async void WaitThenRefresh(Process process)
    {
        try { await process.WaitForExitAsync(); } catch { }
        process.Dispose();
        if (_section != "clouds") return;
        SetSection("clouds", openPanels: false);
        Journal.Add(Lang.T("[облака] список перечитан"));
    }

    /// <summary>A button the rows of buttons name and the code does not know: a mistake of the program, said aloud. Tests\Test-NewWindow.ps1 keeps the two in step.</summary>
    void NoAction(string text) => Journal.Add(Lang.F("[окно] {0}: действие не найдено", text));

    async void Act(string name, string text)
    {
        // The three buttons that ask here (SYNC ALL, OPENVPN, RESTORE) keep the data folder till they are answered.
        using var pending = Pending();
        switch (name)
        {
            // ---------------------------------------------------- STORAGE
            case "SyncAllButton":
            {
                // The mirror levels the local copy by MAIN VPS: what is extra here goes here. For six mirrors at once that is worth a question.
                var go = await Dialog.Ask(this, "Обновить все зеркала?", new[]
                {
                    "ОТКУДА: MAIN VPS",
                    Lang.F("КУДА  : {0}", DataRoot.Path_),
                    "",
                    "Местная копия равняется по MAIN VPS: чего на MAIN VPS нет, того не станет и здесь.",
                    "Посмотреть, что изменится, не трогая файлы, — кнопка DRY RUN.",
                }, "SYNC ALL", Tone.Warn);
                if (go is null) { Journal.Add(Lang.T("[окно] отменено")); return; }
                Engine("Sync-AudionBackup.ps1", "SYNC ALL", "-NoPause");
                break;
            }
            case "SyncSelectedButton":
            {
                // The choice is taken from the panel: what is picked in the data folder is what is updated.
                var picked = _active.Selection().Where(r => r.IsDir).Select(r => r.Name).ToList();
                if (picked.Count == 0) { Journal.Add(Lang.T("[окно] отметьте папки зеркала в панели")); return; }
                Engine("Sync-AudionBackup.ps1", "SYNC SELECTED", "-Only", string.Join(",", picked), "-NoPause");
                break;
            }
            case "SyncPlanButton": Engine("Sync-AudionBackup.ps1", "DRY RUN: SYNC ALL", "-WhatIf", "-NoPause"); break;
            case "SelectAllButton": MarkAll(true); break;
            case "SelectNoneButton": MarkAll(false); break;
            case "StackFolderButton" or "SetupArchiveButton": PickArchiveRoot(); break;
            case "StackPlanButton": StackBackup(publish: false); break;
            case "StackBackupButton": StackBackup(publish: true); break;

            // ---------------------------------------------------- CLOUDS
            case "CloudAddButton": CloudAdd(); break;
            case "CloudRenameButton": CloudRename(); break;
            case "CloudSendButton": CloudSend(); break;
            case "CloudDropButton": WrapperThenClouds("clouds-remove.cmd"); break;
            case "CloudSigninButton": WrapperThenClouds("clouds-reconnect.cmd"); break;
            case "CloudCheckButton": Engine("Manage-Clouds.ps1", "ОБЛАКА", "-Check"); break;
            case "CloudKeysButton": Engine("Sync-CloudKeys.ps1", "КЛЮЧИ ОБЛАКОВ", "-Check"); break;
            case "CloudPushButton": Engine("Sync-CloudKeys.ps1", "GOLDEN COPY → MAIN VPS", "-Push"); break;
            case "CloudPullButton": Engine("Sync-CloudKeys.ps1", "GOLDEN COPY ← MAIN VPS", "-Pull"); break;

            // ---------------------------------------------------- SSH KEYS
            case "KeysExportButton": Engine("Export-AudionKeys.ps1", "СБОР КЛЮЧЕЙ"); break;
            case "KeysCheckButton": Engine("Import-AudionKeys.ps1", "ПРОВЕРКА КЛЮЧЕЙ", "-Check"); break;
            case "SetupKeysButton": Engine("Import-AudionKeys.ps1", "РАСКЛАДКА КЛЮЧЕЙ"); break;
            case "SetupInventoryButton": KeysInventory(); break;
            case "SetupSpreadButton": KeysSpread(); break;
            case "SetupRevokeButton": KeysRevoke(); break;
            case "OpenAppButton": Shell(Paths.Root); break;
            case "SetupStoreButton": if (DataRoot.Chosen) Shell(DataRoot.Path_); break;

            // ---------------------------------------------------- TUNNEL
            case "ProbeButton": StartProbe(quiet: false); break;
            case "RoutesButton": External("check-routes.cmd", "МАРШРУТЫ ДО BASE"); break;
            case "TunnelCheckButton": RunScript("CLOUDFLARED", Path.Combine("Tunnel", "Install-TunnelClient.ps1"), "-Root", DataRoot.Path_, "-Check"); break;
            case "TunnelInstallButton": RunScript("УСТАНОВКА ТУННЕЛЯ", Path.Combine("Tunnel", "Install-TunnelClient.ps1"), "-Root", DataRoot.Path_); break;
            case "DnsRepairButton": Engine("Repair-Dns.ps1", "РАЗРЕШЕНИЕ ИМЁН"); break;
            case "OpenVpnPathButton": External("openvpn-path.cmd", "OVPN PATH"); break;
            case "OpenVpnButton":
            {
                if (Ctrl) { External("openvpn.cmd", "OPENVPN", "-Check"); break; }
                var choice = await ChoiceDialog.Ask(this, "OPENVPN", new[]
                {
                    new Choice("connect", "Подключить и открыть WORK", "Диски WORK через rclone в активной панели"),
                    new Choice("disconnect", "Отключить VPN-профиль", "Только выбранный профиль; доступ к WORK прервётся"),
                });
                if (choice is null) return;
                OpenVpn(connect: choice == "connect");
                break;
            }

            // ---------------------------------------------------- ROUTERS AND WG
            case "RouterSecretButton": SetupRouter(); break;
            case "RouterCheckButton": RouterCheck(); break;
            case "RouterPeerButton": RouterPeer(); break;
            case "SetupWgButton": SetupWg(); break;
            case "SetupVpnButton": SetupVpn(); break;
            case "VpnPowerButton": TunnelPower(); break;

            // ---------------------------------------------------- REMOTE
            case "ForwardDesktopButton": External("desktop-base.cmd", "RDP: BASE"); break;
            case "ForwardRouterButton": External("web-router.cmd", "ROUTER WEB"); break;
            case "ForwardSocksButton": External("socks-base.cmd", "SOCKS: BASE"); break;
            case "TerminalAppButton": PickTerminal(); break;
            case "TabbyButton": SelectTabby(); break;

            // ---------------------------------------------------- SETUP
            case "SetupTargetsButton": SetupTargets(); break;
            case "SetupNewKeyButton": SetupNewKey(); break;
            case "SetupHostsButton": SetupHosts(); break;
            case "SetupTransportButton": SetupTransport(); break;
            case "SetupR2Button": SetupR2(); break;
            case "SetupRouterButton": SetupRouter(); break;
            case "SetupBeaconButton": SetupBeacon(); break;
            case "SetupSshButton": External("setup-ssh-server.cmd", "SSHD"); break;
            case "SetupScheduleButton": RemoveSchedule(); break;
            case "SetupRestoreButton":
            {
                var choice = await ChoiceDialog.Ask(this, "RESTORE", new[]
                {
                    new Choice("mirror", "Начисто из DATA (MIRROR)", "После переустановки: C: ровно как в DATA, лишнее - в DATA\\._runtime. Ждёт UAC, вход в Access и пароли роутеров"),
                    new Choice("restore", "Восстановить эту машину", "Существующий SSH config сохранить"),
                    new Choice("routes", "Восстановить и заменить SSH config", "Маршруты из DATA; прежний config сохранить одной копией"),
                });
                if (choice is null) return;
                External("restore-machine.cmd", "RESTORE", choice switch { "mirror" => new[] { "-Mirror" }, "routes" => new[] { "-RestoreConfig" }, _ => Array.Empty<string>() });
                break;
            }

            default:
                NoAction(text.Length > 0 ? text : name);
                break;
        }
    }

    /// <summary>A script by its path from the root with exactly the arguments given - no data folder added.</summary>
    void RunScript(string title, string relative, params string[] args)
    {
        if (Scripts.Job(title, relative, args, refresh: true, dataRoot: false) is { } job) _jobs.Enqueue(job);
    }

    void MarkAll(bool on)
    {
        if (_active.Rows.Count == 0) { Journal.Add(Lang.T("[окно] в активной панели нечего отмечать")); return; }
        _active.SetMarks(on);
        Journal.Add($"[окно] {Label(_active)}: {_active.Rows.Count} {Lang.T("строк")} {Lang.T(on ? "отмечено" : "без отметок")}");
    }

    async void StackBackup(bool publish)
    {
        using var pending = Pending();
        if (_settings.ArchiveRoot.Length == 0) { Journal.Add(Lang.T("[окно] корень RELEASE не выбран — нажмите RELEASE")); return; }
        // The plan changes nothing and needs no question. The upload goes into a bucket and pushes old snapshots out of it - that is confirmed.
        if (publish)
        {
            var go = await Dialog.Ask(this, "Отправить снимок в R2 bucket?", new[]
            {
                Lang.F("ОТКУДА: {0}", _settings.ArchiveRoot),
                "КУДА  : r2:audion-backup/Projects",
                "",
                "Уйдут приватные архивы Build-стека. Старые снимки в R2 bucket вытесняются по очереди.",
                "Посмотреть, что войдёт, не отправляя, — кнопка DRY RUN.",
            }, "ОТПРАВИТЬ", Tone.Warn);
            if (go is null) { Journal.Add(Lang.T("[окно] отменено")); return; }
        }
        var args = new List<string> { "-ArchiveRoot", _settings.ArchiveRoot, "-NoPause" };
        if (publish) args.Add("-Publish");
        RunScript(publish ? "PRIVATE BACKUP" : "DRY RUN: PRIVATE BACKUP", Path.Combine("Engine", "Scripts", "Backup-AudionArchives.ps1"), args.ToArray());
    }

    async void PickArchiveRoot()
    {
        var picked = await PickFolder("Корень выпуска: папка с _archives_private_full и _archives_private_git", _settings.ArchiveRoot);
        if (picked is null) return;
        _settings.ArchiveRoot = picked;
        _settings.Save();
        Journal.Add(Lang.F("RELEASE: {0}", picked));
    }

    async void PickDataFolder()
    {
        var start = DataRoot.Chosen ? DataRoot.Path_ : Path.GetDirectoryName(Paths.Root) ?? "";
        var picked = await PickFolder("Папка данных этой машины: Audion Backup <Машина>", start);
        if (picked is not null) await ChooseDataFolder(picked);
    }

    /// <summary>
    /// The folder becomes the data folder of this machine: the pointer is written, the window
    /// reads everything anew. One step with nothing awaited inside it: the questions still asked
    /// of the old folder end, its cloud session leaves the window, the folder changes, the
    /// sources are built and both panels are opened anew - a panel of the new folder is never
    /// read through the session of the old one, and a panel of the old folder never stands under
    /// the badge of the new one. What takes time comes after the step: the old session is saved
    /// into its own folder, the new folder is made ready, its clouds are opened.
    /// </summary>
    async Task ChooseDataFolder(string picked)
    {
        var root = DataRoot.Resolve(picked);
        if (!Path.GetFileName(root).StartsWith("Audion Backup", StringComparison.OrdinalIgnoreCase))
        {
            Journal.Add(Lang.F("[окно] {0}: это не папка данных - её имя начинается с «Audion Backup»", root));
            return;
        }
        bool stand = OnStand;
        if (!Paths.Released && !stand)
        {
            // A build run from bin\ is a check: the pointer of the project is the owner's, and a check does not rewrite it.
            Journal.Add(Lang.T("[окно] сборка из Source\\bin указатель папки данных не меняет"));
            return;
        }
        if (_jobs.Running || _pending > 0 || OwnedWindows.Count > 0)
        {
            // A transfer runs with the config of the folder it was started in, and an action that
            // counts or asks has taken its paths from that folder: the folder changes after them,
            // not under them. A question on the screen counts by itself - an action that forgot
            // to say it is pending is still not left with the config of another folder.
            Journal.Add(Lang.T("[окно] идёт операция: папку данных меняют после неё"));
            return;
        }
        var previous = DataRoot.Chosen ? DataRoot.Path_ : "";
        var step = ++_dataStep;
        Rclone.StopAll();
        // A search window is about the places of the folder being left.
        _search?.Close();
        var saved = CloseClouds();
        if (!(stand ? ChooseOnStand(root) : DataRoot.Choose(root)))
        {
            // The pointer was not written: the folder stays, and its clouds come back.
            await saved;
            if (step == _dataStep) OpenClouds();
            return;
        }
        Journal.Add("");
        Journal.Add(Lang.T("===== ПАПКА ДАННЫХ ====="));
        Journal.Add(Lang.F("данные: {0}", DataRoot.Path_));
        // Another data folder - other sets of masks; and the sets an older settings file waited with go into it.
        if (DataStore.Adopt(_settings)) _settings.Save();
        ForgetSavedSets();
        // What the window learnt about the old folder is not known about the new one: which roads
        // answered, what was proven by a panel read through it, what its dots said. As at a start.
        Sources.LanUp.Clear();
        Sources.RouteFail.Clear();
        _lanMs.Clear();
        _proven.Clear();
        _dotStates.Clear();
        _probeStamp = "";
        _setup = _beacon = null;
        Sources.Rebuild();
        UpdateDataBadge();
        bool settings = _settingsOpen;
        // The panels stood in the old folder, by its paths and by its config: both start anew.
        // Left as they were, ДАННЫЕ went on showing the old folder under the badge of the new one.
        _opened = false;
        SetSection(_section, openPanels: true);
        if (settings) ToggleSettings(true);

        // The folder was changed once more meanwhile: the rest is for the step that did it.
        await saved;
        if (step != _dataStep) return;
        // The frame of the addresses, the working files an old version left: what was read before them is read again.
        bool changed = await PrepareData(previous);
        if (step != _dataStep) return;
        if (changed) { LeftPanel.ReloadNow(); RightPanel.ReloadNow(); }
        // Another data folder - other clouds, other keys and configs.
        OpenClouds();
        RefreshState();
        ShowState();
        StartProbe(quiet: true);
    }

    /// <summary>
    /// Every change of the data folder gets a number: what a slower change still waits for is
    /// dropped, and a reading that was asked of the old folder - the probe, the state, the
    /// summary - knows by it that its answer is about another folder.
    /// </summary>
    int _dataStep;

    /// <summary>
    /// An action that waits - for a count, for a script, for an answer to its question - has taken
    /// what it works with from the panels and from the data folder as they stood when it began:
    /// the paths, the kinds of the clouds, the state of a pair. What it starts in the end is run
    /// with the config the data folder has at that later moment. So the data folder is not
    /// changed under an action: while one is pending, ChooseDataFolder refuses, as it does while
    /// a job runs. COPY counted in folder A and confirmed after a change to B went with the
    /// paths of A and the config of B (the audit of 06.10.2026, AST-M07).
    /// An action that awaits before it starts something begins with: using var pending = Pending();
    /// Tests\Test-NewWindow.ps1 names every async method that does not, with its reason.
    /// </summary>
    IDisposable Pending() => new PendingAction(this);

    int _pending;

    sealed class PendingAction : IDisposable
    {
        MainWindow? _window;

        public PendingAction(MainWindow window)
        {
            _window = window;
            window._pending++;
        }

        public void Dispose()
        {
            if (_window is not { } window) return;
            _window = null;
            window._pending--;
        }
    }

#if DEBUG
    /// <summary>A Debug copy on a stand (Tools\dev-run.ps1 -Data): another throwaway folder for this run. The pointer of the project is not written.</summary>
    static bool OnStand => DataRoot.OnStand;
    static bool ChooseOnStand(string root) => DataRoot.ChooseOnStand(root);
#else
    static bool OnStand => false;
    static bool ChooseOnStand(string root) => false;
#endif

    /// <summary>
    /// What a data folder needs before the window works with it, and what no button does:
    /// Engine\Scripts\Initialize-DataFolder.ps1 moves the working files an old version left in
    /// the program folder, lays out the frame of the addresses where there is none and brings
    /// in the entry of SECOND VPS. Called at the start and when another folder is chosen. True
    /// when the list of the machines may have changed and the sources want building again.
    /// </summary>
    async Task<bool> PrepareData(string previous = "")
    {
        if (!DataRoot.Chosen) return false;
        var root = DataRoot.Path_;
        var args = new List<string> { "-Root", root };
        if (previous.Length > 0) { args.Add("-Previous"); args.Add(previous); }
        var answer = await Task.Run(() => Scripts.Capture(SetupScript("Initialize-DataFolder.ps1"), args));
        // The folder changed while the script ran: its answer is about another folder.
        if (!string.Equals(root, DataRoot.Path_, StringComparison.OrdinalIgnoreCase)) return false;
        if (StateOf(answer) is not { } said)
        {
            Journal.Add(Lang.T("[окно] подготовить папку данных не вышло: каркас адресов и перенос рабочих файлов не проверены"));
            return false;
        }

        static List<(string What, string Rel)> Rows(JsonElement from, string name) =>
            from.TryGetProperty(name, out var list) && list.ValueKind == JsonValueKind.Array
                ? list.EnumerateArray().Select(item => (Text(item, "what"), Text(item, "rel"))).ToList() : new();

        bool changed = false;
        var moved = Rows(said, "moved");
        var quarantined = Rows(said, "quarantined");
        if (previous.Length > 0 && quarantined.Count > 0)
        {
            Journal.Add(Lang.T("в программе нашлись рабочие файлы другой машины - убраны в карантин, в выбранную папку не переношу:"));
            foreach (var (_, rel) in quarantined) Journal.Add("  " + rel + " -> " + Text(said, "quarantine"));
        }
        else if (moved.Count + quarantined.Count > 0)
        {
            Journal.Add(Lang.F("перенесено в папку данных: файлов {0}", moved.Count + quarantined.Count));
            foreach (var (what, rel) in moved.Concat(quarantined)) Journal.Add("  " + Lang.T(what) + ": " + rel);
            if (quarantined.Count > 0) Journal.Add(Lang.T("копии из программы, отличные от данных, убраны в карантин ._runtime\\migrated"));
            changed = true;
        }
        if (Flag(said, "targets"))
        {
            Journal.Add(Lang.T("адреса машин: развёрнут пустой каркас, заполните кнопкой АДРЕСА"));
            changed = true;
        }
        if (Text(said, "second") is { Length: > 0 } second)
        {
            Journal.Add(Lang.T(second == "ssh-config"
                ? "SECOND VPS: запись second перенесена в targets.json из ~\\.ssh\\config"
                : "SECOND VPS: в targets.json заведена пустая запись second - адрес вписывается кнопкой АДРЕСА"));
            changed = true;
        }
        return changed;
    }

    async void PickTerminal()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Lang.T("Терминал, которым открывать машины"),
            AllowMultiple = false,
            FileTypeFilter = new[] { new FilePickerFileType(Lang.T("Программы (*.exe)")) { Patterns = new[] { "*.exe" } } },
        });
        if (files.Count == 0 || files[0].TryGetLocalPath() is not { } path) return;
        _settings.TerminalApp = path;
        _settings.Save();
        Journal.Add(Lang.F("терминал: {0}", path));
        UpdateTerminalCaption();
    }

    async System.Threading.Tasks.Task<string?> PickFolder(string title, string start)
    {
        IStorageFolder? from = null;
        try { if (start.Length > 0 && Directory.Exists(start)) from = await StorageProvider.TryGetFolderFromPathAsync(start); } catch { }
        var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = Lang.T(title), AllowMultiple = false, SuggestedStartLocation = from });
        return folders.Count > 0 ? folders[0].TryGetLocalPath() : null;
    }

    Process? _openVpn;

    /// <summary>
    /// OPENVPN: the wrapper connects or disconnects the chosen profile in its own console and
    /// writes what came of it into a file (Message, Code, Root, Action, Ready). When it closes
    /// with a ready connection the panel it was asked from opens WORK - unless the owner has
    /// moved that panel meanwhile: a panel he moved is never changed. The client is the owner's
    /// own; the program neither ships it nor touches any profile but the chosen one.
    /// </summary>
    async void OpenVpn(bool connect)
    {
        if (_jobs.Running || _openVpn is { HasExited: false }) { Journal.Add(Lang.T("OPENVPN: дождитесь завершения текущей операции.")); return; }
        var root = DataRoot.Path_;
        var runtime = Path.Combine(root, "._runtime", "openvpn");
        try { Directory.CreateDirectory(runtime); } catch { }
        var resultPath = Path.Combine(runtime, Guid.NewGuid().ToString("N") + ".json");
        var panel = _active;
        string section = _section, source = panel.SourceKey, path = panel.Path;

        var process = _openVpn = External("openvpn.cmd", "OPENVPN", connect ? "-Connect" : "-Disconnect", "-NoPause", "-ResultPath", resultPath);
        if (process is null) return;
        try { await process.WaitForExitAsync(); } catch { }
        _openVpn = null;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(resultPath));
            var result = doc.RootElement;
            string Text(string name) => result.TryGetProperty(name, out var v) && v.ValueKind == System.Text.Json.JsonValueKind.String ? v.GetString() ?? "" : "";
            if (root != DataRoot.Path_) return;
            if (Text("Message").Length > 0) Journal.Add(Text("Message"));
            int code = result.TryGetProperty("Code", out var c) && c.TryGetInt32(out var n) ? n : -1;
            if (process.ExitCode != 0 || code != 0 || Text("Root") != root) return;
            bool ready = result.TryGetProperty("Ready", out var r) && r.ValueKind == System.Text.Json.JsonValueKind.True;
            if (Text("Action") == "connect" && ready && !_jobs.Running && _section == section
                && panel.SourceKey == source && panel.Path == path && Sources.SectionOf(_section).Sources.Contains("work"))
                panel.Open("work");
            // The visible panels of WORK are read again after either action.
            foreach (var one in new[] { LeftPanel, RightPanel })
                if (one.SourceKey == "work" && one != panel) one.Reload();
            StartProbe(quiet: true);
        }
        catch (Exception ex)
        {
            Journal.Add(Lang.T("[окно] ") + "OpenVPN: " + ex.Message);
        }
        finally
        {
            process.Dispose();
            try { if (File.Exists(resultPath)) File.Delete(resultPath); } catch { }
        }
    }

}
