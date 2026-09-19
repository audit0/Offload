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

    public static func load(_ url: URL) -> [MoveRecord] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue <= maxManifestBytes,
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([MoveRecord].self, from: data)) ?? []
    }

    public static func records(on volume: VolumeInfo) -> [MoveRecord] { load(manifestURL(on: volume)) }
    public static func localRecords() -> [MoveRecord] { load(localURL) }

    public static func save(_ record: MoveRecord, volume: VolumeInfo) throws {
        for url in [manifestURL(on: volume), localURL] {
            var records = load(url)
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
