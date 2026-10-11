using System.IO;

namespace AudionSyncTools.Core;

/// <summary>
/// F4: the editors the project carries in Tools\, both under the MIT license -
/// Microsoft Edit (Tools\edit) and micro (Tools\micro) - found like 7-Zip:
/// beside the program or up the tree, then PATH (where Windows 11 keeps its
/// own Edit). Both are console programs and open in a terminal window.
/// </summary>
public static class Editors
{
    public static string? Edit => Archiver.Find(new[] { Path.Combine("Tools", "edit", "edit.exe") }, new[] { "edit.exe" });

    public static string? Micro => Archiver.Find(new[] { Path.Combine("Tools", "micro", "micro.exe") }, new[] { "micro.exe" });

    /// <summary>Edit and micro draw in a console: F4 opens them inside the terminal.</summary>
    public static bool InConsole(string editor) => Path.GetFileName(editor).ToLowerInvariant() is "edit.exe" or "micro.exe";

    /// <summary>
    /// The program for SETTINGS · РЕДАКТОР И ТЕРМИНАЛ: "" - Edit, "micro",
    /// "notepad", or a path of one's own. A missing one falls back to Edit,
    /// and to Notepad where there is no Edit either.
    /// </summary>
    public static string For(string setting) => setting switch
    {
        "notepad" => "notepad.exe",
        "micro" => Micro ?? Edit ?? "notepad.exe",
        "" => Edit ?? "notepad.exe",
        _ => File.Exists(setting) ? setting : Edit ?? "notepad.exe",
    };
}
