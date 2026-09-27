using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace Offload.Core;

/// <summary>Потоковый SHA-256: файлы любого размера читаются кусками по 4 МБ.</summary>
public static class FileHasher
{
    public const int ChunkSize = 4 * 1024 * 1024;

    /// <summary>SHA-256 файла, прочитанного мимо кеша Windows: сверка копии должна читать носитель,
    /// а не страницы, оставшиеся в памяти после записи.</summary>
    public static string Sha256(string path, Func<bool>? isCancelled = null, Action<int>? progress = null)
    {
        isCancelled ??= () => false;
        using var reader = UnbufferedReader.Open(path);
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        while (true)
        {
            if (isCancelled()) throw new OperationCanceledException();
            var chunk = reader.Read();
            if (chunk.Length == 0) break;
            hasher.AppendData(chunk);
            progress?.Invoke(chunk.Length);
        }
        return Convert.ToHexStringLower(hasher.GetHashAndReset());
    }

    public static string Sha256(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// <summary>SHA-256 первых и последних <paramref name="edge"/> байт — быстрый отпечаток, чтобы отсеять
    /// разные файлы одного размера, не читая их целиком. Файл не длиннее двух краёв читается весь.</summary>
    public static string Sha256Edges(string path, long size, int edge)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1);
        using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        if (size <= (long)edge * 2)
        {
            var all = new byte[size];
            stream.ReadExactly(all);
            hasher.AppendData(all);
        }
        else
        {
            var buffer = new byte[edge];
            stream.ReadExactly(buffer);
            hasher.AppendData(buffer);
            stream.Seek(size - edge, SeekOrigin.Begin);
            stream.ReadExactly(buffer);
            hasher.AppendData(buffer);
        }
        return Convert.ToHexStringLower(hasher.GetHashAndReset());
    }
}

/// <summary>Чтение файла кусками по 4 МБ без кеша Windows (FILE_FLAG_NO_BUFFERING).
/// Буфер выровнен по странице, как того требует чтение без кеша. Там, где без кеша читать нельзя
/// (сетевые и некоторые сторонние файловые системы), файл читается обычно.</summary>
public sealed unsafe class UnbufferedReader : IDisposable
{
    readonly SafeFileHandle handle;
    readonly byte* buffer;
    long offset;
    bool finished;

    UnbufferedReader(SafeFileHandle handle)
    {
        this.handle = handle;
        buffer = (byte*)NativeMemory.AlignedAlloc(FileHasher.ChunkSize, 4096);
    }

    public static UnbufferedReader Open(string path)
    {
        const uint share = Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE | Native.FILE_SHARE_DELETE;
        var handle = Native.CreateFileW(Native.Long(path), Native.GENERIC_READ, share, IntPtr.Zero, Native.OPEN_EXISTING,
                                        Native.FILE_FLAG_NO_BUFFERING | Native.FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            int code = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (code != Native.ERROR_INVALID_PARAMETER && code != Native.ERROR_NOT_SUPPORTED)
                throw new IOException($"Не удалось прочитать «{path}».", new System.ComponentModel.Win32Exception(code));
            handle = Native.CreateFileW(Native.Long(path), Native.GENERIC_READ, share, IntPtr.Zero, Native.OPEN_EXISTING,
                                        Native.FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                code = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new IOException($"Не удалось прочитать «{path}».", new System.ComponentModel.Win32Exception(code));
            }
        }
        return new UnbufferedReader(handle);
    }

    /// <summary>Следующий кусок; пустой — файл кончился. Кусок живёт до следующего вызова.</summary>
    public ReadOnlySpan<byte> Read()
    {
        if (finished) return [];
        var span = new Span<byte>(buffer, FileHasher.ChunkSize);
        int read = RandomAccess.Read(handle, span, offset);
        if (read < FileHasher.ChunkSize) finished = true;
        offset += read;
        return span[..read];
    }

    public void Dispose()
    {
        handle.Dispose();
        NativeMemory.AlignedFree(buffer);
    }
}
