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

    static func cleanupSuggestions() -> [CleanupSuggestion] {
        func suggestion(_ relative: String, _ gb: Double, _ action: CleanupAction, _ reason: String, allowed: [CleanupAction],
                        daysAgo: Double, directory: Bool = true, learned: Bool = false, habit: Bool = false,
                        group: String? = nil) -> CleanupSuggestion {
            CleanupSuggestion(url: home.appendingPathComponent(relative, isDirectory: directory), bytes: Int64(gb * Double(gigabyte)),
                              modified: Date().addingTimeInterval(-daysAgo * 86_400), isDirectory: directory, action: action,
                              reason: reason, allowed: allowed, learned: learned, cautions: [], duplicateGroup: group, habit: habit)
        }
        let redundant = "Лишняя копия: содержимое то же, что у копии, которая остаётся."
        return [
            suggestion("Library/Developer/Xcode/DerivedData", 18.4, .trash,
                       "Промежуточные файлы сборки Xcode — пересоздаются при следующей сборке.", allowed: [.trash, .keep], daysAgo: 0),
            suggestion("Downloads/Xcode_16.xip", 7.9, .trash,
                       "Установщик: если программа уже стоит, он не нужен, а скачать его можно снова.",
                       allowed: [.trash, .safe, .keep], daysAgo: 60, directory: false),
            suggestion("Movies/Съёмки 2023", 86.4, .safe,
                       "Большое и давно не менялось — в сейфе не мешает, а вернуть можно в любой момент.",
                       allowed: [.safe, .backup, .keep], daysAgo: 210),
            suggestion("Downloads/Датасеты", 24.1, .safe, "В прошлый раз вы выбрали это же.",
                       allowed: [.safe, .backup, .keep], daysAgo: 150, learned: true),
            // Привычки — те, что выучены на решениях из `decisions()`.
            suggestion("Movies/Интервью 2024", 12.6, .safe,
                       "Похожее вы обычно убираете в сейф (5 из 5): папки в «Фильмах» больше 10 ГБ.",
                       allowed: [.safe, .backup, .keep], daysAgo: 50, habit: true),
            suggestion("Projects/offload-site", 1.2, .backup,
                       "Похоже на проект (внутри git): его лучше держать в бэкапе, а не переносить.",
                       allowed: [.safe, .backup, .keep], daysAgo: 120),
            suggestion("Pictures/Photos Library.photoslibrary", 41.7, .keep,
                       "«Photos Library.photoslibrary» зарегистрирован в приложении (виртуальная машина, медиатека или проект). После переноса приложение его потеряет, даже если данные целы.",
                       allowed: [.keep], daysAgo: 1),
            suggestion("Documents/Архив 2019", 9.4, .keep,
                       "Похожее вы обычно оставляете (4 из 4): папки в «Документах» от 1 до 10 ГБ, не менялись больше года.",
                       allowed: [.safe, .backup, .keep], daysAgo: 900, habit: true),
            suggestion("Documents/Работа", 8.1, .keep, "Менялось недавно — похоже, вы этим пользуетесь.",
                       allowed: [.safe, .backup, .keep], daysAgo: 2),
            suggestion("Movies/Отпуск 2023.mov", 2.4, .keep,
                       "Лежит на своём месте, а не в Загрузках или на Рабочем столе, — эта копия остаётся.",
                       allowed: [.trash, .keep], daysAgo: 300, directory: false, group: "demo-video"),
            suggestion("Downloads/Отпуск 2023.mov", 2.4, .trash, redundant, allowed: [.trash, .keep], daysAgo: 40,
                       directory: false, group: "demo-video"),
            suggestion("Desktop/Отпуск 2023 (1).mov", 2.4, .trash, redundant, allowed: [.trash, .keep], daysAgo: 12,
                       directory: false, group: "demo-video"),
            suggestion("Documents/Договор аренды.pdf", 0.014, .keep, "Имя без «(1)» и «копия» — похоже на оригинал, он остаётся.",
                       allowed: [.trash, .keep], daysAgo: 90, directory: false, group: "demo-pdf"),
            suggestion("Downloads/Договор аренды (1).pdf", 0.014, .trash, redundant, allowed: [.trash, .keep], daysAgo: 30,
                       directory: false, group: "demo-pdf"),
        ]
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
        // Установщики из «Загрузок» удаляет, как и советуют правила; отснятое в «Фильмах» убирает в сейф;
        // старые папки в «Документах» оставляет, хотя Offload предлагал сейф.
        let installers = ["Figma-124.dmg", "Zoom.pkg", "Docker.dmg", "OBS-Studio-30.dmg", "Blender-4.1.dmg", "Telegram.dmg"]
        return installers.enumerated().map { index, name in
            decision("Downloads/\(name)", .trash, suggested: .trash, kind: .file, 0.3 + Double(index) * 0.2,
                     daysAgo: 20 + Double(index) * 9, decidedDaysAgo: 30 + Double(index) * 20)
        } + ["Съёмки 2019", "Съёмки 2020", "Свадьба Ани", "Съёмки 2021", "Съёмки 2022"].enumerated().map { index, name in
            decision("Movies/\(name)", .safe, suggested: .safe, kind: .folder, 18 + Double(index) * 11,
                     daysAgo: 200 + Double(index) * 60, decidedDaysAgo: 20 + Double(index) * 25)
        } + ["Архив 2015", "Архив 2016", "Архив 2017", "Архив 2018"].enumerated().map { index, name in
            decision("Documents/\(name)", .keep, suggested: .safe, kind: .folder, 2.5 + Double(index) * 1.5,
                     daysAgo: 400 + Double(index) * 200, decidedDaysAgo: 10 + Double(index) * 30)
        }
    }

    static var backupSources: [URL] {
        ["Projects", "Documents", "Desktop"].map { home.appendingPathComponent($0, isDirectory: true) }
    }
}
