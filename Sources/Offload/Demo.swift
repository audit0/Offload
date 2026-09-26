import Foundation
import OffloadCore

/// Демонстрационный режим для снимков экрана: `OFFLOAD_DEMO=1`.
///
/// Показывает вымышленные диск, сейф, папки и журнал, чтобы снимки для README не выдавали
/// ничьих настоящих папок и проектов. В этом режиме Offload ничего не читает с дисков,
/// ничего не сохраняет в настройки и ничего не пишет в журнал.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["OFFLOAD_DEMO"] == "1"

    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let gigabyte: Int64 = 1_000_000_000

    static let macDisk = VolumeInfo(mountPoint: URL(fileURLWithPath: "/"), name: "Macintosh HD", fsType: "apfs",
                                    totalBytes: 494 * gigabyte, availableBytes: 41 * gigabyte, blockSize: 4096,
                                    isReadOnly: false, isInternal: true)

    static let disk = VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/Samsung T7", isDirectory: true), name: "Samsung T7",
                                 fsType: "exfat", totalBytes: 1000 * gigabyte, availableBytes: 612 * gigabyte, blockSize: 131_072,
                                 isReadOnly: false, isInternal: false)

    static let safeMount = URL(fileURLWithPath: "/Volumes/Offload Safe", isDirectory: true)

    static let safeVolume = VolumeInfo(mountPoint: safeMount, name: "Offload Safe", fsType: "apfs",
                                       totalBytes: 1000 * gigabyte, availableBytes: 611 * gigabyte, blockSize: 4096,
                                       isReadOnly: false, isInternal: false, isEncryptedImage: true)

    static var safeState: SafeModel.State {
        let image = disk.mountPoint.appendingPathComponent(SecretsVault.safeImageName, isDirectory: true)
        return SafeModel.State(volumeID: disk.id, imageURL: image, exists: true, isEncrypted: true,
                               info: SecretsVault.EncryptionInfo(encrypted: true, passphraseCount: 1, version: 2,
                                                                 uuid: "5B1E2C4A-0D3F-4E77-9A61-2C8B7F1D0E93"),
                               sizeLimit: disk.totalBytes, allocated: 318 * gigabyte, mount: safeMount,
                               candidates: [image], hostEncrypted: false)
    }

    static let memory = MemorySnapshot(
        physicalBytes: 16 << 30, freeBytes: 1_200 << 20, compressedBytes: 2_300 << 20,
        swapUsedBytes: 1_100 << 20, swapTotalBytes: 3 << 30, pressure: .normal, uptime: 3 * 86_400 + 5 * 3_600,
        apps: [
            AppMemory(name: "Safari", bytes: 3_400 << 20, processes: 9),
            AppMemory(name: "Xcode", bytes: 2_600 << 20, processes: 4),
            AppMemory(name: "Figma", bytes: 1_300 << 20, processes: 5),
            AppMemory(name: "Slack", bytes: 900 << 20, processes: 6),
            AppMemory(name: "Telegram", bytes: 610 << 20, processes: 2),
            AppMemory(name: "Музыка", bytes: 380 << 20, processes: 1),
        ])

    static func spaceItems() -> [SpaceItem] {
        func item(_ name: String, _ gb: Double, _ verdict: Verdict, daysAgo: Double) -> SpaceItem {
            SpaceItem(url: home.appendingPathComponent(name, isDirectory: true), bytes: Int64(gb * Double(gigabyte)),
                      modified: Date().addingTimeInterval(-daysAgo * 86_400), isDirectory: true, accessDenied: false,
                      verdict: verdict, isMeasured: true)
        }
        return [
            item("Movies", 142.6, .safe, daysAgo: 210),
            item("Library", 96.1, .blocked("Данные приложений: перенос сломает программы, которые их используют."), daysAgo: 0),
            item("Downloads", 58.3, .safe, daysAgo: 3),
            item("Pictures", 41.7, .caution(["Внутри медиатека «Фото» — её перенести нельзя, остальное можно."]), daysAgo: 12),
            item("Projects", 31.2, .caution(["Внутри git-репозитории: после переноса с ними можно работать только с диска."]), daysAgo: 1),
            item("Music", 12.4, .safe, daysAgo: 400),
            item("Documents", 17.5, .safe, daysAgo: 5),
            item("Desktop", 2.9, .safe, daysAgo: 0),
        ]
    }

    static func records() -> [MoveRecord] {
        func record(_ relative: String, _ gb: Double, files: Int, daysAgo: Double, inSafe: Bool = true,
                    restored: Bool = false, note: String? = nil) -> MoveRecord {
            let root = inSafe ? safeMount : disk.mountPoint
            return MoveRecord(date: Date().addingTimeInterval(-daysAgo * 86_400),
                              originalPath: home.appendingPathComponent(relative).path,
                              archivedPath: root.appendingPathComponent("Offload").appendingPathComponent(relative).path,
                              volumeName: inSafe ? safeVolume.name : disk.name, files: files, bytes: Int64(gb * Double(gigabyte)),
                              originalRemoved: true, restored: restored, note: note, inSafe: inSafe ? true : nil)
        }
        return [
            record("Movies/Съёмки 2023", 86.4, files: 412, daysAgo: 1),
            record("Library/Application Support/MobileSync/Backup/iPhone 15", 48.2, files: 9_811, daysAgo: 2,
                   note: "Резервная копия iPhone. После возврата Finder снова её увидит."),
            record("Downloads/Установщики", 21.7, files: 64, daysAgo: 2),
            record("Pictures/Экспорт Lightroom 2022", 12.9, files: 1_840, daysAgo: 30, inSafe: false,
                   note: "Перенесено до появления сейфа — лежит на диске открыто."),
            record("Music/Logic Projects", 9.8, files: 2_377, daysAgo: 6),
            record("Projects/old-prototypes", 6.3, files: 18_204, daysAgo: 9),
            record("Documents/Сканы договоров", 1.2, files: 146, daysAgo: 14, restored: true),
        ]
    }

    /// Что находит разбор в демонстрации — через настоящие правила, привычки и память,
    /// чтобы снимок показывал то же, что увидит человек: что отмечено сразу, а что решает он.
    static func cleanupSuggestions(memory: [String: CleanupAction], habits: HabitModel?) -> [CleanupSuggestion] {
        let now = Date()
        func path(_ relative: String) -> String { home.appendingPathComponent(relative, isDirectory: true).path }
        func item(_ relative: String, _ gb: Double, daysAgo: Double, directory: Bool = true, verdict: Verdict = .safe,
                  project: Bool = false) -> CleanupObservation {
            CleanupObservation(url: home.appendingPathComponent(relative, isDirectory: directory), bytes: Int64(gb * Double(gigabyte)),
                               modified: now.addingTimeInterval(-daysAgo * 86_400), isDirectory: directory, verdict: verdict,
                               isProject: project)
        }
        func copy(_ relative: String, _ gb: Double, daysAgo: Double) -> DuplicateCopy {
            DuplicateCopy(url: home.appendingPathComponent(relative), allocated: Int64(gb * Double(gigabyte)),
                          modified: now.addingTimeInterval(-daysAgo * 86_400), created: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let library = Verdict.blocked("Данные приложений")
        let regenerable = Dictionary(uniqueKeysWithValues: CleanupPlanner.regenerableLocations
            .filter { ["Library/Developer/Xcode/DerivedData", "Library/Caches/Homebrew", "Library/Caches/Google/Chrome",
                       ".npm/_cacache"].contains($0.path) }
            .map { (path($0.path), $0.reason) })
        var remembered = memory
        remembered[path("Downloads/Датасеты")] = .safe
        let planner = CleanupPlanner(now: now, home: home, regenerable: regenerable, memory: remembered, habits: habits,
                                     busy: CleanupPlanner.busy(home: home, running: ["com.google.Chrome": "Google Chrome"]))
        return planner.suggestions([
            item("Library/Developer/Xcode/DerivedData", 18.4, daysAgo: 0, verdict: library),
            item("Library/Caches/Homebrew", 3.4, daysAgo: 5, verdict: library),
            item("Library/Caches/Google/Chrome", 1.6, daysAgo: 0, verdict: library),
            item(".npm/_cacache", 1.1, daysAgo: 7, verdict: library),
            item("Movies/Съёмки 2023", 86.4, daysAgo: 210),
            item("Downloads/Датасеты", 24.1, daysAgo: 150),
            item("Movies/Интервью 2024", 12.6, daysAgo: 50),
            item("Documents/Архив 2019", 9.4, daysAgo: 900),
            item("Documents/Работа", 8.1, daysAgo: 2),
            item("Pictures/Photos Library.photoslibrary", 41.7, daysAgo: 1, verdict: .blocked("Медиатека «Фото»")),
            item("Downloads/Xcode_16.xip", 7.9, daysAgo: 60, directory: false),
            item("Downloads/Figma.dmg", 0.3, daysAgo: 40, directory: false),
            item("Projects/offload-site", 1.2, daysAgo: 120, project: true),
        ], duplicates: [
            DuplicateGroup(id: "demo-video", bytes: Int64(2.4 * Double(gigabyte)), copies: [
                copy("Movies/Отпуск 2023.mov", 2.4, daysAgo: 300), copy("Downloads/Отпуск 2023.mov", 2.4, daysAgo: 40),
                copy("Desktop/Отпуск 2023 (1).mov", 2.4, daysAgo: 12)]),
            DuplicateGroup(id: "demo-pdf", bytes: 14_000_000, copies: [
                copy("Documents/Договор аренды.pdf", 0.014, daysAgo: 90), copy("Downloads/Договор аренды (1).pdf", 0.014, daysAgo: 30)]),
        ])
    }

    /// Прошлые решения, на которых в демонстрации выучены привычки. Пишутся только в базу в памяти.
    static func decisions() -> [DecisionStore.Decision] {
        let now = Date()
        func decision(_ relative: String, _ action: CleanupAction, suggested: CleanupAction, kind: DecisionFeatures.Kind,
                      _ gb: Double, daysAgo: Double, decidedDaysAgo: Double) -> DecisionStore.Decision {
            let decided = now.addingTimeInterval(-decidedDaysAgo * 86_400)
            return DecisionStore.Decision(path: home.appendingPathComponent(relative).path, action: action,
                                          bytes: Int64(gb * Double(gigabyte)), suggested: suggested, kind: kind,
                                          modified: decided.addingTimeInterval(-daysAgo * 86_400), decidedAt: decided)
        }
        // Отснятое в «Фильмах» убирает в сейф; старые папки в «Документах» оставляет, хотя Offload
        // предлагал сейф; проекты добавляет в бэкап, как и советуют правила.
        return ["Съёмки 2019", "Съёмки 2020", "Свадьба Ани", "Съёмки 2021", "Съёмки 2022"].enumerated().map { index, name in
            decision("Movies/\(name)", .safe, suggested: .safe, kind: .folder, 18 + Double(index) * 11,
                     daysAgo: 200 + Double(index) * 60, decidedDaysAgo: 20 + Double(index) * 25)
        } + ["Архив 2015", "Архив 2016", "Архив 2017", "Архив 2018"].enumerated().map { index, name in
            decision("Documents/\(name)", .keep, suggested: .safe, kind: .folder, 2.5 + Double(index) * 1.5,
                     daysAgo: 400 + Double(index) * 200, decidedDaysAgo: 10 + Double(index) * 30)
        } + ["landing", "telegram-bot", "scripts"].enumerated().map { index, name in
            decision("Projects/\(name)", .backup, suggested: .backup, kind: .project, 0.2 + Double(index) * 0.3,
                     daysAgo: 5 + Double(index) * 20, decidedDaysAgo: 15 + Double(index) * 10)
        }
    }

    static var backupSources: [URL] {
        ["Projects", "Documents", "Desktop"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    // MARK: - Docker и UTM

    static let dockerRawBytes: Int64 = 64 * gigabyte

    static var dockerVolumes: [DockerVolume] {
        func volume(_ name: String, _ gb: Double, daysAgo: Double, usedBy: [String] = []) -> DockerVolume {
            DockerVolume(name: name, createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
                         sizeBytes: Int64(gb * Double(gigabyte)), usedBy: usedBy)
        }
        return [
            volume("postgres-data", 12.4, daysAgo: 40, usedBy: ["shop-db"]),
            volume("ml-datasets", 9.8, daysAgo: 120),
            volume("redis-cache", 0.6, daysAgo: 40, usedBy: ["shop-cache"]),
            volume("old-wordpress", 3.2, daysAgo: 400),
            volume("minio-storage", 5.1, daysAgo: 200),
        ]
    }

    static var dockerUsage: DockerUsage {
        DockerUsage(images: .init(count: 24, active: 6, bytes: 18 * gigabyte, reclaimable: 11 * gigabyte),
                    containers: .init(count: 9, active: 3, bytes: 400_000_000, reclaimable: 250_000_000),
                    volumes: .init(count: 5, active: 2, bytes: 31 * gigabyte, reclaimable: 18 * gigabyte),
                    buildCache: .init(count: 140, active: 0, bytes: 9 * gigabyte, reclaimable: 9 * gigabyte))
    }

    static var utmMachines: [UTMMachine] {
        let folder = home.appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents", isDirectory: true)
        func machine(_ name: String, _ gb: Double, logical: Double, daysAgo: Double) -> UTMMachine {
            UTMMachine(url: folder.appendingPathComponent("\(name).utm", isDirectory: true), bytes: Int64(gb * Double(gigabyte)),
                       logicalBytes: Int64(logical * Double(gigabyte)), largestFile: Int64(gb * 0.95 * Double(gigabyte)),
                       modified: Date().addingTimeInterval(-daysAgo * 86_400))
        }
        return [
            machine("Windows 11", 38.2, logical: 64, daysAgo: 3),
            machine("Ubuntu 24.04", 11.5, logical: 32, daysAgo: 45),
            machine("macOS Sequoia", 24.9, logical: 80, daysAgo: 210),
        ]
    }
}
