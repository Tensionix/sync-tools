using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AudionSyncTools.Core;

/// <summary>
/// Where two trees really are, through junctions and symbolic links, and
/// whether one lies inside the other. A mirror into the parent of its own
/// source deletes the source; a copy into its own subfolder runs into itself
/// and does not stop; packing into a folder that is then deleted loses the
/// archive. F5, F6, COPY, MIRROR and BISYNC ask here before their question
/// (MainWindow.Ops: Overlap), the archiver before it deletes a source.
///
/// rclone refuses the plain case itself ("overlapping remotes"), and only that
/// one. It does not see a folder named through a junction, nor one place under
/// two names - a disk of this machine and the same machine over ssh - and a
/// copy of a folder into its own subfolder it does not refuse at all. Until
/// the review of 08.10.2026 this class came from Audion Disk Tools with the
/// words "every operation asks here first" over it and nobody calling it.
/// </summary>
public static class PathGuard
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);

    const uint FILE_READ_ATTRIBUTES = 0x80, SHARE_ALL = 0x7, OPEN_EXISTING = 3, FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;

    /// <summary>
    /// The real full path: links resolved by Windows itself. A path that does
    /// not exist yet (a target folder about to be created) is resolved through
    /// its nearest existing parent.
    /// </summary>
    public static string RealPath(string path)
    {
        var full = Path.GetFullPath(path).TrimEnd('\\', '/');
        if (full.Length == 2 && full[1] == ':') full += "\\";
        if (!OperatingSystem.IsWindows()) return full;

        var tail = new Stack<string>();
        var probe = full;
        while (!Directory.Exists(probe) && !File.Exists(probe))
        {
            var parent = Path.GetDirectoryName(probe);
            if (parent is null) return full;
            tail.Push(Path.GetFileName(probe));
            probe = parent;
        }
        var resolved = Resolve(probe) ?? probe;
        foreach (var part in tail) resolved = Path.Combine(resolved, part);
        return resolved.TrimEnd('\\', '/') is { Length: 2 } drive && drive[1] == ':' ? drive + "\\" : resolved.TrimEnd('\\', '/');
    }

    static string? Resolve(string existing)
    {
        try
        {
            using var handle = CreateFileW(existing, FILE_READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) return null;
            var buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0) return null;
            if (length > buffer.Capacity)
            {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0) return null;
            }
            var result = buffer.ToString();
            if (result.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + result[8..];
            if (result.StartsWith(@"\\?\", StringComparison.Ordinal)) return result[4..];
            return result;
        }
        catch { return null; }
    }

    /// <summary>True when <paramref name="child"/> is <paramref name="parent"/> itself or lies inside it (real paths).</summary>
    public static bool Inside(string child, string parent)
    {
        var c = RealPath(child).TrimEnd('\\') + "\\";
        var p = RealPath(parent).TrimEnd('\\') + "\\";
        return c.StartsWith(p, StringComparison.OrdinalIgnoreCase);
    }

    public static bool Same(string a, string b) =>
        string.Equals(RealPath(a).TrimEnd('\\'), RealPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// What stops a copy, a move or a sync from one folder to another, or null.
    /// Branches are the marked folders (or the whole source folder when none
    /// are marked), each against its place in the target.
    ///   copy / move:       a target inside its own source runs into itself;
    ///   mirror / bisync:   also a source inside its target - the mirror would
    ///                      delete it as an extra folder of the target.
    /// </summary>
    public static string? Problem(string from, string to, IEnumerable<(string Name, bool IsDir)> scope, bool mirror)
    {
        if (Same(from, to)) return "источник и приёмник совпадают";
        var items = scope.ToList();
        // Nothing marked: the whole folder is the branch. Marked files alone
        // are copied by name and never recurse: a file into a subfolder of its
        // own folder (E:\ -> E:\folder) is an ordinary copy.
        var branches = items.Count == 0
            ? new List<(string Src, string Dst)> { (from, to) }
            : items.Where(s => s.IsDir).Select(s => (Path.Combine(from, s.Name), Path.Combine(to, s.Name))).ToList();
        foreach (var (src, dst) in branches)
        {
            if (Inside(dst, src))
                return Lang.F("приёмник внутри источника: {0} лежит в {1}", RealPath(dst), RealPath(src));
            if (mirror && Inside(src, dst))
                return Lang.F("источник внутри приёмника: зеркало удалило бы {0} как лишнее", RealPath(src));
        }
        return null;
    }

    /// <summary>
    /// The same question for two addresses of rclone ("remote:path") when both name one storage:
    /// a machine over ssh, a bucket, a cloud. There is nothing to resolve there - the paths are
    /// compared as texts, without the case of the letters: a machine with Windows does not tell
    /// it apart, and a refusal by mistake costs less than a folder copied into itself on someone
    /// else's disk. Two different storages are never in each other's way: null.
    /// </summary>
    public static string? RemoteProblem(string from, string to, IEnumerable<(string Name, bool IsDir)> scope, bool mirror)
    {
        var (fromStore, fromPath) = Address(from);
        var (toStore, toPath) = Address(to);
        if (fromStore.Length == 0 || !string.Equals(fromStore, toStore, StringComparison.OrdinalIgnoreCase)) return null;
        if (string.Equals(fromPath, toPath, StringComparison.OrdinalIgnoreCase)) return "источник и приёмник совпадают";
        var items = scope.ToList();
        var branches = items.Count == 0
            ? new List<(string Src, string Dst)> { (fromPath, toPath) }
            : items.Where(s => s.IsDir).Select(s => (Join(fromPath, s.Name), Join(toPath, s.Name))).ToList();
        foreach (var (src, dst) in branches)
        {
            if (Within(dst, src))
                return Lang.F("приёмник внутри источника: {0} лежит в {1}", $"{toStore}:{dst}", $"{fromStore}:{src}");
            if (mirror && Within(src, dst))
                return Lang.F("источник внутри приёмника: зеркало удалило бы {0} как лишнее", $"{fromStore}:{src}");
        }
        return null;
    }

    /// <summary>"remote:path" cut at the first colon; the path with one kind of slash and none at its ends.</summary>
    static (string Store, string Path) Address(string address)
    {
        int colon = address.IndexOf(':');
        return colon <= 0 ? ("", "") : (address[..colon], address[(colon + 1)..].Replace('\\', '/').Trim('/'));
    }

    static string Join(string path, string name) => path.Length == 0 ? name.Replace('\\', '/').Trim('/') : path + "/" + name.Replace('\\', '/').Trim('/');

    static bool Within(string child, string parent) =>
        parent.Length == 0 || string.Equals(child, parent, StringComparison.OrdinalIgnoreCase) || child.StartsWith(parent + "/", StringComparison.OrdinalIgnoreCase);
}
