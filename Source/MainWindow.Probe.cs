using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Controls.Documents;
using Avalonia.Controls.Primitives;
using Avalonia.Threading;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// The route to the machines: a knock at TCP port 22 of each of them and of both servers decides
/// it (АВТО), or the owner does with a button of the row. A panel that was read is the stronger
/// proof; the probe only says where to start.
/// </summary>
public partial class MainWindow
{
    readonly Dictionary<string, double?> _lanMs = new();
    string _probeStamp = "";
    bool _probing, _probeAsked;
    bool _accessWarned;

    // A probe that reached neither VPS is tried again a little later, three times at most in a row: the program may start
    // before the network is up (with Windows, or while a VPN connects) - the owner, 20.10.2026, saw `нет` at every road
    // 37 s after his VPN came up, and the line stayed so. A change of the network asks for a probe once it settles: a VPN
    // raises and drops its adapter several times while it connects.
    readonly DispatcherTimer _probeAgain = new() { Interval = TimeSpan.FromSeconds(20) };
    readonly DispatcherTimer _networkSettled = new() { Interval = TimeSpan.FromSeconds(8) };
    int _silentProbes;

    const string ProbeTip = "Проба: стук в TCP-порт 22 машин и обоих VPS. Время - до ближайшего узла маршрута; молчащий маршрут АВТО обходит. Запустить заново: TUNNEL → NET → PORT 22 TCP PING или СОСТОЯНИЕ.";

    void WatchNetwork()
    {
        ToolTip.SetTip(ProbeBadge, Lang.T(ProbeTip));
        _probeAgain.Tick += (_, _) => { _probeAgain.Stop(); StartProbe(quiet: true); };
        _networkSettled.Tick += (_, _) => { _networkSettled.Stop(); _silentProbes = 0; StartProbe(quiet: true); };
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        Closed += (_, _) => { NetworkChange.NetworkAddressChanged -= OnNetworkChanged; _probeAgain.Stop(); _networkSettled.Stop(); };
    }

    // Raised on a thread of the system: the timer is restarted on the window's own.
    void OnNetworkChanged(object? sender, EventArgs e) => Dispatcher.UIThread.Post(() => { _networkSettled.Stop(); _networkSettled.Start(); });

    void WireRoutes()
    {
        var buttons = new (ToggleButton Button, string Key)[]
        {
            (RouteAuto, ""), (RouteHome, "home"), (RouteDirect, "direct"), (RouteCf, "cf"), (RouteVia, "via"),
        };
        foreach (var (button, key) in buttons) button.Click += (_, _) => { if (!_routeBusy) SetRoute(key); };
        // The kebab of the row: the roads per machine, for this session or as the defaults the window starts
        // with (the owner, 18.10.2026: «Из SETTINGS выбор дорог убираем. Вместо этого: делаем кнопку в кебабе
        // ... СДЕЛАТЬ ПО УМОЛЧАНИЮ», and «кнопку RESET в этом диалоге - вернуть как было с релиза»).
        RouteMore.Click += (_, _) => ShowRouteBoard();
        MarkRoute();
    }

    /// <summary>The machines a road is chosen for, in the order of the board.</summary>
    static readonly string[] RouteMachines = { "base", "laptop", "server", "home", "dad", "work" };

    /// <summary>Whether the roads of this session are the saved defaults.</summary>
    bool SameAsDefaults() => Sources.All.Values.Where(s => s.Probe.Length > 0)
        .All(s => Sources.Picked.GetValueOrDefault(s.Key, "") == _settings.Routes.GetValueOrDefault(s.Key, ""));

    /// <summary>The route all machines share, or null when they differ.</summary>
    string? CommonRoute()
    {
        var values = Sources.All.Values.Where(s => s.Probe.Length > 0).Select(s => Sources.Picked.GetValueOrDefault(s.Key, "")).Distinct().ToList();
        return values.Count <= 1 ? values.FirstOrDefault() ?? "" : null;
    }

    void MarkRoute()
    {
        _routeBusy = true;
        try
        {
            var common = CommonRoute();
            RouteAuto.IsChecked = common == "";
            RouteHome.IsChecked = common == "home";
            RouteDirect.IsChecked = common == "direct";
            RouteCf.IsChecked = common == "cf";
            RouteVia.IsChecked = common == "via";
            RouteMoreDot.IsVisible = !SameAsDefaults();
        }
        finally { _routeBusy = false; }
    }

    /// <summary>
    /// A route picked by hand; the empty key gives the choice back to the probe. A button of the
    /// row sets it for every machine at once, and the panels of machines are read again at once:
    /// the point of the button is to see the result, not to remember an intention. For this
    /// session only: the window starts with the defaults saved by the board.
    /// </summary>
    void SetRoute(string key)
    {
        foreach (var source in Sources.All.Values.Where(s => s.Probe.Length > 0)) Sources.Picked[source.Key] = key;
        MarkRoute();
        AfterRouteChange();
    }

    void AfterRouteChange()
    {
        LeftPanel.UpdateSourceCaptions();
        RightPanel.UpdateSourceCaptions();
        ShowProbeSummary();
        foreach (var panel in new[] { LeftPanel, RightPanel })
            if (Sources.Get(panel.SourceKey).Probe.Length > 0) panel.Reload();
    }

    /// <summary>
    /// The roads a machine really has, as the board shows them: АВТО, its own address, MAIN VPS by
    /// name, MAIN VPS over cloudflared, SECOND VPS - each with the time to its nearest node, a silent
    /// one dimmed.
    /// </summary>
    List<Views.RouteOption> RouteOptions(string key, Source source, string where)
    {
        bool Live(string node) => !Sources.LanUp.TryGetValue(node, out var up) || up;
        string Time(string node) => _lanMs.ContainsKey(node) ? Delay(_lanMs[node]) : "";

        var options = new List<Views.RouteOption>
        {
            new("", "АВТО", "Маршрут выбирает проба, для каждой машины отдельно: дома - домашняя сеть, издалека - VPS, который отвечает быстрее."),
            // The first road is captioned by the address itself: words are useless here, the address shows where it leads.
            new("home", where.Length > 0 ? where : "адреса нет",
                key is "base" or "laptop"
                    ? "Прямо на адрес, без jump host. Это домашняя сеть: работает дома и пока поднят туннель до сети BASE."
                    : "Прямо на адрес, без jump host. Адрес вписан кнопкой АДРЕСА",
                Time(source.Probe), Live(source.Probe)),
        };
        if (Rclone.Configured(source.RemoteSsh) || Rclone.Configured(source.RemoteDirect))
            options.Add(new("direct", Sources.RouteMain, "Через MAIN VPS по его прямому имени: в SSH TUN машины, если он заведён, иначе через jump host.", Time("direct"), Live("direct")));
        if (Rclone.Configured(source.RemoteCf))
            options.Add(new("cf", Sources.RouteCf, "Тот же MAIN VPS поверх cloudflared: выглядит обычным HTTPS.", Time("cloud"), Live("cloud")));
        if (Rclone.Configured(source.RemoteVia))
            options.Add(new("via", Sources.RouteVia, "Через SECOND VPS. Границу не пересекает.", Time("second"), Live("second")));
        return options;
    }

    /// <summary>Where the road of a machine really leads: the names LAN and SECOND VPS say nothing until the address is seen.</summary>
    static string WhereOf(Dictionary<string, Target> targets, string key) =>
        targets.TryGetValue(key, out var target) ? (target.Lan.Length > 0 ? target.Lan : target.Host) : "";

    /// <summary>
    /// The board of routes per machine (the kebab of the ROUTE row and of the strip between the
    /// panels): the roads of this session, or the defaults the window starts with. The time shown is to the nearest node of a road, not
    /// through to the machine: a through measure would mean a knock along every road and would hold
    /// the window for seconds.
    /// </summary>
    async void ShowRouteBoard()
    {
        using var pending = Pending();
        var targets = Targets.Read().ToDictionary(t => t.Key, t => t);
        var rows = new List<Views.RouteRow>();
        foreach (var key in RouteMachines)
        {
            if (!Sources.All.TryGetValue(key, out var source) || source.Probe.Length == 0) continue;
            var where = WhereOf(targets, key);
            rows.Add(new Views.RouteRow(key, source.Label, Sources.Picked.GetValueOrDefault(key, ""),
                Lang.F("куда ходит: {0}", where.Length > 0 ? where : Lang.T("адрес не вписан")), RouteOptions(key, source, where)));
        }
        if (rows.Count == 0) return;

        var answer = await Views.RouteBoard.Ask(this, rows, new[]
        {
            "Замер показан до ближайшего узла маршрута, а не до самой машины.",
            "Погашенное сейчас молчит. Маршрут, которого у машины нет, здесь не показан вовсе.",
            "АВТО издалека берёт VPS, который отвечает быстрее: MAIN VPS по имени или SECOND VPS; разница меньше десятой доли - не разница.",
            "ПРИМЕНИТЬ - до закрытия программы; СДЕЛАТЬ ПО УМОЛЧАНИЮ - и для следующих запусков; СБРОСИТЬ - всем машинам АВТО, как в новой программе.",
        });
        if (answer is null) return;

        foreach (var (key, route) in answer.Picked) Sources.Picked[key] = route;
        if (answer.Kind == Views.RouteBoardKind.MakeDefault)
        {
            _settings.Routes = new Dictionary<string, string>(Sources.Picked);
            _settings.Save();
        }
        else if (answer.Kind == Views.RouteBoardKind.Reset)
        {
            Sources.Picked.Clear();
            _settings.Routes = new Dictionary<string, string>();
            _settings.Save();
        }
        // The row of buttons shows a common road only when it really is common.
        MarkRoute();
        Journal.Add("");
        Journal.Add(Lang.T("===== МАРШРУТЫ ПО МАШИНАМ ====="));
        foreach (var row in rows)
        {
            var now = Sources.Picked.GetValueOrDefault(row.Key, "");
            var said = row.Options.FirstOrDefault(o => o.Key == now);
            Journal.Add($"{Lang.T(row.Label),-10} {(said is null ? Lang.T("АВТО") : Lang.T(said.Label))}");
        }
        if (answer.Kind == Views.RouteBoardKind.MakeDefault) Journal.Add(Lang.T("сохранено по умолчанию: с этими маршрутами программа и стартует"));
        else if (answer.Kind == Views.RouteBoardKind.Reset) Journal.Add(Lang.T("маршруты сброшены: всем машинам АВТО, умолчаний нет"));
        AfterRouteChange();
    }

    sealed record ProbeItem(string Key, string Address, int Port, string Label);
    sealed record ProbeResult(string Key, bool Ok, double? Ms, string Access);

    /// <summary>
    /// Knocks at port 22 of the machines, of MAIN VPS and SECOND VPS and at the door of
    /// cloudflared. The probes go at once and are timed beside the connection itself, off the
    /// window's thread: six connections in a row would freeze the window for seconds.
    /// </summary>
    async void StartProbe(bool quiet)
    {
        if (_probing) { _probeAsked = true; return; }
        _probeAsked = false;
        var targets = Targets.Read();
        if (targets.Count == 0) { if (!quiet) Journal.Add(Lang.T("[окно] проба: нет файла адресов - SETUP → АДРЕСА")); return; }

        var server = targets.FirstOrDefault(t => t.Key == "server");
        var second = targets.FirstOrDefault(t => t.Key == "second");
        // Both names of MAIN VPS are the household's: targets.json, or the routes the tunnel client wrote into
        // this machine's ~\.ssh\config. The code names none - the straight one leads to the outer address of the server.
        var direct = server is { Host.Length: > 0 } ? server.Host : Ssh.HostNameOf("audion-vps-direct");
        var door = server is { CloudflaredHost.Length: > 0 } ? server.CloudflaredHost : Ssh.HostNameOf("audion-vps");
        var plan = new List<ProbeItem>();
        // MAIN VPS is the way home from other networks. The straight road to it is shorter
        // than over cloudflared but lives until the address is blocked; the probe decides.
        if (direct.Length > 0) plan.Add(new("direct", direct, 22, "MAIN VPS 22"));
        else SetDot("host:server", "idle", "адреса MAIN VPS нет в targets.json - SETUP → АДРЕСА");
        // The door cloudflared walks through: reached almost always, silent only where plain HTTPS is shut too.
        if (door.Length > 0) plan.Add(new("cloud", door, 443, "cloudflare 443"));
        if (second is { Host.Length: > 0 }) plan.Add(new("second", second.Host, second.SshPort, $"SECOND VPS {second.SshPort}"));

        var transports = Rclone.Transports();
        foreach (var target in targets)
        {
            if (target.Key is "server" or "second") continue;
            string address = target.Lan;
            int port = target.SshPort;
            // Probe the endpoint rclone will really use (the LAN name of a laptop, say).
            if (Sources.All.TryGetValue(target.Key, out var source) && Rclone.Configured(source.Remote)
                && transports.TryGetValue(source.Remote.Split(':', 2)[0], out var config)
                && config.GetValueOrDefault("type", "") == "sftp" && !config.ContainsKey("ssh") && config.GetValueOrDefault("host", "").Length > 0)
            {
                address = config["host"];
                if (int.TryParse(config.GetValueOrDefault("port", ""), out var p) && p is > 0 and < 65536) port = p;
            }
            if (address.Length == 0)
            {
                SetDot("host:" + target.Key, "idle", "адреса нет в targets.json");
                continue;
            }
            plan.Add(new(target.Key, address, port, $"{target.Caption} {port}"));
        }

        _probing = true;
        if (_barButtons.TryGetValue("ProbeButton", out var knock)) knock.IsEnabled = false;
        ProbeLine(Lang.T("проба идёт…"));
        var cloudflared = Paths.Script(Path.Combine("Tunnel", "Bin", "cloudflared.exe"));
        var step = _dataStep;
        List<ProbeResult> results;
        try { results = await Task.Run(() => Probe(plan, 1200, cloudflared)); }
        catch { results = new(); }
        if (step != _dataStep)
        {
            // The data folder changed while its addresses were knocked at: these answers are about
            // the machines of the old one and are dropped. The change asks for a probe of the new
            // folder itself; refused while this one ran, it goes now.
            _probing = false;
            if (_barButtons.TryGetValue("ProbeButton", out var free)) free.IsEnabled = true;
            ShowProbeSummary();
            if (_probeAsked) StartProbe(quiet: true);
            return;
        }

        // The answers are remembered whole first: the colour of a dot depends not only on its
        // own probe but on whether a detour is alive.
        foreach (var row in results)
        {
            Sources.LanUp[row.Key] = row.Ok;
            // A machine that answered at its address proves the addresses are written right.
            if (row.Ok && row.Key is "base" or "laptop" or "home" or "dad" or "work") _proven["targets"] = DateTime.Now;
            _lanMs[row.Key] = row.Ok ? row.Ms : null;
            // АВТО picks the VPS by these times (Sources.RouteName).
            if (row.Ok && row.Ms is { } ms) Sources.RoadMs[row.Key] = ms;
            else Sources.RoadMs.Remove(row.Key);
        }
        // No sign-in to Cloudflare Access: said once, until it appears.
        if (results.FirstOrDefault(r => r.Key == "cloud") is { } cloud)
        {
            if (cloud.Access == "missing" && !_accessWarned)
            {
                _accessWarned = true;
                Journal.Add(Lang.F("Cloudflare Access: входа нет - дорога через cloudflared пропущена. Войти: RESTORE → MIRROR или Tunnel\\Bin\\cloudflared.exe access login https://{0}", plan.First(p => p.Key == "cloud").Address));
            }
            else if (cloud.Access == "ok") _accessWarned = false;
        }
        foreach (var row in results)
        {
            var item = plan.First(p => p.Key == row.Key);
            // A red dot at a machine that opens fine by a jump told a lie: it is about the
            // straight road, not about reachability. A silent straight road with a live detour
            // is a warning, not a refusal.
            var detour = !row.Ok && Sources.All.ContainsKey(row.Key) ? Sources.RouteName(row.Key) : "";
            var state = row.Ok ? "ok" : detour.Length > 0 ? "warn" : "bad";
            var hint = $"{item.Address}:{item.Port} " + (row.Ok ? Lang.F("отвечает за {0}", Delay(row.Ms))
                : detour.Length > 0 ? Lang.F("напрямую молчит, идём через {0}", detour) : Lang.T("молчит"));
            SetDot("host:" + (row.Key == "direct" ? "server" : row.Key), state, hint);
        }
        // The network may have changed: old grudges against routes are forgotten.
        Sources.RouteFail.Clear();
        _probeStamp = DateTime.Now.ToString("HH:mm");
        _probing = false;
        // Neither MAIN VPS, nor the door of cloudflared, nor SECOND VPS answered: the way out of this network is not up
        // yet, as a rule. A machine or a router of this very network may answer all the same, and it is no sign of the
        // way out: on 27.10.2026 the router at work answered at the start, and the roads to both VPS stayed "нет" until
        // an update of the tools happened to ask for a probe.
        var roads = results.Where(r => r.Key is "direct" or "cloud" or "second").ToList();
        if (roads.Count > 0 && roads.All(r => !r.Ok)) { if (++_silentProbes <= 3) _probeAgain.Start(); }
        else _silentProbes = 0;
        if (_barButtons.TryGetValue("ProbeButton", out var again)) again.IsEnabled = true;
        // The probe decides the road and ends later than the first reading of the panels: they
        // are read again, or they go on knocking at an address that is silent in this network.
        AfterRouteChange();
        // A probe asked while this one ran - the network settled after a change, the tools were updated - goes now:
        // dropped, it left the answers of the network as it was before.
        if (_probeAsked) { _probeAgain.Stop(); StartProbe(quiet: true); }
    }

    static List<ProbeResult> Probe(List<ProbeItem> items, int timeoutMs, string cloudflared)
    {
        // Names are resolved beforehand and off the clock: DNS takes longer than the handshake
        // itself and would smear the whole picture.
        var addresses = new Dictionary<string, string>();
        foreach (var item in items)
        {
            addresses[item.Key] = item.Address;
            if (IPAddress.TryParse(item.Address, out _)) continue;
            try
            {
                var ip = Dns.GetHostAddresses(item.Address).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
                if (ip is not null) addresses[item.Key] = ip.ToString();
            }
            catch { }
        }

        var probes = items.Select(item =>
        {
            var client = new TcpClient();
            Task task;
            try { task = client.ConnectAsync(addresses[item.Key], item.Port); }
            catch (Exception ex) { task = Task.FromException(ex); }
            // A knock that got no answer is dropped at the timeout, and its task fails later with "aborted":
            // the failure is looked at here, or it would come back as an error nobody waited for.
            _ = task.ContinueWith(failed => _ = failed.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
            return (item.Key, Client: client, Task: task, Watch: Stopwatch.StartNew());
        }).ToList();

        var done = new Dictionary<string, (bool Ok, double? Ms)>();
        var whole = Stopwatch.StartNew();
        while (done.Count < probes.Count)
        {
            foreach (var probe in probes)
            {
                if (done.ContainsKey(probe.Key)) continue;
                if (probe.Task.IsCompleted)
                {
                    probe.Watch.Stop();
                    done[probe.Key] = (probe.Task.IsCompletedSuccessfully && probe.Client.Connected, probe.Watch.Elapsed.TotalMilliseconds);
                }
                else if (whole.ElapsedMilliseconds > timeoutMs)
                {
                    probe.Watch.Stop();
                    done[probe.Key] = (false, null);
                }
            }
            if (done.Count < probes.Count) System.Threading.Thread.Sleep(1);
        }
        foreach (var probe in probes) { try { probe.Client.Close(); } catch { } }

        // An open 443 is not yet a road. Without a sign-in to Cloudflare Access cloudflared opens
        // a browser and waits in silence, ssh waits for it, and the window with them - no time,
        // no line in the journal (26.09.2026). The sign-in is checked here, in the thread of the
        // probe, and without it the road over cloudflared counts as silent: the choice of the
        // route goes on to the next one by itself.
        string access = "";
        if (done.TryGetValue("cloud", out var cloud) && cloud.Ok)
        {
            access = "missing";
            if (File.Exists(cloudflared))
            {
                try
                {
                    var info = new ProcessStartInfo(cloudflared, "access token -app=https://" + items.First(i => i.Key == "cloud").Address)
                    {
                        UseShellExecute = false, CreateNoWindow = true,
                        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                    };
                    using var check = Process.Start(info);
                    if (check is not null)
                    {
                        check.StandardInput.Close();
                        // The answer of a success is the token itself: read and thrown away.
                        _ = check.StandardOutput.ReadToEndAsync();
                        _ = check.StandardError.ReadToEndAsync();
                        if (check.WaitForExit(5000)) { if (check.ExitCode == 0) access = "ok"; }
                        else { try { check.Kill(); } catch { } }
                    }
                }
                catch { }
            }
            if (access != "ok") done["cloud"] = (false, cloud.Ms);
        }
        return items.Select(i => new ProbeResult(i.Key, done[i.Key].Ok, done[i.Key].Ms, i.Key == "cloud" ? access : "")).ToList();
    }

    /// <summary>The answer time in a human shape: milliseconds up to a second, then seconds with one digit.</summary>
    static string Delay(double? ms)
    {
        if (ms is not { } value) return Lang.T("нет");
        var ru = CultureInfo.GetCultureInfo("ru-RU");
        return value < 1000 ? string.Format(ru, Lang.T("{0:N0} мс"), value) : string.Format(ru, Lang.T("{0:N1} с"), value / 1000);
    }

    /// <summary>
    /// The line of the probe in words: what answers, what is silent and by which road we go.
    /// "3 of 6" says nothing when there are four roads.
    /// </summary>
    /// <summary>One plain line in place of the summary. The line is kept in the inlines alone: a text set beside them stayed in front of the next summary.</summary>
    void ProbeLine(string text)
    {
        var inlines = ProbeText.Inlines ??= new InlineCollection();
        inlines.Clear();
        inlines.Add(new Run(text) { Foreground = App.Ink("TextMuted") });
    }

    void ShowProbeSummary()
    {
        var inlines = ProbeText.Inlines ??= new InlineCollection();
        inlines.Clear();
        if (_probeStamp.Length == 0) { ToolTip.SetTip(ProbeBadge, Lang.T(ProbeTip)); return; }
        var muted = App.Ink("TextMuted");
        var whole = new System.Text.StringBuilder(Lang.F("проба {0}", _probeStamp));
        inlines.Add(new Run(Lang.F("проба {0}", _probeStamp)) { Foreground = muted });
        foreach (var (key, text) in new[] { ("base", "BASE"), ("direct", "MAIN VPS"), ("cloud", "MAIN VPS CF"), ("second", "SECOND VPS") })
        {
            if (!Sources.LanUp.ContainsKey(key)) continue;
            var delay = Delay(_lanMs.GetValueOrDefault(key));
            inlines.Add(new Run($" · {text} ") { Foreground = muted });
            inlines.Add(new Run(delay) { Foreground = App.Ink(Sources.LanUp[key] ? "DotOk" : "DotWarn") });
            whole.Append($" · {text} {delay}");
        }
        var route = Sources.RouteName("base");
        var road = route.Length > 0 ? route : "LAN";
        var common = CommonRoute();
        var how = common is null ? Lang.T("по машинам") : common.Length > 0 ? Lang.T("выбрано") : Lang.T("по пробе");
        // The line stands between the data folder and the buttons of the top row and must fit there (the owner,
        // 20.10.2026: «она не влезает»): the road after an arrow, and who chose it only when it was not the probe.
        // The whole line, with the way of the choice, is the tooltip - above what the probe is.
        inlines.Add(new Run(common is { Length: 0 } ? $" → {road}" : $" → {road} ({how})") { Foreground = muted });
        whole.Append(Lang.F(" · путь: {0} ({1})", road, how));
        ToolTip.SetTip(ProbeBadge, whole + "\n\n" + Lang.T(ProbeTip));
    }

    void SetDot(string name, string state, string hint = "")
    {
        if (!_dots.TryGetValue(name, out var dot)) { _dotStates[name] = (state, hint); return; }
        _dotStates[name] = (state, hint);
        dot.Fill = App.Ink(state switch { "ok" => "DotOk", "warn" => "DotWarn", "bad" => "DotBad", _ => "DotIdle" });
        if (hint.Length > 0) ToolTip.SetTip(dot, Lang.T(hint));
    }

    /// <summary>What every dot showed last: a row of buttons is built again with the section, and its dots must not go grey.</summary>
    readonly Dictionary<string, (string State, string Hint)> _dotStates = new();

    void UpdateDots()
    {
        foreach (var (name, (state, hint)) in _dotStates.ToList()) SetDot(name, state, hint);
    }
}
