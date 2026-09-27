using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Offload.Core;

/// <summary>Запись о переносе. Поля и формат — те же, что у версии для Mac: журнал на диске
/// читается обеими.</summary>
public sealed record MoveRecord
{
    [JsonPropertyName("id")] public Guid Id { get; init; } = Guid.NewGuid();
    [JsonPropertyName("date")] public DateTime Date { get; init; } = DateTime.UtcNow;
    [JsonPropertyName("originalPath")] public string OriginalPath { get; init; } = "";
    [JsonPropertyName("archivedPath")] public string ArchivedPath { get; init; } = "";
    [JsonPropertyName("volumeName")] public string VolumeName { get; init; } = "";
    [JsonPropertyName("files")] public int Files { get; init; }
    [JsonPropertyName("bytes")] public long Bytes { get; init; }
    [JsonPropertyName("originalRemoved")] public bool OriginalRemoved { get; init; }
    [JsonPropertyName("restored")] public bool Restored { get; init; }
    /// <summary>Пояснение для человека: например, что архив упакован в tar.</summary>
    [JsonPropertyName("note"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Note { get; init; }
    /// <summary>Архив лежит внутри сейфа (зашифрован). У старых записей поля нет — значит, открыто.</summary>
    [JsonPropertyName("inSafe"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public bool? InSafe { get; init; }

    [JsonIgnore] public bool IsEncrypted => InSafe == true;
    /// <summary>Перенос сделан на Mac: пути в нём — пути Mac.</summary>
    [JsonIgnore] public bool IsFromMac => OriginalPath.StartsWith('/');
    [JsonIgnore] public string OriginalName => Paths.Name(OriginalPath.Replace('/', '\\'));
}

/// <summary>Журнал переносов: на самом внешнем диске (чтобы вернуть данные на любом компьютере) и локальная копия.</summary>
public static class Journal
{
    public const string ManifestName = "manifest.json";
    /// <summary>Журнал с внешнего диска — непроверенные данные, поэтому размер ограничен.</summary>
    internal const int MaxManifestBytes = 20 * 1024 * 1024;

    public static string ManifestPath(VolumeInfo volume) => Path.Combine(volume.MountPoint, SafeMover.FolderName, ManifestName);

    /// <summary>Для проверок: локальный журнал в другом месте, чтобы не трогать настоящий.</summary>
    public static string? LocalOverride { get; set; }

    public static string LocalPath => LocalOverride ?? Path.Combine(Paths.LocalAppData, "Offload", "history.json");

    public enum StateKind { Missing, Records, Broken }

    public static (StateKind kind, List<MoveRecord> records) State(string path)
    {
        if (FileSystem.Stat(path) is not { } stat) return (StateKind.Missing, []);
        // Ссылка или папка на месте журнала — испорченный журнал, а не повод читать неизвестно что.
        if (!stat.IsRegularFile) return (StateKind.Broken, []);
        var data = SafeFile.Read(path, MaxManifestBytes);
        if (data == null) return (StateKind.Broken, []);
        try
        {
            var records = JsonSerializer.Deserialize<List<MoveRecord>>(data, Options);
            return records == null ? (StateKind.Broken, []) : (StateKind.Records, records);
        }
        catch (JsonException) { return (StateKind.Broken, []); }
    }

    public static List<MoveRecord> Load(string path) => State(path) is (StateKind.Records, var records) ? records : [];

    /// <summary>Записи с диска. Буквы дисков в Windows меняются от подключения к подключению («E:» сегодня,
    /// «F:» завтра), а журнал на диске мог написать и Mac («/Volumes/SSD/…»). Поэтому путь архива,
    /// который указывает на другой корень, переписывается на этот диск, если архив лежит здесь.</summary>
    public static List<MoveRecord> Records(VolumeInfo volume) => Load(ManifestPath(volume)).Select(r => Rebase(r, volume)).ToList();

    public static List<MoveRecord> LocalRecords() => Load(LocalPath);

    /// <summary>Путь архива относительно корня его диска: «Offload\Фото» для «E:\Offload\Фото»
    /// и для «/Volumes/SSD/Offload/Фото».</summary>
    public static string? VolumeRelative(string archivedPath)
    {
        if (archivedPath.StartsWith("/Volumes/", StringComparison.Ordinal))
        {
            var rest = archivedPath["/Volumes/".Length..];
            int slash = rest.IndexOf('/');
            return slash < 0 ? null : rest[(slash + 1)..].Replace('/', '\\');
        }
        if (archivedPath.Length > 3 && archivedPath[1] == ':' && archivedPath[2] == '\\') return archivedPath[3..];
        return null;
    }

    public static MoveRecord Rebase(MoveRecord record, VolumeInfo volume)
    {
        if (Paths.IsInside(record.ArchivedPath, volume.MountPoint)) return record;
        if (VolumeRelative(record.ArchivedPath) is not { Length: > 0 } relative) return record;
        var candidate = Path.Combine(volume.MountPoint, relative);
        return FileSystem.Exists(candidate) ? record with { ArchivedPath = candidate } : record;
    }

    /// <summary>Запись из локального журнала — на диск с той же меткой, если архив нашёлся там.</summary>
    public static MoveRecord Rebase(MoveRecord record, IEnumerable<VolumeInfo> volumes)
    {
        if (FileSystem.Exists(record.ArchivedPath)) return record;
        foreach (var volume in volumes.Where(v => v.Name == record.VolumeName))
        {
            var moved = Rebase(record, volume);
            if (!ReferenceEquals(moved, record)) return moved;
        }
        return record;
    }

    /// <summary>Испорченный журнал переименовывается, а не переписывается: иначе одна неудачная
    /// запись (выдернули диск, правили файл руками) молча стёрла бы всю историю переносов.</summary>
    static void SetAside(string path)
    {
        var stamp = DateTime.UtcNow.ToString("yyyy-MM-ddTHH-mm-ssZ", CultureInfo.InvariantCulture);
        try { File.Move(path, path + ".broken-" + stamp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public static void Save(MoveRecord record, VolumeInfo volume)
    {
        var manifest = ManifestPath(volume);
        string[] paths = [manifest, LocalPath];
        var known = new Dictionary<string, List<MoveRecord>>(Paths.Comparer);
        var broken = new HashSet<string>(Paths.Comparer);
        foreach (var path in paths)
        {
            var (kind, records) = State(path);
            known[path] = records;
            if (kind == StateKind.Broken)
            {
                broken.Add(path);
                SetAside(path);
            }
        }
        // Журнал ведётся в двух копиях. Если одна испорчена, она восстанавливается из уцелевшей,
        // иначе запасная копия молча перестала бы быть запасной.
        var rescue = paths.SelectMany(p => known[p]).ToList();
        foreach (var path in paths)
        {
            var records = known[path];
            if (broken.Contains(path))
            {
                var seen = new HashSet<Guid>();
                records = rescue.Where(candidate =>
                    (!Paths.Same(path, manifest) || Paths.IsInside(candidate.ArchivedPath, volume.MountPoint)) && seen.Add(candidate.Id)).ToList();
            }
            int index = records.FindIndex(r => r.Id == record.Id);
            if (index >= 0) records[index] = record;
            else records.Add(record);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            WriteAtomically(path, JsonSerializer.SerializeToUtf8Bytes(records, Options));
        }
    }

    /// <summary>Убирает запись из журнала на диске — когда архив переехал в сейф и на открытой
    /// части диска его больше нет. Локальная копия журнала при этом не трогается:
    /// в ней запись уже обновлена и указывает на сейф.</summary>
    public static void Remove(Guid id, VolumeInfo volume)
    {
        var manifest = ManifestPath(volume);
        if (State(manifest) is not (StateKind.Records, var records) || records.All(r => r.Id != id)) return;
        records.RemoveAll(r => r.Id == id);
        WriteAtomically(manifest, JsonSerializer.SerializeToUtf8Bytes(records, Options));
    }

    /// <summary>Новый журнал пишется рядом и заменяет прежний одним переименованием: оборвётся запись —
    /// прежний журнал останется целым.</summary>
    static void WriteAtomically(string path, byte[] data)
    {
        var temporary = path + ".offload-" + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            SafeFile.CreateExclusive(temporary, data);
            File.Move(temporary, path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    public static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new Iso8601Converter(), new UpperGuidConverter() },
    };

    /// <summary>Даты как у JSONEncoder на Mac: «2026-09-27T10:15:00Z», без долей секунды.</summary>
    sealed class Iso8601Converter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
    }

    /// <summary>UUID заглавными буквами, как пишет Foundation.</summary>
    sealed class UpperGuidConverter : JsonConverter<Guid>
    {
        public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) => Guid.Parse(reader.GetString()!);

        public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
    }
}
