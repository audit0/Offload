import Foundation
import os

/// Строка обзора «что занимает место».
public struct SpaceItem: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let modified: Date?
    public let isDirectory: Bool
    public let accessDenied: Bool
    public let verdict: Verdict
    /// false — размер ещё считается.
    public let isMeasured: Bool
}

public enum SpaceScanner {
    static let logger = Logger(subsystem: "io.github.audit0.offload", category: "scan")

    /// Содержимое папки без символических ссылок и служебных файлов Finder.
    public static func children(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                                  options: [])) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            guard name != ".DS_Store", !name.hasPrefix("._") else { return false }
            return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
        }
    }

    /// Размер через `du`: он быстрее обхода из Swift и не выходит за пределы тома (`-x`).
    public static func measure(_ url: URL, rules: SafetyRules) -> SpaceItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .totalFileAllocatedSizeKey])
        let isDirectory = values?.isDirectory ?? false
        var bytes = Int64(values?.totalFileAllocatedSize ?? 0)
        var denied = values == nil
        if isDirectory {
            do {
                let result = try Runner.run("du", ["-sk", "-x", "--", url.path])
                if let line = result.output.split(separator: "\n").last,
                   let field = line.split(separator: "\t").first,
                   let kilobytes = Int64(field) {
                    bytes = kilobytes * 1024
                } else {
                    logger.error("du не вернул размер для \(url.path, privacy: .public): код \(result.status), stderr: \(result.stderr.prefix(200), privacy: .public)")
                }
                denied = denied || result.stderr.contains("Operation not permitted") || result.stderr.contains("Permission denied")
            } catch {
                logger.error("du не запустился для \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return SpaceItem(url: url, bytes: bytes, modified: values?.contentModificationDate, isDirectory: isDirectory,
                         accessDenied: denied, verdict: rules.pathVerdict(for: url), isMeasured: true)
    }

    /// Строка без размера — показывается сразу, чтобы список не прыгал, пока du считает.
    public static func placeholder(_ url: URL, rules: SafetyRules) -> SpaceItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
        return SpaceItem(url: url, bytes: 0, modified: values?.contentModificationDate, isDirectory: values?.isDirectory ?? false,
                         accessDenied: false, verdict: rules.pathVerdict(for: url), isMeasured: false)
    }

    /// Измеряет объекты параллельно и отдаёт каждый по готовности.
    public static func scan(_ urls: [URL], rules: SafetyRules, concurrency: Int = 4,
                            isCancelled: @escaping @Sendable () -> Bool,
                            onItem: @escaping @Sendable (SpaceItem) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var pending = urls[...]
            var running = 0
            while true {
                while running < concurrency, !isCancelled(), let url = pending.popFirst() {
                    group.addTask { onItem(measure(url, rules: rules)) }
                    running += 1
                }
                guard running > 0 else { break }
                _ = await group.next()
                running -= 1
            }
        }
    }
}
