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
    /// Том внутри зашифрованного образа — сейф. Всё, что пишется сюда, на внешнем диске
    /// лежит зашифрованным.
    public let isEncryptedImage: Bool

    public init(mountPoint: URL, name: String, fsType: String, totalBytes: Int64, availableBytes: Int64,
                blockSize: Int64, isReadOnly: Bool, isInternal: Bool, isEncryptedImage: Bool = false) {
        self.mountPoint = mountPoint
        self.name = name
        self.fsType = fsType
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.blockSize = blockSize
        self.isReadOnly = isReadOnly
        self.isInternal = isInternal
        self.isEncryptedImage = isEncryptedImage
    }

    /// macOS хранит символические ссылки и на exFAT/FAT — в собственном формате (проверено на реальном томе).
    public var keepsSymlinks: Bool { ["apfs", "hfs", "exfat", "msdos"].contains(fsType) }
    /// Такие ссылки работают на Mac, но другие системы могут увидеть вместо них обычные файлы.
    public var emulatesSymlinks: Bool { ["exfat", "msdos"].contains(fsType) }
    public var keepsSparseFiles: Bool { fsType == "apfs" }
    /// exFAT, FAT и NTFS прав доступа не хранят и показывают всем объектам одинаковые.
    public var keepsPermissions: Bool { ["apfs", "hfs"].contains(fsType) }
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

    /// Сейф как место назначения. Свободное место внутри образа — не то же самое, что место
    /// на диске, где образ лежит: разрежённый образ растёт, пока на диске есть куда, и предел
    /// в полдиска ничего не значит, если сам диск почти полон. Поэтому свободным считается
    /// меньшее из двух, за вычетом запаса на служебные данные образа.
    public static func safe(mountedAt mount: URL, host: VolumeInfo) -> VolumeInfo? {
        guard let inside = info(for: mount) else { return nil }
        let hostRoom = max(0, host.availableBytes - safeHostReserve)
        return VolumeInfo(mountPoint: inside.mountPoint, name: inside.name, fsType: inside.fsType,
                          totalBytes: inside.totalBytes, availableBytes: min(inside.availableBytes, hostRoom),
                          blockSize: inside.blockSize, isReadOnly: inside.isReadOnly, isInternal: false,
                          isEncryptedImage: true)
    }

    /// Полосы образа по 8 МБ и его служебные файлы: оставляем на диске немного воздуха.
    public static let safeHostReserve: Int64 = 1 << 30

    /// Зашифрован ли сам том целиком (APFS с шифрованием, FileVault). У exFAT и FAT
    /// шифрования не бывает вовсе — всё, что лежит на таком диске вне сейфа, читается как есть.
    public static func isVolumeEncrypted(_ volume: VolumeInfo) -> Bool {
        guard ["apfs", "hfs"].contains(volume.fsType),
              let result = try? Runner.run("diskutil", ["info", "-plist", volume.mountPoint.path], timeout: 20), result.succeeded,
              let plist = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any] else {
            return false
        }
        return (plist["Encryption"] as? Bool) == true || (plist["FileVault"] as? Bool) == true
    }

    static func string<T>(fromCTuple tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
