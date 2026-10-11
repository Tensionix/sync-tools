using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AudionSyncTools.Core;

/// <summary>config\mask-sets.json of the data folder.</summary>
public sealed class MaskSetFile
{
    public string About { get; set; } = "The sets of masks saved in the window of the mark: a name and the masks as typed. Each is a button there.";
    public List<MaskSet> Sets { get; set; } = new();
}

/// <summary>A pair of folders BISYNC keeps in step, as config\bisync\pairs.json of the data folder names it.</summary>
public sealed class BisyncPair
{
    /// <summary>The name of the folder of its state: config\bisync\state\ID.</summary>
    public string Id { get; set; } = "";
    public string Source { get; set; } = "";
    public string Target { get; set; } = "";
    /// <summary>When the first run of the pair ended well.</summary>
    public string Since { get; set; } = "";
}

/// <summary>config\bisync\pairs.json of the data folder.</summary>
public sealed class BisyncPairFile
{
    public string About { get; set; } = "The pairs of folders BISYNC keeps in step. The state of a pair - the listings rclone compares with - lies in state\\<id>. A pair without its listings is asked about again.";
    public List<BisyncPair> Pairs { get; set; } = new();
}

/// <summary>
/// What a person made in the window and what must outlive a cleanup of the program: the sets
/// of masks saved under a name and the pairs of BISYNC. Both lie in the data folder of the
/// machine - pointing at it is the whole setup - and not in config\gui-settings.json, which
/// holds the look of the window and goes with a cleanup.
///
///   config\mask-sets.json        the sets of masks
///   config\bisync\pairs.json     the pairs, for a person to read
///   config\bisync\state\ID\      what rclone keeps for one pair: its --workdir
///
/// A pair counts as known only while its listings are there. Before, the list of the pairs lay
/// in the settings and the listings in ._runtime of the program: a cleanup took the listings
/// and left the list, rclone refused with "must run --resync", and the window had no way to
/// ask the question again.
/// </summary>
public static class DataStore
{
    static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    static string ConfigDir => Path.Combine(DataRoot.Path_, "config");

    public static string MaskSetsFile => Path.Combine(ConfigDir, "mask-sets.json");

    /// <summary>Without a data folder a pair still has to keep its state somewhere: the scratch of the program, till a cleanup.</summary>
    static string BisyncDir => DataRoot.Chosen ? Path.Combine(ConfigDir, "bisync") : Path.Combine(Paths.State, "bisync");

    public static string BisyncPairsFile => Path.Combine(BisyncDir, "pairs.json");

    // ------------------------------------------------------------ the sets of masks

    /// <summary>The sets of the data folder; none where the folder is not chosen or holds no file yet.</summary>
    public static List<MaskSet> LoadMaskSets()
    {
        if (!DataRoot.Chosen) return new();
        var kept = SafeFile.Read<MaskSetFile>(MaskSetsFile, Json);
        return kept?.Sets?.Where(set => set is not null && set.Name.Length > 0).ToList() ?? new();
    }

    /// <summary>False when there is nowhere to keep them - no data folder - or the file could not be written.</summary>
    public static bool SaveMaskSets(IReadOnlyList<MaskSet> sets)
    {
        if (!DataRoot.Chosen) return false;
        return SafeFile.Write(MaskSetsFile, JsonSerializer.Serialize(new MaskSetFile { Sets = sets.ToList() }, Json));
    }

    // ------------------------------------------------------------ the pairs of BISYNC

    /// <summary>One folder of state a pair. The two addresses are taken letter for letter: on a far side a path differs by the case of a letter.</summary>
    public static string PairId(string source, string target) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source + "|" + target)))[..16].ToLowerInvariant();

    /// <summary>The --workdir of rclone for the pair; made if it is not there.</summary>
    public static string PairState(string source, string target)
    {
        var dir = Path.Combine(BisyncDir, "state", PairId(source, target));
        Directory.CreateDirectory(dir);
        return dir;
    }

    /// <summary>
    /// The pair had a run that ended well and its state is still there. rclone leaves two
    /// listings a pair - *.path1.lst and *.path2.lst - and renames them when a run breaks, so
    /// a pair that needs --resync again answers "not known" here by itself.
    /// </summary>
    public static bool PairKnown(string source, string target)
    {
        try
        {
            var dir = Path.Combine(BisyncDir, "state", PairId(source, target));
            return Directory.Exists(dir)
                && Directory.EnumerateFiles(dir, "*.path1.lst").Any()
                && Directory.EnumerateFiles(dir, "*.path2.lst").Any();
        }
        catch { return false; }
    }

    /// <summary>The pair into pairs.json, after its first run ended well: which folder of state is whose.</summary>
    public static void RememberPair(string source, string target)
    {
        var id = PairId(source, target);
        var file = SafeFile.Read<BisyncPairFile>(BisyncPairsFile, Json) ?? new BisyncPairFile();
        file.Pairs ??= new();
        file.Pairs.RemoveAll(pair => pair is null || pair.Id == id);
        file.Pairs.Add(new BisyncPair { Id = id, Source = source, Target = target, Since = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss") });
        SafeFile.Write(BisyncPairsFile, JsonSerializer.Serialize(file, Json));
    }

    // ------------------------------------------------------------ what the settings held before

    /// <summary>
    /// Until 06.10.2026 both lists lay in config\gui-settings.json. The sets of masks are carried
    /// into the data folder once it is chosen. The pairs are not: their listings lay in ._runtime
    /// of the program and do not fit the new place, so each pair is asked about once more - and
    /// that is said, not done in silence. True when the settings changed and want saving.
    /// </summary>
    public static bool Adopt(Settings settings)
    {
        bool changed = false;
        if (settings.BisyncPairs is { } pairs)
        {
            if (pairs.Count > 0)
                Journal.Add(Lang.F("[окно] пары BISYNC из прежних настроек не перенесены ({0}): первый запуск каждой пары спросит заново", pairs.Count));
            settings.BisyncPairs = null;
            changed = true;
        }
        if (settings.MaskSets is { } sets)
        {
            if (sets.Count == 0)
            {
                settings.MaskSets = null;
                changed = true;
            }
            else if (DataRoot.Chosen)
            {
                // What the data folder already holds wins: a set of the same name is not overwritten.
                var kept = LoadMaskSets();
                var fresh = sets.Where(set => !kept.Any(have => string.Equals(have.Name, set.Name, StringComparison.OrdinalIgnoreCase))).ToList();
                if (fresh.Count == 0 || SaveMaskSets(kept.Concat(fresh).ToList()))
                {
                    if (fresh.Count > 0) Journal.Add(Lang.F("[окно] наборы масок перенесены в папку данных: {0}", fresh.Count));
                    settings.MaskSets = null;
                    changed = true;
                }
            }
            // No data folder yet: the sets wait in the settings till one is chosen.
        }
        return changed;
    }
}
