using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// CLOUDS. The attached cloud drives are sources of the panels: their set is data, not markup.
/// rclone writes a refreshed OAuth token back into the file a remote came from, so while clouds
/// are attached the window works with a config of the session - the transport together with the
/// clouds, encrypted - built by Engine\Scripts\Get-Clouds.ps1. Its password goes to the window's
/// rclone calls in their environment and nowhere else; what a session refreshed is written back
/// into the encrypted clouds.conf of the data folder when the window closes.
/// </summary>
public partial class MainWindow
{
    static readonly Regex CloudName = new("^[A-Za-z0-9][A-Za-z0-9_-]*$");
    string _cloudLine = "";

    /// <summary>The answer of Get-Clouds.ps1. Nothing of it reaches the journal: with -Open it carries the password of the config.</summary>
    static async Task<JsonElement?> AskClouds(params string[] args)
    {
        var (code, output) = await Task.Run(() => Scripts.Capture(SetupScript("Get-Clouds.ps1"), args));
        var line = output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith('{'));
        if (code != 0 || line is null) return null;
        try { using var doc = JsonDocument.Parse(line); return doc.RootElement.Clone(); } catch { return null; }
    }

    static List<(string Name, string Type)> CloudsOf(JsonElement state) =>
        state.TryGetProperty("clouds", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => (Text(item, "name"), Text(item, "type"))).Where(item => item.Item1.Length > 0).ToList()
            : new List<(string, string)>();

    /// <summary>
    /// Read at the start, after the data folder changed and after a wizard of clouds closed: the
    /// working config of the session and the sources of the panels. Without clouds the window
    /// works with the plain config, as before.
    /// </summary>
    async void OpenClouds()
    {
        if (!DataRoot.Chosen || Paths.Rclone is null) return;
        // The answer is taken only by the question that is still the last one, and only for the
        // folder it was asked about. A slow answer for folder A used to arrive after the answer
        // for B and put the config of A back - under a badge that said B.
        var epoch = ++_cloudsEpoch;
        var root = DataRoot.Path_;
        var state = await AskClouds("-Open", "-Root", root);
        if (epoch != _cloudsEpoch || !string.Equals(root, DataRoot.Path_, StringComparison.OrdinalIgnoreCase)) return;
        if (state is not { } said || !Flag(said, "ready"))
        {
            Rclone.SessionConfig = null;
            Rclone.SessionEnv.Remove("RCLONE_CONFIG_PASS");
            Sources.SetClouds(Array.Empty<Source>());
            var why = state is { } answer ? Text(answer, "why") : "";
            SayClouds(Lang.T(why == "session" ? "[облака] собрать рабочий конфиг не вышло: работаем обычным, облака не видны" : "[облака] не заведены: работаем обычным конфигом"));
        }
        else
        {
            Rclone.SessionConfig = Text(said, "session");
            Rclone.SessionEnv["RCLONE_CONFIG_PASS"] = Text(said, "password");
            var clouds = CloudsOf(said);
            Sources.SetClouds(clouds.Select(cloud => new Source
            {
                Key = "cloud-" + cloud.Name, Label = cloud.Name.ToUpperInvariant(), Remote = cloud.Name + ":", Cloud = true, CloudType = cloud.Type,
                Tip = Lang.F(CloudTip, cloud.Type, cloud.Name),
            }));
            var shadowed = said.TryGetProperty("shadowed", out var hidden) && hidden.ValueKind == JsonValueKind.Array
                ? hidden.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0).ToList() : new List<string>();
            if (shadowed.Count > 0)
            {
                Journal.Add(Lang.F("[облака] не видны, имя занято в rclone.conf программы: {0}", string.Join(", ", shadowed)));
                Journal.Add(Lang.T("[облака] переименовать: clouds.cmd, там же и список"));
            }
            SayClouds(Lang.F("[облака] в рабочем конфиге: {0}", clouds.Count > 0 ? string.Join(", ", clouds.Select(cloud => $"{cloud.Name} ({cloud.Type})")) : Lang.T("ни одного")));
        }
        if (_section == "clouds" && !_settingsOpen) SetSection(_section, openPanels: false);
    }

    /// <summary>The same line is said once: the clouds are read again after every wizard.</summary>
    void SayClouds(string line)
    {
        if (line == _cloudLine) return;
        _cloudLine = line;
        Journal.Add(line);
    }

    /// <summary>Every question about the clouds gets a number; an answer to an older number is dropped.</summary>
    int _cloudsEpoch;

    /// <summary>What a session refreshed goes back into the encrypted clouds.conf of the folder it was opened for.</summary>
    static void SaveSession(string session, string root)
    {
        try { Scripts.Capture(SetupScript("Get-Clouds.ps1"), new[] { "-Save", "-Session", session, "-Root", root }); } catch { }
    }

    /// <summary>Waited for: the window is closing.</summary>
    void SaveClouds()
    {
        if (Rclone.SessionConfig is { Length: > 0 } session) SaveSession(session, DataRoot.Path_);
    }

    /// <summary>
    /// The session of the clouds ends, before the data folder changes. At once, before this
    /// returns, nothing of it stays in the window - neither the config rclone is run with, nor
    /// its password, nor the sources of the panels - and an answer still on its way belongs to
    /// nobody. What the session refreshed is saved into the folder it came from; that takes a
    /// script, and the task returned ends when it has run. The savings stand in one line: a
    /// folder left and chosen again must not have its session opened while it is still saved.
    /// </summary>
    Task CloseClouds()
    {
        _cloudsEpoch++;
        var session = Rclone.SessionConfig;
        var root = DataRoot.Path_;
        Rclone.SessionConfig = null;
        Rclone.SessionEnv.Remove("RCLONE_CONFIG_PASS");
        Sources.SetClouds(Array.Empty<Source>());
        _cloudLine = "";
        if (session is { Length: > 0 })
            _sessionsSaved = _sessionsSaved.ContinueWith(_ => SaveSession(session, root), TaskScheduler.Default);
        return _sessionsSaved;
    }

    Task _sessionsSaved = Task.CompletedTask;

    /// <summary>CONNECT: which cloud, under what name; the signing in is on the side of the cloud itself, in a console of its own.</summary>
    async void CloudAdd()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await AskClouds("-Kinds") is not { } state || !state.TryGetProperty("kinds", out var list) || list.ValueKind != JsonValueKind.Array) return;
        var kinds = list.EnumerateArray().ToList();
        var picked = await ChoiceDialog.Ask(this, CloudAddHead,
            kinds.Select(kind => new Choice(Text(kind, "key"), Text(kind, "label"), Text(kind, "login") == "oauth" ? CloudOauth : CloudPassword)).ToList(),
            RouterNext, new[] { CloudAddNote1, CloudAddNote2 });
        if (picked is null) return;
        var chosen = kinds.First(kind => Text(kind, "key") == picked);

        var name = await Dialog.Ask(this, CloudNameHead, new[] { Lang.T(CloudNameNote1), Lang.T(CloudNameNote2) }, okText: CloudNameOk, value: picked);
        if (name is null) return;
        name = name.Trim();
        if (!CloudName.IsMatch(name)) { Journal.Add(Lang.F(BadName, name)); return; }
        Journal.Add(Lang.F(CloudOpening, Lang.T(Text(chosen, "label")), name));
        WrapperThenClouds("clouds-add.cmd", "-Kind", picked, "-Name", name);
    }

    /// <summary>A wizard of rclone in its own console; when it closes, the clouds are read again.</summary>
    async void WrapperThenClouds(string wrapper, params string[] args)
    {
        if (Scripts.Wrapper(Path.Combine("Runs", wrapper), args) is not { } process) return;
        Journal.Add(Lang.F("[окно] открыто окно: {0}", wrapper));
        try { await process.WaitForExitAsync(); } catch { }
        process.Dispose();
        OpenClouds();
    }

    /// <summary>RENAME: the name is the caption of the button over a panel and the name of the remote; the token stays.</summary>
    async void CloudRename()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await AskClouds("-List") is not { } state) return;
        var clouds = CloudsOf(state);
        if (clouds.Count == 0) { Journal.Add(Lang.T(CloudNone)); return; }
        var old = await ChoiceDialog.Ask(this, CloudRenameHead,
            clouds.Select(cloud => new Choice(cloud.Name, cloud.Name.ToUpperInvariant(), cloud.Type)).ToList(), RouterNext, new[] { CloudRenameNote });
        if (string.IsNullOrEmpty(old)) return;
        var name = await Dialog.Ask(this, CloudNewHead, new[] { Lang.T(CloudLatinNote) }, okText: CloudRenameOk, value: old);
        if (name is null) return;
        name = name.Trim();
        if (name == old) return;
        if (!CloudName.IsMatch(name)) { Journal.Add(Lang.F(BadName, name)); return; }
        if (Scripts.Job(CloudRenameTitle, SetupScript("Manage-Clouds.ps1"), new[] { "-Rename", "-Name", old, "-To", name }, refresh: true) is not { } job) return;
        job.OnSuccess = OpenClouds;
        _jobs.Enqueue(job);
    }

    /// <summary>
    /// THROUGH MAIN VPS: what the left panel shows goes into what the right one shows, cloud to
    /// cloud, by the server itself. It asks first and says how much will go, as COPY does since
    /// 24.09.2026 - until the review of 08.10.2026 one press started it - and it says what is
    /// true of no other transfer of the window: the work goes on MAIN VPS by itself, and СТОП
    /// does not reach it. The script lets one such transfer run at a time.
    /// </summary>
    async void CloudSend()
    {
        using var pending = Pending();
        Source from = Sources.Get(LeftPanel.SourceKey), to = Sources.Get(RightPanel.SourceKey);
        if (!from.Cloud || !to.Cloud)
        {
            Journal.Add(Lang.T(CloudSendNeedsBoth));
            return;
        }
        // Both addresses as they are now: what the question names is what goes.
        string source = from.Remote + LeftPanel.Path.Replace('\\', '/').TrimStart('/'), target = to.Remote + RightPanel.Path.Replace('\\', '/').TrimStart('/');
        string sourceLabel = $"{Lang.T(from.Label)} : {(LeftPanel.Path.Length > 0 ? LeftPanel.Path : "/")}", targetLabel = $"{Lang.T(to.Label)} : {(RightPanel.Path.Length > 0 ? RightPanel.Path : "/")}";
        if (PathGuard.RemoteProblem(source, target, Array.Empty<(string, bool)>(), mirror: false) is { } problem) { Say(problem); return; }

        SetStatus("считаю, что поедет…");
        var plan = await MeasureCopy(source, target, Array.Empty<string>(), Array.Empty<string>());
        SetStatus("");
        string badge = plan is null ? Lang.T("СКОЛЬКО ПОЕДЕТ · сосчитать не успел")
            : plan.Value.Files == 0 ? Lang.T("ПРИЁМНИК УЖЕ СВЕЖИЙ · копировать нечего")
            : Lang.F("БУДЕТ СКОПИРОВАНО: {0} файл. · {1}", plan.Value.Files, Format.Size(plan.Value.Bytes));
        var go = await Dialog.Ask(this, CloudSendHead, new[]
        {
            Lang.T("ИСТОЧНИК: ") + sourceLabel,
            Lang.T("ПРИЁМНИК: ") + targetLabel,
            "",
            CloudSendNote1,
            CloudSendNote2,
        }, CloudSendOk, Tone.Run, badge: badge);
        if (go is null) { Journal.Add(Lang.T("[окно] отменено")); return; }
        Engine("Send-ViaServer.ps1", CloudSendTitle, "-From", source, "-To", target);
    }
}
