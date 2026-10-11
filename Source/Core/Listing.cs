using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace AudionSyncTools.Core;

public enum SortKey { Name, Ext, Size, Date }

/// <summary>The rows of one folder of a source, read off the window's thread.</summary>
public static class Listing
{
    /// <summary>Rows, or null with the reason when the source gave no answer.</summary>
    public sealed record Result(List<FileRow>? Rows, string Trouble, bool TimedOut);

    public static async Task<Result> Read(string key, string path, RowPalette palette, CancellationToken cancel)
    {
        var source = Sources.Get(key);
        if (!source.IsRemote) return await Task.Run(() => ReadLocal(path, palette), cancel);

        var (listed, answer) = await Rclone.List(Sources.RemotePath(key, path), cancel);
        if (listed is null)
            return new Result(null, Journal.ShortTrouble(answer.Errors, Lang.T(source.Label)), answer.TimedOut);
        var rows = listed.Select(item => new FileRow
        {
            Name = item.Name, IsDir = item.IsDir, Size = item.Size, Modified = item.Modified,
            Colour = palette.For(item.Name, item.IsDir, item.Modified),
        }).ToList();
        return new Result(rows, "", false);
    }

    static Result ReadLocal(string path, RowPalette palette)
    {
        var rows = new List<FileRow>();
        try
        {
            if (path.Length == 0)
            {
                // The top of LOCAL: the disks of the machine. The time comes from the root of each -
                // without it a row would miss the colouring by freshness.
                foreach (var drive in DriveInfo.GetDrives())
                {
                    var name = drive.Name.TrimEnd('\\');
                    DateTime? when = null;
                    try { if (drive.IsReady) when = drive.RootDirectory.LastWriteTime; } catch { }
                    rows.Add(new FileRow { Name = name, IsDir = true, Modified = when, Colour = palette.For(name, true, when) });
                }
                return new Result(rows, "", false);
            }
            var dir = new DirectoryInfo(path);
            if (!dir.Exists) return new Result(null, Lang.F("{0}: папки нет", path), false);
            foreach (var entry in dir.EnumerateFileSystemInfos())
            {
                bool isDir = (entry.Attributes & FileAttributes.Directory) != 0;
                DateTime? when = null;
                long size = -1;
                try { when = entry.LastWriteTime; if (!isDir) size = ((FileInfo)entry).Length; } catch { }
                rows.Add(new FileRow { Name = entry.Name, IsDir = isDir, Size = size, Modified = when, Colour = palette.For(entry.Name, isDir, when) });
            }
            return new Result(rows, "", false);
        }
        catch (Exception ex)
        {
            return new Result(null, $"{path}: {ex.Message}", false);
        }
    }

    /// <summary>Folders first, then by the key; names break every tie, so the order never jumps.</summary>
    public static List<FileRow> Sort(IEnumerable<FileRow> rows, SortKey key, bool desc)
    {
        IEnumerable<FileRow> Order(IEnumerable<FileRow> part)
        {
            var byName = StringComparer.OrdinalIgnoreCase;
            IOrderedEnumerable<FileRow> sorted = key switch
            {
                SortKey.Ext => desc ? part.OrderByDescending(r => r.Ext, byName) : part.OrderBy(r => r.Ext, byName),
                SortKey.Size => desc ? part.OrderByDescending(r => r.Size) : part.OrderBy(r => r.Size),
                SortKey.Date => desc ? part.OrderByDescending(r => r.Modified ?? DateTime.MinValue) : part.OrderBy(r => r.Modified ?? DateTime.MinValue),
                _ => desc ? part.OrderByDescending(r => r.Name, byName) : part.OrderBy(r => r.Name, byName),
            };
            return key == SortKey.Name ? sorted : sorted.ThenBy(r => r.Name, byName);
        }
        var list = rows.ToList();
        return Order(list.Where(r => r.IsDir)).Concat(Order(list.Where(r => !r.IsDir))).ToList();
    }

    /// <summary>Free and total bytes of where a panel looks; null - the source does not tell.</summary>
    public static async Task<(long Free, long Total)?> Space(string key, string path, CancellationToken cancel)
    {
        var source = Sources.Get(key);
        if (!source.IsRemote)
        {
            if (path.Length == 0) return null;
            return await Task.Run<(long, long)?>(() =>
            {
                try
                {
                    var drive = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(path)) ?? path);
                    return drive.IsReady ? (drive.AvailableFreeSpace, drive.TotalSize) : null;
                }
                catch { return null; }
            }, cancel);
        }
        return await Rclone.About(Sources.RemotePath(key, path), cancel);
    }

    /// <summary>The bytes of a whole folder: the disk itself for this machine, "rclone size" for a far one. Null - no answer.</summary>
    public static async Task<long?> FolderSize(string key, string path, CancellationToken cancel)
    {
        if (!Sources.Get(key).IsRemote)
            return await Task.Run<long?>(() =>
            {
                try
                {
                    long sum = 0;
                    var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint };
                    foreach (var file in new DirectoryInfo(path).EnumerateFiles("*", options))
                    {
                        cancel.ThrowIfCancellationRequested();
                        sum += file.Length;
                    }
                    return sum;
                }
                catch { return null; }
            }, cancel);
        var answer = await Rclone.Run(new[] { "size", "--json", Sources.RemotePath(key, path) }, 600, cancel);
        int brace = answer.Output.IndexOf('{');
        if (answer.Code != 0 || brace < 0) return null;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(answer.Output[brace..]);
            return doc.RootElement.GetProperty("bytes").GetInt64();
        }
        catch { return null; }
    }
}
