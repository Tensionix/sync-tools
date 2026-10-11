using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// The dots of the SETUP and TUNNEL buttons, the look of the power button of the tunnel and the
/// summary of the state in the journal. What
/// is there is asked of the engine - Engine\Scripts\Get-SetupState.ps1 and Get-BeaconState.ps1,
/// JSON, off the window's thread: at the start, when the queue of jobs ends, when a console of a
/// wizard closes, by СОСТОЯНИЕ. A dot is grey when the thing is not there, green when it is there,
/// and for what must work to count - the keys, the addresses, the transport, the pair of R2 -
/// amber until a panel was really read through it: the file alone proves nothing.
/// </summary>
public partial class MainWindow
{
    JsonElement? _setup, _beacon;
    bool _stateBusy, _stateStale;

    static JsonElement? StateOf((int Code, string Output) answer)
    {
        var line = answer.Output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.StartsWith('{'));
        if (answer.Code != 0 || line is null) return null;
        try { using var doc = JsonDocument.Parse(line); return doc.RootElement.Clone(); } catch { return null; }
    }

    async void RefreshState()
    {
        if (!DataRoot.Chosen) return;
        // One question at a time; asked again meanwhile - once more when it ends.
        if (_stateBusy) { _stateStale = true; return; }
        _stateBusy = true;
        try
        {
            do
            {
                _stateStale = false;
                // The folder is named to both scripts here, on the window's thread: asked of the
                // window later, from another thread, it could already be another one.
                var root = DataRoot.Path_;
                var args = new List<string> { "-Root", root };
                if (_settings.ClientName.Length > 0) { args.Add("-ClientName"); args.Add(_settings.ClientName); }
                if (_settings.ArchiveRoot.Length > 0) { args.Add("-ArchiveRoot"); args.Add(_settings.ArchiveRoot); }
                var setup = Task.Run(() => Scripts.Capture(SetupScript("Get-SetupState.ps1"), args));
                var beacon = Task.Run(() => Scripts.Capture(SetupScript("Get-BeaconState.ps1"), new[] { "-Root", root }));
                JsonElement? setupSaid = StateOf(await setup), beaconSaid = StateOf(await beacon);
                // The data folder changed meanwhile: the answers are about the old one and are dropped.
                // The change asks for the state of the new folder itself - now, if it was refused while this one ran.
                if (!string.Equals(root, DataRoot.Path_, StringComparison.OrdinalIgnoreCase)) continue;
                // An answer that did not come leaves the dots as they were: grey would say "not there".
                _setup = setupSaid ?? _setup;
                _beacon = beaconSaid ?? _beacon;
                PaintState();
            }
            while (_stateStale);
        }
        catch { }
        finally { _stateBusy = false; }
    }

    /// <summary>A road proven by deed: a panel was read through it. The dots that waited for the proof go green.</summary>
    void Prove(string key)
    {
        var now = DateTime.Now;
        _proven[key] = now;
        if (Sources.All.TryGetValue(key, out var source))
        {
            _proven["transport"] = now;
            if (source.Probe.Length > 0) _proven["keys"] = now;
            if (source.Remote.StartsWith("r2:", StringComparison.OrdinalIgnoreCase)) _proven["r2"] = now;
        }
        PaintState();
    }

    /// <summary>The dots and the power button from what was asked last - no question is asked here.</summary>
    void PaintState()
    {
        if (_setup is { } s)
        {
            void Fact(string dot, string fact, string? proof = null) =>
                SetDot(dot, !Flag(s, fact) ? "idle" : proof is null || _proven.ContainsKey(proof) ? "ok" : "warn");
            Fact("DotSetupR2", "r2", "r2");
            Fact("DotSetupStore", "store");
            Fact("DotSetupTargets", "targets", "targets");
            Fact("DotSetupNewKey", "newKey", "keys");
            Fact("DotSetupKeys", "keys", "keys");
            Fact("DotSetupHosts", "hosts", "transport");
            Fact("DotSetupTransport", "transport", "transport");
            Fact("DotSetupRouter", "router");
            Fact("DotSetupArchive", "archive");
            SetDot("DotSetupSchedule", _legacyTaskFound ? "ok" : "idle");

            var sshd = Text(s, "sshd");
            SetDot("DotSsh", sshd == "running" ? "ok" : sshd is "none" or "" ? "idle" : "warn", Lang.F("Служба sshd: {0}", SshdSaid(sshd)));

            string wireguard = Text(s, "wireguard"), awg = Text(s, "awg");
            // No client is not a failure: the dot is grey, and the hint says what is missing.
            SetDot("DotWg", wireguard.Length > 0 || awg.Length > 0 ? "ok" : "idle",
                wireguard.Length > 0 && awg.Length > 0 ? Lang.F("WireGuard: {0}\nAmneziaWG: {1}\nтуннели ставятся на AmneziaWG - он тут первый", wireguard, awg)
                : awg.Length > 0 ? Lang.F("AmneziaWG: {0}\nставить WireGuard не нужно: туннели пойдут на этом", awg)
                : wireguard.Length > 0 ? "WireGuard: " + wireguard
                : Lang.T("клиента нет: ни WireGuard, ни AmneziaWG"));

            if (s.TryGetProperty("vpn", out var vpn) && vpn.ValueKind == JsonValueKind.Object)
            {
                bool installed = Flag(vpn, "installed"), conf = Flag(vpn, "conf");
                SetDot("DotVpn", installed ? "ok" : conf ? "warn" : "idle", Lang.F("WG BASE-ROUTER: {0}", VpnSaid(vpn)));
                PaintPower(Text(vpn, "power"));
            }
        }

        if (_beacon is { } b)
        {
            bool alive = Flag(b, "alive"), made = Flag(b, "made");
            int port = b.TryGetProperty("port", out var p) && p.TryGetInt32(out var n) ? n : 0;
            SetDot("DotBeacon", alive ? "ok" : made ? "warn" : "idle",
                alive ? Lang.F("SSH TUN: свой ssh держит канал через {0}, порт туннеля {1}; слушает ли порт - покажет осмотр", Text(b, "via"), port)
                : Flag(b, "starting") ? Lang.T("SSH TUN: канал поднимается")
                : Flag(b, "holder") ? Lang.T("SSH TUN: процесс работает, канала сейчас нет - он пробует снова")
                : made ? Lang.T("SSH TUN: заведён, процесс не работает")
                : Lang.T("SSH TUN: не заведён"));
            // "SSH TUN · MAIN VPS" while the channel lives: which VPS it goes through is the first thing asked.
            if (_dotWords.TryGetValue("DotBeacon", out var word) && word.Tag is string name)
                word.Text = alive && Text(b, "vps") is { Length: > 0 } vps ? name + " · " + vps : name;
        }
    }

    static string SshdSaid(string sshd) =>
        sshd == "running" ? Lang.T("работает") : sshd is "none" or "" ? Lang.T("не заведена") : Lang.F("заведена, {0}", sshd);

    static string VpnSaid(JsonElement vpn) =>
        Flag(vpn, "installed") ? Lang.F("установлен: {0}", Text(vpn, "name")) : Lang.T(Flag(vpn, "conf") ? "не установлен, конфиг есть" : "не установлен");

    static long Number(JsonElement from, string name) =>
        from.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n) ? n : 0;

    bool _summaryBusy, _summaryAsked;

    /// <summary>
    /// The summary of the state in the journal: the latest snapshot, the keys of R2, cloudflared,
    /// sshd, the tunnel to the router of BASE - and every tunnel service of this machine, the ones
    /// of another VPN too: they share one driver with ours. The facts are asked of
    /// Engine\Scripts\Get-StateSummary.ps1 off the window's thread and written in one piece: at
    /// the start, by СОСТОЯНИЕ, and when another data folder is chosen.
    /// </summary>
    async void ShowState()
    {
        if (!DataRoot.Chosen) return;
        if (_summaryBusy) { _summaryAsked = true; return; }
        _summaryBusy = true;
        _summaryAsked = false;
        var root = DataRoot.Path_;
        JsonElement? facts = null;
        bool answered = false;
        try
        {
            facts = StateOf(await Task.Run(() => Scripts.Capture(SetupScript("Get-StateSummary.ps1"), new[] { "-Root", root })));
            answered = true;
        }
        catch { }
        finally { _summaryBusy = false; }
        // The data folder changed while the facts were gathered: they are about the old one and
        // are not written. The change asks for the summary of the new folder itself; refused
        // while this one was busy, it is read now - once, not twice.
        if (!string.Equals(root, DataRoot.Path_, StringComparison.OrdinalIgnoreCase))
        {
            if (_summaryAsked) ShowState();
            return;
        }
        if (!answered) return;
        if (facts is { } said) Journal.AddMany(SummaryLines(said));
        else Journal.Add(Lang.T("[окно] состояние не прочиталось"));
    }

    static List<string> SummaryLines(JsonElement s)
    {
        var lines = new List<string> { "", Lang.T("===== СОСТОЯНИЕ =====") };

        if (s.TryGetProperty("snapshot", out var shot) && shot.ValueKind == JsonValueKind.Object
            && DateTime.TryParse(Text(shot, "time"), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var when))
            lines.Add(Lang.F("снимок: {0}, {1}, возраст {2} ч", when.ToString("dd.MM HH:mm"), Format.Short(Number(shot, "bytes")), Number(shot, "hours")));
        else lines.Add(Lang.T("снимок: ни одного в Snapshots"));

        lines.Add(Lang.F("ключи R2: {0}", Lang.T(Flag(s, "r2") ? "свои, на месте" : "нет")));

        var cloudflared = Text(s, "cloudflared");
        lines.Add(cloudflared.Length == 0 ? Lang.T("cloudflared: нет в Tunnel\\Bin")
            : cloudflared == "?" ? Lang.T("cloudflared: есть, версия не прочиталась")
            : "cloudflared: " + cloudflared);

        // The program registers no task: the line is written only where one of earlier versions is left.
        if (Flag(s, "task")) lines.Add(Lang.F("расписание: {0}", Lang.T("осталось задание прежних версий")));

        lines.Add(Lang.F("sshd: {0} · WG BASE-ROUTER: {1}", SshdSaid(Text(s, "sshd")),
            s.TryGetProperty("vpn", out var vpn) && vpn.ValueKind == JsonValueKind.Object ? VpnSaid(vpn) : Lang.T("не установлен")));

        if (!s.TryGetProperty("tunnels", out var tunnels) || tunnels.ValueKind != JsonValueKind.Array || tunnels.GetArrayLength() == 0) return lines;

        lines.Add("");
        lines.Add(Lang.T("===== ТУННЕЛИ ====="));
        var clients = s.TryGetProperty("clients", out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(one => one.GetString() ?? "").Where(one => one.Length > 0).ToList() : new List<string>();
        lines.Add(clients.Count == 0 ? Lang.T("клиентов туннелей нет") : Lang.F("клиенты: {0} · ставим на {1}", string.Join(", ", clients), Text(s, "pick")));

        foreach (var tunnel in tunnels.EnumerateArray())
        {
            bool on = Text(tunnel, "power") == "on";
            var power = Lang.T(on ? "поднят" : "опущен");
            // null - nobody could be asked; -1 - the ends never shook hands.
            int? shake = tunnel.TryGetProperty("handshake", out var h) && h.ValueKind == JsonValueKind.Number && h.TryGetInt32(out var seconds) ? seconds : null;
            string said;
            // A tunnel of another VPN is shown and marked: it is not ours, but it decides whether ours come up.
            if (Flag(tunnel, "foreign")) said = power + ", " + Lang.T("чужой") + (shake is { } theirs ? ", " + HandshakeSaid(theirs) : "");
            else if (Text(tunnel, "lost") is { Length: > 0 } lost) said = Lang.F("клиент пропал: {0} - переустановите мастером", PathTail(lost));
            else if (!on) said = power;
            else
            {
                said = power + ", " + (shake is { } ours ? HandshakeSaid(ours) : Lang.T("рукопожатия не видно"));
                if (Text(tunnel, "peer") is { Length: > 0 } peer)
                    said += ", " + (Flag(tunnel, "alive") ? Lang.F("{0} отвечает за {1} мс", peer, Number(tunnel, "ms")) : Lang.F("{0} молчит", peer));
            }
            lines.Add($"{Text(tunnel, "name"),-16} {said}");
        }
        return lines;
    }

    /// <summary>The age of a handshake in words: seconds, minutes, hours.</summary>
    static string HandshakeSaid(int seconds) =>
        seconds < 0 ? Lang.T("не здоровались")
        : seconds < 90 ? Lang.F("{0} с назад", seconds)
        : seconds < 5400 ? Lang.F("{0} мин назад", (int)Math.Round(seconds / 60.0))
        : Lang.F("{0} ч назад", (int)Math.Round(seconds / 3600.0));

    /// <summary>
    /// The power button of the tunnel to the router of BASE: green while the tunnel is up, amber
    /// while its service stands but the tunnel is down, and off where no service is installed -
    /// there is nothing to switch, WG BASE-ROUTER raises it first.
    /// </summary>
    void PaintPower(string power)
    {
        MidPower.Classes.Set("live", power == "on");
        MidPower.Classes.Set("down", power == "off");
        MidPower.IsEnabled = power is "on" or "off";
    }
}
