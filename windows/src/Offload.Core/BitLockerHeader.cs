using System.Buffers.Binary;
using System.Text;

namespace Offload.Core;

/// <summary>Что известно о шифровании образа, не открывая его: то же, что на Mac даёт <c>hdiutil isencrypted</c>.</summary>
public sealed record EncryptionInfo(bool Encrypted, int PassphraseCount, int? Version, string? Uuid, bool HasClearKey = false)
{
    /// <summary>Зашифрован, есть хотя бы один пароль, и нет «открытого ключа», при котором BitLocker
    /// приостановлен и данные читаются без пароля.</summary>
    public bool OpensWithPassword => Encrypted && PassphraseCount > 0 && !HasClearKey;
}

/// <summary>Заголовок BitLocker внутри тома: подпись «-FVE-FS-» в загрузочном секторе и три копии метаданных
/// по 64 КБ. В метаданных — GUID тома и ключи тома, зашифрованные каждым способом защиты (пароль, ключ
/// восстановления…). Ключ шифрования данных от смены пароля не меняется, поэтому копия метаданных,
/// снятая раньше, открывает сейф тем паролем, что действовал тогда, — как копия заголовка VeraCrypt.</summary>
public static class BitLockerHeader
{
    public const int BlockRegion = 64 * 1024;
    const ushort EntryVolumeMasterKey = 0x0002;
    const ushort ProtectionClearKey = 0x0000;
    const ushort ProtectionPassword = 0x2000;

    public sealed record Layout(long PartitionOffset, long[] BlockOffsets, Guid VolumeGuid, int Version,
                                int PassphraseCount, bool HasClearKey, int ProtectorCount);

    /// <summary>Разбирает заголовок тома в образе; null — BitLocker там нет или заголовок не читается.</summary>
    public static Layout? Read(Vhdx disk)
    {
        if (disk.DataPartition() is not { } partition) return null;
        var boot = disk.Read(partition.offset, 512);
        if (Encoding.ASCII.GetString(boot, 3, 8) != "-FVE-FS-") return null;
        var offsets = new long[3];
        for (int i = 0; i < 3; i++) offsets[i] = (long)BinaryPrimitives.ReadUInt64LittleEndian(boot.AsSpan(0xB0 + i * 8));
        if (offsets.Any(o => o <= 0 || o + BlockRegion > partition.size)) return null;
        // Копии равноправны: берём первую, что разбирается.
        foreach (var offset in offsets)
        {
            var block = disk.Read(partition.offset + offset, BlockRegion);
            if (Parse(block) is not { } parsed) continue;
            return new Layout(partition.offset, offsets, parsed.guid, parsed.version, parsed.passwords, parsed.clear, parsed.protectors);
        }
        return null;
    }

    static (Guid guid, int version, int passwords, bool clear, int protectors)? Parse(byte[] block)
    {
        if (Encoding.ASCII.GetString(block, 0, 8) != "-FVE-FS-") return null;
        int version = BinaryPrimitives.ReadUInt16LittleEndian(block.AsSpan(10));
        if (version != 2) return null;
        int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(block.AsSpan(64));
        int headerSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(block.AsSpan(72));
        if (headerSize != 48 || size < headerSize || 64 + size > block.Length) return null;
        var guid = new Guid(block.AsSpan(80, 16));
        int passwords = 0, protectors = 0;
        bool clear = false;
        int position = 64 + headerSize;
        int end = 64 + size;
        while (position + 8 <= end)
        {
            int entrySize = BinaryPrimitives.ReadUInt16LittleEndian(block.AsSpan(position));
            if (entrySize < 8 || position + entrySize > end) break;
            ushort type = BinaryPrimitives.ReadUInt16LittleEndian(block.AsSpan(position + 2));
            if (type == EntryVolumeMasterKey && entrySize >= 36)
            {
                protectors++;
                ushort protection = BinaryPrimitives.ReadUInt16LittleEndian(block.AsSpan(position + 34));
                if (protection == ProtectionPassword) passwords++;
                if (protection == ProtectionClearKey) clear = true;
            }
            position += entrySize;
        }
        return (guid, 2, passwords, clear, protectors);
    }

    /// <summary>Сведения о шифровании закрытого образа; null — образ не читается как VHDX.</summary>
    public static EncryptionInfo? Info(string image)
    {
        using var disk = Vhdx.Open(image);
        if (disk == null) return null;
        try
        {
            if (Read(disk) is not { } layout) return new EncryptionInfo(false, 0, null, null);
            return new EncryptionInfo(true, layout.PassphraseCount, layout.Version, layout.VolumeGuid.ToString("D").ToUpperInvariant(),
                                      layout.HasClearKey);
        }
        catch (Exception ex) when (ex is IOException or ArgumentException) { return null; }
    }

    /// <summary>Копия заголовка: три блока метаданных по 64 КБ ровно в том виде, как они лежат на диске.</summary>
    public static (Layout layout, byte[][] blocks) Snapshot(string image)
    {
        using var disk = Vhdx.Open(image) ?? throw new IOException("образ не читается как VHDX");
        var layout = Read(disk) ?? throw new IOException("в образе нет заголовка BitLocker");
        var blocks = layout.BlockOffsets.Select(o => disk.Read(layout.PartitionOffset + o, BlockRegion)).ToArray();
        return (layout, blocks);
    }

    /// <summary>Где лежат блоки метаданных — по загрузочному сектору, даже если сами блоки испорчены.
    /// Смещения null, если испорчен и загрузочный сектор.</summary>
    public static (long partitionOffset, long partitionSize, long[]? offsets) Locate(string image)
    {
        using var disk = Vhdx.Open(image) ?? throw new IOException("образ не читается как VHDX");
        var partition = disk.DataPartition() ?? throw new IOException("в образе нет раздела с данными");
        var boot = disk.Read(partition.offset, 512);
        if (Encoding.ASCII.GetString(boot, 3, 8) != "-FVE-FS-") return (partition.offset, partition.size, null);
        var offsets = Enumerable.Range(0, 3).Select(i => (long)BinaryPrimitives.ReadUInt64LittleEndian(boot.AsSpan(0xB0 + i * 8))).ToArray();
        return (partition.offset, partition.size, offsets.All(o => o > 0 && o + BlockRegion <= partition.size) ? offsets : null);
    }

    /// <summary>Байты по местам блоков метаданных — какими бы они сейчас ни были.</summary>
    public static byte[][] ReadRaw(string image, long partitionOffset, long[] offsets)
    {
        using var disk = Vhdx.Open(image) ?? throw new IOException("образ не читается как VHDX");
        return offsets.Select(o => disk.Read(partitionOffset + o, BlockRegion)).ToArray();
    }

    /// <summary>GUID тома из блоков метаданных; null — ни один блок не разбирается.</summary>
    public static Guid? VolumeGuid(IEnumerable<byte[]> blocks) =>
        blocks.Select(Parse).FirstOrDefault(p => p != null)?.guid;

    /// <summary>Кладёт блоки метаданных на место. Образ должен быть закрыт.</summary>
    public static void Write(string image, long partitionOffset, long[] offsets, byte[][] blocks)
    {
        using var disk = Vhdx.Open(image, writable: true) ?? throw new IOException("образ не читается как VHDX");
        for (int i = 0; i < offsets.Length; i++) disk.Write(partitionOffset + offsets[i], blocks[i]);
    }
}
