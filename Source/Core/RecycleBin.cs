using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace AudionSyncTools.Core;

/// <summary>What a delete into the bin left behind: in the bin, past it (Windows asked), not deleted; and whether СТОП ended it.</summary>
public sealed class BinResult
{
    public List<string> Recycled { get; } = new();
    public List<string> PastBin { get; } = new();
    /// <summary>Objects the bin cannot take: they are all in place.</summary>
    public List<string> NoRoom { get; } = new();
    public List<string> Failed { get; } = new();
    public bool Cancelled { get; set; }
}

/// <summary>
/// Deletes into the Windows Recycle Bin - one guarded path for F8, DEL and the archive windows: the
/// shell's IFileOperation, never past the bin (the older SHFileOperation route deleted for good in
/// silence when the bin could not take an object - audit N17).
/// </summary>
public static class RecycleBin
{
    const ushort FOF_SILENT = 0x0004, FOF_NOCONFIRMATION = 0x0010, FOF_ALLOWUNDO = 0x0040, FOF_NOERRORUI = 0x0400;

    /// <summary>
    /// All the given objects into the Recycle Bin in one shell operation (IFileOperation): the shell
    /// reports its progress and a cancel is heard between two steps. An object the bin cannot take
    /// (too big, a drive without a bin) stays where it is (BinResult.NoRoom), never deleted for good.
    /// </summary>
    public static BinResult SendMany(IReadOnlyList<string> paths, IntPtr owner, Action<string, double> progress, CancellationToken cancel, bool windowsUi = false)
    {
        var result = new BinResult();
        if (!OperatingSystem.IsWindows()) { result.Failed.Add(Lang.T("корзины здесь нет")); return result; }
        Exception? crash = null;
        // The shell's file operation lives in a single-threaded apartment; the job's thread is not one.
        var thread = new Thread(() =>
        {
            try { if (OperatingSystem.IsWindows()) Perform(paths, owner, progress, cancel, result, windowsUi); }
            catch (Exception ex) { crash = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        thread.Join();
        if (crash is not null) result.Failed.Add(Lang.F("корзина: {0}", crash.Message));
        return result;
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    static void Perform(IReadOnlyList<string> paths, IntPtr owner, Action<string, double> progress, CancellationToken cancel, BinResult result, bool windowsUi)
    {
        var op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3ad05575-8857-4850-9277-11b85bdb8e09"))!)!;
        var sink = new Sink(progress, cancel, result);
        uint cookie = 0;
        try
        {
            // DEL leaves out FOF_SILENT: Windows shows its own progress window; the bin guard in the sink stays.
            var flags = (uint)(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI) | FOF_WANTNUKEWARNING | FOFX_RECYCLEONDELETE;
            if (!windowsUi) flags |= FOF_SILENT;
            Check(op.SetOperationFlags(flags));
            if (owner != IntPtr.Zero) op.SetOwnerWindow(owner);
            Check(op.Advise(sink, out cookie));
            int queued = 0;
            foreach (var path in paths)
            {
                var full = Path.GetFullPath(path);
                var iid = typeof(IShellItem).GUID;
                if (!File.Exists(full) && !Directory.Exists(full)) { result.Failed.Add(Lang.F("нет такого объекта: {0}", full)); continue; }
                int hr = SHCreateItemFromParsingName(full, IntPtr.Zero, ref iid, out var item);
                if (hr < 0) { result.Failed.Add($"{full}: {Reason(hr)}"); continue; }
                try { Check(op.DeleteItem(item, IntPtr.Zero)); queued++; }
                finally { Marshal.ReleaseComObject(item); }
            }
            if (queued == 0) return;
            // Before the first percent Windows walks the whole tree - minutes on a big folder:
            // the status says so, or it looks as if nothing happens.
            progress("Windows готовит список файлов…", 0);
            int done = op.PerformOperations();
            op.GetAnyOperationsAborted(out bool aborted);
            // Refused by the sink because an object would go past the bin: nothing of it was deleted.
            if (result.NoRoom.Count > 0) { }
            else if (cancel.IsCancellationRequested || done == ERROR_CANCELLED) result.Cancelled = true;
            else if (done < 0) result.Failed.Add(Lang.F("корзина отказала: {0}", Reason(done)));
            else if (aborted && result.Failed.Count == 0) result.Failed.Add(Lang.T("удаление прервано"));
        }
        finally
        {
            if (cookie != 0) op.Unadvise(cookie);
            Marshal.ReleaseComObject(op);
        }
    }

    static void Check(int hr) { if (hr < 0) Marshal.ThrowExceptionForHR(hr); }

    static string Reason(int hr) => Marshal.GetExceptionForHR(hr)?.Message ?? Lang.F("код 0x{0:X8}", hr);

    static string PathOf(IShellItem? item)
    {
        if (item is null || item.GetDisplayName(SIGDN_FILESYSPATH, out var text) < 0) return "";
        try { return Marshal.PtrToStringUni(text) ?? ""; }
        finally { Marshal.FreeCoTaskMem(text); }
    }

    const uint FOF_WANTNUKEWARNING = 0x4000, FOFX_RECYCLEONDELETE = 0x80000;
    const uint SIGDN_FILESYSPATH = 0x80058000;
    // PreDeleteItem: set when the item goes into the bin; missing - Windows is about to delete it for good.
    const uint TSF_DELETE_RECYCLE_IF_POSSIBLE = 0x80;
    const int ERROR_CANCELLED = unchecked((int)0x800704C7);

    /// <summary>The shell's reports: the bar, the name in the status, what the bin did not take.</summary>
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    sealed class Sink : IFileOperationProgressSink
    {
        readonly Action<string, double> _progress;
        readonly CancellationToken _cancel;
        readonly BinResult _result;
        string _name = "";

        public Sink(Action<string, double> progress, CancellationToken cancel, BinResult result)
        {
            _progress = progress; _cancel = cancel; _result = result;
        }

        // Every step asks whether to go on: СТОП answers "cancelled", and the shell stops there.
        int Go => _cancel.IsCancellationRequested ? ERROR_CANCELLED : 0;

        public int StartOperations() => Go;
        public int FinishOperations(int hrResult) => 0;
        public int PreRenameItem(uint flags, IntPtr item, IntPtr newName) => Go;
        public int PostRenameItem(uint flags, IntPtr item, IntPtr newName, int hr, IntPtr created) => Go;
        public int PreMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName) => Go;
        public int PostMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName, int hr, IntPtr created) => Go;
        public int PreCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName) => Go;
        public int PostCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName, int hr, IntPtr created) => Go;

        public int PreDeleteItem(uint flags, IShellItem item)
        {
            // The bin cannot take it (too big for its size, a drive without a bin): Windows would delete
            // it for good, file by file, without asking - 27.09 it did so to 144 208 files. F8 never does
            // that: the operation stops here, before this item is touched; Shift+Del is the way past the bin.
            if ((flags & TSF_DELETE_RECYCLE_IF_POSSIBLE) == 0)
            {
                _result.NoRoom.Add(PathOf(item));
                return ERROR_CANCELLED;
            }
            _name = Path.GetFileName(PathOf(item));
            return Go;
        }

        public int PostDeleteItem(uint flags, IShellItem item, int hrDelete, IShellItem? created)
        {
            var path = PathOf(item);
            if (hrDelete == ERROR_CANCELLED) { }
            else if (hrDelete < 0) _result.Failed.Add($"{path}: {Reason(hrDelete)}");
            // Gone, but nothing new in the bin: Windows deleted it for good (the user said yes to its question).
            else if (created is null) _result.PastBin.Add(path);
            else _result.Recycled.Add(path);
            return Go;
        }

        public int PreNewItem(uint flags, IntPtr folder, IntPtr newName) => Go;
        public int PostNewItem(uint flags, IntPtr folder, IntPtr newName, IntPtr template, uint attributes, int hr, IntPtr item) => Go;

        public int UpdateProgress(uint total, uint soFar)
        {
            // No item started yet: the preparation is still going, its label stays.
            if (_name.Length > 0 || soFar > 0) _progress(_name, total == 0 ? 0 : Math.Min(100, soFar * 100.0 / total));
            return Go;
        }

        public int ResetTimer() => 0;
        public int PauseTimer() => 0;
        public int ResumeTimer() => 0;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        [PreserveSig] int BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
        [PreserveSig] int GetParent(out IShellItem parent);
        [PreserveSig] int GetDisplayName(uint sigdn, out IntPtr name);
        [PreserveSig] int GetAttributes(uint mask, out uint attributes);
        [PreserveSig] int Compare(IShellItem other, uint hint, out int order);
    }

    // Declared in vtable order; only the slots used here have real parameter types.
    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperation
    {
        [PreserveSig] int Advise(IFileOperationProgressSink sink, out uint cookie);
        [PreserveSig] int Unadvise(uint cookie);
        [PreserveSig] int SetOperationFlags(uint flags);
        [PreserveSig] int SetProgressMessage(IntPtr message);
        [PreserveSig] int SetProgressDialog(IntPtr dialog);
        [PreserveSig] int SetProperties(IntPtr properties);
        [PreserveSig] int SetOwnerWindow(IntPtr owner);
        [PreserveSig] int ApplyPropertiesToItem(IntPtr item);
        [PreserveSig] int ApplyPropertiesToItems(IntPtr items);
        [PreserveSig] int RenameItem(IntPtr item, IntPtr newName, IntPtr sink);
        [PreserveSig] int RenameItems(IntPtr items, IntPtr newName);
        [PreserveSig] int MoveItem(IntPtr item, IntPtr folder, IntPtr newName, IntPtr sink);
        [PreserveSig] int MoveItems(IntPtr items, IntPtr folder);
        [PreserveSig] int CopyItem(IntPtr item, IntPtr folder, IntPtr newName, IntPtr sink);
        [PreserveSig] int CopyItems(IntPtr items, IntPtr folder);
        [PreserveSig] int DeleteItem(IShellItem item, IntPtr sink);
        [PreserveSig] int DeleteItems(IntPtr items);
        [PreserveSig] int NewItem(IntPtr folder, uint attributes, IntPtr name, IntPtr template, IntPtr sink);
        [PreserveSig] int PerformOperations();
        [PreserveSig] int GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }

    [ComImport, Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperationProgressSink
    {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int hrResult);
        [PreserveSig] int PreRenameItem(uint flags, IntPtr item, IntPtr newName);
        [PreserveSig] int PostRenameItem(uint flags, IntPtr item, IntPtr newName, int hr, IntPtr created);
        [PreserveSig] int PreMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName);
        [PreserveSig] int PostMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName, int hr, IntPtr created);
        [PreserveSig] int PreCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName);
        [PreserveSig] int PostCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr newName, int hr, IntPtr created);
        [PreserveSig] int PreDeleteItem(uint flags, IShellItem item);
        [PreserveSig] int PostDeleteItem(uint flags, IShellItem item, int hrDelete, IShellItem? created);
        [PreserveSig] int PreNewItem(uint flags, IntPtr folder, IntPtr newName);
        [PreserveSig] int PostNewItem(uint flags, IntPtr folder, IntPtr newName, IntPtr template, uint attributes, int hr, IntPtr item);
        [PreserveSig] int UpdateProgress(uint total, uint soFar);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }
}
