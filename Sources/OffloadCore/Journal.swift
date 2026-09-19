import Foundation

/// Журнал переносов: на самом внешнем диске (чтобы вернуть данные на любом Mac) и локальная копия.
public enum Journal {
    public static let manifestName = "manifest.json"
    /// Журнал с внешнего диска — непроверенные данные, поэтому размер ограничен.
    static let maxManifestBytes = 20 * 1024 * 1024

    public static func manifestURL(on volume: VolumeInfo) -> URL {
        volume.mountPoint.appendingPathComponent(SafeMover.folderName, isDirectory: true).appendingPathComponent(manifestName)
    }

    /// Для проверок: локальный журнал в другом месте, чтобы не трогать настоящий.
    public static var localOverride: URL?

    public static var localURL: URL {
        if let localOverride { return localOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offload", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// Что лежит по пути журнала: файла нет, записи прочитаны или файл есть, но не читается.
    public enum State: Sendable {
        case missing
        case records([MoveRecord])
        case broken
    }

    public static func state(of url: URL) -> State {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .missing }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maxManifestBytes,
              let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([MoveRecord].self, from: data) else { return .broken }
        return .records(records)
    }

    public static func load(_ url: URL) -> [MoveRecord] {
        if case .records(let records) = state(of: url) { return records }
        return []
    }

    public static func records(on volume: VolumeInfo) -> [MoveRecord] { load(manifestURL(on: volume)) }
    public static func localRecords() -> [MoveRecord] { load(localURL) }

    /// Испорченный журнал переименовывается, а не переписывается: иначе одна неудачная
    /// запись (выдернули диск, правили файл руками) молча стёрла бы всю историю переносов.
    static func setAside(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".broken-" + stamp)
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    public static func save(_ record: MoveRecord, volume: VolumeInfo) throws {
        let manifest = manifestURL(on: volume)
        let urls = [manifest, localURL]
        var known: [URL: [MoveRecord]] = [:]
        var broken: Set<URL> = []
        for url in urls {
            switch state(of: url) {
            case .missing: known[url] = []
            case .records(let records): known[url] = records
            case .broken:
                broken.insert(url)
                known[url] = []
                setAside(url)
            }
        }
        // Журнал ведётся в двух копиях. Если одна испорчена, она восстанавливается из уцелевшей,
        // иначе запасная копия молча перестала бы быть запасной.
        let rescue = urls.flatMap { known[$0] ?? [] }
        for url in urls {
            var records = known[url] ?? []
            if broken.contains(url) {
                let mountPrefix = volume.mountPoint.path + "/"
                var seen = Set<UUID>()
                records = rescue.filter { candidate in
                    guard url != manifest || candidate.archivedPath.hasPrefix(mountPrefix) else { return false }
                    return seen.insert(candidate.id).inserted
                }
            }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = record
            } else {
                records.append(record)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: url, options: .atomic)
            if volume.createsAppleDouble { SafeMover.removeSidecar(of: url) }
        }
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
