using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Offload.Core;

public enum MovePhase { Inspecting, Copying, Verifying, Removing }

public static class MovePhaseText
{
    public static string Title(this MovePhase phase) => phase switch
    {
        MovePhase.Inspecting => "Проверка",
        MovePhase.Copying => "Копирование",
        MovePhase.Verifying => "Сверка",
        _ => "Удаление оригинала",
    };
}

public readonly record struct MoveProgress(MovePhase Phase, long BytesDone, long BytesTotal, string Item)
{
    public double Fraction => BytesTotal > 0 ? Math.Min(1, (double)BytesDone / BytesTotal) : 0;
}

public enum MoveErrorKind { Blocked, NeedsConfirmation, Destination, UnsafeRecord, AlreadyExists, ContentMismatch }

public sealed class MoveException : Exception
{
    public MoveErrorKind Kind { get; }
    public IReadOnlyList<string> Details { get; }

    public MoveException(MoveErrorKind kind, string detail) : this(kind, [detail]) { }

    public MoveException(MoveErrorKind kind, IReadOnlyList<string> details) : base(Describe(kind, details))
    {
        Kind = kind;
        Details = details;
    }

    static string Describe(MoveErrorKind kind, IReadOnlyList<string> details) => kind switch
    {
        MoveErrorKind.Blocked => details[0],
        MoveErrorKind.NeedsConfirmation => "Нужно подтверждение: " + string.Join(" ", details),
        MoveErrorKind.Destination => string.Join(" ", details),
        MoveErrorKind.UnsafeRecord => $"Запись журнала выглядит небезопасной: {details[0]}",
        MoveErrorKind.AlreadyExists => $"«{details[0]}» уже существует — перезаписывать не буду.",
        _ => $"Содержимое не совпало с проверкой, ничего не удалено: {details[0]}. Проверьте ещё раз.",
    };
}

public sealed record MovePlan(string Source, ContentReport Content, Verdict Verdict, VolumeInfo Volume, DestinationCheck Check, string Target)
{
    public bool CanProceed => !Verdict.IsBlocked && Check.IsOK;
}

/// <summary>Итог возврата: сама запись и оговорки, о которых стоит сказать человеку.</summary>
public sealed record RestoreOutcome(MoveRecord Record, List<string> Notes, bool NeedsAttention);

/// <summary>Что дала сверка архива со списком сумм, записанным при переносе.</summary>
internal sealed class StoredChecksumReport
{
    public List<string> Notes { get; } = [];
    /// <summary>Архив отличается от того, каким его унесли, или сверить его не с чем.</summary>
    public bool HasDifferences { get; set; }
}

/// <summary>Перенос на внешний диск: копия → сверка SHA-256 → проверка, что оригинал не менялся → удаление оригинала.</summary>
public sealed class SafeMover(SafetyRules? rules = null)
{
    public const string FolderName = "Offload";
    public SafetyRules Rules { get; } = rules ?? new SafetyRules();

    // MARK: План

    public MovePlan Plan(string source, VolumeInfo volume, Func<bool>? isCancelled = null)
    {
        source = Paths.Normalize(source);
        var content = Inspector.Inspect(source, isCancelled: isCancelled);
        var locks = FileLocks.Scan(source, isCancelled);
        if (locks != null)
        {
            content.Undeletable = locks.DeniedCount;
            content.UndeletableExamples = [.. locks.Denied];
        }
        var verdict = Rules.FullVerdict(source, content, locks?.Holders ?? []);
        if (locks == null && !verdict.IsBlocked)
        {
            // Проверить не удалось — не делаем вид, что всё чисто.
            const string note = "Не удалось проверить, открыты ли файлы в других программах. Закройте программы, которые могут с ними работать.";
            verdict = Verdict.Caution([.. verdict.Notes, note]);
        }
        bool? symlinks = content.SymbolicLinks > 0 && volume.KeepsSymlinks
            ? Volumes.CanCreateSymlinks(Path.Combine(volume.MountPoint)) : null;
        var check = SafetyRules.CheckDestination(volume, Volumes.Info(source), content, symlinks);
        return new MovePlan(source, content, verdict, volume, check, TargetPath(source, volume));
    }

    /// <summary>Offload\&lt;путь относительно домашней папки&gt;: по архиву сразу видно, откуда объект.</summary>
    public string TargetPath(string source, VolumeInfo volume)
    {
        var path = Path.Combine(Paths.Resolve(Paths.Parent(source)), Paths.Name(source));
        string relative = Paths.Relative(path, Rules.Home)
                          ?? (Paths.Relative(path, Rules.Public) is { } shared ? Path.Combine("Public", shared) : Paths.Name(source));
        return Unique(Path.Combine(volume.MountPoint, FolderName, relative));
    }

    /// <summary>Кто держит файлы открытыми. null — проверить не удалось.</summary>
    public static List<string>? OpenFiles(string path) => FileLocks.Scan(path)?.Holders;

    // MARK: Перенос

    public MoveRecord Execute(MovePlan plan, bool deleteOriginal, bool acceptCautions, Func<bool>? isCancelled = null,
                              Action<MoveProgress>? progress = null)
    {
        isCancelled ??= () => false;
        if (plan.Verdict.IsBlocked) throw new MoveException(MoveErrorKind.Blocked, plan.Verdict.Reason!);
        if (plan.Verdict.IsCaution && !acceptCautions) throw new MoveException(MoveErrorKind.NeedsConfirmation, plan.Verdict.Notes);
        if (!plan.Check.IsOK) throw new MoveException(MoveErrorKind.Destination, plan.Check.Blockers);
        if (Exists(plan.Target)) throw new MoveException(MoveErrorKind.AlreadyExists, plan.Target);

        var source = plan.Source;
        progress?.Invoke(new MoveProgress(MovePhase.Inspecting, 0, 0, Paths.Name(source)));
        // План мог часами простоять в окне подтверждения, и за это время файлы успели открыть.
        var locks = AssertNotOpen(source);
        if (deleteOriginal && UndeletableReason(locks, source) is { } reason) throw new MoveException(MoveErrorKind.Blocked, reason);
        // Служебные файлы Проводника едут в копию вместе со всем остальным: в desktop.ini — значок и вид папки.
        var entries = TreeWalker.Walk(source, strict: true, isCancelled: isCancelled).entries;
        AssertMatches(entries, plan.Content);
        long total = entries.Sum(e => e.Size);

        var parent = Paths.Parent(plan.Target);
        Directory.CreateDirectory(parent);
        // Копия пишется под временным именем: при сбое удаляется только она, чужие файлы не трогаются.
        var partial = Path.Combine(parent, ".offload-partial-" + Guid.NewGuid().ToString().ToUpperInvariant());
        RemoveStalePartials(parent, partial);
        Dictionary<string, string> hashes;
        bool wroteModes = false, wroteChecksums = false;
        try
        {
            long copied = 0;
            var marker = new PartialMarker(partial);
            hashes = VerifiedCopy.CopyTree(entries, source, partial, keepAttributes: true, isCancelled: isCancelled,
                progress: (name, bytes) =>
                {
                    copied += bytes;
                    marker.Touch(name);
                    progress?.Invoke(new MoveProgress(MovePhase.Copying, copied, total, name));
                },
                didCreateRoot: _ => marker.Write());
            long verified = 0;
            VerifiedCopy.Verify(entries, hashes, partial, isCancelled, (name, bytes) =>
            {
                verified += bytes;
                progress?.Invoke(new MoveProgress(MovePhase.Verifying, verified, total, name));
            });
            VerifiedCopy.AssertUnchanged(entries, source);
            WriteModes(entries, plan.Target);
            wroteModes = true;
            // Список сумм пишется до переименования: иначе сбой записи оставил бы на диске архив,
            // о котором не знает журнал.
            SafeFile.CreateExclusive(ChecksumPath(plan.Target), Encoding.UTF8.GetBytes(VerifiedCopy.ChecksumList(hashes, Paths.Name(plan.Target))));
            wroteChecksums = true;
            // Метка снимается до переименования: в архив она попасть не должна.
            marker.Remove(entries.FirstOrDefault());
            FileSystem.RenameExclusive(partial, plan.Target);
        }
        catch
        {
            FileSystem.TryDeleteTree(partial);
            if (wroteModes) TryDelete(ModesPath(plan.Target));
            if (wroteChecksums) TryDelete(ChecksumPath(plan.Target));
            throw;
        }

        var record = new MoveRecord
        {
            OriginalPath = source,
            ArchivedPath = plan.Target,
            VolumeName = plan.Volume.Name,
            Files = hashes.Count,
            Bytes = total,
            InSafe = plan.Volume.IsEncryptedImage ? true : null,
        };
        Journal.Save(record, plan.Volume);
        if (deleteOriginal)
        {
            progress?.Invoke(new MoveProgress(MovePhase.Removing, total, total, Paths.Name(source)));
            VerifiedCopy.AssertUnchanged(entries, source);
            var again = AssertNotOpen(source);
            if (UndeletableReason(again, source) is { } late) throw new MoveException(MoveErrorKind.Blocked, late);
            FileSystem.DeleteTree(source);
            record = record with { OriginalRemoved = true };
            try { Journal.Save(record, plan.Volume); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
        return record;
    }

    // MARK: Зашифровать перенесённое

    /// <summary>Переносит архив, который уже лежит на внешнем диске открыто, внутрь сейфа.
    ///
    /// Та же дисциплина, что при переносе с компьютера: копия под временным именем, побайтовая
    /// сверка, и только потом открытый архив удаляется. Журнал переписывается до удаления:
    /// оборвись работа на удалении — запись уже указывает на копию в сейфе, и данные
    /// найдутся. Оговорка, которую надо сказать человеку честно: удалённые с флешки или SSD
    /// байты не затираются физически, их можно восстановить специальными средствами,
    /// пока контроллер диска их не перезапишет. Полную гарантию даёт только диск,
    /// зашифрованный целиком.</summary>
    public MoveRecord Relocate(MoveRecord record, VolumeInfo safe, Func<bool>? isCancelled = null, Action<MoveProgress>? progress = null)
    {
        isCancelled ??= () => false;
        if (!safe.IsEncryptedImage) throw new MoveException(MoveErrorKind.UnsafeRecord, "сейф не открыт");
        var (archived, _) = Validate(record);
        if (!Exists(archived)) throw new MoveException(MoveErrorKind.UnsafeRecord, $"архив не найден — подключите диск «{record.VolumeName}»");
        var host = Volumes.Info(archived);
        if (host == null || Paths.Same(host.MountPoint, safe.MountPoint) || Paths.IsInside(archived, safe.MountPoint))
            throw new MoveException(MoveErrorKind.UnsafeRecord, "архив уже в сейфе");
        // Внутри сейфа путь повторяет путь на диске, чтобы по архиву было видно, откуда он.
        var hostOffload = Path.Combine(host.MountPoint, FolderName);
        var relative = Paths.Relative(archived, hostOffload) ?? Paths.Relative(archived, host.MountPoint)!;
        var target = Path.Combine(safe.MountPoint, FolderName, relative);
        if (Exists(target)) throw new MoveException(MoveErrorKind.AlreadyExists, target);

        progress?.Invoke(new MoveProgress(MovePhase.Inspecting, 0, 0, Paths.Name(archived)));
        // Архивом пользуются на месте (папка моделей LM Studio): пока он открыт, переносить нельзя.
        AssertNotOpen(archived, strict: true);
        // «._»-двойники, которые Mac наплодил на exFAT, в сейф не везём. Настоящие файлы с такими именами едут как все.
        var stored = StoredChecksums(archived);
        var all = TreeWalker.Walk(archived, strict: true, isCancelled: isCancelled).entries;
        var entries = host.MayHaveAppleDouble ? all.Where(e => !IsGeneratedAppleDouble(e, archived, stored.Hashes)).ToList() : all;
        AssertMatches(entries, Inspector.Inspect(archived, isCancelled: isCancelled), all.Count - entries.Count);
        long total = entries.Sum(e => e.Size);
        if (total + (64L << 20) > safe.AvailableBytes)
            throw new MoveException(MoveErrorKind.Destination,
                $"В сейфе не хватает места: нужно {Format.Bytes(total)}, свободно {Format.Bytes(safe.AvailableBytes)}. Освободите место на диске «{host.Name}».");

        var parent = Paths.Parent(target);
        Directory.CreateDirectory(parent);
        var partial = Path.Combine(parent, ".offload-partial-" + Guid.NewGuid().ToString().ToUpperInvariant());
        RemoveStalePartials(parent, partial);
        try
        {
            long copied = 0;
            var marker = new PartialMarker(partial);
            var hashes = VerifiedCopy.CopyTree(entries, archived, partial, keepAttributes: host.KeepsAttributes, isCancelled: isCancelled,
                progress: (name, bytes) =>
                {
                    copied += bytes;
                    marker.Touch(name);
                    progress?.Invoke(new MoveProgress(MovePhase.Copying, copied, total, name));
                },
                didCreateRoot: _ => marker.Write());
            long verified = 0;
            VerifiedCopy.Verify(entries, hashes, partial, isCancelled, (name, bytes) =>
            {
                verified += bytes;
                progress?.Invoke(new MoveProgress(MovePhase.Verifying, verified, total, name));
            });
            marker.Remove(entries.FirstOrDefault());
            FileSystem.RenameExclusive(partial, target);
        }
        catch
        {
            FileSystem.TryDeleteTree(partial);
            throw;
        }
        // Открытый архив удаляется ниже, поэтому он должен быть ровно тем, что скопировано и сверено:
        // если в него писали, пока шло копирование, — копию в сейфе убираем, архив остаётся как был.
        try
        {
            VerifiedCopy.AssertUnchanged(all, archived);
            AssertNotOpen(archived, strict: true);
        }
        catch
        {
            FileSystem.TryDeleteTree(target);
            throw;
        }
        // Список сумм и атрибуты, записанные при переносе, едут вместе с архивом: возврат из сейфа
        // сверится с тем же списком, что и раньше. Только обычные файлы: ссылка на их месте
        // не должна утащить в сейф что-то с компьютера.
        foreach (var suffix in SidecarSuffixes)
        {
            var sidecar = archived + suffix;
            if (SafeFile.Read(sidecar, MaxSidecarBytes) is not { } data) continue;
            try { SafeFile.CreateExclusive(target + suffix, data); } catch (CopyException) { }
        }

        var moved = record with { ArchivedPath = target, VolumeName = safe.Name, InSafe = true };
        Journal.Save(moved, safe);
        try { Journal.Remove(record.Id, host); } catch (IOException) { } catch (UnauthorizedAccessException) { }

        progress?.Invoke(new MoveProgress(MovePhase.Removing, total, total, Paths.Name(archived)));
        FileSystem.DeleteTree(archived);
        foreach (var suffix in SidecarSuffixes) TryDelete(archived + suffix);
        return moved;
    }

    // MARK: Ручные переносы

    /// <summary>Регистрирует перенос, сделанный без Offload: папка или файл уже лежит на внешнем диске.
    /// Запись попадает в журнал, и вернуть данные можно как обычно.</summary>
    public MoveRecord ImportRecord(string archived, string original, bool originalRemoved, string? note = null)
    {
        var record = new MoveRecord
        {
            OriginalPath = Paths.Normalize(original),
            ArchivedPath = Paths.Normalize(archived),
            OriginalRemoved = originalRemoved,
            Note = note,
        };
        var (archivedPath, _) = Validate(record);
        if (!Exists(archivedPath)) throw new MoveException(MoveErrorKind.UnsafeRecord, $"на диске нет «{archivedPath}»");
        var volume = Volumes.Info(archivedPath);
        if (volume == null || Paths.Same(volume.MountPoint, Paths.SystemDrive) || !Volumes.IsExternal(volume.MountPoint))
            throw new MoveException(MoveErrorKind.UnsafeRecord, $"«{archivedPath}» лежит не на внешнем диске");
        var content = Inspector.Inspect(archivedPath);
        record = record with { VolumeName = volume.Name, Files = content.Files, Bytes = content.LogicalBytes };
        Journal.Save(record, volume);
        return record;
    }

    // MARK: Возврат

    /// <summary>Журнал лежит на внешнем диске, и его могли изменить. Прежде чем читать и писать
    /// по путям из него, убеждаемся, что они не выходят за разрешённые границы.</summary>
    public (string archived, string original) Validate(MoveRecord record)
    {
        if (record.IsFromMac)
            throw new MoveException(MoveErrorKind.UnsafeRecord,
                "перенос сделан на Mac — вернуть его можно в Offload для Mac. Архив лежит на диске, его можно скопировать и вручную.");
        var archived = record.ArchivedPath;
        var original = record.OriginalPath;
        if (!Paths.IsPlainLocal(archived) || !Paths.IsPlainLocal(original))
            throw new MoveException(MoveErrorKind.UnsafeRecord, "пути должны быть полными, на диске с буквой и без «..»");
        // Не только папка Offload: переносы, сделанные вручную, лежат где угодно на внешнем диске.
        if (Paths.Same(Paths.Root(archived), Paths.SystemDrive) || Paths.Parts(archived[3..]).Length < 1)
            throw new MoveException(MoveErrorKind.UnsafeRecord, "архив должен лежать на внешнем диске");
        if (!Paths.Same(Paths.Resolve(archived), archived))
            throw new MoveException(MoveErrorKind.UnsafeRecord, "путь к архиву проходит через ссылку или точку соединения");
        // PathVerdict разворачивает ссылки и в пути, которого ещё нет: без этого подложенная
        // в журнал запись вида «Documents\Фото\old\Startup\…», где old — ссылка на AppData,
        // прошла бы все проверки и записала бы файл в автозагрузку.
        var verdict = Rules.PathVerdict(original);
        if (verdict.IsBlocked) throw new MoveException(MoveErrorKind.UnsafeRecord, verdict.Reason!);
        return (archived, original);
    }

    /// <summary>Имя метки внутри «.offload-partial-…»: по ней видно, что копирование идёт прямо сейчас.</summary>
    internal const string PartialLockName = ".offload-lock";

    /// <summary>Метка «здесь работает Offload», которую кладут внутрь своей partial-папки.
    ///
    /// По одной дате папки «свежесть» остатка не определить: пока копирование идёт в подпапках, дата
    /// корня не меняется, а CopyTree в конце и вовсе ставит корню дату оригинала. Соседний экземпляр
    /// Offload мог бы принять идущее копирование за мусор и стереть его вместе с уже скопированными данными.</summary>
    internal sealed class PartialMarker(string partial)
    {
        string? lastTop;
        DateTime lastWrite = DateTime.MinValue;
        string PathOf => Path.Combine(partial, PartialLockName);

        public void Write()
        {
            lastWrite = DateTime.UtcNow;
            try { File.WriteAllText(PathOf, LockText(lastWrite)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        /// <summary>Один огромный файл может копироваться сутками, и тогда смены имени верхнего уровня
        /// не случится ни разу — поэтому ещё и по времени.</summary>
        public void Touch(string relative)
        {
            var top = relative.Split('\\', 2)[0];
            if (top == lastTop && DateTime.UtcNow - lastWrite <= TimeSpan.FromMinutes(5)) return;
            lastTop = top;
            Write();
        }

        /// <summary>Снимает метку перед переименованием копии на место и возвращает корню дату и атрибуты оригинала.</summary>
        public void Remove(TreeEntry? root)
        {
            try
            {
                if (FileSystem.Exists(PathOf))
                {
                    FileSystem.ClearReadOnly(PathOf);
                    File.Delete(PathOf);
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            if (root != null) VerifiedCopy.ApplyMetadata(partial, root, 0);
        }
    }

    internal readonly record struct PartialLock(int Pid, DateTime Date, string Host);

    internal static string HostIdentifier => Environment.MachineName;

    internal static string LockText(DateTime date) =>
        $"{Environment.ProcessId} {(date - DateTime.UnixEpoch).TotalSeconds.ToString(CultureInfo.InvariantCulture)} {HostIdentifier}\n";

    internal static PartialLock? ReadPartialLock(string partial)
    {
        if (SafeFile.Read(Path.Combine(partial, PartialLockName), 4096) is not { } data) return null;
        var fields = Encoding.UTF8.GetString(data).Trim().Split(' ', 3);
        if (fields.Length < 2 || !int.TryParse(fields[0], out var pid) || pid <= 0
            || !double.TryParse(fields[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)) return null;
        return new PartialLock(pid, DateTime.UnixEpoch.AddSeconds(seconds), fields.Length > 2 ? fields[2] : "");
    }

    /// <summary>Процесса с таким номером больше нет.</summary>
    internal static bool ProcessIsGone(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.HasExited;
        }
        catch (ArgumentException) { return true; }
        catch (InvalidOperationException) { return true; }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    /// <summary>За остатком точно никто не стоит. Метку наш Offload обновляет по ходу работы, поэтому
    /// «её не трогали сутки» означает, что копирования нет. Свежая метка чужого компьютера бережётся
    /// до тех же суток: там прямо сейчас может идти копирование.</summary>
    internal static bool PartialIsAbandoned(string path, FileStat stat, TimeSpan age)
    {
        if (ReadPartialLock(path) is not { } lockInfo)
            return stat.Modified is { } modified && DateTime.UtcNow - modified > age;
        if (DateTime.UtcNow - lockInfo.Date > age) return true;
        if (!lockInfo.Host.Equals(HostIdentifier, StringComparison.OrdinalIgnoreCase)) return false;
        return ProcessIsGone(lockInfo.Pid);
    }

    /// <summary>Остатки прерванных операций: если во время копирования выйти из программы или выдернуть
    /// диск, папка «.offload-partial-…» остаётся лежать рядом и место не возвращается. Свою папку не трогаем никогда.</summary>
    internal static void RemoveStalePartials(string parent, string? own = null, TimeSpan? olderThan = null)
    {
        var age = olderThan ?? TimeSpan.FromDays(1);
        List<string> names;
        try { names = FileSystem.Names(parent); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return; }
        foreach (var name in names.Where(n => n.StartsWith(".offload-partial-", StringComparison.Ordinal)))
        {
            if (own != null && Paths.Name(own) == name) continue;
            var path = Path.Combine(parent, name);
            if (FileSystem.Stat(path) is not { IsRegularDirectory: true } stat || !PartialIsAbandoned(path, stat, age)) continue;
            FileSystem.TryDeleteTree(path);
        }
    }

    public RestoreOutcome Restore(MoveRecord record, bool deleteArchive, Func<bool>? isCancelled = null, Action<MoveProgress>? progress = null)
    {
        isCancelled ??= () => false;
        var (archived, original) = Validate(record);
        // Программа могла оставить на старом месте пустую папку (так делает LM Studio с папкой моделей) — её можно заменить.
        if (Exists(original) && !IsEmptyDirectory(original)) throw new MoveException(MoveErrorKind.AlreadyExists, original);
        var volume = Volumes.Info(archived);
        if (volume == null || !Exists(archived))
            throw new MoveException(MoveErrorKind.UnsafeRecord, $"архив не найден — подключите диск «{record.VolumeName}»");
        // Место с оговорками (скрытые папки программ и т. п.) — туда кладут то, что программа потом читает
        // и исполняет. Такой возврат принимаем, только если перенос сделан на этом компьютере: локальный
        // журнал в AppData подложить с внешнего диска нельзя.
        if (Rules.PathVerdict(original).IsCaution
            && !Journal.LocalRecords().Any(r => r.Id == record.Id && Paths.Same(r.OriginalPath, record.OriginalPath)))
            throw new MoveException(MoveErrorKind.UnsafeRecord,
                $"«{original}» — место, откуда программы читают настройки и код, а запись об этом переносе есть только в журнале на диске, не на этом компьютере. Если архив ваш, скопируйте его вручную.");

        // Служебные «._»-двойники, которые Mac сам наплодил рядом с файлами на exFAT, обратно не везём.
        var stored = StoredChecksums(archived);
        var all = TreeWalker.Walk(archived, strict: true, isCancelled: isCancelled).entries;
        var entries = volume.MayHaveAppleDouble ? all.Where(e => !IsGeneratedAppleDouble(e, archived, stored.Hashes)).ToList() : all;
        int skipped = all.Count - entries.Count;
        AssertMatches(entries, Inspector.Inspect(archived, isCancelled: isCancelled), skipped);
        long total = entries.Sum(e => e.Size);

        var parent = Paths.Parent(original);
        Directory.CreateDirectory(parent);
        var partial = Path.Combine(parent, ".offload-partial-" + Guid.NewGuid().ToString().ToUpperInvariant());
        RemoveStalePartials(parent, partial);
        var notes = new List<string>();
        bool attention = false;
        try
        {
            long copied = 0;
            var marker = new PartialMarker(partial);
            // «Системный» из недоверенного архива не восстанавливаем.
            var hashes = VerifiedCopy.CopyTree(entries, archived, partial, keepAttributes: volume.KeepsAttributes,
                attributeMask: TreeWalker.KeptAttributes & ~Native.FILE_ATTRIBUTE_SYSTEM, isCancelled: isCancelled,
                progress: (name, bytes) =>
                {
                    copied += bytes;
                    marker.Touch(name);
                    progress?.Invoke(new MoveProgress(MovePhase.Copying, copied, total, name));
                },
                didCreateRoot: _ => marker.Write());
            // Сверка с тем, что было записано при переносе, — только чтобы рассказать человеку, что в архиве
            // изменилось. Отказывать из-за этого нельзя: архив на внешнем диске живёт своей жизнью, и отказ
            // вернуть данные — это потеря доступа к ним.
            var report = CheckStoredChecksums(hashes, stored, archived);
            notes.AddRange(report.Notes);
            attention |= report.HasDifferences;
            long verified = 0;
            VerifiedCopy.Verify(entries, hashes, partial, isCancelled, (name, bytes) =>
            {
                verified += bytes;
                progress?.Invoke(new MoveProgress(MovePhase.Verifying, verified, total, name));
            });
            var restoredPaths = new HashSet<string>(entries.Where(e => !e.IsLink).Select(e => e.RelativePath), Paths.Comparer);
            ApplyModes(ModesPath(archived), partial, restoredPaths);
            marker.Remove(entries.FirstOrDefault());
            if (Exists(original))
            {
                if (!IsEmptyDirectory(original)) throw new MoveException(MoveErrorKind.AlreadyExists, original);
                RemoveEmptyDirectory(original);
            }
            FileSystem.RenameExclusive(partial, original);
        }
        catch
        {
            FileSystem.TryDeleteTree(partial);
            throw;
        }
        var updated = record with { Restored = true };
        if (deleteArchive)
        {
            // Данные уже на компьютере и сверены. Неудача с удалением архива — повод сказать об этом,
            // а не объявить весь возврат провалившимся.
            try
            {
                // Удаляется ровно то, что вернулось: если в архив писали, пока шёл возврат, или его держит программа — архив остаётся.
                try { VerifiedCopy.AssertUnchanged(all, archived); }
                catch (CopyException) { throw new MoveException(MoveErrorKind.Blocked, "пока шёл возврат, в архиве что-то изменилось, и вернулось не всё новое."); }
                AssertNotOpen(archived, strict: true);
                FileSystem.DeleteTree(archived);
                foreach (var suffix in SidecarSuffixes) TryDelete(archived + suffix);
            }
            catch (Exception ex) when (ex is MoveException or IOException or UnauthorizedAccessException or CopyException)
            {
                notes.Add($"Данные вернулись на компьютер и сверены, а архив удалить не удалось: {ex.Message} Он остался в «{archived}» — удалите его сами, когда будет удобно.");
                attention = true;
            }
        }
        try { Journal.Save(updated, volume); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        return new RestoreOutcome(updated, notes, attention);
    }

    /// <summary>Сверяет посчитанное при чтении архива с файлом «&lt;архив&gt;.sha256», записанным при переносе,
    /// и рассказывает человеку, чем архив отличается от того, каким его унесли. Только оговорки, никаких отказов.
    /// Сверка идёт по множествам путей в обе стороны: подложенный в архив файл в списке не значится.</summary>
    internal static StoredChecksumReport CheckStoredChecksums(IReadOnlyDictionary<string, string> hashes, StoredChecksumList list, string archive)
    {
        static bool IsJunk(string path) => Inspector.ExplorerJunk.Contains(Path.GetFileName(path));
        string Name(string path) => path.Length == 0 ? Paths.Name(archive) : path;
        string Listing(IEnumerable<string> paths, int limit) => string.Join(", ", paths.Take(limit).Select(Name));

        var present = new HashSet<string>(hashes.Keys.Where(k => !IsJunk(k)), Paths.Comparer);
        var report = new StoredChecksumReport();
        switch (list.Kind)
        {
            case StoredChecksumKind.Missing:
                report.Notes.Add($"Рядом с архивом нет списка контрольных сумм, записанного при переносе, — сверить архив с его прежним состоянием не с чем. Все {present.Count} файлов сверены с тем, что лежит на диске сейчас, и вернулись такими.");
                report.HasDifferences = true;
                return report;
            case StoredChecksumKind.Unreadable:
                report.Notes.Add($"Список контрольных сумм рядом с архивом не читается — сверить архив с его прежним состоянием не с чем. Все {present.Count} файлов сверены с тем, что лежит на диске сейчас, и вернулись такими.");
                report.HasDifferences = true;
                return report;
        }
        var stored = list.Hashes!;
        var expected = new HashSet<string>(stored.Keys.Where(k => !IsJunk(k)), Paths.Comparer);
        var common = present.Intersect(expected, Paths.Comparer).ToList();
        var changed = common.Where(p => stored[p] != hashes[p]).OrderBy(p => p, StringComparer.Ordinal).ToList();
        var extra = present.Except(expected, Paths.Comparer).OrderBy(p => p, StringComparer.Ordinal).ToList();
        var missing = expected.Except(present, Paths.Comparer).OrderBy(p => p, StringComparer.Ordinal).ToList();
        // Первым делом — главное: сверено со списком переноса столько-то из стольких-то.
        report.Notes.Add($"Со списком, записанным при переносе, сверено {common.Count - changed.Count} файлов из {present.Count} в архиве.");
        if (changed.Count > 0)
            report.Notes.Add($"С момента переноса на диске изменилось файлов: {changed.Count} ({Listing(changed, 5)}). Вернулось то, что лежит в архиве сейчас, — оно сверено побайтово.");
        if (extra.Count > 0)
            report.Notes.Add($"В архиве появилось {extra.Count} файлов, которых при переносе не было ({Listing(extra, 5)}). Они тоже вернулись, но сверить их не с чем — откуда они, программа не знает.");
        if (missing.Count > 0)
            report.Notes.Add($"В архиве не хватает {missing.Count} файлов из списка, записанного при переносе ({Listing(missing, 3)}). Остальное сверено и возвращено.");
        report.HasDifferences = changed.Count > 0 || extra.Count > 0 || missing.Count > 0;
        return report;
    }

    // MARK: Служебное

    /// <summary>Независимая сверка двух обходов — TreeWalker и Inspector написаны по-разному.
    /// Если они разошлись, содержимое изменилось с момента проверки или один из обходов что-то пропустил;
    /// удалять оригинал в такой ситуации нельзя. Служебные файлы Проводника вычитаются с обеих сторон.</summary>
    internal static void AssertMatches(IReadOnlyList<TreeEntry> entries, ContentReport content, int skippedFiles = 0)
    {
        int walkedJunk = entries.Count(e => e.IsFile && Inspector.ExplorerJunk.Contains(e.Name));
        int files = entries.Count(e => e.IsFile) - walkedJunk + skippedFiles;
        int expectedFiles = content.Files - content.ExplorerJunkFiles;
        int directories = entries.Count(e => e.IsDirectory);
        int links = entries.Count(e => e.IsLink);
        if (files != expectedFiles || directories != content.Directories || links != content.SymlinkCount)
            throw new MoveException(MoveErrorKind.ContentMismatch,
                $"проверка насчитала файлов {expectedFiles}, папок {content.Directories}, ссылок {content.SymlinkCount}, а обход — {files}, {directories} и {links}");
    }

    internal static bool Exists(string path) => FileSystem.Exists(path);

    /// <summary>Почему оригинал нельзя удалить целиком — или null. Удаление остановилось бы на первом файле
    /// без права на удаление и оставило бы оригинал удалённым наполовину, а возврат потом отказал бы:
    /// «уже существует». Поэтому проверяем до того, как удалить хоть что-то.</summary>
    internal static string? UndeletableReason(LockReport? locks, string source)
    {
        if (locks == null || locks.DeniedCount == 0) return null;
        if (locks.Denied.Contains(Paths.Name(source)) && locks.DeniedCount == 1)
            return $"Оригинал не удалить: нет права на удаление «{Paths.Name(source)}». Копия на диске цела, оригинал не тронут.";
        return $"Оригинал не удалить целиком: у части файлов нет права на удаление ({string.Join(", ", locks.Denied.Take(3))}). Ничего не удалено; перенесите без удаления оригинала или выдайте права.";
    }

    /// <summary>Предел для служебных файлов рядом с архивом: они лежат на недоверенном диске.</summary>
    internal const int MaxSidecarBytes = 200 * 1024 * 1024;

    internal enum StoredChecksumKind { Missing, Unreadable, List }

    internal sealed record StoredChecksumList(StoredChecksumKind Kind, Dictionary<string, string>? Hashes = null);

    internal static StoredChecksumList StoredChecksums(string archive)
    {
        var path = ChecksumPath(archive);
        if (!Exists(path)) return new(StoredChecksumKind.Missing);
        if (SafeFile.Read(path, MaxSidecarBytes) is not { } data) return new(StoredChecksumKind.Unreadable);
        var hashes = VerifiedCopy.ParseChecksumList(Encoding.UTF8.GetString(data), Paths.Name(archive));
        return hashes == null ? new(StoredChecksumKind.Unreadable) : new(StoredChecksumKind.List, hashes);
    }

    /// <summary>Служебный «._»-двойник, который Mac сам кладёт рядом с файлом на exFAT. Признаков три,
    /// и нужны все: рядом лежит файл, к которому он относится; его нет в списке сумм, записанном при переносе;
    /// и он начинается с сигнатуры AppleDouble.</summary>
    internal static bool IsGeneratedAppleDouble(TreeEntry entry, string root, IReadOnlyDictionary<string, string>? listed)
    {
        var name = entry.Name;
        if (!entry.IsFile || !name.StartsWith("._", StringComparison.Ordinal) || name.Length <= 2) return false;
        if (listed != null && listed.ContainsKey(entry.RelativePath)) return false;
        var sibling = Path.Combine(Path.GetDirectoryName(entry.RelativePath) ?? "", name[2..]);
        if (!Exists(Path.Combine(root, sibling))) return false;
        return HasAppleDoubleMagic(Path.Combine(root, entry.RelativePath));
    }

    internal static bool HasAppleDoubleMagic(string path)
    {
        var data = SafeFile.Read(path, 64 * 1024 * 1024);
        return data is { Length: >= 4 } && data[0] == 0x00 && data[1] == 0x05 && data[2] == 0x16 && data[3] == 0x07;
    }

    /// <summary>Файлы держит другая программа — удалять и копировать их нельзя.</summary>
    /// <param name="strict">true — если проверить не удалось, тоже отказ.</param>
    internal static LockReport? AssertNotOpen(string path, bool strict = false)
    {
        var report = FileLocks.Scan(path);
        if (report == null)
        {
            if (strict) throw new MoveException(MoveErrorKind.Blocked, $"Не удалось проверить, открыты ли файлы «{Paths.Name(path)}» в других программах. Повторите чуть позже.");
            return null;
        }
        if (report.Holders.Count > 0)
            throw new MoveException(MoveErrorKind.Blocked, $"Файлы сейчас открыты: {string.Join(", ", report.Holders.Take(3))}. Закройте программу и повторите.");
        return report;
    }

    /// <summary>Настоящая папка (не ссылка), в которой нет ничего, кроме служебных файлов Проводника.</summary>
    internal static bool IsEmptyDirectory(string path)
    {
        if (FileSystem.Stat(path) is not { IsRegularDirectory: true }) return false;
        try { return FileSystem.Names(path).All(Inspector.ExplorerJunk.Contains); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }

    /// <summary>RemoveDirectory не удалит папку, в которой успело что-то появиться.</summary>
    internal static void RemoveEmptyDirectory(string path)
    {
        foreach (var junk in Inspector.ExplorerJunk)
        {
            var file = Path.Combine(path, junk);
            if (FileSystem.IsRegularFile(file))
            {
                FileSystem.ClearReadOnly(file);
                Native.SetFileAttributesW(Native.Long(file), Native.FILE_ATTRIBUTE_NORMAL);
                File.Delete(file);
            }
        }
        FileSystem.ClearReadOnly(path);
        if (!Native.RemoveDirectoryW(Native.Long(path))) throw new MoveException(MoveErrorKind.AlreadyExists, path);
    }

    /// <summary>Спутники архива: список сумм и атрибуты. «.modes.json» пишет версия для Mac — его тоже узнаём.</summary>
    internal static readonly string[] SidecarSuffixes = [".sha256", ".attrs.json", ".modes.json"];

    /// <summary>Свободное имя — и для самого архива, и для его спутников: оставшийся от удалённого архива
    /// «.attrs.json» иначе срывал бы каждый следующий перенос, а подложенный «.sha256» принимал бы запись.</summary>
    internal static string Unique(string path)
    {
        static bool IsFree(string candidate) => !Exists(candidate) && SidecarSuffixes.All(s => !Exists(candidate + s));
        if (IsFree(path)) return path;
        var parent = Paths.Parent(path);
        var name = Paths.Name(path);
        var ext = Path.GetExtension(name);
        var stem = ext.Length > 0 ? name[..^ext.Length] : name;
        for (int number = 2; ; number++)
        {
            var candidate = Path.Combine(parent, $"{stem} ({number}){ext}");
            if (IsFree(candidate)) return candidate;
        }
    }

    internal static string ChecksumPath(string item) => item + ".sha256";

    internal static string ModesPath(string item) => item + ".attrs.json";

    /// <summary>Атрибуты («только чтение», «скрытый») сохраняются рядом с архивом и возвращаются при восстановлении.</summary>
    internal static void WriteModes(IReadOnlyList<TreeEntry> entries, string item)
    {
        var modes = entries.Where(e => !e.IsLink && e.Attributes != 0)
                           .ToDictionary(e => e.RelativePath.Replace('\\', '/'), e => (int)e.Attributes);
        SafeFile.CreateExclusive(ModesPath(item), JsonSerializer.SerializeToUtf8Bytes(modes));
    }

    /// <summary>false — списка атрибутов рядом с архивом нет или он не читается.</summary>
    internal static bool ApplyModes(string path, string root, IReadOnlySet<string> allowed)
    {
        if (SafeFile.Read(path, MaxSidecarBytes) is not { } data) return false;
        Dictionary<string, int>? modes;
        try { modes = JsonSerializer.Deserialize<Dictionary<string, int>>(data); }
        catch (JsonException) { return false; }
        if (modes == null) return false;
        foreach (var (key, value) in modes.OrderByDescending(p => p.Key.Length))
        {
            var relative = key.Replace('/', '\\');
            // Только объекты, которые обход действительно восстановил: путь через подложенную в архив
            // ссылку сюда не попадёт, и атрибуты чужого файла не изменятся.
            if (!allowed.Contains(relative) || relative.Contains("..") || Path.IsPathRooted(relative)) continue;
            var target = relative.Length == 0 ? root : Path.Combine(root, relative);
            if (FileSystem.Stat(target) is not { IsLink: false } stat) continue;
            uint keep = (uint)value & TreeWalker.KeptAttributes & ~Native.FILE_ATTRIBUTE_SYSTEM;
            uint result = (stat.Attributes & ~(TreeWalker.KeptAttributes | Native.FILE_ATTRIBUTE_DIRECTORY | Native.FILE_ATTRIBUTE_REPARSE_POINT)) | keep;
            Native.SetFileAttributesW(Native.Long(target), result == 0 ? Native.FILE_ATTRIBUTE_NORMAL : result);
        }
        return true;
    }

    static void TryDelete(string path)
    {
        try
        {
            if (FileSystem.IsRegularFile(path))
            {
                FileSystem.ClearReadOnly(path);
                File.Delete(path);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
