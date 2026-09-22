import Darwin
import Foundation
import OffloadCore

// Проверки сейфа: пароль, настоящий зашифрованный образ, заголовок, место, закрытие
// и перенос открытых архивов внутрь. Пароли — только через stdin: ни одна проверка
// не должна вызвать системное окно с запросом пароля.

private func safeHostMount(_ name: String, fs: String, volumeName: String, sizeMB: Int) throws -> URL {
    let image = scratch.appendingPathComponent(name)
    try Runner.check("hdiutil", ["create", "-size", "\(sizeMB)m", "-type", "SPARSE", "-fs", fs,
                                 "-volname", volumeName, "-quiet", image.path], timeout: 180)
    guard let mount = mountPoint(fromAttachPlist: try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", image.path],
                                                                   timeout: 120).stdout) else {
        throw CopyError.unreadable(image.path)
    }
    return mount
}

func checksSafe() {
    section("Сейф: оценка пароля") {
        for weak in ["short", "Qwerty123!", "password12345678", "aaaaaaaaaaaaaaaaaaaa", "12345678901234567890", "йцукенйцукен"] {
            check(!PasswordStrength.evaluate(weak).isAcceptable, "слабый пароль «\(weak)» не принимается (≈\(Int(PasswordStrength.evaluate(weak).bits)) бит)")
        }
        for strong in ["correct horse battery staple", "лось ест сено у реки в пять утра", "t7#Kp9!vQ2@xZ4&m"] {
            check(PasswordStrength.evaluate(strong).isAcceptable, "стойкий пароль «\(strong)» принимается (≈\(Int(PasswordStrength.evaluate(strong).bits)) бит)")
        }
        check(PasswordStrength.evaluate("лось ест сено у реки в пять утра").level >= .good, "фраза из случайных слов оценивается как надёжная")
        check(PasswordStrength.evaluate("").bits == 0, "пустой пароль — ноль бит")
        check(PasswordStrength.evaluate("password-and-more-words").advice.contains { $0.contains("password") },
              "словарное слово названо в совете, а не просто снижает оценку")
    }

    guard env["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Сейф на настоящих образах — пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }

    section("Сейф: создание, занятость, место, заголовок, пароль") {
        let folder = scratch.appendingPathComponent("safe-ops", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("Сейф проверки.sparsebundle", isDirectory: true)
        let vault = SecretsVault(imageURL: image)
        let first = "первый пароль сейфа для проверки 2026"
        let second = "второй пароль сейфа тоже длинный 2026"

        expectError("слабым паролем сейф не создаётся",
                    { try vault.create(password: "Qwerty123!", maxBytes: 256 << 20, volumeName: "OffloadCheckOps") },
                    matching: { ($0 as? VaultError) == .weakPassword })
        try vault.create(password: first, maxBytes: 8 << 30, volumeName: "OffloadCheckOps")
        check((vault.sizeLimit ?? 0) >= 7 << 30, "предел образа — сколько просили: \(vault.sizeLimit ?? 0)")
        check(vault.allocatedBytes < 256 << 20, "образ разрежённый: на диске занимает \(vault.allocatedBytes) байт, а не 8 ГБ")
        let info = SecretsVault.encryptionInfo(of: image)
        check(info?.encrypted == true && info?.passphraseCount == 1 && info?.uuid != nil,
              "macOS без пароля подтверждает: зашифрован, один пароль, есть UUID — \(String(describing: info))")
        check(vault.isEncrypted, "настоящий сейф признан зашифрованным")

        // Место: свободным считается меньшее из свободного внутри образа и на диске-хозяине.
        var mount = try vault.attach(password: first)
        let tinyHost = VolumeInfo(mountPoint: folder, name: "Почти полный диск", fsType: "exfat", totalBytes: 10 << 30,
                                  availableBytes: Volumes.safeHostReserve + (5 << 20), blockSize: 4096,
                                  isReadOnly: false, isInternal: false)
        let clamped = Volumes.safe(mountedAt: mount, host: tinyHost)
        check(clamped?.isEncryptedImage == true, "том сейфа помечен как зашифрованный")
        check((clamped?.availableBytes ?? .max) <= 5 << 20,
              "свободное в сейфе ограничено местом на самом диске: \(clamped?.availableBytes ?? -1)")

        // Занятость: пока в сейфе открыт файл, обычное закрытие отказывает, а не обрывает чужую работу.
        let busyFile = mount.appendingPathComponent("открыт.txt")
        try write("держу открытым", to: busyFile)
        let handle = try FileHandle(forReadingFrom: busyFile)
        expectError("сейф с открытым файлом без force не закрывается", { try SecretsVault.detach(mount) },
                    matching: { ($0 as? VaultError) == .busy })
        try handle.close()
        try SecretsVault.detach(mount)
        check(vault.currentMountPoint() == nil, "после закрытия файла сейф закрылся")

        // Сжатие. macOS возвращает освобождённое внутри место на диск не всегда: на образе
        // с пределом 8 ГБ проверено — «Reclaimed 0 bytes out of 7.7 GB possible», хотя 40 МБ
        // удалены. На маленьком образе возвращает. Поэтому проверяем нашу часть работы —
        // пароль через stdin, отказ с чужим паролем, закрытый сейф — там, где поведение
        // macOS определённое, а человеку честно показываем, сколько вернулось на самом деле.
        let small = SecretsVault(imageURL: folder.appendingPathComponent("Маленький.sparsebundle", isDirectory: true))
        try small.create(password: first, maxBytes: 96 << 20, volumeName: "OffloadCheckSmall")
        mount = try small.attach(password: first)
        let big = mount.appendingPathComponent("большой.bin")
        var random = Data(count: 40 << 20)
        random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try random.write(to: big)
        try SecretsVault.detach(mount)
        let filled = small.allocatedBytes
        mount = try small.attach(password: first)
        expectError("открытый сейф не сжимается", { try small.compact(password: first) },
                    matching: { ($0 as? VaultError) == .busy })
        try fm.removeItem(at: big)
        sync()
        try SecretsVault.detach(mount)
        check(small.allocatedBytes > filled - (8 << 20), "удалённое внутри сейфа место само на диск не возвращается")
        expectError("сжатие чужим паролем не идёт", { try small.compact(password: second) },
                    matching: { ($0 as? VaultError) == .wrongPassword })
        try small.compact(password: first)
        check(small.allocatedBytes < filled - (20 << 20), "после сжатия место вернулось: было \(filled), стало \(small.allocatedBytes)")

        // Резервная копия заголовка.
        let backups = scratch.appendingPathComponent("header-backups", isDirectory: true)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = try vault.backupHeader(to: backups)
        check(mode(backup) == 0o600, "копия заголовка доступна только владельцу")
        expectError("вторая копия в ту же папку первую не затирает", { _ = try vault.backupHeader(to: backups) },
                    matching: { ($0 as? VaultError) == .alreadyExists })

        let token = image.appendingPathComponent("token")
        let original = try Data(contentsOf: token)
        try Data(count: original.count).write(to: token)
        expectError("с испорченным заголовком сейф не открывается даже верным паролем", { _ = try vault.attach(password: first) })
        expectError("чужой пароль к копии заголовка не подходит", { try vault.restoreHeader(from: backup, password: second) },
                    matching: { if case VaultError.headerRejected = $0 { return true }; return false })
        check(try Data(contentsOf: token) == Data(count: original.count), "после неудачи прежний заголовок остался как был")
        try vault.restoreHeader(from: backup, password: first)
        check(try Data(contentsOf: token) == original, "заголовок восстановлен из копии байт в байт")
        check(!fm.fileExists(atPath: image.appendingPathComponent("token.offload-previous").path),
              "испорченный заголовок внутри образа не оставлен")
        mount = try vault.attach(password: first)
        try SecretsVault.detach(mount)

        // Смена пароля и та самая оговорка VeraCrypt: старая копия заголовка открывается старым паролем.
        expectError("неверный текущий пароль пароль не меняет",
                    { try vault.changePassword(old: "совсем не тот пароль 2026 года", new: second) },
                    matching: { ($0 as? VaultError) == .wrongPassword })
        expectError("слабый новый пароль не принимается", { try vault.changePassword(old: first, new: "short") },
                    matching: { ($0 as? VaultError) == .weakPassword })
        try vault.changePassword(old: first, new: second)
        expectError("после смены старый пароль не открывает", { _ = try vault.attach(password: first) },
                    matching: { ($0 as? VaultError) == .wrongPassword })
        mount = try vault.attach(password: second)
        check(fm.fileExists(atPath: mount.path), "новый пароль открывает")
        try SecretsVault.detach(mount)
        try vault.restoreHeader(from: backup, password: first)
        mount = try vault.attach(password: first)
        check(fm.fileExists(atPath: mount.path), "старая копия заголовка возвращает старый пароль — об этом и предупреждает Offload")
        try SecretsVault.detach(mount)

        // Копия заголовка от другого сейфа не принимается.
        let other = SecretsVault(imageURL: folder.appendingPathComponent("Другой.sparsebundle", isDirectory: true))
        try other.create(password: second, maxBytes: 128 << 20, volumeName: "OffloadCheckOther")
        let otherBackup = try other.backupHeader(to: backups)
        expectError("копия заголовка другого сейфа отклоняется", { try vault.restoreHeader(from: otherBackup, password: second) },
                    matching: { if case VaultError.headerRejected = $0 { return true }; return false })
    }

    section("Сейф: зашифровать перенесённое") {
        let hostMount = try safeHostMount("safe-host.sparseimage", fs: "ExFAT", volumeName: "OFFSAFEHOST", sizeMB: 2048)
        defer { _ = try? Runner.run("hdiutil", ["detach", "-force", hostMount.path], timeout: 60) }
        guard let host = Volumes.info(for: hostMount) else { throw CopyError.unreadable(hostMount.path) }

        let password = "пароль сейфа на пробном диске 2026"
        let vault = SecretsVault(imageURL: hostMount.appendingPathComponent(SecretsVault.safeImageName, isDirectory: true))
        try vault.create(password: password, maxBytes: 768 << 20, volumeName: "OffloadCheckSafe")
        check(SecretsVault(on: host).imageURL.lastPathComponent == SecretsVault.safeImageName, "свой сейф на диске находится первым")
        let safeMount = try vault.attach(password: password)
        defer { SecretsVault.detachIgnoringErrors(safeMount) }
        guard let safe = Volumes.safe(mountedAt: safeMount, host: host) else { throw CopyError.unreadable(safeMount.path) }

        let rules = SafetyRules(home: scratch.appendingPathComponent("home-safe", isDirectory: true))
        let mover = SafeMover(rules: rules)
        let source = rules.home.appendingPathComponent("Documents/Сканы паспорта", isDirectory: true)
        try write("очень личное", to: source.appendingPathComponent("страница 1.txt"))
        try write("ещё личное", to: source.appendingPathComponent("вложено/страница 2.txt"))
        try write("#!/bin/sh\necho ok\n", to: source.appendingPathComponent("run.sh"))
        chmod(source.appendingPathComponent("run.sh").path, 0o755)

        // Перенос прямо в сейф помечается в журнале как зашифрованный.
        let direct = rules.home.appendingPathComponent("Documents/Сразу в сейф", isDirectory: true)
        try write("сразу", to: direct.appendingPathComponent("a.txt"))
        let directRecord = try mover.execute(mover.plan(source: direct, volume: safe), deleteOriginal: true, acceptCautions: true)
        check(directRecord.isEncrypted && directRecord.archivedPath.hasPrefix(safeMount.path + "/"),
              "перенос в сейф ложится в сейф и помечен зашифрованным")

        // А это — старый открытый перенос, который теперь надо зашифровать.
        let open = try mover.execute(mover.plan(source: source, volume: host), deleteOriginal: true, acceptCautions: true)
        check(!open.isEncrypted, "перенос на открытую часть диска помечен как незашифрованный")
        let moved = try mover.relocate(open, into: safe)
        check(moved.isEncrypted && moved.archivedPath.hasPrefix(safeMount.path + "/"), "архив переехал в сейф")
        check(moved.id == open.id, "это та же запись журнала, а не новая")
        check(!fm.fileExists(atPath: open.archivedPath), "открытая копия удалена")
        check(!fm.fileExists(atPath: open.archivedPath + ".sha256"), "список сумм рядом с открытой копией тоже убран")
        check(fm.fileExists(atPath: moved.archivedPath + ".sha256"), "список сумм переехал вместе с архивом")
        check(!Journal.records(on: host).contains { $0.id == open.id }, "в журнале открытой части записи больше нет")
        check(Journal.records(on: safe).contains { $0.id == open.id && $0.isEncrypted }, "в журнале внутри сейфа запись есть")
        check(Journal.localRecords().first { $0.id == open.id }?.archivedPath == moved.archivedPath,
              "локальный журнал указывает на сейф")
        expectError("архив, уже лежащий в сейфе, второй раз не переносится", { _ = try mover.relocate(moved, into: safe) })

        // Ручной перенос, лежащий вне папки Offload (как модели LM Studio), тоже переезжает.
        let manual = hostMount.appendingPathComponent("Модели", isDirectory: true)
        try write("веса", to: manual.appendingPathComponent("model.bin"))
        let imported = try mover.importRecord(archived: manual, original: rules.home.appendingPathComponent("Модели"), originalRemoved: true)
        let movedManual = try mover.relocate(imported, into: safe)
        check(movedManual.archivedPath == safeMount.appendingPathComponent("Offload/Модели").path,
              "ручной перенос ложится в сейф под своим именем: \(movedManual.archivedPath)")
        check(!fm.fileExists(atPath: manual.path), "открытая папка ручного переноса удалена")

        // Возврат из сейфа — как раньше, со сверкой и правами.
        let outcome = try mover.restore(moved, deleteArchive: true)
        check(try String(contentsOf: source.appendingPathComponent("вложено/страница 2.txt"), encoding: .utf8) == "ещё личное",
              "данные вернулись из сейфа")
        check(mode(source.appendingPathComponent("run.sh")) == 0o755, "права вернулись из списка, приехавшего в сейф")
        check(!outcome.needsAttention, "возврат из сейфа прошёл без поводов для тревоги: \(outcome.notes)")
    }
}
