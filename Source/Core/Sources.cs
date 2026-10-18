using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

/// <summary>
/// What a panel can show. Remote empty - local paths, otherwise a remote of rclone; Root - where
/// the walk starts. A machine has up to four routes, each a remote of its own in rclone.conf:
/// straight over the LAN, a jump through MAIN VPS by its name, the same over cloudflared, a jump
/// through SECOND VPS.
/// </summary>
public sealed class Source
{
    public string Key { get; init; } = "";
    public string Label { get; init; } = "";
    public string Tip { get; init; } = "";
    public string Root { get; init; } = "";
    public string Remote { get; init; } = "";
    public string RemoteSsh { get; init; } = "";
    public string RemoteDirect { get; init; } = "";
    public string RemoteCf { get; init; } = "";
    public string RemoteVia { get; init; } = "";
    /// <summary>The name of the probe that says whether the straight road is up; empty - nothing to choose.</summary>
    public string Probe { get; init; } = "";
    /// <summary>A cloud drive: its own encrypted config and a password for it.</summary>
    public bool Cloud { get; init; }
    /// <summary>The kind of the cloud as rclone names it ("drive", "dropbox"): two clouds of one kind can copy between themselves on the side of the provider.</summary>
    public string CloudType { get; init; } = "";

    public bool IsRemote => Remote.Length > 0;
}

/// <summary>A mode of the window: which row of buttons is shown and what the panels open.</summary>
public sealed record Section(string Key, string Title, string Hint, string[] Sources, string Left, string Right);

public static class Sources
{
    public const string RouteMain = "SSH MAIN VPS", RouteCf = "SSH MAIN VPS CF", RouteVia = "SSH SECOND VPS";

    static Dictionary<string, Source> _all = Build();

    public static IReadOnlyDictionary<string, Source> All => _all;

    public static Source Get(string key) => _all.TryGetValue(key, out var s) ? s : _all["local"];

    /// <summary>After the data folder changed: the local sources are folders inside it.</summary>
    public static void Rebuild()
    {
        var clouds = _all.Values.Where(s => s.Cloud).ToList();
        _all = Build();
        foreach (var cloud in clouds) _all[cloud.Key] = cloud;
        // Another data folder is another config: the same name of a remote may lead to another machine.
        lock (Asked) Asked.Clear();
    }

    /// <summary>The clouds the owner attached: their set is data, not markup.</summary>
    public static void SetClouds(IEnumerable<Source> clouds)
    {
        foreach (var key in _all.Values.Where(s => s.Cloud).Select(s => s.Key).ToList()) _all.Remove(key);
        foreach (var cloud in clouds) _all[cloud.Key] = cloud;
    }

    static Dictionary<string, Source> Build()
    {
        var data = DataRoot.Path_;
        var list = new[]
        {
            new Source { Key = "local", Label = "LOCAL", Tip = "Диски этой машины." },
            new Source { Key = "base", Label = "BASE", Remote = "base:", RemoteDirect = "base-direct:", RemoteCf = "base-cf:", RemoteVia = "base-via:", Probe = "base", Root = "/",
                Tip = "Стационар BASE по ssh, ключом этой машины. Дома идём по домашней сети, издалека — через jump host SECOND VPS. Верхний уровень — диски машины." },
            new Source { Key = "home", Label = "HOME", Remote = "home:", RemoteVia = "home-via:", Probe = "home", Root = "/",
                Tip = "HOME по SSH/SFTP: напрямую по LAN или через SECOND VPS." },
            new Source { Key = "dad", Label = "DAD", Remote = "dad:", RemoteVia = "dad-via:", Probe = "dad", Root = "/",
                Tip = "DAD по SSH/SFTP: напрямую по LAN или через SECOND VPS. На целевой машине достаточно службы sshd." },
            new Source { Key = "work", Label = "WORK", Remote = "work:", Probe = "work", Root = "/",
                Tip = "Рабочий компьютер по ssh, ключом этой машины. Панель ходит прямо по его адресу из targets.json и отвечает, когда этот адрес виден отсюда." },
            new Source { Key = "laptop", Label = "LAPTOP", Remote = "laptop:", RemoteDirect = "laptop-direct:", RemoteCf = "laptop-cf:", RemoteVia = "laptop-via:", Probe = "laptop", Root = "/",
                Tip = "Лэптоп LAPTOP по SSH. Дома напрямую, издалека — через явно настроенный SSH TUN и VPS. Постоянный туннель работает без окна Sync Tools и выключается повторным нажатием SSH TUN. На ноутбуке должен работать sshd." },
            new Source { Key = "server", Label = "MAIN VPS", Remote = "server:", RemoteCf = "server-cf:", Probe = "direct", Root = "/",
                Tip = "MAIN VPS по ssh, под учётной записью root. Панель показывает его файловую систему целиком: файлы туда и обратно возятся как между папками, без scp и без консоли. Маршрут прямой по имени, а если имя перестанет отвечать - тем же ssh поверх cloudflared." },
            // SECOND VPS: what must lie closer goes here - from home the road to it is straight, without a VPN.
            new Source { Key = "second", Label = "SECOND VPS", Remote = "second:", RemoteCf = "second-cf:", Probe = "second", Root = "/",
                Tip = "SECOND VPS по ssh. Из дома маршрут прямой, из сетей с фильтрацией его ssh рвут — тогда работает запасной поверх cloudflared. Отсюда файл уходит и на машины, и в R2." },
            new Source { Key = "backup", Label = "R2 BACKUP", Remote = "r2:audion-backup",
                Tip = "R2 bucket резервов: ночные снимки MAIN VPS в daily и PRIVATE BACKUP в Projects." },
            new Source { Key = "releases", Label = "R2 RELEASES", Remote = "r2:audion-releases", Tip = "R2 bucket релизов: то, что отдаёт dl.audion.dev." },
            new Source { Key = "share", Label = "R2 SHARE", Remote = "r2:audion-share", Tip = "Временные публичные ссылки и видео-хостинг share.audion.dev." },
            new Source { Key = "media", Label = "R2 MEDIA", Remote = "r2:audion-media", Tip = "R2 bucket с видео и картинками — то, что показывают страницы и заметки." },
            new Source { Key = "vault", Label = "R2 VAULT", Remote = "r2:audion-vault", Tip = "Общее хранилище заметок портала vault.audion.dev — то, что портал показывает без ключа v в адресе." },
            new Source { Key = "daily", Label = "СНИМКИ", Remote = "r2:audion-backup/daily", Tip = "Ночные снимки MAIN VPS по датам — источник для зеркала." },
            new Source { Key = "data", Label = "ДАННЫЕ", Root = data, Tip = "Папка данных: снимки, шесть зеркал, ключи Tunnel\\SSH." },
            new Source { Key = "store", Label = "GOLDEN COPY", Root = Path.Combine(data, "Tunnel", "SSH"), Tip = "Golden copy ключей - Tunnel\\SSH. EXPORT KEYS в неё не пишет никогда." },
            new Source { Key = "kit", Label = "EXPORT KEYS", Root = Path.Combine(data, "Tunnel", "Export"), Tip = "Export Keys - ключи, собранные с живой машины: их предпочитает IMPORT KEYS." },
            new Source { Key = "profile", Label = "ПРОФИЛЬ", Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh"), Tip = "Профиль пользователя — место, где ключи ищет ssh." },
            new Source { Key = "rclone", Label = "КЛЮЧИ R2", Root = Path.Combine(data, "config", "rclone"), Tip = "Ключи к R2 bucket в папке данных." },
        };
        return list.ToDictionary(s => s.Key, StringComparer.OrdinalIgnoreCase);
    }

    static readonly string[] Machines = { "base", "laptop", "work", "home", "dad", "server", "second", "local" };

    public static readonly Section[] Sections =
    {
        new("setup", "SETUP", "первая настройка", new[] { "profile", "rclone", "store", "kit", "data", "local" }, "profile", "rclone"),
        new("keys", "SSH KEYS", "ключи машины", new[] { "store", "kit", "profile", "rclone" }, "store", "profile"),
        new("tunnel", "TUNNEL", "настройка связи", Machines, "base", "local"),
        // The panels of REMOTE are those of TUNNEL: switching the section must not undo what is open in them.
        new("transport", "REMOTE", "терминал и RDP", Machines, "base", "local"),
        // The mirror and R2 are one section: the nightly snapshots on the left, the data folder on the right.
        new("mirror", "STORAGE", "снимки и R2", new[] { "daily", "data", "backup", "releases", "share", "media", "vault", "server", "second", "local" }, "daily", "data"),
        new("clouds", "CLOUDS", "облачные диски", new[] { "base", "laptop", "work", "home", "dad", "local" }, "local", "local"),
    };

    public static Section SectionOf(string key) => Sections.FirstOrDefault(s => s.Key == key) ?? Sections[3];

    /// <summary>What a panel of the section can show. CLOUDS begins with the attached clouds, in the order they were attached.</summary>
    public static string[] Of(Section section) =>
        section.Key == "clouds" ? _all.Values.Where(s => s.Cloud).Select(s => s.Key).Concat(section.Sources).ToArray() : section.Sources;

    // ------------------------------------------------------------ routes

    /// <summary>What the probe saw last: the name of a probe -> the straight road answered.</summary>
    public static Dictionary<string, bool> LanUp { get; } = new();

    /// <summary>Routes that just gave no answer: "source|route" -> when. They go to the end of the line for a quarter of an hour.</summary>
    public static Dictionary<string, DateTime> RouteFail { get; } = new();

    /// <summary>The route picked by hand per machine ("home", "direct", "cf", "via"); empty - the probe decides.</summary>
    public static Dictionary<string, string> Picked { get; set; } = new();

    /// <summary>What the probe measured last: the name of a probe -> milliseconds to its node; a silent node has none.</summary>
    public static Dictionary<string, double> RoadMs { get; } = new();

    static string Has(string remote) => Rclone.Configured(remote) ? remote : "";

    /// <summary>
    /// By which road a machine is reached; a word for the caption: empty - straight, otherwise
    /// through whom. What is picked by hand is stronger than the probe: the owner may know of a
    /// network more than a knock on a port shows - ssh arrives there and is cut on the first packet.
    /// </summary>
    public static string RouteName(string key)
    {
        var source = Get(key);
        if (source.Probe.Length == 0) return "";

        if (Picked.TryGetValue(key, out var picked) && picked.Length > 0)
        {
            switch (picked)
            {
                case "home": return "";
                case "direct": return source.RemoteSsh.Length > 0 || source.RemoteDirect.Length > 0 ? RouteMain : "";
                case "cf": return source.RemoteCf.Length > 0 ? RouteCf : "";
                case "via": return source.RemoteVia.Length > 0 ? RouteVia : "";
            }
        }

        // A VPS that answers does not mean the data folder has a route through it.
        string ssh = Has(source.RemoteSsh), direct = Has(source.RemoteDirect), cf = Has(source.RemoteCf), via = Has(source.RemoteVia);
        if (!LanUp.TryGetValue(source.Probe, out var up) || up) return "";

        bool cloudUp = !LanUp.TryGetValue("cloud", out var c) || c;
        bool serverUp = LanUp.TryGetValue("direct", out var d) && d;
        bool Fresh(string route) => !RouteFail.TryGetValue(key + "|" + route, out var stamp) || (DateTime.Now - stamp).TotalMinutes > 15;
        bool secondUp = !LanUp.TryGetValue("second", out var s2) || s2;

        // The VPS that answers faster goes first (the owner, 18.10.2026: «Делаем выбор VPS по задержке»): the
        // time of MAIN VPS by its name against the time of SECOND VPS, each knocked at the server itself.
        // Cloudflared has no time of its own to set against them - its probe reaches the edge of Cloudflare,
        // not MAIN VPS - so it stays after MAIN VPS by name (a session by the name stands up faster: 1.7 s
        // against 2.8) and after every road with a time.
        var roads = new List<(string Road, double? Ms)>();
        if (serverUp && (ssh.Length > 0 || direct.Length > 0) && Fresh(RouteMain)) roads.Add((RouteMain, RoadMs.TryGetValue("direct", out var main) ? main : null));
        if (cloudUp && cf.Length > 0 && Fresh(RouteCf)) roads.Add((RouteCf, null));
        if (secondUp && via.Length > 0 && Fresh(RouteVia)) roads.Add((RouteVia, RoadMs.TryGetValue("second", out var second) ? second : null));
        if (Fastest(roads) is { Length: > 0 } fastest) return fastest;

        // Every route is marked failed: take the one that usually lives longest and try again -
        // better to wait than not to go at all.
        if (via.Length > 0) return RouteVia;
        if (ssh.Length > 0 || direct.Length > 0) return RouteMain;
        if (cf.Length > 0) return RouteCf;
        return "";
    }

    /// <summary>
    /// The first of the far roads by time: those with a time by their milliseconds, the rest after them
    /// in their own order. Times within a tenth of each other (or 5 ms) are equal and the order decides -
    /// MAIN VPS first: a road does not swing between two probes over a few milliseconds.
    /// </summary>
    public static string Fastest(IReadOnlyList<(string Road, double? Ms)> roads)
    {
        string best = "";
        double? bestMs = null;
        foreach (var (road, ms) in roads)
        {
            if (best.Length == 0) { best = road; bestMs = ms; continue; }
            if (ms is null) continue;
            if (bestMs is null || ms < bestMs - Math.Max(5, bestMs.Value / 10)) { best = road; bestMs = ms; }
        }
        return best;
    }

    /// <summary>
    /// The full address for rclone: a plain path for a local source, "remote:path" for a remote
    /// one. The separator of rclone is the forward slash, and for remotes it is the only right one.
    /// </summary>
    public static string RemotePath(string key, string path)
    {
        var source = Get(key);
        if (!source.IsRemote) return path;

        var remote = RouteName(key) switch
        {
            // The machine's own forward is older than the jump: it does not depend on whether
            // MAIN VPS sees its network - the machine holds the channel itself.
            RouteMain => Rclone.Configured(source.RemoteSsh) ? source.RemoteSsh : source.RemoteDirect,
            RouteCf => source.RemoteCf,
            RouteVia => source.RemoteVia,
            _ => source.Remote,
        };

        var tail = path.Replace('\\', '/');
        // "/" of ssh is not the empty path: "base:" opens the home folder of the user, "base:/" the list of the machine's disks.
        if (tail == "/") return remote + "/";
        if (remote.EndsWith(':'))
        {
            // Paths of machines over ssh are absolute and the leading slash is a must: "base:S:"
            // is a folder S: inside the user's home, not the root of the disk.
            if (!tail.StartsWith('/')) tail = "/" + tail;
            return tail == "/" ? remote + "/" : remote + tail;
        }
        tail = tail.TrimStart('/');
        return tail.Length == 0 ? remote : remote + "/" + tail;
    }

    // ------------------------------------------------------------ one name by any road

    /// <summary>What decides the road of an sftp remote: these alone are handed over when the road changes.</summary>
    static readonly string[] RoadKeys = { "ssh", "host", "port", "user", "key_file", "known_hosts_file" };

    /// <summary>
    /// The address of a place for an operation that remembers what it worked with - BISYNC keeps
    /// the listings of a pair under the names of its two remotes. A machine is named here by its
    /// plain remote ("base:") whatever road leads to it now, and the road is handed to rclone in
    /// variables of the process (RCLONE_CONFIG_BASE_SSH and its kin), which stand above the file
    /// of the config. rclone then calls the remote "base{xxxxx}:", and bisync cuts that tail off:
    /// the listings stay the same by any road (tried on BASE, 08.10.2026). Named by the remote of
    /// the road ("base-via:"), the same pair was a new one for rclone and for the window alike,
    /// and its first run from afar went with --resync: what had changed in the target since the
    /// last run was overwritten, and what had been deleted in the source came back.
    ///
    /// Every key that decides the road is said the way the remote of the road has it - an empty
    /// one too. What that remote leaves empty or does not name must not be inherited from the
    /// plain one: with "ssh =" on the chosen road rclone started the ssh program of the straight
    /// road for a pair meant to go by the host of the far one (the audit after the review of
    /// 08.10.2026, seen with the real rclone and a stub in place of ssh). An empty variable does
    /// reach the child and takes the value of the file away - tried the same way.
    ///
    /// Where the plain remote is not in the config, the address is the one of the road, as for
    /// every other operation.
    /// </summary>
    public static (string Address, Dictionary<string, string> Env) SteadyPath(string key, string path)
    {
        var env = new Dictionary<string, string>();
        var address = RemotePath(key, path);
        var source = Get(key);
        if (!source.IsRemote || source.Probe.Length == 0 || !source.Remote.EndsWith(':')) return (address, env);
        int colon = address.IndexOf(':');
        string road = colon > 0 ? address[..colon] : "", plain = source.Remote.TrimEnd(':');
        if (road.Length == 0 || string.Equals(road, plain, StringComparison.OrdinalIgnoreCase)) return (address, env);

        var config = Rclone.Transports();
        if (!config.TryGetValue(plain, out var straight) || !config.TryGetValue(road, out var far)) return (address, env);
        var prefix = "RCLONE_CONFIG_" + new string(plain.ToUpperInvariant().Select(c => char.IsAsciiLetterOrDigit(c) ? c : '_').ToArray()) + "_";
        foreach (var name in RoadKeys)
        {
            // What the road says against what the plain remote would say in its place: any difference
            // is handed over, and "nothing" is handed over as an empty variable.
            string wanted = far.GetValueOrDefault(name, ""), inherited = straight.GetValueOrDefault(name, "");
            if (wanted != inherited) env[prefix + name.ToUpperInvariant()] = wanted;
        }
        return (source.Remote + address[(colon + 1)..], env);
    }

    // ------------------------------------------------------------ this machine under another name

    /// <summary>
    /// True when a source is this very computer reached over ssh by the straight road: its config
    /// names an address this machine holds. A disk of this machine and such a source are one
    /// place under two names, and rclone does not know it: a mirror of a folder into its parent
    /// "on the other machine" deleted the neighbours and the folder itself (tried 08.10.2026).
    /// The panels of TUNNEL and REMOTE open just so on BASE - BASE on the left, LOCAL on the right.
    ///
    /// The address tells nothing about a far road: the same number may be somebody else's in
    /// another network, and the address this machine has there is not the one in the config. Yet
    /// a far road leads home too - a button of the row ROUTE sets it for every machine at once,
    /// the one the program runs on among them, and a laptop away from home reaches itself through
    /// its own REVERSE SSH TUN (the audit of 08.10.2026: the same mirror, let through). Whether a
    /// far road ends here is asked of the machine itself: SameMachine.
    /// </summary>
    public static bool IsThisMachine(string key)
    {
        var source = Get(key);
        if (source.Probe.Length == 0 || RouteName(key).Length > 0) return false;
        if (!Rclone.Transports().TryGetValue(source.Remote.TrimEnd(':'), out var config)) return false;
        if (!config.TryGetValue("host", out var host) || host.Length == 0) return false;
        if (string.Equals(host, "localhost", StringComparison.OrdinalIgnoreCase) || string.Equals(host, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) return true;
        return IPAddress.TryParse(host, out var address) && (IPAddress.IsLoopback(address) || OwnAddresses().Contains(address));
    }

    /// <summary>The addresses the network cards of this machine hold now; asked every time - a laptop changes networks.</summary>
    static HashSet<IPAddress> OwnAddresses()
    {
        var own = new HashSet<IPAddress>();
        try
        {
            foreach (var card in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (card.OperationalStatus != OperationalStatus.Up) continue;
                foreach (var held in card.GetIPProperties().UnicastAddresses) own.Add(held.Address);
            }
        }
        catch { }
        return own;
    }

    /// <summary>What a machine said when asked whether it is this computer; Unasked - there was no way to ask.</summary>
    public enum Same { Yes, No, Silent, Unasked }

    /// <summary>
    /// The mark of this computer: a file of the program's own, ._runtime\this-machine.id, with
    /// the name of the computer and a random number. Read through a machine over ssh, the same
    /// file with the same words means that machine is this computer - by any road and with any
    /// address. A folder of the program copied from another computer carries that one's mark:
    /// the name in it is not ours, and a new mark is made. The host keys of sshd would be the
    /// natural mark, but an ordinary account cannot read them, their public halves included.
    /// </summary>
    static (string File, string Text)? OwnMark()
    {
        try
        {
            var file = Path.Combine(Paths.State, "this-machine.id");
            var name = Environment.MachineName;
            if (File.Exists(file))
            {
                var text = File.ReadAllText(file).Trim();
                if (text.Length == name.Length + 33 && text.StartsWith(name + "|", StringComparison.OrdinalIgnoreCase)) return (file, text);
            }
            var fresh = $"{name}|{Guid.NewGuid():N}";
            File.WriteAllText(file, fresh);
            return (file, fresh);
        }
        catch { return null; }
    }

    /// <summary>What the machines answered last: the name of a remote -> is it this computer, and when it was asked.</summary>
    static readonly Dictionary<string, (bool Same, DateTime At)> Asked = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Is the machine behind a source this very computer? The straight road is known by its
    /// address at once; any other is asked of the machine: the mark of this computer is read
    /// through it. No such file there - another machine; no answer - Silent, and the caller
    /// decides what a silence is worth. An answer is remembered for five minutes under the name
    /// of the remote it came by: every F5 between the same two machines need not ask again.
    /// </summary>
    public static async Task<Same> SameMachine(string key, CancellationToken cancel)
    {
        if (Get(key).Probe.Length == 0) return Same.No;
        if (IsThisMachine(key)) return Same.Yes;
        if (OwnMark() is not { } mark) return Same.Unasked;
        // The file as a machine over ssh names it: C:\x -> /C:/x. A program run from a share has no such name.
        if (mark.File.Length < 3 || !char.IsLetter(mark.File[0]) || mark.File[1] != ':') return Same.Unasked;
        var address = RemotePath(key, "/" + mark.File[..2] + mark.File[2..].Replace('\\', '/'));
        var remote = address[..address.IndexOf(':')];
        lock (Asked)
            if (Asked.TryGetValue(remote, out var known) && (DateTime.Now - known.At).TotalMinutes < 5) return known.Same ? Same.Yes : Same.No;

        var answer = await Rclone.Run(new[] { "cat", address }, 30, cancel);
        // rclone: 0 - the file was read, 3 and 4 - no such folder or file there (tried over sftp, 08.10.2026).
        var said = answer.Code == 0 ? (answer.Output.Trim() == mark.Text ? Same.Yes : Same.No)
            : answer.Code is 3 or 4 ? Same.No : Same.Silent;
        if (said is Same.Yes or Same.No) lock (Asked) Asked[remote] = (said == Same.Yes, DateTime.Now);
        return said;
    }

    /// <summary>
    /// A path of a machine over ssh as a path of a disk: "/C:/Work" as C:\Work. Null for a list
    /// of disks, which is not a folder, and for what is not a path of Windows at all.
    /// </summary>
    public static string? AsLocal(string path)
    {
        var flat = path.Replace('\\', '/');
        if (flat.Length < 3 || flat[0] != '/' || !char.IsLetter(flat[1]) || flat[2] != ':') return null;
        var rest = flat[3..].Trim('/');
        return rest.Length == 0 ? $"{flat[1]}:\\" : $"{flat[1]}:\\{rest.Replace('/', '\\')}";
    }

    /// <summary>
    /// The path of a source as a path of this machine: the path itself on a disk of this
    /// machine, "/C:/Work" as C:\Work for this machine over ssh by the straight road. Null for
    /// any other place - and for a list of disks, which is not a folder.
    /// </summary>
    public static string? LocalPath(string key, string path)
    {
        if (!Get(key).IsRemote) return path.Length > 0 ? path : null;
        return IsThisMachine(key) ? AsLocal(path) : null;
    }

    /// <summary>
    /// The path one level up, or null at the top of the source. One rule for local and remote
    /// paths, as the PowerShell window had it: the root of a disk must end in a slash - "E:"
    /// means "the current folder on that disk" to Windows, and a step up from a folder led into
    /// the folder of the program itself.
    /// </summary>
    public static string? Parent(string key, string path)
    {
        var root = Get(key).Root;
        if (path.Length == 0 || path == root) return null;
        var trimmed = path.TrimEnd('/', '\\');
        int cut = Math.Max(trimmed.LastIndexOf('/'), trimmed.LastIndexOf('\\'));
        var up = cut > 0 ? trimmed[..cut] : root;
        if (up.Length == 2 && char.IsLetter(up[0]) && up[1] == ':') up += "\\";
        else if (up.EndsWith(':')) up += "/";
        return up;
    }

    /// <summary>The path of a child by its name.</summary>
    public static string Child(string path, string name)
    {
        if (path.Length == 0 && name.Length == 2 && char.IsLetter(name[0]) && name[1] == ':') return name + "\\";
        return path.Length > 0 ? path.TrimEnd('/', '\\') + "/" + name : name;
    }

    /// <summary>
    /// The path as crumbs: the first is the source itself - the way back to its top. The leading
    /// slash of ssh is a level of its own: the list of disks starts there.
    /// </summary>
    public static List<(string Text, string Path)> Crumbs(string key, string path)
    {
        var source = Get(key);
        var crumbs = new List<(string, string)> { (source.Label, source.Root) };
        if (path.Length == 0 || path == source.Root) return crumbs;
        var rest = path;
        // A source that is a folder shows what is below it, not the road to it.
        if (!source.IsRemote && source.Root.Length > 0 && rest.StartsWith(source.Root, StringComparison.OrdinalIgnoreCase))
        {
            var accumulated = source.Root;
            foreach (var part in rest[source.Root.Length..].Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries))
            {
                accumulated = accumulated.TrimEnd('/', '\\') + "/" + part;
                crumbs.Add((part, accumulated));
            }
            return crumbs;
        }
        var walked = rest.StartsWith('/') || rest.StartsWith('\\') ? "/" : "";
        foreach (var part in rest.Split(new[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries))
        {
            walked = walked.Length > 0 && !walked.EndsWith('/') && !walked.EndsWith('\\') ? walked + "/" + part : walked + part;
            var step = walked.Length == 2 && char.IsLetter(walked[0]) && walked[1] == ':' ? walked + "/" : walked;
            crumbs.Add((part, step));
        }
        return crumbs;
    }
}
