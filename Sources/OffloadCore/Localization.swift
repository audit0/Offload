import Foundation

/// Перевод текста интерфейса. Ключ — сам русский текст: русский — язык, на котором программа написана,
/// английский перевод лежит в en.lproj/Localizable.strings пакета OffLoadAI.app. Интерполяции становятся
/// форматами (%@, %lld), как у String(localized:). Без перевода — в проверках и в сборке без ресурсов —
/// возвращается русский текст как есть.
public func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .main)
}

/// Перевод текста, который известен только во время работы (rawValue перечислений и т. п.).
/// Ключ должен быть в Localizable.strings так же, как у tr.
public func trDynamic(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

public enum AppLanguage {
    /// Интерфейс на русском: macOS выбрала русский из переводов программы, или английского перевода
    /// в пакете нет вовсе (проверки, исполняемый файл без OffLoadAI.app).
    public static var isRussian: Bool {
        guard Bundle.main.localizations.contains("en") else { return true }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("ru") ?? true
    }

    /// Локаль для дат и относительного времени — того же языка, что интерфейс.
    public static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }

    /// Код языка для модели помощника: на нём она пишет пояснения.
    public static var modelLanguage: String { isRussian ? "русский" : "English" }
}
