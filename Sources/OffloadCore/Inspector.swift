import Darwin
import Foundation

/// Что лежит внутри папки: всё, что нужно знать до переноса.
public struct ContentReport: Sendable, Equatable {
    public var allocatedBytes: Int64 = 0
    public var logicalBytes: Int64 = 0
    public var files = 0
    public var directories = 0
    public var symlinkCount = 0
    public var symlinkExamples: [String] = []
    /// Разрежённые или сжатые файлы: на диске занимают меньше, чем весят.
    public var sparseFiles = 0
    /// Файлы, на которые ведёт больше одного имени (жёсткие ссылки): копия сделает из них независимые файлы.
    public var hardLinkedFiles = 0
    /// Объекты с расширенными атрибутами, кроме служебных: метки Finder, комментарии, теги.
    public var taggedFiles = 0
    public var largestFile: Int64 = 0
    public var newestModification: Date?
    /// Первый найденный пакет, зарегистрированный в приложении (виртуалка UTM и т. п.).
    public var registeredBundle: String?
    /// Внутри смонтирован другой диск: его содержимое не должно уехать и удалиться вместе с папкой.
    public var mountedVolume: String?
    public var containsGitRepo = false
    public var unreadable = 0
    public var unreadableExamples: [String] = []
    public var truncated = false

    public init() {}
}

public enum Inspector {
    /// Атрибуты, которые macOS ставит сама и о потере которых человеку говорить незачем.
    static let routineXattrs: Set<String> = [
        "com.apple.quarantine", "com.apple.provenance", "com.apple.macl",
        "com.apple.lastuseddate#PS", "com.apple.metadata:kMDLabel_", "com.apple.TextEncoding",
    ]

    /// Есть ли у объекта расширенные атрибуты, которые человек заметит: метки, комментарии,
    /// ресурсная вилка. Один вызов listxattr, содержимое атрибутов не читается.
    static func hasNotableXattrs(_ path: String) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = listxattr(path, &buffer, buffer.count, XATTR_NOFOLLOW)
        if length < 0 { return errno == ERANGE }
        guard length > 0 else { return false }
        var names: [String] = []
        var current: [CChar] = []
        for index in 0..<Int(length) {
            if buffer[index] == 0 {
                if !current.isEmpty { names.append(String(decoding: current.map { UInt8(bitPattern: $0) }, as: UTF8.self)) }
                current = []
            } else {
                current.append(buffer[index])
            }
        }
        return names.contains { name in
            !routineXattrs.contains(name) && !routineXattrs.contains(where: { name.hasPrefix($0) })
        }
    }

    /// Считает содержимое через fts. Это намеренно другой механизм, чем в TreeWalker (readdir):
    /// перед удалением оригинала их результаты сверяются, и ошибка одного не пройдёт незамеченной.
    /// FileManager.enumerator здесь не годится — он молча скрывает файлы с именами на «._».
    public static func inspect(_ root: URL, limit: Int = 2_000_000, isCancelled: () -> Bool = { false }) -> ContentReport {
        var report = ContentReport()
        let rootPath = root.path

        func relative(_ path: String) -> String {
            path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : (path as NSString).lastPathComponent
        }
        func noteDate(_ info: UnsafeMutablePointer<stat>?) {
            guard let info else { return }
            let spec = info.pointee.st_mtimespec
            let date = Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
            if report.newestModification.map({ date > $0 }) ?? true { report.newestModification = date }
        }
        func noteRegistered(_ name: String, _ path: String) {
            guard report.registeredBundle == nil,
                  SafetyRules.registeredBundleExtensions.contains((name as NSString).pathExtension.lowercased()) else { return }
            report.registeredBundle = relative(path)
        }

        guard let rootArgument = strdup(rootPath) else {
            report.unreadable = 1
            return report
        }
        defer { free(rootArgument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [rootArgument, nil]
        guard let stream = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            report.unreadable = 1
            report.unreadableExamples = [root.lastPathComponent]
            return report
        }
        defer { fts_close(stream) }

        var rootDevice: dev_t?
        var seen = 0
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_DP { continue }
            seen += 1
            if seen > limit || isCancelled() {
                report.truncated = true
                break
            }
            let path = String(cString: entry.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if let status = entry.pointee.fts_statp, info != FTS_NS {
                if let rootDevice {
                    if status.pointee.st_dev != rootDevice, report.mountedVolume == nil { report.mountedVolume = relative(path) }
                } else {
                    rootDevice = status.pointee.st_dev
                }
            }
            switch info {
            case FTS_D:
                report.directories += 1
                if name == ".git" { report.containsGitRepo = true }
                noteRegistered(name, path)
                noteDate(entry.pointee.fts_statp)
                if Self.hasNotableXattrs(path) { report.taggedFiles += 1 }
            case FTS_F, FTS_DEFAULT:
                report.files += 1
                noteRegistered(name, path)
                if let status = entry.pointee.fts_statp {
                    let logical = Int64(status.pointee.st_size)
                    let allocated = Int64(status.pointee.st_blocks) * 512
                    report.logicalBytes += logical
                    report.allocatedBytes += allocated
                    report.largestFile = max(report.largestFile, logical)
                    if logical > 16 << 20, allocated + (1 << 20) < logical { report.sparseFiles += 1 }
                    if status.pointee.st_nlink > 1 { report.hardLinkedFiles += 1 }
                }
                noteDate(entry.pointee.fts_statp)
                if Self.hasNotableXattrs(path) { report.taggedFiles += 1 }
            case FTS_SL, FTS_SLNONE:
                report.symlinkCount += 1
                if report.symlinkExamples.count < 5 { report.symlinkExamples.append(relative(path)) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                report.unreadable += 1
                if report.unreadableExamples.count < 5 { report.unreadableExamples.append(relative(path)) }
            default:
                continue
            }
        }
        return report
    }
}
