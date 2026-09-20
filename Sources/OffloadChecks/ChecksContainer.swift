import Foundation
import OffloadCore

// Проверки на подделку зашифрованного контейнера и на оценку свободного места.
// Вызывается из main.swift; check/expectError/section берутся оттуда же — это один модуль.

func checksContainer() {
    section("Место на приёмнике: мелкие файлы и разрежённые") {
        // Тысяча мелких файлов: логически весят копейки, а на диске каждый занял целый блок.
        // Раньше оценка шла по логическому размеру — проверка пропускала перенос, которому
        // места заведомо не хватит.
        var small = ContentReport()
        small.files = 20_000
        small.directories = 500
        small.logicalBytes = 20_000 * 200           // ~4 МБ на бумаге
        small.allocatedBytes = 20_000 * 4096        // ~78 МБ на диске
        let roomy = probeVolume(free: 100 << 30)
        let smallCheck = SafetyRules.checkDestination(roomy, sourceVolume: nil, content: small)
        check(smallCheck.requiredBytes >= small.allocatedBytes,
              "оценка места для дерева мелких файлов не меньше занятого на диске: \(smallCheck.requiredBytes) против \(small.allocatedBytes)")
        check(smallCheck.isOK, "на просторном диске перенос мелких файлов всё равно разрешён: \(smallCheck.blockers)")

        // Свободного места хватает на логический размер с запасом, но не на реально занятое —
        // ровно тот случай, когда проверка проходила, а перенос падал посередине.
        let margin: Int64 = 512 * 1024 * 1024
        let tight = probeVolume(free: (small.logicalBytes + small.allocatedBytes) / 2 + margin)
        check(tight.availableBytes > small.logicalBytes + margin,
              "условие задачи: по логическому размеру места хватало бы — иначе проверка ниже ничего не доказывает")
        check(!SafetyRules.checkDestination(tight, sourceVolume: nil, content: small).isOK,
              "места хватает только по логическому размеру — перенос запрещён")

        // Обратный случай: у разрежённого файла занятое мало, а писаться он будет целиком.
        // Оговорка про разрежённые файлы и счёт по логическому размеру должны остаться.
        var sparse = ContentReport()
        sparse.files = 1
        sparse.directories = 1
        sparse.logicalBytes = 200 << 30
        sparse.allocatedBytes = 20 << 30
        sparse.sparseFiles = 1
        let sparseCheck = SafetyRules.checkDestination(probeVolume(free: 60 << 30), sourceVolume: nil, content: sparse)
        check(sparseCheck.requiredBytes >= sparse.logicalBytes, "разрежённый файл считается по логическому размеру")
        check(!sparseCheck.isOK, "разрежённый файл на 200 ГБ не пускают туда, где свободно 60 ГБ")
        check(sparseCheck.notes.contains { $0.contains("Разрежённые") }, "оговорка про разрежённые файлы на месте")
    }

    guard ProcessInfo.processInfo.environment["OFFLOAD_SKIP_INTEGRATION"] != "1" else {
        print("▸ Контейнер: подделанный заголовок — пропущено (OFFLOAD_SKIP_INTEGRATION=1)")
        return
    }

    section("Контейнер: подделанный заголовок шифрования") {
        let root = scratch.appendingPathComponent("vault-forgery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Имена выбраны так, что по алфавиту подделка идёт первой: если отсев не сработает,
        // именно её программа и предложит как «ваш контейнер».
        let forged = root.appendingPathComponent("AAA-Подделка.sparsebundle", isDirectory: true)
        let real = root.appendingPathComponent("ZZZ-Настоящий.sparsebundle", isDirectory: true)

        // Обычный незашифрованный образ, которому дописали в token сигнатуру «encrcdsa».
        // Так выглядит атака: запись в корень внешнего диска есть у кого угодно.
        try Runner.check("hdiutil", ["create", "-size", "20m", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                                     "-volname", "ПодделкаOffload", "-quiet", forged.path], timeout: 180)
        try Data("encrcdsa".utf8).write(to: forged.appendingPathComponent("token"))

        let forgedVault = SecretsVault(imageURL: forged)
        check(forgedVault.isEncrypted, "дешёвая проверка заголовка на подделку ловится — значит, она не последняя")
        expectError("подделанный образ не открывается как контейнер",
                    { _ = try forgedVault.attach(password: "какой-угодно-пароль-123") },
                    matching: { ($0 as? VaultError) == .notEncrypted })
        check(forgedVault.currentMountPoint() == nil, "после отказа подделка не осталась подключённой")

        // В подделку не должно попасть ничего: открываем её сами и смотрим, пусто ли внутри.
        let peek = try Runner.check("hdiutil", ["attach", "-nobrowse", "-plist", forged.path], timeout: 120)
        if let mount = mountPoint(fromAttachPlist: peek.stdout) {
            defer { _ = try? Runner.run("hdiutil", ["detach", "-force", mount.path], timeout: 60) }
            let inside = ((try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? [])
                .filter { $0 != ".fseventsd" && $0 != ".Spotlight-V100" && $0 != ".Trashes" }
            check(inside.isEmpty, "в подделку ничего не записано: \(inside)")
        } else {
            check(false, "не удалось открыть подделку для осмотра")
        }

        // Настоящий зашифрованный контейнер должен открываться по паролю как раньше:
        // отказ вернуть человеку его ключи — это тоже потеря.
        let realVault = SecretsVault(imageURL: real)
        let password = "offload-check-\(UUID().uuidString)"
        try realVault.create(password: password, sizeGB: 1)
        let mount = try realVault.attach(password: password)
        var opened = true
        defer { if opened { SecretsVault.detachIgnoringErrors(mount) } }
        check(FileManager.default.fileExists(atPath: mount.path), "настоящий зашифрованный контейнер открылся по паролю")
        try Data("секрет".utf8).write(to: mount.appendingPathComponent("проверка.txt"))
        check(FileManager.default.fileExists(atPath: mount.appendingPathComponent("проверка.txt").path),
              "в открытый контейнер пишется")
        SecretsVault.detachIgnoringErrors(mount)
        opened = false

        // Выбор контейнера на диске: подделка стоит первой по алфавиту, но взять должны настоящий.
        let chosen = SecretsVault.existingEncryptedBundle(in: root)
        check(chosen?.lastPathComponent == "ZZZ-Настоящий.sparsebundle",
              "подделка не выбирается автоматически, выбран \(chosen?.lastPathComponent ?? "ничего")")
    }
}

/// Диск назначения для расчётов: APFS, ссылки хранит, служебных файлов не плодит —
/// чтобы в оценке места был виден только сам размер данных.
private func probeVolume(free: Int64) -> VolumeInfo {
    VolumeInfo(mountPoint: URL(fileURLWithPath: "/Volumes/ПробныйПриёмник"), name: "Пробный", fsType: "apfs",
               totalBytes: 500 << 30, availableBytes: free, blockSize: 4096, isReadOnly: false, isInternal: false)
}
