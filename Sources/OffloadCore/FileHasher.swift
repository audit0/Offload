import CryptoKit
import Foundation

/// Потоковый SHA-256: файлы любого размера читаются кусками по 4 МБ.
public enum FileHasher {
    public static let chunkSize = 4 * 1024 * 1024

    public static func sha256(of url: URL, isCancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if isCancelled() { throw CancellationError() }
            let read: Int = try autoreleasepool {
                guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return 0 }
                hasher.update(data: data)
                return data.count
            }
            if read == 0 { break }
            progress(read)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// SHA-256 первых и последних `edge` байт — быстрый отпечаток, чтобы отсеять разные файлы
    /// одного размера, не читая их целиком. Файл не длиннее двух краёв читается весь.
    public static func sha256(edgesOf url: URL, size: Int64, edge: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        if size <= Int64(edge) * 2 {
            hasher.update(data: try handle.read(upToCount: Int(size)) ?? Data())
        } else {
            hasher.update(data: try handle.read(upToCount: edge) ?? Data())
            try handle.seek(toOffset: UInt64(size - Int64(edge)))
            hasher.update(data: try handle.read(upToCount: edge) ?? Data())
        }
        return hex(hasher.finalize())
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
