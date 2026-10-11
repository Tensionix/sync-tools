using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The wizards of TUNNEL: the routers and the WG tunnel to the router of BASE. As with SETUP, the
/// window asks and a wrapper does the work in a console of its own - a conversation with a router
/// and the installing of a service are sessions the owner watches. What a wizard shows before it
/// asks comes from Engine\Scripts\Get-TunnelState.ps1 (JSON): the window touches neither a
/// service nor a router itself.
/// </summary>
public partial class MainWindow
{
    /// <summary>The router to talk to. One with an address - no question; several - a choice; none - a word in the journal.</summary>
    async Task<JsonElement?> PickRouter(string head)
    {
        if (await Describe("Set-RouterSecret.ps1", "-Describe") is not { } state) return null;
        var routers = state.TryGetProperty("routers", out var list) && list.ValueKind == JsonValueKind.Array ? list.EnumerateArray().ToList() : new List<JsonElement>();
        if (routers.Count == 0)
        {
            Journal.Add(Lang.T("[роутер] ни у одного роутера нет адреса - впишите его кнопкой АДРЕСА"));
            return null;
        }
        if (routers.Count == 1) return routers[0];
        var picked = await ChoiceDialog.Ask(this, head, routers.Select(item => new Choice(Text(item, "key"), Text(item, "label"),
            $"{Lang.T(RouterNotes.GetValueOrDefault(Text(item, "key"), ""))} · {Text(item, "address")}")).ToList(), RouterNext);
        return picked is null ? null : routers.First(item => Text(item, "key") == picked);
    }

    /// <summary>NDMS API: a read-only talk with a router, in its own console.</summary>
    async void RouterCheck()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await PickRouter(CheckWhich) is not { } router) return;
        External("check-router.cmd", Lang.F(CheckTitle, Text(router, "label")), "-Address", Text(router, "address"), "-Router", Text(router, "key"));
    }

    /// <summary>ROUTER WG PEER: a config for a new peer. The pair is born here - the router gets the public key alone. First a show: the commands are seen before they go.</summary>
    async void RouterPeer()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await PickRouter(PeerWhich) is not { } router) return;
        // Who is registered already is asked of the router: without it the wizard wrote blindly.
        var lines = new List<string>();
        var badges = new List<FormBadge>();
        var peers = await Describe("Get-TunnelState.ps1", "-Peers", "-Router", Text(router, "key"), "-Address", Text(router, "address"));
        if (peers is { } known && Flag(known, "answered"))
        {
            var busy = known.TryGetProperty("busy", out var b) && b.ValueKind == JsonValueKind.Object ? b.EnumerateObject().ToList() : new List<JsonProperty>();
            lines.Add(Lang.F(PeerTaken, string.Join(", ", busy.OrderBy(item => item.Name, StringComparer.Ordinal).Select(item => $"{item.Name} - {item.Value.GetString()}"))));
            if (Text(known, "free").Length > 0) lines.Add(Lang.F(PeerFree, Text(known, "free")));
            badges.Add(new FormBadge(Lang.F(PeerCount, busy.Count), "ok"));
        }
        else
        {
            lines.Add(Lang.T(PeerSilentNote));
            badges.Add(new FormBadge(Lang.T(PeerSilent), "warn"));
        }
        lines.Add(Lang.T(TunnelWhere));
        lines.Add(Lang.T(PeerPairNote));

        var answer = await FormDialog.Ask(this, PeerHead, RouterNext, lines, badges,
            fields: new[] { new FormField("name", PeerNameLabel, _settings.ClientName) },
            choices: new[] { new Choice("show", PeerShow, PeerShowNote), new Choice("write", PeerWrite, PeerWriteNote) }, picked: "show");
        if (answer is null) return;
        var name = answer.Fields["name"].Trim();
        if (name.Length == 0 || name.StartsWith('-')) return;
        var args = new List<string> { "-Name", name };
        if (answer.Choice == "show") args.Add("-WhatIf");
        // The address of the router is always passed: the script's default is the router of BASE, and there are three routers.
        args.AddRange(new[] { "-Address", Text(router, "address"), "-Router", Text(router, "key") });
        External("new-router-peer.cmd", Lang.F(PeerTitle, Text(router, "label"), name), args.ToArray());
    }

    /// <summary>WIREGUARD: what tunnel client stands; the installer runs only where there is none - a second client beside the first takes the driver away.</summary>
    async void SetupWg()
    {
        using var pending = Pending();
        if (await Describe("Get-TunnelState.ps1", "-Clients") is not { } state) return;
        string wireguard = Text(state, "wireguard"), awg = Text(state, "awg");
        var badges = new[]
        {
            new FormBadge(Lang.F("WireGuard: {0}", Lang.T(wireguard.Length > 0 ? Yes : NotInstalled)), wireguard.Length > 0 ? "ok" : "idle"),
            new FormBadge(Lang.F("AmneziaWG: {0}", Lang.T(awg.Length > 0 ? Yes : NotInstalled)), awg.Length > 0 ? "ok" : "idle"),
        };
        var lines = new List<string>();
        if (wireguard.Length > 0) lines.Add("WireGuard: " + wireguard);
        if (awg.Length > 0) lines.Add("AmneziaWG: " + awg);
        if (lines.Count > 0)
        {
            lines.Add("");
            lines.Add(Lang.T(awg.Length > 0 ? WgAwgNote : WgHaveNote));
            await FormDialog.Ask(this, WgHead, WgClose, lines, badges);
            Journal.Add("");
            Journal.Add(Lang.T(WgJournalHead));
            foreach (var line in lines.Where(line => line.Length > 0)) Journal.Add(line);
            return;
        }
        if (await FormDialog.Ask(this, WgHead, WgInstall, new[] { Lang.T(WgNoneNote) }, badges) is null) return;
        External("install-wireguard.cmd", WgInstallTitle);
    }

    string Handshake(int seconds) => seconds < 0 ? Lang.T(HandNever)
        : seconds < 90 ? Lang.F(HandSeconds, seconds)
        : seconds < 5400 ? Lang.F(HandMinutes, seconds / 60)
        : Lang.F(HandHours, seconds / 3600);

    /// <summary>
    /// WG BASE-ROUTER: the tunnel to the router of BASE - raise it, raise it at every boot, look at
    /// it, or take it down. Only the listed networks go through the tunnel; they are kept in
    /// Tunnel\WG\routes.txt of the data folder, a network a line.
    /// </summary>
    async void SetupVpn()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("Get-TunnelState.ps1", "-Tunnel") is not { } state) return;
        string status = Text(state, "status"), name = Text(state, "name"), inside = Text(state, "inside"), conf = Text(state, "conf");
        bool live = status.Length > 0;
        var badges = new List<FormBadge>
        {
            new(Lang.F(TunService, live ? status : Lang.T(TunNotMade)), status == "Running" ? "ok" : live ? "warn" : "idle"),
            new(Lang.F(TunName, name), name == "router-base-wg" ? "ok" : "warn"),
            new(Lang.F(TunAddress, inside.Length > 0 ? inside : Lang.T(No)), inside.Length > 0 ? "ok" : "idle"),
            new(Lang.F(TunConf, conf.Length > 0 ? conf : Lang.T(No)), conf.Length > 0 ? "ok" : "bad"),
        };
        if (Flag(state, "handshake"))
        {
            int seconds = state.TryGetProperty("seconds", out var s) && s.TryGetInt32(out var n) ? n : -1;
            badges.Add(new FormBadge(Lang.F(TunHandshake, Handshake(seconds)), seconds >= 0 && seconds < 300 ? "ok" : "warn"));
        }
        if (Text(state, "peer") is { Length: > 0 } peer)
        {
            int ms = state.TryGetProperty("ms", out var m) && m.TryGetInt32(out var k) ? k : 0;
            badges.Add(Flag(state, "alive") ? new FormBadge(Lang.F(TunPeerAlive, peer, ms), "ok") : new FormBadge(Lang.F(TunPeerSilent, peer), "warn"));
        }
        List<string> Strings(string key) => state.TryGetProperty(key, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0).ToList() : new List<string>();
        var here = Strings("local");

        var answer = await FormDialog.Ask(this, TunHead, RouterNext, new[]
        {
            Lang.T(TunnelWhere),
            Lang.F("LOCAL: {0}", here.Count > 0 ? string.Join(", ", here) : Lang.T(NoAddress)),
            "",
            Lang.T(TunRoutesNote),
        }, badges,
        routes: Strings("routes"),
        choices: new[]
        {
            new Choice("up", TunUp, TunUpNote), new Choice("boot", TunBoot, TunBootNote),
            new Choice("check", TunCheck, TunCheckNote), new Choice("down", TunDown, TunDownNote),
        }, picked: live ? "check" : "up");
        if (answer is null) return;

        var wanted = new List<string>();
        foreach (var typed in answer.Routes)
        {
            // A network that is not one would become a route nobody asked for - or none, silently.
            if (Network(typed) is not { } net)
            {
                Journal.Add(Lang.F("[туннель] сеть записана неверно: {0}", typed));
                Journal.Add(Lang.T("[туннель] годится адрес с маской: 192.168.10.0/24 или 192.168.1.10/32"));
                return;
            }
            if (!wanted.Contains(net)) wanted.Add(net);
        }
        if (wanted.Count > 0)
        {
            try
            {
                var dir = DataRoot.File_(Path.Combine("Tunnel", "WG"));
                Directory.CreateDirectory(dir);
                // With a BOM, as the previous window wrote it: Windows PowerShell reads the file too.
                File.WriteAllLines(Path.Combine(dir, "routes.txt"), new[] { TunFileHead1, TunFileHead2, TunFileHead3, "" }.Concat(wanted), new UTF8Encoding(true));
                Journal.Add(Lang.F(TunRoutesSaid, string.Join(", ", wanted)));
            }
            catch (Exception ex) { Journal.Add(Lang.F("[окно] не записалось: {0}", ex.Message)); return; }
        }
        var args = answer.Choice switch { "check" => new[] { "-Check" }, "down" => new[] { "-Remove" }, "boot" => new[] { "-AtBoot" }, _ => Array.Empty<string>() };
        External("setup-base-vpn.cmd", "WG BASE-ROUTER", args);
    }

    /// <summary>An IPv4 network as routes.txt keeps it: four numbers and a mask; an address without a mask is one machine.</summary>
    static string? Network(string typed)
    {
        var parts = typed.Split('/');
        if (parts.Length > 2) return null;
        var octets = parts[0].Split('.');
        if (octets.Length != 4 || octets.Any(o => o.Length is 0 or > 3 || !o.All(char.IsAsciiDigit) || int.Parse(o) > 255)) return null;
        int bits = 32;
        if (parts.Length == 2 && (parts[1].Length is 0 or > 2 || !parts[1].All(char.IsAsciiDigit) || (bits = int.Parse(parts[1])) > 32)) return null;
        return $"{string.Join(".", octets.Select(int.Parse))}/{bits}";
    }

    /// <summary>The power of the tunnel to the router of BASE. With Ctrl it is raised in spite of a clash with the network the machine stands in.</summary>
    void TunnelPower()
    {
        if (!NeedData()) return;
        Engine("Switch-Tunnel.ps1", "WG BASE-ROUTER", Ctrl ? new[] { "-Force" } : Array.Empty<string>());
    }
}
