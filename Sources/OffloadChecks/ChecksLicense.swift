import CryptoKit
import Foundation
import OffloadCore

/// Offload Pro: ключ проверяется подписью без сети, чужой и испорченный не проходят,
/// проба и ранние пользователи считаются так, как обещано в окне «Offload Pro».
func checksLicense() {
    let signer = Curve25519.Signing.PrivateKey()
    let publicKey = signer.publicKey.rawRepresentation.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    let issued = LicenseCodec.day("2026-09-27")!
    let until = LicenseCodec.day("2027-09-27")!
    let license = License(id: "a1b2c3d4", name: "Анна «тест» / QA", issued: issued, updatesUntil: until)

    section("Pro: ключ") {
        let key = try LicenseCodec.issue(license, privateKey: signer)
        check(key.hasPrefix("OFFLOAD-"), "ключ начинается с OFFLOAD-")
        check(try LicenseCodec.verify(key, publicKey: publicKey) == license, "свой ключ проверяется и читается как выпущен")
        // Письма и мессенджеры переносят длинные строки и добавляют пробелы по краям.
        let wrapped = "  " + stride(from: 0, to: key.count, by: 40).map { i -> String in
            let start = key.index(key.startIndex, offsetBy: i)
            return String(key[start..<(key.index(start, offsetBy: 40, limitedBy: key.endIndex) ?? key.endIndex)])
        }.joined(separator: "\n") + "\n"
        check(try LicenseCodec.verify(wrapped, publicKey: publicKey) == license, "ключ с переносами строк и пробелами проходит")

        let stranger = Curve25519.Signing.PrivateKey()
        let forged = try LicenseCodec.issue(license, privateKey: stranger)
        expectError("ключ, подписанный чужим ключом, не проходит", { _ = try LicenseCodec.verify(forged, publicKey: publicKey) },
                    matching: { $0 as? LicenseError == .badSignature })

        // Подмена срока обновлений в содержимом при прежней подписи.
        let parts = key.dropFirst(LicenseCodec.prefix.count).split(separator: ".")
        let body = Data(base64Encoded: base64(String(parts[0])))!
        let tampered = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "2027-09-27", with: "2099-09-27")
        let tamperedKey = LicenseCodec.prefix + base64URL(Data(tampered.utf8)) + "." + parts[1]
        expectError("ключ с продлённым вручную сроком не проходит", { _ = try LicenseCodec.verify(tamperedKey, publicKey: publicKey) },
                    matching: { $0 as? LicenseError == .badSignature })

        for garbage in ["", "OFFLOAD-", "OFFLOAD-abc", "OFFLOAD-абв.где", "offload-" + key.dropFirst(8), "OFFLOAD-..", String(key.dropLast(4))] {
            expectError("мусор «\(garbage.prefix(20))» не проходит", { _ = try LicenseCodec.verify(garbage, publicKey: publicKey) })
        }
        check(LicenseCodec.publicKey.count == 43 && Data(base64Encoded: base64(LicenseCodec.publicKey))?.count == 32,
              "в программе настоящий открытый ключ Ed25519")
    }

    section("Pro: какие версии открывает ключ") {
        check(license.covers(release: nil), "сборка из исходников без даты выхода — открывается")
        check(license.covers(release: LicenseCodec.day("2027-09-27")), "версия, вышедшая в последний день обновлений, — открывается")
        check(!license.covers(release: LicenseCodec.day("2027-09-28")), "версия, вышедшая позже, — нет")
    }

    section("Pro: проба, ранние пользователи, продление") {
        let start = LicenseCodec.day("2026-10-01")!
        func at(_ days: Int) -> Date { start.addingTimeInterval(TimeInterval(days) * 86_400 + 3_600) }
        let later = LicenseCodec.day("2028-01-01")
        check(ProStatus.resolve(license: nil, release: nil, early: false, trialStarted: start, now: at(0)) == .trial(daysLeft: 14),
              "в первый день проба — 14 дней")
        check(ProStatus.resolve(license: nil, release: nil, early: false, trialStarted: start, now: at(13)) == .trial(daysLeft: 1),
              "на 14-й день — остался один")
        check(ProStatus.resolve(license: nil, release: nil, early: false, trialStarted: start, now: at(14)) == .free,
              "на 15-й день — бесплатная версия")
        check(ProStatus.resolve(license: nil, release: nil, early: true, trialStarted: nil, now: at(400)).isPro,
              "ранний пользователь — Pro без срока")
        check(ProStatus.resolve(license: license, release: nil, early: false, trialStarted: start, now: at(400)) == .licensed(license),
              "ключ — Pro и после пробы")
        check(ProStatus.resolve(license: license, release: later, early: false, trialStarted: start, now: at(400)) == .expired(license),
              "версия новее конца обновлений — просит продлить, а не молчит")
        check(ProStatus.resolve(license: license, release: later, early: false, trialStarted: start, now: at(3)) == .trial(daysLeft: 11),
              "ключ, не подходящий к версии, пробу не отнимает")
        check(ProStatus.resolve(license: license, release: later, early: true, trialStarted: nil, now: at(400)) == .early,
              "ранний пользователь с просроченным ключом — всё открыто")
        // Часы переведены назад — проба не становится длиннее 14 дней.
        check(ProStatus.resolve(license: nil, release: nil, early: false, trialStarted: start, now: at(-30)) == .trial(daysLeft: 14),
              "часы назад не удлиняют пробу")
    }

    section("Pro: что закрыто, а что нет") {
        check(CleanupQuestion.Kind.module(.duplicates).proFeature == .duplicates, "лишние копии — Pro")
        check(CleanupQuestion.Kind.module(.projects).proFeature == .projectBackup, "проекты в бэкап — Pro")
        // То, что освобождает место без риска и возвращает своё, — бесплатно всегда.
        for kind: CleanupQuestion.Kind in [.module(.junk), .module(.safe), .module(.installers), .docker] {
            check(kind.proFeature == nil, "\(kind) — бесплатно")
        }
    }
}

private func base64(_ url: String) -> String {
    var s = url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    return s
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
