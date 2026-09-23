import Foundation
import OffloadCore

/// Проверки под сообщения интерфейса о возврате. Интерфейс собой проверить нельзя (Offload —
/// отдельная программа, не библиотека), поэтому проверяется то, на чём эти сообщения держатся:
/// какие оговорки ядро действительно отдаёт и что оно делает с архивом при отмене.
func checksInterface() {
    guard ProcessInfo.processInfo.environment["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Сообщения после возврата: пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }
    section("Сообщения после возврата") {
        let room = fm.temporaryDirectory.appendingPathComponent("offload-checks-ui-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: room, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: room) }
        let image = room.appendingPathComponent("ui.sparseimage")
        try Runner.check("hdiutil", ["create", "-size", "512m", "-type", "SPARSE", "-fs", "ExFAT", "-volname", "OFFCHECKUI", "-quiet", image.path], timeout: 180)
        guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path], timeout: 120).stdout) else {
            throw CopyError.unreadable(image.path)
        }
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
        guard Volumes.info(for: mount) != nil else { throw CopyError.unreadable(mount.path) }
        let rules = SafetyRules(home: room.appendingPathComponent("home", isDirectory: true))
        let mover = SafeMover(rules: rules)

        // Возврат переноса, сделанного мимо Offload: списка сумм рядом с архивом нет, права
        // exFAT не хранит. Раньше эти оговорки ядра нигде не показывались, и человек видел
        // «каждый файл сверен по SHA-256» — при том что сверить архив было не с чем.
        let manual = mount.appendingPathComponent("Вручную/папка", isDirectory: true)
        try write("данные", to: manual.appendingPathComponent("file.txt"))
        let imported = try mover.importRecord(archived: manual, original: rules.home.appendingPathComponent("Downloads/папка"),
                                              originalRemoved: true, note: nil)
        let outcome = try mover.restore(imported, deleteArchive: false)
        check(!outcome.notes.isEmpty, "возврат без списка сумм возвращает оговорки, а не молчаливый успех")
        check(outcome.notes.allSatisfy { !$0.isEmpty }, "оговорки не пустые — плашке есть что показать")

        // Текст отмены обещает, что архив на диске не тронут. Отмена ловится до того,
        // как дело доходит до удаления архива, — иначе обещание было бы ложью.
        let other = mount.appendingPathComponent("Вручную/вторая", isDirectory: true)
        try write("данные", to: other.appendingPathComponent("file.txt"))
        let second = try mover.importRecord(archived: other, original: rules.home.appendingPathComponent("Downloads/вторая"),
                                            originalRemoved: true, note: nil)
        expectError("отменённый возврат заканчивается отменой, а не тихим успехом",
                    { _ = try mover.restore(second, deleteArchive: true, isCancelled: { true }) },
                    matching: { $0 is CancellationError })
        check(fm.fileExists(atPath: other.appendingPathComponent("file.txt").path),
              "после отмены архив на диске на месте — как и написано в сообщении")
        check(!fm.fileExists(atPath: rules.home.appendingPathComponent("Downloads/вторая").path),
              "после отмены на месте оригинала ничего не создано")
    }
}
