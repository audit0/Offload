import Foundation

/// Оценка пароля сейфа: сколько попыток понадобится перебору.
///
/// Шифр AES-256 перебором не взламывают — взламывают пароль. Поэтому стойкость сейфа
/// ровно такая, какова стойкость пароля, и мерить её надо в битах: каждый бит удваивает
/// число попыток. Оценка намеренно скромная (считает худший случай для человека): набор
/// «Qwerty123!» формально из четырёх классов символов, но первым делом проверяется
/// словарями, и настоящей стойкости в нём почти нет.
public struct PasswordStrength: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case weak, fair, good, strong
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let bits: Double
    public let level: Level
    /// Что конкретно ослабляет пароль и как сделать лучше — по-человечески.
    public let advice: [String]

    /// Длиннее этого пароль быть не обязан, но короче — сейф не создаётся.
    public static let minimumLength = SecretsVault.minimumPasswordLength
    /// Порог допуска: около 2^60 попыток. Даже с медленной функцией получения ключа
    /// это годы перебора на видеокартах, а не недели.
    public static let acceptableBits = 60.0
    /// VeraCrypt советует не меньше 20 символов; с этим согласуется и оценка «надёжный».
    public static let recommendedLength = 20

    public var isAcceptable: Bool { bits >= Self.acceptableBits && length >= Self.minimumLength }
    public let length: Int

    public var title: String {
        switch level {
        case .weak: return "Слабый"
        case .fair: return "Так себе"
        case .good: return "Хороший"
        case .strong: return "Надёжный"
        }
    }

    public static func evaluate(_ password: String) -> PasswordStrength {
        let characters = Array(password)
        let length = characters.count
        guard length > 0 else { return PasswordStrength(bits: 0, level: .weak, advice: [], length: 0) }

        var pool = 0
        var classes = Set<String>()
        for character in characters {
            let scalar = character.unicodeScalars.first!.value
            switch scalar {
            case 0x61...0x7A: classes.insert("latin-lower")
            case 0x41...0x5A: classes.insert("latin-upper")
            case 0x30...0x39: classes.insert("digit")
            case 0x20: classes.insert("space")
            case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: classes.insert("symbol")
            case 0x430...0x44F, 0x451: classes.insert("cyrillic-lower")
            case 0x410...0x42F, 0x401: classes.insert("cyrillic-upper")
            default: classes.insert("other")
            }
        }
        let sizes = ["latin-lower": 26, "latin-upper": 26, "digit": 10, "space": 1, "symbol": 33,
                     "cyrillic-lower": 33, "cyrillic-upper": 33, "other": 100]
        for name in classes { pool += sizes[name] ?? 0 }

        // Повторы и цепочки («aaaa», «1234», «abcd», «qwer») почти ничего не добавляют:
        // перебор пробует их одними из первых. Каждый такой символ считается за четверть.
        var weakCharacters = 0
        for index in characters.indices.dropFirst() {
            let previous = characters[index - 1].unicodeScalars.first!.value
            let current = characters[index].unicodeScalars.first!.value
            if current == previous || current == previous + 1 || current + 1 == previous { weakCharacters += 1 }
        }
        let lowered = password.lowercased()
        var advice: [String] = []
        var bits = Double(length - weakCharacters) * log2(Double(max(pool, 2)))
            + Double(weakCharacters) * 0.25 * log2(Double(max(pool, 2)))

        // Слова, с которых перебор начинается всегда. Нашлось — пароль стоит столько,
        // сколько стоит всё остальное вокруг слова.
        let common = ["password", "passw0rd", "qwerty", "йцукен", "пароль", "123456", "111111", "admin", "letmein",
                      "iloveyou", "welcome", "monkey", "dragon", "master", "secret", "любовь", "привет", "asdfgh", "zxcvbn"]
        for word in common where lowered.contains(word) {
            bits -= Double(word.count) * log2(Double(max(pool, 2))) * 0.8
            advice.append("В пароле есть «\(word)» — такие слова перебор пробует первыми.")
        }
        bits = max(0, bits)

        if length < minimumLength {
            advice.append("Нужно не меньше \(minimumLength) символов, сейчас \(length).")
        } else if length < recommendedLength {
            advice.append("VeraCrypt советует от \(recommendedLength) символов. Проще всего — фраза из 4–6 случайных слов через пробел.")
        }
        if weakCharacters * 3 >= length {
            advice.append("Много повторов и подряд идущих символов — их перебирают в первую очередь.")
        }
        if classes.count == 1, length < recommendedLength {
            advice.append("Один вид символов: добавьте слов или длины — это надёжнее, чем цифры в конце.")
        }

        let level: Level
        switch bits {
        case ..<acceptableBits: level = .weak
        case ..<80: level = .fair
        case ..<110: level = .good
        default: level = .strong
        }
        return PasswordStrength(bits: bits, level: length < minimumLength ? .weak : level, advice: advice, length: length)
    }
}
