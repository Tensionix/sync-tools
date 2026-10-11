using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using AudionSyncTools.Core;

namespace AudionSyncTools;

/// <summary>
/// F3 ССЫЛКА: the public links of what is marked in a panel that stands in an R2 bucket with a
/// site of its own - into the clipboard, a link a line, and into the journal. Nothing is
/// uploaded or changed: a link is built from the place of the object. Where the site serves
/// only the paths named in .audion/public.json of the bucket, a link to a closed path is said
/// to be closed - it is built all the same, it will work once the path is opened.
/// </summary>
public partial class MainWindow
{
    /// <summary>The site of a bucket: its address, whether it serves by a list of open paths, whether it is the portal with its own routes.</summary>
    sealed record ShareSite(string Site, bool Manifest, bool Portal, string Note);

    static readonly Dictionary<string, ShareSite> ShareSites = new(StringComparer.OrdinalIgnoreCase)
    {
        ["audion-share"] = new("https://share.audion.dev", Manifest: true, Portal: false, Note: ""),
        ["audion-media"] = new("https://media.audion.dev", Manifest: true, Portal: false, Note: ""),
        ["audion-releases"] = new("https://dl.audion.dev", Manifest: false, Portal: false, Note: ""),
        ["audion-vault"] = new("https://vault.audion.dev", Manifest: false, Portal: true, Note: "за Access: откроется только вам"),
    };

    static string ShareUrl(ShareSite site, string path, bool folder)
    {
        var clean = path.Trim('/');
        var encoded = string.Join("/", clean.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.EscapeDataString));
        if (!site.Portal) return $"{site.Site}/{encoded}{(folder ? "/" : "")}";
        if (folder) return $"{site.Site}/?p={Uri.EscapeDataString(clean + "/")}";
        return Regex.IsMatch(clean, @"\.(md|markdown)$", RegexOptions.IgnoreCase) ? $"{site.Site}/view/{encoded}" : $"{site.Site}/raw/{encoded}";
    }

    async void ShareLinks()
    {
        using var pending = Pending();
        var panel = _active;
        // The list of open paths is asked of the bucket and takes seconds; the links are of the place the panel stands in now.
        var place = Place.Of(panel);
        var remote = Sources.Get(panel.SourceKey).Remote;
        var bucket = Regex.Match(remote, "^r2:([^/]+)") is { Success: true } hit ? hit.Groups[1].Value : "";
        if (!ShareSites.TryGetValue(bucket, out var site))
        {
            SetStatus(Lang.T("у этого R2 bucket нет адреса для публичных ссылок"));
            return;
        }
        var picked = panel.Selection();
        if (picked.Count == 0)
        {
            SetStatus(Lang.T("нечего связывать: отметьте файлы"));
            return;
        }

        // What the site serves: null - the list could not be read, nothing is called closed.
        List<string>? open = null;
        if (site.Manifest)
        {
            try
            {
                var answer = await Rclone.Run(new[] { "cat", $"r2:{bucket}/.audion/public.json" }, 30, CancellationToken.None);
                if (answer.Code == 0)
                {
                    var text = answer.Output.Trim();
                    open = new List<string>();
                    if (text.Length > 0)
                    {
                        using var doc = JsonDocument.Parse(text[text.IndexOf('[')..]);
                        open.AddRange(doc.RootElement.EnumerateArray().Select(item => item.GetString() ?? "").Where(item => item.Length > 0));
                    }
                }
            }
            catch { open = null; }
        }

        var prefix = $"r2:{bucket}/";
        var lines = new List<(string Url, bool Closed)>();
        foreach (var item in picked)
        {
            // The place of the object inside its bucket, as rclone names it.
            var full = place.Target(item.Name);
            var path = (full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? full[prefix.Length..] : full).Trim('/');
            if (item.IsDir) path += "/";
            bool closed = false;
            if (open is not null)
                closed = !open.Any(rule => rule.EndsWith('/') ? path.StartsWith(rule, StringComparison.OrdinalIgnoreCase) : rule == path.TrimEnd('/'));
            lines.Add((ShareUrl(site, path, item.IsDir), closed));
        }

        Journal.Add("");
        Journal.Add(Lang.F("===== ССЫЛКИ: {0}", picked.Count));
        foreach (var (url, closed) in lines) Journal.Add("  " + url + (closed ? "  " + Lang.T("(путь закрыт)") : ""));
        try
        {
            if (Clipboard is not { } clipboard) throw new InvalidOperationException();
            await Avalonia.Input.Platform.ClipboardExtensions.SetTextAsync(clipboard, string.Join(Environment.NewLine, lines.Select(line => line.Url)));
            SetStatus(Lang.F("ссылок в буфере: {0}", lines.Count));
        }
        catch { SetStatus(Lang.T("ссылки в журнале: буфер занят другой программой")); }
        if (site.Note.Length > 0) Journal.Add(Lang.F("[ссылки] {0}", Lang.T(site.Note)));
        if (site.Manifest)
        {
            int shut = lines.Count(line => line.Closed);
            if (open is null) Journal.Add(Lang.T("[ссылки] манифест публичных ссылок не прочитан - работают они или нет, не знаю"));
            else if (shut > 0) Journal.Add(Lang.F("[ссылки] закрытых путей: {0} - откройте их на {1}/manage", shut, site.Site));
        }
    }
}
