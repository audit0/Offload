import Darwin
import Foundation

/// Сведения о смонтированном томе, важные для переноса.
public struct VolumeInfo: Hashable, Sendable, Identifiable {
    public var id: String { mountPoint.path }
    public let mountPoint: URL
    public let name: String
    /// Имя файловой системы из statfs: apfs, hfs, exfat, msdos, ntfs, smbfs…
    public let fsType: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let blockSize: Int64
    public let isReadOnly: Bool
    public let isInternal: Bool

    public init(mountPoint: URL, name: String, fsType: String, totalBytes: Int64, availableBytes: Int64,
                blockSize: Int64, isReadOnly: Bool, isInternal: Bool) {
        self.mountPoint = mountPoint
        self.name = name
        self.fsType = fsType
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.blockSize = blockSize
        self.isReadOnly = isReadOnly
        self.isInternal = isInternal
    }

    /// macOS хранит символические ссылки и на exFAT/FAT — в собственном формате (проверено на реальном томе).
    public var keepsSymlinks: Bool { ["apfs", "hfs", "exfat", "msdos"].contains(fsType) }
    /// Такие ссылки работают на Mac, но другие системы могут увидеть вместо них обычные файлы.
    public var emulatesSymlinks: Bool { ["exfat", "msdos"].contains(fsType) }
    public var keepsSparseFiles: Bool { fsType == "apfs" }
    /// FAT32 не принимает файлы больше 4 ГБ.
    public var maxFileSize: Int64? { fsType == "msdos" ? 4 * 1024 * 1024 * 1024 - 1 : nil }
    /// Там, где нет расширенных атрибутов, macOS создаёт рядом файлы ._*.
    public var createsAppleDouble: Bool { !["apfs", "hfs"].contains(fsType) }

    public var fsDisplayName: String {
        switch fsType {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "exFAT"
        case "msdos": return "FAT32"
        case "ntfs": return "NTFS"
        default: return fsType
        }
    }
}

public enum Volumes {
    public static func info(for url: URL) -> VolumeInfo? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }
        let mount = string(fromCTuple: stats.f_mntonname)
        let mountURL = URL(fileURLWithPath: mount, isDirectory: true)
        let values = try? mountURL.resourceValues(forKeys: [.volumeNameKey, .volumeIsInternalKey])
        let blockSize = Int64(stats.f_bsize)
        return VolumeInfo(
            mountPoint: mountURL,
            name: values?.volumeName ?? mountURL.lastPathComponent,
            fsType: string(fromCTuple: stats.f_fstypename),
            totalBytes: Int64(stats.f_blocks) * blockSize,
            availableBytes: Int64(stats.f_bavail) * blockSize,
            blockSize: blockSize,
            isReadOnly: (stats.f_flags & UInt32(MNT_RDONLY)) != 0,
            isInternal: values?.volumeIsInternal ?? false
        )
    }

    /// Внешние диски, на которые можно писать.
    public static func external() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { info(for: $0) }
            .filter { !$0.isInternal && !$0.isReadOnly && $0.mountPoint.path.hasPrefix("/Volumes/") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func string<T>(fromCTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
