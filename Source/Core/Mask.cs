using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace AudionSyncTools.Core;

/// <summary>
/// Total Commander masks: separated by ';' (or spaces for typed input), '*'
/// and '?' as in Explorer, matched against the whole name.
/// </summary>
public static class Mask
{
    // The one mask language of the program - the panel filter, the BLAKE3 plan
    // and both engines mean the same files by it (audit 14):
    //   *  any characters, ?  one character, the whole name, any letter case;
    //   *.* is everything, names without an extension too - as in Windows and robocopy;
    //   [ ] { } are plain characters, as robocopy reads them (rclone gets them escaped).

    /// <summary>
    /// Typed text of the mark box (and the masks of a TC theme): several masks
    /// separated by ';' or spaces - "*.zip 2026-* *aud*".
    /// </summary>
    public static Regex[] Compile(string masks) =>
        Compile(masks.Split(new[] { ';', ' ' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));

    /// <summary>A list of masks as they are - a space is part of a name here ("my *.txt").</summary>
    public static Regex[] Compile(IEnumerable<string> masks)
    {
        var list = new List<Regex>();
        foreach (var raw in masks)
        {
            var one = raw.Trim();
            if (one.Length == 0) continue;
            // "*." - no extension: no dot after the first letter (id_rsa, credentials, .env, .bashrc).
            var pattern = one == "*.*" ? "^.*$"
                : one == "*." ? NoExtension
                : "^" + Regex.Escape(one).Replace(@"\*", ".*").Replace(@"\?", ".") + "$";
            list.Add(new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled));
        }
        return list.ToArray();
    }

    /// <summary>"*.": a name with no dot after its first letter - Linux configs, keys, credentials.</summary>
    public const string NoExtension = @"^\.?[^.]+$";

    /// <summary>The same mask for rclone: "*.*" is "*", "*." a regular expression, brackets and braces taken literally.</summary>
    public static string ForRclone(string mask)
    {
        var one = mask.Trim();
        if (one == "*.*") return "*";
        if (one == "*.") return @"{{\.?[^./]+}}";
        var sb = new StringBuilder();
        foreach (var c in one)
        {
            if (c is '[' or ']' or '{' or '}' or '\\') sb.Append('\\');
            sb.Append(c);
        }
        return sb.ToString();
    }

    public static bool Matches(string name, Regex[] masks)
    {
        foreach (var regex in masks)
            if (regex.IsMatch(name)) return true;
        return false;
    }

    // ------------------------------------------------------------ robocopy

    /// <summary>
    /// Robocopy reads a mask the Win32 way (FindFirstFile underneath): '?' may
    /// match nothing before a dot ("photo?.jpg" takes "photo.jpg"), "*." and
    /// ".*" keep their DOS meanings, and the short 8.3 name matches too
    /// ("*.htm" takes "page.html" where short names exist). The tree is read
    /// once and every name on which the two languages disagree is returned:
    /// Take - the program means it, robocopy would miss it; Skip - robocopy
    /// would take it, the program does not mean it (audit recheck R1).
    /// Junctions are not entered, as robocopy runs with /XJ.
    /// </summary>
    public static (List<string> Take, List<string> Skip) Win32Mismatch(string root, IReadOnlyList<string> masks, System.Threading.CancellationToken cancel)
    {
        var ours = Compile(masks);
        var win32 = new List<string>();
        // "*." takes nothing in robocopy (checked 28.09.2026), whatever FindFirstFile's DOS rule says:
        // its files - those without an extension - all go to robocopy as literal names.
        foreach (var m in masks)
            if (m.Trim().Length > 0 && m.Trim() != "*.") win32.Add(System.IO.Enumeration.FileSystemName.TranslateWin32Expression(m.Trim()));
        bool Windows(string name) =>
            name.Length > 0 && win32.Exists(e => System.IO.Enumeration.FileSystemName.MatchesWin32Expression(e, name, ignoreCase: true));

        var take = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dirs = new Stack<string>();
        dirs.Push(System.IO.Path.GetFullPath(root).TrimEnd('\\'));
        while (dirs.Count > 0)
        {
            cancel.ThrowIfCancellationRequested();
            var dir = dirs.Pop();
            var handle = FindFirstFileExW(Long(dir) + "\\*", 0, out var data, 0, IntPtr.Zero, 2);
            if (handle == new IntPtr(-1)) continue;
            try
            {
                do
                {
                    if (data.Name is "." or "..") continue;
                    const uint Directory = 0x10, Reparse = 0x400;
                    if ((data.Attributes & Directory) != 0)
                    {
                        if ((data.Attributes & Reparse) == 0) dirs.Push(dir + "\\" + data.Name);
                        continue;
                    }
                    bool program = Matches(data.Name, ours);
                    bool robocopy = Windows(data.Name) || Windows(data.ShortName);
                    if (program && !robocopy) take.Add(data.Name);
                    else if (!program && robocopy) skip.Add(data.Name);
                }
                while (FindNextFileW(handle, out data));
            }
            finally { FindClose(handle); }
        }
        return (new List<string>(take), new List<string>(skip));
    }

    static string Long(string path) =>
        path.StartsWith(@"\\?\") ? path : path.StartsWith(@"\\") ? @"\\?\UNC\" + path.Substring(2) : @"\\?\" + path;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    struct FindData
    {
        public uint Attributes;
        public uint Created1, Created2, Accessed1, Accessed2, Written1, Written2;
        public uint SizeHigh, SizeLow, Reserved0, Reserved1;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 14)] public string ShortName;
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFileExW(string name, int infoLevel, out FindData data, int searchOp, IntPtr filter, int flags);

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    static extern bool FindNextFileW(IntPtr handle, out FindData data);

    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr handle);
}
