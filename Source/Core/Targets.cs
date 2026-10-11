using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace AudionSyncTools.Core;

/// <summary>
/// The targets of remote access - Tunnel\RemoteDesktop\config\targets.json of the data folder:
/// the machines, the two servers and the routers with their addresses. The names and the
/// addresses of the owner's household live there, in the data, never in the code.
/// </summary>
public sealed class Target
{
    public string Key { get; init; } = "";
    public string Desc { get; init; } = "";
    public string Lan { get; init; } = "";
    public string Host { get; init; } = "";
    public string Hint { get; init; } = "";
    public string User { get; init; } = "";
    /// <summary>A host of ~\.ssh\config the target is reached by: MAIN VPS has no home address at all.</summary>
    public string SshHost { get; init; } = "";
    public int SshPort { get; init; } = 22;
    /// <summary>False - the target lets in by password only: no key is offered to it (a router).</summary>
    public bool KeyAuth { get; init; } = true;

    public bool IsRouter => Key.StartsWith("router-", StringComparison.OrdinalIgnoreCase);
    public bool HasAddress => Lan.Length > 0 || Host.Length > 0;

    /// <summary>The caption for buttons and the journal: only MAIN VPS and SECOND VPS for the servers, the key itself for the rest.</summary>
    public string Caption => Captions(Key);

    public static string Captions(string key) => key switch
    {
        "server" => "MAIN VPS",
        "second" => "SECOND VPS",
        _ => key.ToUpperInvariant(),
    };
}

public static class Targets
{
    public static string File_ => DataRoot.File_(Path.Combine("Tunnel", "RemoteDesktop", "config", "targets.json"));

    /// <summary>The targets in the order of the file; empty when the file is not there yet.</summary>
    public static List<Target> Read()
    {
        var list = new List<Target>();
        try
        {
            if (!File.Exists(File_)) return list;
            using var doc = JsonDocument.Parse(File.ReadAllText(File_), new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            foreach (var property in doc.RootElement.EnumerateObject())
            {
                if (property.Name.StartsWith('_') || property.Value.ValueKind != JsonValueKind.Object) continue;
                var v = property.Value;
                string Text(string name) => v.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? "" : "";
                list.Add(new Target
                {
                    Key = property.Name,
                    Desc = Text("desc"),
                    Lan = Text("lan"),
                    Host = Text("host"),
                    Hint = Text("hint"),
                    User = Text("user"),
                    SshHost = Text("sshHost"),
                    SshPort = v.TryGetProperty("sshPort", out var port) && port.TryGetInt32(out var n) ? n : 22,
                    KeyAuth = !v.TryGetProperty("keyAuth", out var key) || key.ValueKind != JsonValueKind.False,
                });
            }
        }
        catch { }
        return list;
    }
}
