import Foundation

/// Крупные данные приложений, место из-под которых освобождается не переносом,
/// а средствами самих приложений: Offload показывает, как это сделать.
public enum AppData: Sendable, Equatable {
    case docker
    case utm

    /// К чему относится объект: контейнер приложения целиком, папка внутри него или пакет виртуальной машины.
    public static func kind(of url: URL, home: URL) -> AppData? {
        let path = url.standardizedFileURL.path
        let containers = home.standardizedFileURL.path + "/Library/Containers/"
        func within(_ identifier: String) -> Bool {
            path == containers + identifier || path.hasPrefix(containers + identifier + "/")
        }
        if within("com.docker.docker") { return .docker }
        if within(UTMMachines.bundleIdentifier) || UTMMachines.isMachine(url) { return .utm }
        return nil
    }
}

/// Виртуальная машина UTM — пакет «.utm» с настройками и дисками.
public struct UTMMachine: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    /// Сколько занимает на диске сейчас.
    public let bytes: Int64
    /// Полный объём файлов. Виртуальные диски разрежённые: там, где разрежённых файлов нет
    /// (exFAT, FAT), машина займёт столько, а не `bytes`.
    public let logicalBytes: Int64
    /// Самый большой файл — обычно диск машины. FAT32 больше 4 ГБ в одном файле не примет.
    public let largestFile: Int64
    /// Когда в машине что-то менялось последний раз — обычно это последний запуск.
    public let modified: Date?

    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL, bytes: Int64, logicalBytes: Int64, largestFile: Int64 = 0, modified: Date?) {
        self.url = url
        self.bytes = bytes
        self.logicalBytes = logicalBytes
        self.largestFile = largestFile
        self.modified = modified
    }
}

public enum UTMMachines {
    public static let bundleIdentifier = "com.utmapp.UTM"

    /// Пакет машины. Папки с идентификатором UTM («com.utmapp.UTM» в кешах, «…com.utmapp.UTM»
    /// у группы приложений) тоже оканчиваются на «.UTM», но машинами не являются.
    public static func isMachine(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "utm" && !name.hasSuffix(bundleIdentifier.lowercased())
    }

    /// Куда UTM кладёт машины, созданные в нём самом.
    public static func folder(home: URL) -> URL {
        home.appendingPathComponent("Library/Containers/\(bundleIdentifier)/Data/Documents", isDirectory: true)
    }

    /// Машины в папке по убыванию размера — то же, что `du -sh …/Documents/*.utm`.
    public static func list(in folder: URL, isCancelled: () -> Bool = { false }) -> [UTMMachine] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter(isMachine)
            .map { machine(at: $0, isCancelled: isCancelled) }
            .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
    }

    public static func machine(at url: URL, isCancelled: () -> Bool = { false }) -> UTMMachine {
        let report = Inspector.inspect(url, isCancelled: isCancelled)
        return UTMMachine(url: url, bytes: report.allocatedBytes, logicalBytes: report.logicalBytes,
                          largestFile: report.largestFile, modified: report.newestModification)
    }
}
