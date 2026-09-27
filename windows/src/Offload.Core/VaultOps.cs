using System.Management;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace Offload.Core;

/// <summary>Сейф на самом деле: образ VHDX, раздел NTFS, BitLocker с паролем. Всё здесь требует прав
/// администратора — в программе это делает отдельный процесс с повышенными правами.
///
/// Пароль уходит в BitLocker через WMI (Win32_EncryptableVolume) — не в командную строку и не в файл.</summary>
public sealed class VaultOps : IVaultBackend, IDisposable
{
    const string Namespace = @"root\cimv2\security\microsoftvolumeencryption";
    const uint FailedAuthentication = 0x80310027;
    /// <summary>Способ шифрования XTS-AES-256.</summary>
    const uint XtsAes256 = 7;
    /// <summary>Шифровать только занятое место: том только что отформатирован, старых данных на нём нет.</summary>
    const uint EncryptDataOnly = 1;
    const uint ProtectorPassphrase = 8;

    /// <summary>Образы, которые подключил этот процесс: пока дескриптор жив, образ подключён.</summary>
    readonly Dictionary<string, SafeFileHandle> attached = new(Paths.Comparer);
    readonly Lock gate = new();

    public static bool IsElevated
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    static void RequireImage(string image)
    {
        if (!Paths.IsPlainLocal(image) || Paths.Extension(image) != "vhdx")
            throw new VaultException(VaultErrorKind.Unavailable, "Сейф — это файл .vhdx на диске с буквой.");
    }

    // MARK: Создание

    public void Create(string image, long maxBytes, string label, string password, string userSid)
    {
        RequireImage(image);
        if (File.Exists(image)) throw new VaultException(VaultErrorKind.AlreadyExists);
        RequireBitLocker();
        VirtualDisks.Create(image, maxBytes);
        SafeFileHandle? handle = null;
        try
        {
            handle = VirtualDisks.Attach(image);
            int disk = VirtualDisks.DiskNumber(handle);
            // Разметка и форматирование — без буквы диска: иначе Проводник показал бы окно «Отформатировать диск?».
            var volume = PowerShellLine($$"""
                $d = Get-Disk -Number {{disk}}
                if ($d.PartitionStyle -eq 'RAW') { Initialize-Disk -Number {{disk}} -PartitionStyle GPT | Out-Null }
                $p = New-Partition -DiskNumber {{disk}} -UseMaximumSize
                Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel {{Quote(label)}} -Confirm:$false -Force | Out-Null
                (Get-Partition -DiskNumber {{disk}} -PartitionNumber $p.PartitionNumber).AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1
                """);
            var encryptable = WaitForEncryptable(volume);
            Call(encryptable, "ProtectKeyWithPassphrase", new() { ["FriendlyName"] = "Offload", ["Passphrase"] = password }, "пароль не принят");
            Call(encryptable, "Encrypt", new() { ["EncryptionMethod"] = XtsAes256, ["EncryptionFlags"] = EncryptDataOnly }, "шифрование не началось");
            WaitFullyEncrypted(encryptable);
            RestrictToOwner(volume, userSid);
            VirtualDisks.Detach(handle);
        }
        catch (Exception ex)
        {
            try { if (handle != null) VirtualDisks.Detach(handle); } catch (IOException) { }
            handle?.Dispose();
            try { File.Delete(image); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            if (ex is VaultException) throw;
            throw new VaultException(VaultErrorKind.MountFailed, ex.Message);
        }
        handle.Dispose();
    }

    // MARK: Открыть и закрыть

    public string Attach(string image, string password, string userSid)
    {
        RequireImage(image);
        RequireBitLocker();
        if (BitLockerHeader.Info(image) is not { OpensWithPassword: true }) throw new VaultException(VaultErrorKind.NotEncrypted);
        lock (gate)
        {
            // Образ уже подключён (например, Проводником) и заблокирован — открываем тот же том.
            string? volume = VolumeOfAttached(image);
            SafeFileHandle? handle = null;
            if (volume == null)
            {
                handle = VirtualDisks.Attach(image);
                try { volume = DataVolume(VirtualDisks.DiskNumber(handle)); }
                catch
                {
                    Release(handle);
                    throw;
                }
            }
            try
            {
                var encryptable = WaitForEncryptable(volume);
                Unlock(encryptable, password);
                // Код ответа BitLocker тут ничего не доказывает — спрашиваем сам BitLocker про открытый том:
                // зашифрован целиком, защита включена, открывается паролем. Нет — отключаем, не записав ни байта.
                if (!IsProtected(encryptable)) throw new VaultException(VaultErrorKind.NotEncrypted);
                var root = MountPointOf(volume) ?? AssignLetter(volume);
                RestrictToOwner(volume, userSid);
                if (handle != null) attached[Paths.Resolve(image)] = handle;
                return root;
            }
            catch
            {
                if (handle != null) Release(handle);
                throw;
            }
        }
    }

    /// <summary>Закрыть том: сначала заблокировать том (если в нём открыты файлы — «занят»), снять с него букву,
    /// затем отключить образ. Ключ шифрования уходит из памяти вместе с томом.</summary>
    public void Detach(string mountRoot, bool force)
    {
        var volume = Native.VolumeGuidPath(mountRoot) ?? throw new VaultException(VaultErrorKind.CloseFailed, $"«{mountRoot}» — не том");
        var image = VirtualDisks.BackingFile(volume)
                    ?? throw new VaultException(VaultErrorKind.CloseFailed, $"«{mountRoot}» — не образ диска, отключать его Offload не будет");
        if (Paths.Extension(image) != "vhdx") throw new VaultException(VaultErrorKind.CloseFailed, "это не сейф Offload");
        lock (gate)
        {
            DismountVolume(volume, force);
            foreach (var point in Native.VolumeMountPoints(volume)) Native.DeleteVolumeMountPointW(point);
            var key = Paths.Resolve(image);
            if (attached.Remove(key, out var handle)) Release(handle);
            else
            {
                try { VirtualDisks.Detach(image); }
                catch (IOException ex) { throw new VaultException(VaultErrorKind.CloseFailed, ex.Message); }
            }
        }
    }

    static unsafe void DismountVolume(string volume, bool force)
    {
        using var handle = Native.CreateFileW(volume.TrimEnd('\\'), Native.GENERIC_READ | Native.GENERIC_WRITE,
                                              Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
        if (handle.IsInvalid) throw new VaultException(VaultErrorKind.CloseFailed, Native.LastError().Message);
        // Заблокировать том можно, только если никто не держит на нём файлов: это и есть проверка «занят».
        bool locked = false;
        for (int i = 0; i < 3 && !locked; i++)
        {
            locked = Native.DeviceIoControl(handle, Native.FSCTL_LOCK_VOLUME, null, 0, null, 0, out _, IntPtr.Zero);
            if (!locked) Thread.Sleep(300);
        }
        if (!locked && !force) throw new VaultException(VaultErrorKind.Busy);
        Native.DeviceIoControl(handle, Native.FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, out _, IntPtr.Zero);
    }

    void Release(SafeFileHandle handle)
    {
        try { VirtualDisks.Detach(handle); } catch (IOException) { }
        handle.Dispose();
    }

    /// <summary>Отключить всё, что подключил этот процесс, — при выходе.</summary>
    public void DetachAll()
    {
        lock (gate)
        {
            foreach (var (image, handle) in attached.ToList())
            {
                try
                {
                    if (VolumeOfAttached(image) is { } volume)
                    {
                        try { DismountVolume(volume, force: true); } catch (VaultException) { }
                        foreach (var point in Native.VolumeMountPoints(volume)) Native.DeleteVolumeMountPointW(point);
                    }
                }
                catch (IOException) { }
                Release(handle);
            }
            attached.Clear();
        }
    }

    public void Dispose() => DetachAll();

    // MARK: Предел, место, пароль

    public void Grow(string image, long maxBytes, string password)
    {
        RequireImage(image);
        RequireBitLocker();
        using (var disk = Vhdx.Open(image))
        {
            if (disk == null) throw new VaultException(VaultErrorKind.GrowFailed, "образ не читается");
            if (maxBytes > disk.DiskSize)
            {
                try { VirtualDisks.Resize(image, maxBytes); }
                catch (IOException ex) { throw new VaultException(VaultErrorKind.GrowFailed, ex.Message); }
            }
        }
        WithUnlocked(image, password, (disk, volume, _) =>
        {
            // Раздел занимает весь образ, кроме служебных разделов в начале и копии таблицы в конце.
            var reached = PowerShellLine($$"""
                Update-Disk -Number {{disk}}
                $p = Get-Partition -DiskNumber {{disk}} | Where-Object { $_.AccessPaths -contains {{Quote(volume)}} }
                $max = (Get-PartitionSupportedSize -DiskNumber {{disk}} -PartitionNumber $p.PartitionNumber).SizeMax
                if ($max -gt $p.Size) { Resize-Partition -DiskNumber {{disk}} -PartitionNumber $p.PartitionNumber -Size $max }
                (Get-Partition -DiskNumber {{disk}} -PartitionNumber $p.PartitionNumber).Size
                """);
            if (!long.TryParse(reached, out var size) || size < maxBytes - (64L << 20))
                throw new VaultException(VaultErrorKind.GrowFailed, $"раздел занимает {reached} байт из {maxBytes}");
        });
    }

    /// <summary>Возвращает диску место, освободившееся внутри сейфа.
    ///
    /// На Mac образ сжимает hdiutil compact. У VHDX тот же путь — TRIM изнутри и CompactVirtualDisk — на деле
    /// ничего не возвращает (проверено: даже без BitLocker освобождённые блоки образа остаются занятыми).
    /// Поэтому сейф переписывается заново: рядом создаётся новый образ с тем же паролем и пределом, всё
    /// содержимое копируется в него со сверкой SHA-256, и только потом новый образ встаёт на место старого.
    /// Оборвётся посередине — старый сейф цел и лежит на месте.</summary>
    public string Compact(string image, string password)
    {
        RequireImage(image);
        RequireBitLocker();
        var folder = Paths.Parent(image);
        var fresh = Path.Combine(folder, Path.GetFileNameWithoutExtension(image) + ".offload-repack.vhdx");
        var old = Path.Combine(folder, Path.GetFileNameWithoutExtension(image) + ".offload-old.vhdx");
        if (File.Exists(fresh) || File.Exists(old))
            throw new VaultException(VaultErrorKind.MountFailed, $"рядом с сейфом остался образ от прерванного сжатия («{Paths.Name(File.Exists(fresh) ? fresh : old)}»). Проверьте его и удалите, если сейф открывается.");
        long limit;
        using (var disk = Vhdx.Open(image) ?? throw new VaultException(VaultErrorKind.MountFailed, "образ не читается"))
            limit = disk.DiskSize;

        string? oldRoot = null, freshRoot = null;
        try
        {
            oldRoot = Attach(image, password, SecretsVault.CurrentUserSid);
            var owner = new DirectoryInfo(oldRoot).GetAccessControl().GetOwner(typeof(SecurityIdentifier))?.Value ?? SecretsVault.CurrentUserSid;
            var label = Native.VolumeInformation(oldRoot)?.label is { Length: > 0 } name ? name : SecretsVault.VolumeName;
            var used = new DriveInfo(oldRoot);
            long needed = used.TotalSize - used.TotalFreeSpace + (1L << 30);
            var host = Volumes.Info(folder) ?? throw new VaultException(VaultErrorKind.MountFailed, "диск с сейфом не читается");
            if (host.AvailableBytes < needed)
                throw new VaultException(VaultErrorKind.MountFailed,
                    $"чтобы сжать сейф, рядом нужно место под его содержимое: около {Format.Bytes(needed)}, а свободно {Format.Bytes(host.AvailableBytes)}");
            Create(fresh, limit, label, password, owner);
            freshRoot = Attach(fresh, password, owner);
            var skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "System Volume Information", "$RECYCLE.BIN" };
            foreach (var item in FileSystem.List(oldRoot).Where(i => !skip.Contains(i.Name)))
            {
                var source = Path.Combine(oldRoot, item.Name);
                var target = Path.Combine(freshRoot, item.Name);
                var entries = TreeWalker.Walk(source, strict: true).entries;
                var hashes = VerifiedCopy.CopyTree(entries, source, target, keepAttributes: true);
                VerifiedCopy.Verify(entries, hashes, target);
            }
            Detach(freshRoot, force: false);
            freshRoot = null;
            Detach(oldRoot, force: false);
            oldRoot = null;
            File.Move(image, old);
            try { File.Move(fresh, image); }
            catch
            {
                File.Move(old, image);
                throw;
            }
            File.Delete(old);
        }
        catch (Exception ex)
        {
            if (freshRoot != null) try { Detach(freshRoot, force: true); } catch (VaultException) { }
            if (oldRoot != null) try { Detach(oldRoot, force: true); } catch (VaultException) { }
            try { if (File.Exists(fresh) && File.Exists(image)) File.Delete(fresh); } catch (IOException) { }
            if (ex is VaultException) throw;
            throw new VaultException(VaultErrorKind.MountFailed, ex.Message);
        }
        return "Сейф переписан заново: в новом образе только то, что в нём лежит. Пароль тот же, а копии заголовка, снятые раньше, к нему больше не подходят — снимите новую.";
    }

    public void ChangePassword(string image, string oldPassword, string newPassword)
    {
        RequireImage(image);
        RequireBitLocker();
        WithUnlocked(image, oldPassword, (_, _, encryptable) =>
        {
            // У тома BitLocker бывает только один пароль. Чтобы ни на миг не остаться без способа открыть том,
            // сначала добавляется временный ключ восстановления, потом меняется пароль, потом ключ удаляется.
            var old = Protectors(encryptable, ProtectorPassphrase);
            var temporary = (string)Call(encryptable, "ProtectKeyWithNumericalPassword", new(), "не удалось подготовить смену пароля")["VolumeKeyProtectorID"];
            try
            {
                foreach (var id in old) Call(encryptable, "DeleteKeyProtector", new() { ["VolumeKeyProtectorID"] = id }, "старый пароль не снят");
                try
                {
                    Call(encryptable, "ProtectKeyWithPassphrase", new() { ["FriendlyName"] = "Offload", ["Passphrase"] = newPassword }, "новый пароль не принят");
                }
                catch
                {
                    Call(encryptable, "ProtectKeyWithPassphrase", new() { ["FriendlyName"] = "Offload", ["Passphrase"] = oldPassword }, "старый пароль не вернулся");
                    throw;
                }
            }
            finally
            {
                if (Protectors(encryptable, ProtectorPassphrase).Count > 0)
                    Call(encryptable, "DeleteKeyProtector", new() { ["VolumeKeyProtectorID"] = temporary }, "временный ключ не удалён");
            }
        });
    }

    public void TryUnlock(string image, string password)
    {
        RequireImage(image);
        RequireBitLocker();
        WithUnlocked(image, password, (_, _, encryptable) =>
        {
            if (!IsProtected(encryptable)) throw new VaultException(VaultErrorKind.NotEncrypted);
        });
    }

    /// <summary>Подключает образ без буквы, открывает паролем, выполняет работу и отключает, что бы ни случилось.</summary>
    void WithUnlocked(string image, string password, Action<int, string, ManagementObject> body)
    {
        lock (gate)
        {
            if (VolumeOfAttached(image) != null) throw new VaultException(VaultErrorKind.Busy);
            var handle = VirtualDisks.Attach(image);
            try
            {
                int disk = VirtualDisks.DiskNumber(handle);
                var volume = DataVolume(disk);
                var encryptable = WaitForEncryptable(volume);
                Unlock(encryptable, password);
                body(disk, volume, encryptable);
                try { DismountVolume(volume, force: true); } catch (VaultException) { }
            }
            finally
            {
                Release(handle);
            }
        }
    }

    // MARK: BitLocker

    static void RequireBitLocker()
    {
        if (!IsElevated) throw new VaultException(VaultErrorKind.Unavailable, "Для сейфа нужны права администратора.");
        try
        {
            using var cls = new ManagementClass(Namespace, "Win32_EncryptableVolume", null);
            cls.Get();
        }
        catch (ManagementException)
        {
            throw new VaultException(VaultErrorKind.Unavailable,
                "BitLocker недоступен: сейфу нужна Windows 10 или 11 в редакции Pro, Enterprise или Education.");
        }
    }

    /// <summary>Том BitLocker по пути «\\?\Volume{…}\». После подключения Windows сообщает о нём не сразу.</summary>
    static ManagementObject WaitForEncryptable(string volume)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            using (var searcher = new ManagementObjectSearcher(Namespace, "SELECT * FROM Win32_EncryptableVolume"))
            {
                foreach (ManagementObject candidate in searcher.Get())
                {
                    if (string.Equals(candidate["DeviceID"] as string, volume, StringComparison.OrdinalIgnoreCase)) return candidate;
                    candidate.Dispose();
                }
            }
            if (DateTime.UtcNow > deadline) throw new VaultException(VaultErrorKind.MountFailed, "BitLocker не увидел том сейфа");
            Thread.Sleep(500);
        }
    }

    static ManagementBaseObject Call(ManagementObject target, string method, Dictionary<string, object> arguments, string failure)
    {
        using var parameters = target.GetMethodParameters(method);
        foreach (var (key, value) in arguments) parameters[key] = value;
        var result = target.InvokeMethod(method, parameters, null);
        uint code = Convert.ToUInt32(result["ReturnValue"]);
        if (code == FailedAuthentication) throw new VaultException(VaultErrorKind.WrongPassword);
        if (code != 0) throw new VaultException(VaultErrorKind.MountFailed, $"{failure} (BitLocker: 0x{code:X8})");
        return result;
    }

    static uint Query(ManagementObject target, string method, string field)
    {
        var result = target.InvokeMethod(method, null, null);
        return Convert.ToUInt32(result[field]);
    }

    static void Unlock(ManagementObject encryptable, string password)
    {
        // Уже открыт (например, в прошлый раз) — пароль не нужен.
        if (Query(encryptable, "GetLockStatus", "LockStatus") == 0) return;
        Call(encryptable, "UnlockWithPassphrase", new() { ["Passphrase"] = password }, "BitLocker не открыл том");
    }

    /// <summary>Зашифрован целиком, защита включена, способ шифрования — AES, и есть хотя бы один пароль.</summary>
    static bool IsProtected(ManagementObject encryptable)
    {
        var conversion = encryptable.InvokeMethod("GetConversionStatus", null, null);
        if (Convert.ToUInt32(conversion["ConversionStatus"]) != 1 || Convert.ToUInt32(conversion["EncryptionPercentage"]) != 100) return false;
        if (Query(encryptable, "GetProtectionStatus", "ProtectionStatus") != 1) return false;
        if (Query(encryptable, "GetEncryptionMethod", "EncryptionMethod") == 0) return false;
        return Protectors(encryptable, ProtectorPassphrase).Count > 0;
    }

    static List<string> Protectors(ManagementObject encryptable, uint type)
    {
        using var parameters = encryptable.GetMethodParameters("GetKeyProtectors");
        parameters["KeyProtectorType"] = type;
        var result = encryptable.InvokeMethod("GetKeyProtectors", parameters, null);
        return (result["VolumeKeyProtectorID"] as string[] ?? []).ToList();
    }

    static void WaitFullyEncrypted(ManagementObject encryptable)
    {
        var deadline = DateTime.UtcNow.AddMinutes(10);
        while (DateTime.UtcNow < deadline)
        {
            var status = encryptable.InvokeMethod("GetConversionStatus", null, null);
            if (Convert.ToUInt32(status["ConversionStatus"]) == 1) return;
            Thread.Sleep(500);
        }
        throw new VaultException(VaultErrorKind.MountFailed, "BitLocker не закончил шифрование");
    }

    // MARK: Тома

    /// <summary>Том с данными на подключённом диске (самый большой основной раздел).</summary>
    static string DataVolume(int disk)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            var volume = PowerShellLine($$"""
                Get-Partition -DiskNumber {{disk}} | Where-Object { $_.Type -eq 'Basic' } | Sort-Object Size -Descending |
                    Select-Object -First 1 | ForEach-Object { $_.AccessPaths | Where-Object { $_ -like '\\?\Volume*' } | Select-Object -First 1 }
                """, allowEmpty: true);
            if (volume.Length > 0) return volume;
            if (DateTime.UtcNow > deadline) throw new VaultException(VaultErrorKind.MountFailed, "в образе не нашёлся раздел с данными");
            Thread.Sleep(500);
        }
    }

    /// <summary>Том уже подключённого образа; null — образ не подключён.</summary>
    static string? VolumeOfAttached(string image)
    {
        var target = Paths.Resolve(image);
        foreach (var volume in Native.AllVolumeGuidPaths())
        {
            if (Native.StorageBus(volume.TrimEnd('\\')) is not { bus: Native.BusType.FileBackedVirtual }) continue;
            if (VirtualDisks.BackingFile(volume) is { } backing && Paths.Same(Paths.Resolve(backing), target)
                && Native.DeviceNumber(volume.TrimEnd('\\')) is { PartitionNumber: > 0 } number)
            {
                // Служебный раздел MSR томом не бывает, так что первый найденный том и есть раздел с данными.
                _ = number;
                return volume;
            }
        }
        return null;
    }

    static string? MountPointOf(string volume) => Native.VolumeMountPoints(volume).FirstOrDefault(m => m.Length == 3);

    /// <summary>Свободная буква для сейфа: сначала S (Safe), дальше по алфавиту назад и вперёд.</summary>
    static string AssignLetter(string volume)
    {
        var used = new HashSet<char>(DriveInfo.GetDrives().Select(d => char.ToUpperInvariant(d.Name[0])));
        var order = "STUVWXYZRQPONMLKJIHGFED";
        foreach (var letter in order)
        {
            if (used.Contains(letter)) continue;
            var root = letter + @":\";
            if (Native.SetVolumeMountPointW(root, volume)) return root;
        }
        throw new VaultException(VaultErrorKind.MountFailed, "нет свободной буквы диска");
    }

    /// <summary>Корень тома — только для владельца (и системы): пока сейф открыт, его не должны читать
    /// другие учётные записи этого компьютера. Индексатор Windows внутрь тоже не заходит: иначе имена
    /// и содержимое файлов оказались бы в открытом индексе на системном диске.</summary>
    static void RestrictToOwner(string volume, string userSid)
    {
        try
        {
            var root = new DirectoryInfo(volume);
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            foreach (var sid in new[] { new SecurityIdentifier(userSid), new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                                        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
                security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
            security.SetOwner(new SecurityIdentifier(userSid));
            root.SetAccessControl(security);
            uint attributes = Native.GetFileAttributesW(volume);
            if (attributes != Native.INVALID_FILE_ATTRIBUTES)
                Native.SetFileAttributesW(volume, attributes | Native.FILE_ATTRIBUTE_NOT_CONTENT_INDEXED);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or SystemException)
        {
            throw new VaultException(VaultErrorKind.MountFailed, $"не удалось закрыть сейф от других пользователей этого компьютера: {ex.Message}");
        }
    }

    // MARK: PowerShell

    /// <summary>Строка в кавычках PowerShell: одинарные кавычки внутри удваиваются.</summary>
    static string Quote(string text) => "'" + text.Replace("'", "''") + "'";

    /// <summary>Сценарий без секретов; ответ — последняя непустая строка вывода.</summary>
    static string PowerShellLine(string script, bool allowEmpty = false)
    {
        var result = Runner.PowerShell(script, timeout: TimeSpan.FromMinutes(10));
        if (!result.Succeeded)
            throw new VaultException(VaultErrorKind.MountFailed, result.Stderr.Trim().Split('\n').LastOrDefault()?.Trim() ?? $"код {result.Status}");
        var line = result.Output.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0) ?? "";
        if (line.Length == 0 && !allowEmpty) throw new VaultException(VaultErrorKind.MountFailed, "PowerShell ничего не ответил");
        return line;
    }
}
