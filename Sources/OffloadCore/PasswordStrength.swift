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
        case .weak: return tr("Слабый")
        case .fair: return tr("Так себе")
        case .good: return tr("Хороший")
        case .strong: return tr("Надёжный")
        }
    }

    public static func evaluate(_ password: String) -> PasswordStrength {
        let characters = Array(password)
        let length = characters.count
        guard length > 0 else { return PasswordStrength(bits: 0, level: .weak, advice: [], length: 0) }
        // hdiutil читает пароль из stdin до первого нулевого байта: «верный\0что угодно» открыл бы
        // сейф одной первой частью, а оценка считала бы весь пароль. Управляющим символам в пароле не место.
        if password.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return PasswordStrength(bits: 0, level: .weak,
                                    advice: [tr("В пароле есть невидимые управляющие символы (перевод строки, табуляция, нулевой байт) — уберите их.")],
                                    length: length)
        }

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

        // Сколько стоит каждый символ: 1 — полный, меньше — почти ничего не добавляет.
        var weight = [Double](repeating: 1, count: length)
        // Повторы и цепочки («aaaa», «1234», «abcd», «qwer») перебор пробует одними из первых:
        // каждый такой символ считается за четверть.
        var weakCharacters = 0
        for index in characters.indices.dropFirst() {
            let previous = characters[index - 1].unicodeScalars.first!.value
            let current = characters[index].unicodeScalars.first!.value
            if current == previous || current == previous + 1 || current + 1 == previous {
                weakCharacters += 1
                weight[index] = 0.25
            }
        }
        // Повтор куска («aCaCaCaC», «Qwerty123!Qwerty»): второй раз он почти ничего не стоит —
        // перебор пробует удвоенные слова. Раньше такие пароли набирали под 70 бит.
        var repeated = 0
        var index = 1
        while index < length {
            var best = 0
            for start in 0..<index {
                var run = 0
                while index + run < length, start + run < index, characters[start + run] == characters[index + run] { run += 1 }
                best = max(best, run)
            }
            if best >= 2 {
                for offset in 0..<best { weight[index + offset] = min(weight[index + offset], 0.1) }
                repeated += best
                index += best
            } else {
                index += 1
            }
        }
        let lowered = password.lowercased()
        var advice: [String] = []
        let perCharacter = log2(Double(max(pool, 2)))
        var bits = weight.reduce(0, +) * perCharacter

        // Слова, с которых перебор начинается всегда, — и в «хакерской» записи: «P@ssw0rd» перебор
        // пробует сразу за «password». Нашлось — пароль стоит столько, сколько всё остальное вокруг слова.
        let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i"]
        let plain = String(lowered.map { leet[$0] ?? $0 })
        let common = ["password", "passw0rd", "qwerty", "qwertz", "йцукен", "пароль", "123456", "111111", "admin", "letmein",
                      "iloveyou", "welcome", "monkey", "dragon", "master", "secret", "любовь", "привет", "asdfgh", "zxcvbn",
                      "qazwsx", "1qaz", "фыва", "summer", "winter", "spring", "autumn", "football", "baseball", "sunshine",
                      "princess", "shadow", "москва", "moskva", "russia", "россия", "лето", "зима", "весна", "осень"]
        for word in common where lowered.contains(word) || plain.contains(word) {
            bits -= Double(word.count) * perCharacter * 0.8
            advice.append(tr("В пароле есть «\(word)» — такие слова перебор пробует первыми, в том числе с заменами букв на цифры и знаки."))
        }
        // Год («2024», «1987») — сотня вариантов, а не четыре случайные цифры.
        if let year = lowered.range(of: #"(19|20)\d\d"#, options: .regularExpression) {
            bits -= max(0, 4 * perCharacter - 7)
            advice.append(tr("«\(lowered[year])» похоже на год — перебор подставляет годы первыми."))
        }
        bits = max(0, bits)

        if length < minimumLength {
            advice.append(tr("Нужно не меньше \(minimumLength) символов, сейчас \(length)."))
        } else if length < recommendedLength {
            advice.append(tr("VeraCrypt советует от \(recommendedLength) символов. Проще всего — фраза из 4–6 случайных слов через пробел."))
        }
        if (weakCharacters + repeated) * 3 >= length {
            advice.append(tr("Много повторов и подряд идущих символов — их перебирают в первую очередь."))
        }
        if classes.count == 1, length < recommendedLength {
            advice.append(tr("Один вид символов: добавьте слов или длины — это надёжнее, чем цифры в конце."))
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
