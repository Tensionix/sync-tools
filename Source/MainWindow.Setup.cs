using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The wizards of SETUP. In the previous window each was one function: it asked, and then did
/// the work itself, inside the window. Here the two halves are apart. The window asks - a dialog
/// of Views\FormDialog with what the previous one showed, text for text. The work is a script of
/// Engine\Scripts, run by the PowerShell the program carries, its lines in the journal: the same
/// script does the same from a console, so nothing happens in the window that cannot be done
/// without it. What a wizard shows before it asks comes from the script too (-Describe, JSON).
/// A secret never rides on a command line: it goes in a variable of the child process alone.
/// </summary>
public partial class MainWindow
{
    static string SetupScript(string name) => Path.Combine("Engine", "Scripts", name);

    bool NeedData()
    {
        if (DataRoot.Chosen) return true;
        Journal.Add(Lang.T("[окно] папка данных не выбрана: SETTINGS → ПАПКА ДАННЫХ → ВЫБРАТЬ"));
        return false;
    }

    /// <summary>What a script says about the state of things, as JSON; null with its words in the journal when it did not answer.</summary>
    async Task<JsonElement?> Describe(string script, params string[] args)
    {
        // The script answers in a second or two: the window shows it is busy instead of looking deaf to the press.
        var was = Cursor;
        Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.AppStarting);
        int code;
        string output;
        try { (code, output) = await Task.Run(() => Scripts.Capture(SetupScript(script), args)); }
        finally { Cursor = was; }
        var line = output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith('{'));
        if (code == 0 && line is not null)
            try { using var doc = JsonDocument.Parse(line); return doc.RootElement.Clone(); } catch { }
        Journal.Add(Lang.F("[окно] {0}: сценарий не ответил", script));
        foreach (var said in output.Split('\n').Select(l => l.TrimEnd()).Where(l => l.Length > 0).Take(6)) Journal.Add(said);
        return null;
    }

    /// <summary>The work of a wizard: a job of the queue, its lines in the journal. The variables are of the child alone.</summary>
    void RunSetup(string title, string script, IEnumerable<string> args, Dictionary<string, string>? env = null, Action? onSuccess = null)
    {
        if (Scripts.Job(title, SetupScript(script), args, refresh: true) is not { } job) return;
        foreach (var (name, value) in env ?? new Dictionary<string, string>()) job.Env[name] = value;
        job.OnSuccess = onSuccess;
        _jobs.Enqueue(job);
    }

    static string Text(JsonElement from, string name) =>
        from.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";

    static bool Flag(JsonElement from, string name) =>
        from.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;

    // ------------------------------------------------------------ ADDRESSES

    /// <summary>The addresses of the machines, all at once, as one table. Routers are not here: they have fields of their own.</summary>
    async void SetupTargets()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        var file = DataRoot.File_(Path.Combine("Tunnel", "RemoteDesktop", "config", "targets.json"));
        // A data folder that never had its addresses gets their frame from the sample of the program
        // first: the wizard edits the text of a file, and on a missing one it had nowhere to write.
        if (!File.Exists(file) && await PrepareData()) Sources.Rebuild();
        JsonElement targets;
        try { using var doc = JsonDocument.Parse(File.ReadAllText(file)); targets = doc.RootElement.Clone(); }
        catch
        {
            Journal.Add(Lang.F("[адреса] нет файла {0} - и развернуть его из образца программы не вышло", file));
            return;
        }

        // The list of machines comes from the file itself: a machine written there gets into the wizard without a change of the code.
        var rows = new List<FormRow>();
        foreach (var entry in targets.EnumerateObject())
        {
            if (entry.Name.StartsWith('_') || entry.Name.StartsWith("router-") || entry.Value.ValueKind != JsonValueKind.Object) continue;
            string lan = Text(entry.Value, "lan"), host = Text(entry.Value, "host");
            // SECOND VPS has no home address: its address is "host".
            var address = entry.Name == "second" ? (host.Length > 0 ? host : lan) : (lan.Length > 0 ? lan : host);
            var port = entry.Value.TryGetProperty("sshPort", out var p) && p.TryGetInt32(out var n) ? n : 22;
            var source = Sources.Get(entry.Name);
            bool known = source.Key == entry.Name;
            rows.Add(new FormRow(entry.Name, known ? source.Label : Core.Target.Captions(entry.Name), known ? source.Tip : "", new[]
            {
                new FormCell("address", address, 250, CellAddress),
                new FormCell("user", Text(entry.Value, "user"), 150, CellUser),
                new FormCell("port", port.ToString(), 64, CellPort),
            }));
        }
        if (rows.Count == 0) return;

        // The names of the servers - fields under the table: a row has room for the address, the account and the port only.
        var fields = new List<FormField>();
        // The name cloudflared goes to MAIN VPS by: the household's, written here and nowhere in the program. A machine set up
        // before the field has it in its ~\.ssh\config only - the field starts from there.
        if (targets.TryGetProperty("server", out var main) && main.ValueKind == JsonValueKind.Object)
            fields.Add(new FormField("mainCloudflared", MainCfLabel, Text(main, "cloudflaredHost") is { Length: > 0 } door ? door : Core.Ssh.HostNameOf("audion-vps")));
        if (targets.TryGetProperty("second", out var second) && second.ValueKind == JsonValueKind.Object)
        {
            string Or(string name, string fallback) => Text(second, name) is { Length: > 0 } said ? said : fallback;
            fields.Add(new FormField("secondSshHost", SecondHostLabel, Or("sshHost", "second-vps")));
            fields.Add(new FormField("secondSshHostCf", SecondCfLabel, Or("sshHostCf", "second-vps-cf")));
            fields.Add(new FormField("secondKey", SecondKeyLabel, Or("key", "second_vps_ed25519")));
        }

        var answer = await FormDialog.Ask(this, TargetsHead, TargetsOk,
            new[] { Lang.T(TargetsAddressNote), Lang.T(TargetsSecondNote), Lang.T(TargetsPortNote), Lang.T(TargetsEmptyNote) }, table: rows, fields: fields);
        if (answer is null) return;

        var said = new Dictionary<string, object> { ["rows"] = rows.ToDictionary(row => row.Key, row => (object)new Dictionary<string, string>
        {
            ["label"] = Lang.T(row.Label),
            ["address"] = answer.Table[row.Key]["address"],
            ["user"] = answer.Table[row.Key]["user"],
            ["port"] = answer.Table[row.Key]["port"],
        }) };
        if (answer.Fields.ContainsKey("secondSshHost"))
            said["second"] = new Dictionary<string, string>
            {
                ["sshHost"] = answer.Fields["secondSshHost"], ["sshHostCf"] = answer.Fields["secondSshHostCf"], ["key"] = answer.Fields["secondKey"],
            };
        if (answer.Fields.TryGetValue("mainCloudflared", out var cloudflared))
            said["server"] = new Dictionary<string, string> { ["cloudflaredHost"] = cloudflared };
        var answers = Path.Combine(Paths.State, $"setup-answers-{Guid.NewGuid():N}.json");
        File.WriteAllText(answers, JsonSerializer.Serialize(said));
        RunSetup("АДРЕСА МАШИН", "Set-Targets.ps1", new[] { "-AnswerFile", answers }, onSuccess: () =>
        {
            // The machines of the rows and of the panels are read from the same file.
            Sources.Rebuild();
            SetSection(_section, openPanels: false);
            StartProbe(quiet: true);
        });
    }

    // ------------------------------------------------------------ SSH-KEYGEN

    /// <summary>The pair of THIS machine. The private half stays here; the name becomes the name of the key file and the signature on every target.</summary>
    async void SetupNewKey()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("New-ClientKey.ps1", "-Describe") is not { } state) return;
        var known = state.TryGetProperty("known", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0).ToList() : new List<string>();
        var guess = _settings.ClientName.Length > 0 ? _settings.ClientName : Text(state, "guess");

        var answer = await FormDialog.Ask(this, KeyHead, KeyOk, new[]
        {
            Lang.F(KeyLocal, Text(state, "user"), Text(state, "computer")),
            Lang.T(KeyNameNote),
            "",
            known.Count > 0 ? Lang.F(KeyKnown, string.Join(", ", known)) : Lang.T(KeyNone),
        }, fields: new[] { new FormField("name", KeyNameLabel, guess) });
        if (answer is null) return;
        var name = answer.Fields["name"].Trim();
        // A name that begins with a dash would be read as a switch of the script, not as a name.
        if (name.Length == 0 || name.StartsWith('-')) { Journal.Add(Lang.F("[ключи] имя не годится: {0}", name)); return; }

        // The person wrote it as it suits him; our part is to show how it lies down into a file name and to ask.
        if (await Describe("New-ClientKey.ps1", "-Fix", name) is not { } fit) return;
        if (!Flag(fit, "valid"))
        {
            var better = Text(fit, "fixed");
            if (!Flag(fit, "fixedValid"))
            {
                Journal.Add(Lang.F("[ключи] имя не годится: {0}", name));
                Journal.Add(Lang.T("[ключи] годятся латиница в нижнем регистре, цифры, тире и подчёркивание"));
                return;
            }
            var agreed = await Dialog.Ask(this, KeyFixHead, new[] { Lang.F(KeyTyped, name), Lang.F(KeyWillBe, better), "", Lang.T(KeyFixNote) }, okText: KeyFixOk);
            if (agreed is null) return;
            name = better;
        }

        RunSetup("SSH-KEYGEN", "New-ClientKey.ps1", new[] { "-Name", name }, onSuccess: () =>
        {
            _settings.ClientName = name;
            _settings.Save();
            SetStatus(Lang.F("ключ машины: {0}", name));
            ShowPublicKey(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", name + "_ed25519.pub"));
        });
    }

    /// <summary>The line the other side takes; one press puts it into the clipboard.</summary>
    async void ShowPublicKey(string path)
    {
        string text;
        try { text = File.ReadAllText(path).Trim(); } catch { return; }
        if (await Dialog.Ask(this, PublicKeyHead, new[] { Lang.T(PublicKeyNote), "", text }, okText: PublicKeyOk) is null) return;
        try
        {
            if (Clipboard is { } clipboard) await Avalonia.Input.Platform.ClipboardExtensions.SetTextAsync(clipboard, text);
            Journal.Add(Lang.T("публичный ключ скопирован в буфер"));
        }
        catch (Exception ex) { Journal.Add(Lang.F("[окно] не скопировалось: {0}", ex.Message)); }
    }

    // ------------------------------------------------------------ SSH-KEYSCAN

    /// <summary>With Ctrl a new host key is accepted; a plain press does not accept it - a changed key looks the same after a reinstall and after a swap of the host.</summary>
    void SetupHosts()
    {
        if (!NeedData()) return;
        Engine("Update-SshHosts.ps1", "SSH-KEYSCAN", Ctrl ? new[] { "-Force", "-NoPause" } : new[] { "-NoPause" });
    }

    // ------------------------------------------------------------ RCLONE.CONF

    /// <summary>The transport is built from what is already known; the one thing to ask is the identifier of the Cloudflare account.</summary>
    async void SetupTransport()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        var hint = _settings.ClientName.Length > 0 ? new[] { "-Describe", "-ClientName", _settings.ClientName } : new[] { "-Describe" };
        if (await Describe("Build-Transport.ps1", hint) is not { } state) return;
        if (!Flag(state, "template")) { Journal.Add(Lang.F("[окно] нет файла: {0}", Paths.Script(Path.Combine("config", "rclone.sample.conf")))); return; }
        if (!Flag(state, "targets")) { Journal.Add(Lang.F("[адреса] нет файла {0} - впишите адреса кнопкой АДРЕСА", DataRoot.File_(Path.Combine("Tunnel", "RemoteDesktop", "config", "targets.json")))); return; }

        string Or(string name) => Text(state, name) is { Length: > 0 } said ? said : Lang.T(NoAddress);
        var answer = await FormDialog.Ask(this, TransportHead, TransportOk, new[]
        {
            Lang.T(TransportNote),
            "",
            Lang.F("BASE: {0}", Or("base")),
            Lang.F("LAPTOP: {0}", Or("laptop")),
            Lang.F("MAIN VPS: {0}", Or("server")),
            Lang.F(TransportMachineKey, Text(state, "machineKey")),
            Lang.F(TransportServerKey, Text(state, "serverKey")),
        }, fields: new[]
        {
            new FormField("account", TransportAccount, Text(state, "account")),
            new FormField("profile", TransportProfile, Text(state, "profile")),
        });
        if (answer is null) return;

        var args = new List<string>();
        foreach (var (flag, value) in new[] { ("-Account", answer.Fields["account"].Trim()), ("-Profile", answer.Fields["profile"].Trim()), ("-ClientName", _settings.ClientName) })
            if (value.Length > 0 && !value.StartsWith('-')) { args.Add(flag); args.Add(value); }
        RunSetup("RCLONE.CONF", "Build-Transport.ps1", args, onSuccess: () => StartProbe(quiet: true));
    }

    // ------------------------------------------------------------ R2 CREDS

    /// <summary>The pair of keys of the bucket: laid where rclone reads it, the buckets asked for at once. The values are in no journal.</summary>
    async void SetupR2()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("Set-R2Credentials.ps1", "-Describe") is not { } state) return;
        var answer = await FormDialog.Ask(this, R2Head, R2Ok, new[]
        {
            Lang.T(R2File) + PathTail(Text(state, "path")),
            Lang.T(R2Profile) + Text(state, "profile"),
            Lang.T(R2Now) + Lang.T(Flag(state, "exists") ? R2Exists : R2Missing),
            "",
            Lang.T(R2Note),
        }, fields: new[] { new FormField("id", "ACCESS KEY ID"), new FormField("secret", "SECRET ACCESS KEY", Secret: true) });
        if (answer is null) return;
        string id = answer.Fields["id"].Trim(), secret = answer.Fields["secret"].Trim();
        if (id.Length == 0 || secret.Length == 0) { Journal.Add(Lang.T("[ключи] пусто - ничего не записано")); return; }
        RunSetup("R2 CREDS", "Set-R2Credentials.ps1", Array.Empty<string>(),
            new Dictionary<string, string> { ["ABK_R2_ID"] = id, ["ABK_R2_SECRET"] = secret },
            onSuccess: () => SetStatus(Lang.T("ключи R2: приняты")));
    }

    /// <summary>A long path by its end: the folders that tell one file from another.</summary>
    static string PathTail(string path)
    {
        var parts = path.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length <= 4 ? path : "…\\" + string.Join('\\', parts[^4..]);
    }

    // ------------------------------------------------------------ ROUTER PASS

    static readonly Dictionary<string, string> RouterNotes = new()
    {
        ["router-base"] = "роутер BASE",
        ["router-home"] = "роутер HOME: виден через SECOND VPS",
        ["router-work"] = "роутер на работе",
    };

    /// <summary>The password of a router account: kept portably in the data folder, checked at once by asking the router for its version.</summary>
    async void SetupRouter()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("Set-RouterSecret.ps1", "-Describe") is not { } state) return;
        var routers = state.TryGetProperty("routers", out var list) && list.ValueKind == JsonValueKind.Array ? list.EnumerateArray().ToList() : new List<JsonElement>();
        if (routers.Count == 0)
        {
            Journal.Add(Lang.T("[роутер] ни у одного роутера нет адреса - впишите его кнопкой АДРЕСА"));
            return;
        }

        // One router - no question: a question where there is no choice only irritates.
        var router = routers[0];
        if (routers.Count > 1)
        {
            var picked = await ChoiceDialog.Ask(this, RouterWhose, routers.Select(item => new Choice(Text(item, "key"), Text(item, "label"),
                $"{Lang.T(RouterNotes.GetValueOrDefault(Text(item, "key"), ""))} · {Text(item, "address")}")).ToList(), RouterNext);
            if (picked is null) return;
            router = routers.First(item => Text(item, "key") == picked);
        }

        var password = await Dialog.Ask(this, RouterHead, new[] { Lang.T(RouterName) + Text(router, "address"), Lang.T(RouterAccount), "", Lang.T(RouterNote) }, okText: RouterOk, secret: true);
        if (string.IsNullOrEmpty(password)) return;

        // Whether all the routers share one password is the owner's choice. Without an answer the password of one is not even tried on another.
        var args = new List<string> { "-Router", Text(router, "key") };
        var others = routers.Where(item => Text(item, "key") != Text(router, "key") && !Flag(item, "saved")).ToList();
        bool unanswered = !state.TryGetProperty("shared", out var shared) || shared.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined;
        if (others.Count > 0 && unanswered)
        {
            var names = string.Join(", ", others.Select(item => Text(item, "label")));
            var same = await ChoiceDialog.Ask(this, RouterSharedHead, new[]
            {
                new Choice("yes", RouterSharedYes, Lang.F(RouterSharedNote, names)),
                new Choice("no", RouterSharedNo, RouterSingleNote),
            }, RouterNext);
            if (same is not null) { args.Add("-Shared"); args.Add(same); }
        }
        RunSetup("ДОСТУП К РОУТЕРУ", "Set-RouterSecret.ps1", args, new Dictionary<string, string> { ["ABK_ROUTER_PASSWORD"] = password });
    }

    // ------------------------------------------------------------ SSH TUN

    /// <summary>
    /// REVERSE SSH TUN of this machine. A tunnel that is set up is switched on and off by a plain
    /// press; with Ctrl, or while there is none, the wizard opens: raise it over SECOND VPS or
    /// over MAIN VPS, look at it, or remove it. The network is not touched here - whether the
    /// port lives is said by the inspection, which opens in its own console.
    /// </summary>
    async void SetupBeacon()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        bool ctrl = Ctrl;
        if (await Describe("Get-BeaconState.ps1") is not { } state) return;
        bool made = Flag(state, "made"), alive = Flag(state, "alive");
        if (made && !ctrl)
        {
            External("reverse-ssh-toggle.cmd", "SSH TUN: ON/OFF");
            return;
        }

        int port = state.TryGetProperty("port", out var p) && p.TryGetInt32(out var n) ? n : 0;
        var channel = alive ? Lang.F(BeaconAlive, Text(state, "via"))
            : Flag(state, "starting") ? Lang.T(BeaconStarting)
            : Flag(state, "holder") ? Lang.T(BeaconRetrying)
            : made ? Lang.T(BeaconDown) : Lang.T(BeaconNotMade);
        var answer = await FormDialog.Ask(this, BeaconHead, BeaconNext,
            new[] { Lang.F(BeaconMachine, Text(state, "name")), "", Lang.T(BeaconWhat), Lang.T(BeaconWhen) },
            badges: new[]
            {
                new FormBadge(Lang.F(BeaconKey, Lang.T(Flag(state, "key") ? Yes : No)), Flag(state, "key") ? "ok" : "idle"),
                new FormBadge(Lang.F(BeaconPort, port > 0 ? port.ToString() : Lang.T(No)), made ? "ok" : "idle"),
                new FormBadge(channel, alive ? "ok" : made ? "warn" : "idle"),
            },
            choices: new[]
            {
                new Choice("fast", BeaconFast, BeaconFastNote),
                new Choice("private", BeaconPrivate, BeaconPrivateNote),
                new Choice("check", BeaconCheck, BeaconCheckNote),
                new Choice("remove", BeaconRemove, BeaconRemoveNote),
            }, picked: made ? "check" : "fast");
        if (answer is null) return;

        // The names of the wrappers are written out, not put together: the check of the window and the console finds a button its pair by the file name.
        switch (answer.Choice)
        {
            case "fast": External("reverse-ssh-second-vps.cmd", BeaconFastTitle, "-Persistent"); break;
            case "private": External("reverse-ssh-main-vps.cmd", BeaconPrivateTitle, "-Persistent"); break;
            case "check": External("reverse-ssh-check.cmd", BeaconCheckTitle); break;
            case "remove": External("reverse-ssh-remove.cmd", BeaconRemoveTitle); break;
        }
    }
}
