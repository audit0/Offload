using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Offload.Core;

/// <summary>Корзина Windows. Удаляемое уходит туда так же, как из Проводника, и видно в Корзине с кнопкой
/// «Восстановить». OffLoadAI запоминает, куда именно легло каждое, чтобы вернуть его на место или удалить
/// насовсем ровно то, что туда отправил, а не соседей по Корзине.</summary>
public static class RecycleBin
{
    public sealed class RecycleException(string message) : Exception(message);

    /// <summary>В Корзину; ответ — где объект лежит теперь («C:\$Recycle.Bin\S-1-5-…\$R4Q2J1K.pdf») и какой это файл.</summary>
    public static (string path, FileIdentity? identity) Trash(string path)
    {
        var identity = FileIdentity.Of(path) ?? throw new FileNotFoundException($"Нет «{path}».");
        // Объект больше Корзины Windows удалила бы насовсем, не спросив. Такое в Корзину не отправляем вовсе.
        if (Capacity(path) is { } capacity && SizeOf(path) > capacity)
            throw new RecycleException($"«{Paths.Name(path)}» больше Корзины на этом диске ({Format.Bytes(capacity)}) — Windows удалила бы его насовсем. Удалите его сами или увеличьте размер Корзины в её свойствах.");
        string? created = null;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { created = Perform(path); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure != null) throw failure is RecycleException ? failure : new RecycleException($"«{Paths.Name(path)}» не удалось отправить в Корзину: {failure.Message}");
        if (created == null)
        {
            if (FileSystem.Exists(path)) throw new RecycleException($"«{Paths.Name(path)}» осталось на месте: Windows не отправила его в Корзину.");
            throw new RecycleException($"Windows удалила «{Paths.Name(path)}», а не отправила в Корзину.");
        }
        return (created, identity);
    }

    /// <summary>Вернуть из Корзины на прежнее место. Запись Корзины о нём («$I…») убирается вместе с ним.</summary>
    public static void Restore(string inTrash, string original)
    {
        Directory.CreateDirectory(Paths.Parent(original));
        FileSystem.RenameExclusive(inTrash, original);
        DeleteInfo(inTrash);
    }

    /// <summary>Удалить насовсем то, что лежит в Корзине, и запись о нём.</summary>
    public static void Erase(string inTrash)
    {
        FileSystem.DeleteTree(inTrash);
        DeleteInfo(inTrash);
    }

    /// <summary>Рядом с каждым «$Rxxxxxx» Корзина держит «$Ixxxxxx» — откуда и когда удалено.</summary>
    static void DeleteInfo(string inTrash)
    {
        var name = Paths.Name(inTrash);
        if (!name.StartsWith("$R", StringComparison.Ordinal)) return;
        var info = Path.Combine(Paths.Parent(inTrash), "$I" + name[2..]);
        try { if (FileSystem.IsRegularFile(info)) File.Delete(info); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    static long SizeOf(string path)
    {
        if (FileSystem.Stat(path) is not { } stat) return 0;
        return stat.IsDirectory ? Inspector.Inspect(path).LogicalBytes : stat.Size;
    }

    /// <summary>Предел Корзины на томе, как его задали в её свойствах; null — не узнать.</summary>
    public static long? Capacity(string path)
    {
        var root = Native.VolumePathName(Paths.Normalize(path));
        if (root == null) return null;
        var volume = Native.VolumeGuidPath(root);
        if (volume == null) return null;
        var guid = volume[(volume.IndexOf('{'))..(volume.IndexOf('}') + 1)];
        using var key = Registry.CurrentUser.OpenSubKey($@"Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{guid}");
        if (key?.GetValue("NukeOnDelete") is int nuke && nuke != 0) return 0;
        if (key?.GetValue("MaxCapacity") is int megabytes) return (long)megabytes << 20;
        // Настроек нет: Windows по умолчанию отводит Корзине около 5 % тома.
        return Volumes.Info(root) is { } info ? info.TotalBytes / 20 : null;
    }

    // MARK: IFileOperation

    const uint FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOCONFIRMMKDIR = 0x200, FOF_NOERRORUI = 0x400,
               FOF_WANTNUKEWARNING = 0x4000, FOFX_EARLYFAILURE = 0x00100000, FOFX_RECYCLEONDELETE = 0x00080000;
    const uint SIGDN_FILESYSPATH = 0x80058000;

    static string? Perform(string path)
    {
        var operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09"))!)!;
        var sink = new Sink();
        uint cookie = operation.Advise(sink);
        try
        {
            // Предупреждение «удалить насовсем?» оставлено: если предел Корзины прочитан неверно,
            // Windows спросит, а не удалит молча.
            operation.SetOperationFlags(FOF_ALLOWUNDO | FOFX_RECYCLEONDELETE | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
                                        | FOF_NOCONFIRMMKDIR | FOF_WANTNUKEWARNING | FOFX_EARLYFAILURE);
            var iid = typeof(IShellItem).GUID;
            SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out var item);
            operation.DeleteItem(item, null);
            operation.PerformOperations();
            if (sink.Failure is { } hr && hr < 0) throw new RecycleException(Marshal.GetExceptionForHR(hr)?.Message ?? $"0x{hr:X8}");
            return sink.Created;
        }
        finally
        {
            operation.Unadvise(cookie);
            Marshal.ReleaseComObject(operation);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem
    {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint form, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperation
    {
        uint Advise(IFileOperationProgressSink sink);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message);
        void SetProgressDialog([MarshalAs(UnmanagedType.IUnknown)] object dialog);
        void SetProperties([MarshalAs(UnmanagedType.IUnknown)] object properties);
        void SetOwnerWindow(IntPtr owner);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IFileOperationProgressSink? sink);
        void RenameItems([MarshalAs(UnmanagedType.IUnknown)] object items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string? name, IFileOperationProgressSink? sink);
        void MoveItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destination);
        void CopyItem(IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string? name, IFileOperationProgressSink? sink);
        void CopyItems([MarshalAs(UnmanagedType.IUnknown)] object items, IShellItem destination);
        void DeleteItem(IShellItem item, IFileOperationProgressSink? sink);
        void DeleteItems([MarshalAs(UnmanagedType.IUnknown)] object items);
        uint NewItem(IShellItem destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name,
                     [MarshalAs(UnmanagedType.LPWStr)] string? template, IFileOperationProgressSink? sink);
        void PerformOperations();
        [return: MarshalAs(UnmanagedType.Bool)] bool GetAnyOperationsAborted();
    }

    [ComImport, Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileOperationProgressSink
    {
        void StartOperations();
        void FinishOperations(int result);
        void PreRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        void PreDeleteItem(uint flags, IShellItem item);
        void PostDeleteItem(uint flags, IShellItem item, int result, IShellItem? created);
        void PreNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void PostNewItem(uint flags, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name,
                         [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IShellItem created);
        void UpdateProgress(uint total, uint done);
        void ResetTimer();
        void PauseTimer();
        void ResumeTimer();
    }

    /// <summary>Узнаёт, куда в Корзине лёг удалённый объект.</summary>
    [ComVisible(true)]
    sealed class Sink : IFileOperationProgressSink
    {
        public string? Created;
        public int? Failure;

        public void StartOperations() { }
        public void FinishOperations(int result) { if (result < 0) Failure = result; }
        public void PreRenameItem(uint flags, IShellItem item, string name) { }
        public void PostRenameItem(uint flags, IShellItem item, string name, int result, IShellItem created) { }
        public void PreMoveItem(uint flags, IShellItem item, IShellItem destination, string name) { }
        public void PostMoveItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { }
        public void PreCopyItem(uint flags, IShellItem item, IShellItem destination, string name) { }
        public void PostCopyItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { }
        public void PreDeleteItem(uint flags, IShellItem item) { }

        public void PostDeleteItem(uint flags, IShellItem item, int result, IShellItem? created)
        {
            if (result < 0) { Failure = result; return; }
            if (created == null) return;
            created.GetDisplayName(SIGDN_FILESYSPATH, out var name);
            Created = Marshal.PtrToStringUni(name);
            Marshal.FreeCoTaskMem(name);
        }

        public void PreNewItem(uint flags, IShellItem destination, string name) { }
        public void PostNewItem(uint flags, IShellItem destination, string name, string template, uint attributes, int result, IShellItem created) { }
        public void UpdateProgress(uint total, uint done) { }
        public void ResetTimer() { }
        public void PauseTimer() { }
        public void ResumeTimer() { }
    }
}
