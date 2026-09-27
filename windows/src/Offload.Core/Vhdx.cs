using System.Buffers.Binary;

namespace Offload.Core;

/// <summary>Чтение (и точечная запись) виртуального диска VHDX прямо из файла, без подключения
/// и без прав администратора — по спецификации MS-VHDX.
///
/// Нужно, чтобы про закрытый сейф узнать то же, что на Mac сообщает <c>hdiutil isencrypted</c>:
/// зашифрован ли том внутри, каким паролем открывается, — не подключая образ и не показывая
/// системных окон. И чтобы снять и вернуть копию заголовка BitLocker, как копию заголовка VeraCrypt.</summary>
public sealed class Vhdx : IDisposable
{
    static readonly Guid BatRegion = new("2DC27766-F623-4200-9D64-115E9BFD4A08");
    static readonly Guid MetadataRegion = new("8B7CA206-4790-4B9A-B8FE-575F050F886E");
    static readonly Guid FileParameters = new("CAA16737-FA36-4D43-B3B6-33F0AA44E76B");
    static readonly Guid VirtualDiskSize = new("2FA54224-CD1B-4876-B211-5DBED83BF4B8");
    static readonly Guid LogicalSectorSize = new("8141BF1D-A96F-4709-BA47-F233A8FAAB5F");

    readonly FileStream file;
    readonly long batOffset;
    public long BlockSize { get; }
    public long DiskSize { get; }
    public int SectorSize { get; }
    long ChunkRatio => (1L << 23) * SectorSize / BlockSize;
    /// <summary>В журнале VHDX есть незавершённые записи: писать мимо него нельзя.</summary>
    public bool HasPendingLog { get; }

    Vhdx(FileStream file, long batOffset, long blockSize, long diskSize, int sectorSize, bool pendingLog)
    {
        this.file = file;
        this.batOffset = batOffset;
        BlockSize = blockSize;
        DiskSize = diskSize;
        SectorSize = sectorSize;
        HasPendingLog = pendingLog;
    }

    /// <summary>Открывает образ; null — это не VHDX или он повреждён.</summary>
    public static Vhdx? Open(string path, bool writable = false)
    {
        FileStream file;
        try
        {
            file = new FileStream(path, FileMode.Open, writable ? FileAccess.ReadWrite : FileAccess.Read,
                                  writable ? FileShare.Read : FileShare.ReadWrite, 1, FileOptions.RandomAccess);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return null; }
        try
        {
            var result = Parse(file);
            if (result == null) file.Dispose();
            return result;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or OverflowException)
        {
            file.Dispose();
            return null;
        }
    }

    static byte[] ReadRaw(FileStream file, long offset, int length)
    {
        var buffer = new byte[length];
        int total = 0;
        while (total < length)
        {
            int read = RandomAccess.Read(file.SafeFileHandle, buffer.AsSpan(total), offset + total);
            if (read == 0) throw new IOException("образ обрывается");
            total += read;
        }
        return buffer;
    }

    static Vhdx? Parse(FileStream file)
    {
        var identifier = ReadRaw(file, 0, 8);
        if (System.Text.Encoding.ASCII.GetString(identifier) != "vhdxfile") return null;
        // Два заголовка, действует тот, что прошёл проверку и новее.
        byte[]? header = null;
        ulong sequence = 0;
        foreach (var offset in new long[] { 64 * 1024, 128 * 1024 })
        {
            var candidate = ReadRaw(file, offset, 4096);
            if (System.Text.Encoding.ASCII.GetString(candidate, 0, 4) != "head" || !ChecksumOK(candidate)) continue;
            var seq = BinaryPrimitives.ReadUInt64LittleEndian(candidate.AsSpan(8));
            if (header == null || seq > sequence)
            {
                header = candidate;
                sequence = seq;
            }
        }
        if (header == null) return null;
        bool pendingLog = new Guid(header.AsSpan(48, 16)) != Guid.Empty;

        byte[]? regions = null;
        foreach (var offset in new long[] { 192 * 1024, 256 * 1024 })
        {
            var candidate = ReadRaw(file, offset, 64 * 1024);
            if (System.Text.Encoding.ASCII.GetString(candidate, 0, 4) == "regi" && ChecksumOK(candidate))
            {
                regions = candidate;
                break;
            }
        }
        if (regions == null) return null;
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(regions.AsSpan(8));
        long bat = -1, metadata = -1;
        int metadataLength = 0;
        for (int i = 0; i < Math.Min(count, 2047u); i++)
        {
            var entry = regions.AsSpan(16 + i * 32, 32);
            var guid = new Guid(entry[..16]);
            long fileOffset = (long)BinaryPrimitives.ReadUInt64LittleEndian(entry[16..]);
            int length = (int)BinaryPrimitives.ReadUInt32LittleEndian(entry[24..]);
            if (guid == BatRegion) bat = fileOffset;
            else if (guid == MetadataRegion) { metadata = fileOffset; metadataLength = length; }
        }
        if (bat < 0 || metadata < 0 || metadataLength < 65536) return null;

        var table = ReadRaw(file, metadata, Math.Min(metadataLength, 1 << 20));
        if (System.Text.Encoding.ASCII.GetString(table, 0, 8) != "metadata") return null;
        int items = BinaryPrimitives.ReadUInt16LittleEndian(table.AsSpan(10));
        long blockSize = 0, diskSize = 0;
        int sectorSize = 0;
        bool hasParent = false;
        for (int i = 0; i < Math.Min(items, 2047); i++)
        {
            var entry = table.AsSpan(32 + i * 32, 32);
            var id = new Guid(entry[..16]);
            int offset = (int)BinaryPrimitives.ReadUInt32LittleEndian(entry[16..]);
            if (offset <= 0 || offset + 8 > table.Length) continue;
            if (id == FileParameters)
            {
                blockSize = BinaryPrimitives.ReadUInt32LittleEndian(table.AsSpan(offset));
                hasParent = (BinaryPrimitives.ReadUInt32LittleEndian(table.AsSpan(offset + 4)) & 2) != 0;
            }
            else if (id == VirtualDiskSize) diskSize = (long)BinaryPrimitives.ReadUInt64LittleEndian(table.AsSpan(offset));
            else if (id == LogicalSectorSize) sectorSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(table.AsSpan(offset));
        }
        // Разностный образ читать без родителя нельзя — сейф таким не бывает.
        if (hasParent || blockSize < 1 << 20 || diskSize <= 0 || sectorSize is not (512 or 4096)) return null;
        return new Vhdx(file, bat, blockSize, diskSize, sectorSize, pendingLog);
    }

    /// <summary>CRC-32C по всему заголовку с обнулённым полем суммы.</summary>
    static bool ChecksumOK(byte[] data)
    {
        uint stored = BinaryPrimitives.ReadUInt32LittleEndian(data.AsSpan(4));
        var copy = (byte[])data.Clone();
        copy[4] = copy[5] = copy[6] = copy[7] = 0;
        return Crc32C(copy) == stored;
    }

    static readonly uint[] CrcTable = Enumerable.Range(0, 256).Select(n =>
    {
        uint c = (uint)n;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0x82F63B78u ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    static uint Crc32C(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (var b in data) crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return ~crc;
    }

    /// <summary>Где в файле лежит блок диска; null — блока нет (читается нулями).</summary>
    long? BlockFileOffset(long block)
    {
        long index = block + block / ChunkRatio;
        var entry = BinaryPrimitives.ReadUInt64LittleEndian(ReadRaw(file, batOffset + index * 8, 8));
        int state = (int)(entry & 7);
        if (state is not (6 or 7)) return null;
        return (long)(entry >> 20) * (1L << 20);
    }

    /// <summary>Сколько блоков в каком состоянии: 6 — занят, 3 — освобождён (TRIM), 0/2 — пуст.</summary>
    public Dictionary<int, long> BlockStates()
    {
        var result = new Dictionary<int, long>();
        long blocks = (DiskSize + BlockSize - 1) / BlockSize;
        for (long block = 0; block < blocks; block++)
        {
            long index = block + block / ChunkRatio;
            var entry = BinaryPrimitives.ReadUInt64LittleEndian(ReadRaw(file, batOffset + index * 8, 8));
            int state = (int)(entry & 7);
            result[state] = result.GetValueOrDefault(state) + 1;
        }
        return result;
    }

    /// <summary>Байты виртуального диска по смещению.</summary>
    public byte[] Read(long offset, int length)
    {
        if (offset < 0 || offset + length > DiskSize) throw new ArgumentException("за пределами диска");
        var result = new byte[length];
        int done = 0;
        while (done < length)
        {
            long position = offset + done;
            long block = position / BlockSize;
            long inBlock = position % BlockSize;
            int part = (int)Math.Min(length - done, BlockSize - inBlock);
            if (BlockFileOffset(block) is { } fileOffset)
                ReadRaw(file, fileOffset + inBlock, part).CopyTo(result, done);
            done += part;
        }
        return result;
    }

    /// <summary>Записывает байты в уже существующие блоки. Новый блок не выделяется: заголовок BitLocker
    /// всегда лежит в выделенных блоках, и если блока нет — это не тот образ.</summary>
    public void Write(long offset, byte[] data)
    {
        if (HasPendingLog) throw new IOException("в журнале образа есть незавершённые записи — сначала подключите и отключите его");
        if (offset < 0 || offset + data.Length > DiskSize) throw new ArgumentException("за пределами диска");
        int done = 0;
        while (done < data.Length)
        {
            long position = offset + done;
            long block = position / BlockSize;
            long inBlock = position % BlockSize;
            int part = (int)Math.Min(data.Length - done, BlockSize - inBlock);
            var fileOffset = BlockFileOffset(block) ?? throw new IOException("нужный участок образа пуст");
            RandomAccess.Write(file.SafeFileHandle, data.AsSpan(done, part), fileOffset + inBlock);
            done += part;
        }
        RandomAccess.FlushToDisk(file.SafeFileHandle);
    }

    /// <summary>Раздел с данными на диске GPT: самый большой «основной раздел данных».
    /// Смещение и размер в байтах; null — таблицы разделов нет.</summary>
    public (long offset, long size)? DataPartition()
    {
        var gpt = Read(SectorSize, SectorSize);
        if (System.Text.Encoding.ASCII.GetString(gpt, 0, 8) != "EFI PART") return null;
        long entriesLba = (long)BinaryPrimitives.ReadUInt64LittleEndian(gpt.AsSpan(72));
        int count = (int)Math.Min(BinaryPrimitives.ReadUInt32LittleEndian(gpt.AsSpan(80)), 256u);
        int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(gpt.AsSpan(84));
        if (size < 128 || size > 4096) return null;
        var table = Read(entriesLba * SectorSize, count * size);
        var basicData = new Guid("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
        (long, long)? best = null;
        for (int i = 0; i < count; i++)
        {
            var entry = table.AsSpan(i * size, size);
            if (new Guid(entry[..16]) != basicData) continue;
            long first = (long)BinaryPrimitives.ReadUInt64LittleEndian(entry[32..]);
            long last = (long)BinaryPrimitives.ReadUInt64LittleEndian(entry[40..]);
            long bytes = (last - first + 1) * SectorSize;
            if (best == null || bytes > best.Value.Item2) best = (first * SectorSize, bytes);
        }
        return best;
    }

    public void Dispose() => file.Dispose();
}
