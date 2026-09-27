import CryptoKit
import Foundation
import OffloadCore

// Выпуск ключей Offload Pro. Нужен только автору: закрытый ключ лежит у него, не в репозитории.
//
//   swift run OffloadLicense keygen                    — завести пару ключей (один раз)
//   swift run OffloadLicense issue "Имя покупателя"     — выпустить ключ на год обновлений
//   swift run OffloadLicense issue "Имя" --days 730 --note "USDT, заказ 17"
//   swift run OffloadLicense verify OFFLOAD-…           — проверить ключ
//
// Каждый выпущенный ключ дописывается в issued.tsv рядом с закрытым ключом: номер, имя, даты, заметка.

let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OFFLOAD_LICENSE_HOME"]
    ?? (NSHomeDirectory() + "/.config/offload-license"), isDirectory: true)
let privateKeyURL = folder.appendingPathComponent("signing.key")
let ledgerURL = folder.appendingPathComponent("issued.tsv")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: privateKeyURL, encoding: .utf8),
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else { fail("Нет закрытого ключа в \(privateKeyURL.path). Сначала: swift run OffloadLicense keygen") }
    return key
}

func publicKeyString(_ key: Curve25519.Signing.PrivateKey) -> String {
    key.publicKey.rawRepresentation.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    guard !FileManager.default.fileExists(atPath: privateKeyURL.path) else {
        fail("Закрытый ключ уже есть: \(privateKeyURL.path). Новый сделал бы недействительными все выданные ключи — не перезаписываю.")
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: privateKeyURL.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600])
    else { fail("Не получилось записать \(privateKeyURL.path)") }
    print("Закрытый ключ: \(privateKeyURL.path) — сделайте его копию в сейф; потеряете — старые ключи останутся рабочими, но новых не выпустить.")
    print("Открытый ключ для LicenseCodec.publicKey:")
    print(publicKeyString(key))

case "pubkey":
    print(publicKeyString(loadPrivateKey()))

case "issue":
    guard args.count >= 2, !args[1].hasPrefix("--") else { fail("Использование: issue \"Имя покупателя\" [--days 365] [--note текст]") }
    let name = args[1].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= 80, !name.contains("\t"), !name.contains("\n") else { fail("Имя — одна строка до 80 знаков.") }
    let days = Int(option("--days", in: args) ?? "365") ?? 365
    let note = (option("--note", in: args) ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    let key = loadPrivateKey()
    let now = Date()
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    let license = License(id: id, name: name, issued: now, updatesUntil: now.addingTimeInterval(TimeInterval(days) * 86_400))
    let text = try LicenseCodec.issue(license, privateKey: key)
    // Сразу проверяем тем же путём, что и программа: ключ, который не откроется у покупателя, не выдаём.
    guard let checked = try? LicenseCodec.verify(text, publicKey: publicKeyString(key)), checked.id == id, checked.name == name,
          LicenseCodec.dayString(checked.updatesUntil) == LicenseCodec.dayString(license.updatesUntil) else {
        fail("Выпущенный ключ не прошёл проверку — не выдавайте его.")
    }
    if publicKeyString(key) != LicenseCodec.publicKey {
        FileHandle.standardError.write(Data("⚠️  Этот закрытый ключ не совпадает с открытым в LicenseCodec.publicKey: программа такой ключ не примет.\n".utf8))
    }
    let line = [id, name, LicenseCodec.dayString(license.issued), LicenseCodec.dayString(license.updatesUntil), note].joined(separator: "\t") + "\n"
    if !FileManager.default.fileExists(atPath: ledgerURL.path) {
        FileManager.default.createFile(atPath: ledgerURL.path, contents: Data("id\tname\tissued\tuntil\tnote\n".utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
    guard let ledger = try? FileHandle(forWritingTo: ledgerURL) else { fail("Не открылся \(ledgerURL.path)") }
    ledger.seekToEndOfFile()
    ledger.write(Data(line.utf8))
    try ledger.close()
    print(text)

case "verify":
    guard args.count >= 2 else { fail("Использование: verify OFFLOAD-…") }
    do {
        let license = try LicenseCodec.verify(args.dropFirst().joined())
        print("Ключ верный: \(license.name), №\(license.id), выдан \(LicenseCodec.dayString(license.issued)), обновления до \(LicenseCodec.dayString(license.updatesUntil))")
    } catch {
        fail(error.localizedDescription)
    }

default:
    fail("Команды: keygen, pubkey, issue \"Имя\" [--days 365] [--note …], verify OFFLOAD-…")
}
