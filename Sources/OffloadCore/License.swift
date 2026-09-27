import CryptoKit
import Foundation

/// OffLoadAI Pro: что в нём и как проверяется ключ.
///
/// Правила, из которых всё остальное:
/// - Ключ проверяется на этом Mac, без сети: подпись Ed25519 над содержимым ключа.
///   OffLoadAI не ходит на сервер ни при покупке, ни при запуске.
/// - Pro никогда не стоит между человеком и его данными. Сейф, перенос со сверкой, возврат
///   перенесённого, возврат тома Docker, восстановление из iCloud, ключи и токены в сейф,
///   очистка мусора — бесплатны всегда. Pro — это удобство и инструменты сверху.
/// - Кончилась пробная неделя посреди работы — начатое доделывается; ограничение действует
///   только на новое «да».
public enum ProFeature: String, CaseIterable, Sendable, Hashable {
    /// «Удалить лишние копии?» в разборе.
    case duplicates
    /// Привычки: похожее само попадает в нужный вопрос.
    case habits
    /// Обновляемый бэкап проектов и вопрос «Добавить проекты в бэкап?».
    case projectBackup
    /// Упаковать тома Docker в сейф и убрать из Docker. Вернуть том — бесплатно.
    case dockerVolumes

    public var title: String {
        switch self {
        case .duplicates: return "Лишние копии"
        case .habits: return "Привычки"
        case .projectBackup: return "Бэкап проектов"
        case .dockerVolumes: return "Тома Docker в сейф"
        }
    }

    public var detail: String {
        switch self {
        case .duplicates: return "Одинаковые файлы находятся по SHA-256, одна копия остаётся всегда, лишние уходят в Корзину."
        case .habits: return "OffLoadAI учится на ваших ответах и сам кладёт похожее в нужный вопрос."
        case .projectBackup: return "Обновляемая копия папок с проектами в сейф: копируется только изменённое."
        case .dockerVolumes: return "Неиспользуемые тома упаковываются в сейф со сверкой каждого файла."
        }
    }

    public var symbol: String {
        switch self {
        case .duplicates: return "doc.on.doc"
        case .habits: return "sparkles"
        case .projectBackup: return "externaldrive.badge.checkmark"
        case .dockerVolumes: return "shippingbox"
        }
    }
}

/// Проверенный ключ: кому выдан и до какой даты выходящие версии им открываются.
public struct License: Sendable, Hashable, Codable {
    /// Номер ключа — по нему ключ находят в списке выданных (возврат денег, замена).
    public var id: String
    /// Как ключ подписан в окне «OffLoadAI Pro»: имя или ник покупателя.
    public var name: String
    public var issued: Date
    /// Версии, вышедшие до этой даты, открываются ключом навсегда; вышедшие позже — нужно продлить.
    public var updatesUntil: Date

    public init(id: String, name: String, issued: Date, updatesUntil: Date) {
        self.id = id
        self.name = name
        self.issued = issued
        self.updatesUntil = updatesUntil
    }

    /// Открывает ли ключ версию, вышедшую в этот день. Без даты (сборка из исходников) — открывает.
    public func covers(release: Date?) -> Bool {
        guard let release else { return true }
        return release <= updatesUntil
    }
}

public enum LicenseError: Error, LocalizedError, Equatable {
    case malformed
    case badSignature
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .malformed: return "Это не похоже на ключ OffLoadAI Pro. Скопируйте его целиком, вместе с «OFFLOAD-»."
        case .badSignature: return "Ключ не подходит: подпись не сходится. Возможно, в нём опечатка — скопируйте его заново."
        case .unsupportedVersion: return "Ключ выпущен для более новой версии OffLoadAI. Обновите программу."
        }
    }
}

/// Формат ключа: `OFFLOAD-<содержимое>.<подпись>`, обе части — base64url без `=`.
/// Содержимое — JSON с полями v, id, name, issued, until (даты — ISO 8601, день).
/// Пробелы и переносы строк внутри ключа игнорируются: письма и мессенджеры любят их вставлять.
public enum LicenseCodec {
    public static let prefix = "OFFLOAD-"
    static let formatVersion = 1

    /// Открытый ключ OffLoadAI: им проверяются все ключи Pro. Закрытый — только у автора, не в репозитории.
    public static let publicKey = "5oVE56bMjfoHIRATsWD3zx4KO9t5suncTNJG7qv7wqk"

    private struct Payload: Codable {
        var v: Int
        var id: String
        var name: String
        var issued: String
        var until: String
    }

    public static func verify(_ text: String, publicKey: String = publicKey) throws -> License {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.hasPrefix(prefix) else { throw LicenseError.malformed }
        let parts = compact.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let body = Data(base64URL: String(parts[0])),
              let signature = Data(base64URL: String(parts[1])),
              let keyData = Data(base64URL: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else { throw LicenseError.malformed }
        // Подпись — над байтами содержимого как они есть, до разбора JSON.
        guard key.isValidSignature(signature, for: body) else { throw LicenseError.badSignature }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else { throw LicenseError.malformed }
        guard payload.v == formatVersion else { throw LicenseError.unsupportedVersion }
        guard let issued = day(payload.issued), let until = day(payload.until) else { throw LicenseError.malformed }
        return License(id: payload.id, name: payload.name, issued: issued, updatesUntil: until)
    }

    /// Выпуск ключа — только у автора, с закрытым ключом (`swift run OffloadLicense`).
    public static func issue(_ license: License, privateKey: Curve25519.Signing.PrivateKey) throws -> String {
        let payload = Payload(v: formatVersion, id: license.id, name: license.name,
                              issued: dayString(license.issued), until: dayString(license.updatesUntil))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(payload)
        let signature = try privateKey.signature(for: body)
        return prefix + body.base64URL + "." + signature.base64URL
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func day(_ string: String) -> Date? { dayFormatter.date(from: string) }
    public static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
}

/// Что открыто на этом Mac: ключ, пробный период, ранний пользователь или бесплатная версия.
public enum ProStatus: Sendable, Hashable {
    case licensed(License)
    /// Ключ есть, но эта версия вышла после конца его обновлений: работает прежняя, эту — продлить.
    case expired(License)
    /// Пользовался OffLoadAI до появления Pro: всё, что было, остаётся открытым.
    case early
    case trial(daysLeft: Int)
    case free

    public var isPro: Bool {
        switch self {
        case .licensed, .early, .trial: return true
        case .expired, .free: return false
        }
    }

    /// Сколько дней пробы, считая с первого запуска версии с Pro.
    public static let trialDays = 14

    /// Итог по ключу, дате выхода этой версии и началу пробы. Ключ, который не подходит к этой
    /// версии, пробу не отнимает: человек заплатил и точно не хуже того, кто не платил.
    public static func resolve(license: License?, release: Date?, early: Bool, trialStarted: Date?, now: Date) -> ProStatus {
        if let license, license.covers(release: release) { return .licensed(license) }
        if early { return .early }
        if let trialStarted {
            let days = Calendar(identifier: .gregorian).dateComponents([.day], from: trialStarted, to: now).day ?? 0
            let left = trialDays - max(days, 0)
            if left > 0 { return .trial(daysLeft: left) }
        }
        if let license { return .expired(license) }
        return .free
    }
}

extension Data {
    init?(base64URL string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard base64.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else { return nil }
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
