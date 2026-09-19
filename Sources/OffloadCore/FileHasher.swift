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

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
