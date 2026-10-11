using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using AudionSyncTools.Core;
using AudionSyncTools.Views;

namespace AudionSyncTools;

/// <summary>
/// The keys of the machines in SETUP: the list, SSH-COPY-ID and revoking. The window asks; the
/// walk over the machines is Engine\Scripts\Manage-ClientKeys.ps1, a job of the queue - the same
/// script does the same from a console. How a machine is gone to depends on what the probe saw:
/// one that answers in the local network is called by its name with -lan.
/// </summary>
public partial class MainWindow
{
    static readonly string[] Household = { "base", "laptop", "home", "dad", "work" };

    /// <summary>What every call of the script is told besides its task: the machines near, and the name of the key of this machine.</summary>
    string[] KeyArgs(params string[] first)
    {
        var args = new List<string>(first);
        var near = Household.Where(name => Sources.LanUp.TryGetValue(name, out var up) && up).ToList();
        if (near.Count > 0) { args.Add("-Lan"); args.Add(string.Join(",", near)); }
        if (_settings.ClientName.Length > 0) { args.Add("-ClientName"); args.Add(_settings.ClientName); }
        return args.ToArray();
    }

    static List<string> Strings(JsonElement from, string name) =>
        from.TryGetProperty(name, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0).ToList() : new List<string>();

    /// <summary>LIST: every key in one list - what it is, where it lies, whether its private half is kept, and on which machines it is written.</summary>
    void KeysInventory()
    {
        if (!NeedData()) return;
        Engine("Manage-ClientKeys.ps1", "КЛЮЧИ", KeyArgs("-Inventory"));
    }

    /// <summary>SSH-COPY-ID: the public keys of CLIENTS are appended to authorized_keys of every machine, through the access that already works.</summary>
    async void KeysSpread()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("Manage-ClientKeys.ps1", KeyArgs("-Describe")) is not { } state) return;
        var clients = Strings(state, "clients");
        if (clients.Count == 0) { Journal.Add(Lang.T(SpreadEmpty)); return; }
        if (!Flag(state, "targets")) { Journal.Add(Lang.T("[окно] проба: нет файла адресов - SETUP → АДРЕСА")); return; }

        var lines = new List<string> { Lang.T(SpreadNote), "" };
        if (state.TryGetProperty("plan", out var plan) && plan.ValueKind == JsonValueKind.Array)
            lines.AddRange(plan.EnumerateArray().Select(item => $"{Text(item, "caption"),-10} {Text(item, "host")}"));
        lines.AddRange(Strings(state, "mine").Select(machine => Lang.F(SpreadMine, machine)));
        lines.Add("");
        lines.Add(Lang.F(SpreadCount, string.Join(", ", clients)));
        if (await Dialog.Ask(this, SpreadHead, lines, "SSH-COPY-ID", Tone.Warn) is null) return;
        RunSetup("SSH-COPY-ID", "Manage-ClientKeys.ps1", KeyArgs("-Spread"));
    }

    /// <summary>REVOKE: a public key leaves authorized_keys of every machine that answers. The key of this machine goes only after a second question.</summary>
    async void KeysRevoke()
    {
        using var pending = Pending();
        if (!NeedData()) return;
        if (await Describe("Manage-ClientKeys.ps1", KeyArgs("-Describe")) is not { } state) return;
        var keys = state.TryGetProperty("keys", out var list) && list.ValueKind == JsonValueKind.Array ? list.EnumerateArray().ToList() : new List<JsonElement>();
        if (keys.Count == 0) { Journal.Add(Lang.T(RevokeNone)); return; }

        var choices = keys.Select(key =>
        {
            string name = Text(key, "name");
            bool mine = Flag(key, "mine"), shared = Flag(key, "shared");
            return new Choice(name,
                name + (mine ? Lang.T(RevokeMineMark) : shared ? Lang.T(RevokeSharedMark) : ""),
                mine ? RevokeMineNote : shared ? RevokeSharedNote : Lang.F(RevokeKeyNote, name));
        }).ToList();
        // The key of this machine is never the one picked beforehand.
        var first = keys.FirstOrDefault(key => !Flag(key, "mine"));
        var answer = await FormDialog.Ask(this, RevokeHead, RevokeOk, new[] { Lang.T(RevokeNote) },
            choices: choices, picked: first.ValueKind == JsonValueKind.Object ? Text(first, "name") : Text(keys[0], "name"));
        if (answer is null) return;
        var pick = keys.FirstOrDefault(key => Text(key, "name") == answer.Choice);
        if (pick.ValueKind != JsonValueKind.Object) return;

        if (Flag(pick, "mine") && await Dialog.Ask(this, RevokeSureHead, new[] { Lang.T(RevokeSureNote) }, RevokeSureOk, Tone.Warn) is null) return;
        RunSetup("ОТЗЫВ КЛЮЧА", "Manage-ClientKeys.ps1", KeyArgs("-Revoke", answer.Choice));
    }
}
