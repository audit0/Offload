using System.Globalization;
using System.Text.RegularExpressions;

namespace Offload.Core;

public enum PasswordLevel { Weak, Fair, Good, Strong }

/// <summary>Оценка пароля сейфа: сколько попыток понадобится перебору.
///
/// Шифр AES-256 перебором не взламывают — взламывают пароль. Поэтому стойкость сейфа ровно такая,
/// какова стойкость пароля, и мерить её надо в битах: каждый бит удваивает число попыток. Оценка намеренно
/// скромная (считает худший случай для человека): набор «Qwerty123!» формально из четырёх классов символов,
/// но первым делом проверяется словарями, и настоящей стойкости в нём почти нет.</summary>
public sealed record PasswordStrength(double Bits, PasswordLevel Level, IReadOnlyList<string> Advice, int Length)
{
    /// <summary>Длиннее этого пароль быть не обязан, но короче — сейф не создаётся.</summary>
    public const int MinimumLength = SecretsVault.MinimumPasswordLength;
    /// <summary>Длиннее BitLocker пароль не примет.</summary>
    public const int MaximumLength = 256;
    /// <summary>Порог допуска: около 2^60 попыток.</summary>
    public const double AcceptableBits = 60;
    /// <summary>VeraCrypt советует не меньше 20 символов; с этим согласуется и оценка «надёжный».</summary>
    public const int RecommendedLength = 20;

    public bool IsAcceptable => Bits >= AcceptableBits && Length >= MinimumLength && Length <= MaximumLength;

    public string Title => Level switch
    {
        PasswordLevel.Weak => "Слабый",
        PasswordLevel.Fair => "Так себе",
        PasswordLevel.Good => "Хороший",
        _ => "Надёжный",
    };

    static readonly (string word, int length)[] Common = new[]
    {
        "password", "passw0rd", "qwerty", "qwertz", "йцукен", "пароль", "123456", "111111", "admin", "letmein",
        "iloveyou", "welcome", "monkey", "dragon", "master", "secret", "любовь", "привет", "asdfgh", "zxcvbn",
        "qazwsx", "1qaz", "фыва", "summer", "winter", "spring", "autumn", "football", "baseball", "sunshine",
        "princess", "shadow", "москва", "moskva", "russia", "россия", "лето", "зима", "весна", "осень",
    }.Select(w => (w, new StringInfo(w).LengthInTextElements)).ToArray();

    static readonly Dictionary<char, char> Leet = new()
    {
        ['0'] = 'o', ['1'] = 'i', ['3'] = 'e', ['4'] = 'a', ['5'] = 's', ['7'] = 't', ['@'] = 'a', ['$'] = 's', ['!'] = 'i',
    };

    public static PasswordStrength Evaluate(string password)
    {
        var characters = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(password);
        while (enumerator.MoveNext()) characters.Add((string)enumerator.Current);
        int length = characters.Count;
        if (length == 0) return new PasswordStrength(0, PasswordLevel.Weak, [], 0);
        // Управляющим символам в пароле не место: их не набрать при входе, и программы обрезают строку на нулевом байте.
        if (password.Any(c => c < 0x20 || c == 0x7F))
            return new PasswordStrength(0, PasswordLevel.Weak,
                ["В пароле есть невидимые управляющие символы (перевод строки, табуляция, нулевой байт) — уберите их."], length);

        var scalars = characters.Select(c => char.ConvertToUtf32(c, 0)).ToArray();
        var classes = new HashSet<string>();
        foreach (var scalar in scalars)
        {
            classes.Add(scalar switch
            {
                >= 0x61 and <= 0x7A => "latin-lower",
                >= 0x41 and <= 0x5A => "latin-upper",
                >= 0x30 and <= 0x39 => "digit",
                0x20 => "space",
                >= 0x21 and <= 0x2F or >= 0x3A and <= 0x40 or >= 0x5B and <= 0x60 or >= 0x7B and <= 0x7E => "symbol",
                >= 0x430 and <= 0x44F or 0x451 => "cyrillic-lower",
                >= 0x410 and <= 0x42F or 0x401 => "cyrillic-upper",
                _ => "other",
            });
        }
        var sizes = new Dictionary<string, int>
        {
            ["latin-lower"] = 26, ["latin-upper"] = 26, ["digit"] = 10, ["space"] = 1, ["symbol"] = 33,
            ["cyrillic-lower"] = 33, ["cyrillic-upper"] = 33, ["other"] = 100,
        };
        int pool = classes.Sum(c => sizes[c]);

        // Сколько стоит каждый символ: 1 — полный, меньше — почти ничего не добавляет.
        var weight = Enumerable.Repeat(1.0, length).ToArray();
        // Повторы и цепочки («aaaa», «1234», «abcd») перебор пробует одними из первых: каждый такой символ — за четверть.
        int weakCharacters = 0;
        for (int i = 1; i < length; i++)
        {
            int previous = scalars[i - 1], current = scalars[i];
            if (current == previous || current == previous + 1 || current + 1 == previous)
            {
                weakCharacters++;
                weight[i] = 0.25;
            }
        }
        // Повтор куска («aCaCaCaC», «Qwerty123!Qwerty»): второй раз он почти ничего не стоит.
        int repeated = 0;
        int index = 1;
        while (index < length)
        {
            int best = 0;
            for (int start = 0; start < index; start++)
            {
                int run = 0;
                while (index + run < length && start + run < index && characters[start + run] == characters[index + run]) run++;
                best = Math.Max(best, run);
            }
            if (best >= 2)
            {
                for (int offset = 0; offset < best; offset++) weight[index + offset] = Math.Min(weight[index + offset], 0.1);
                repeated += best;
                index += best;
            }
            else index++;
        }
        var lowered = password.ToLowerInvariant();
        var advice = new List<string>();
        double perCharacter = Math.Log2(Math.Max(pool, 2));
        double bits = weight.Sum() * perCharacter;

        // Слова, с которых перебор начинается всегда, — и в «хакерской» записи: «P@ssw0rd» перебор пробует сразу за «password».
        var plain = new string(lowered.Select(c => Leet.GetValueOrDefault(c, c)).ToArray());
        foreach (var (word, wordLength) in Common)
        {
            if (!lowered.Contains(word, StringComparison.Ordinal) && !plain.Contains(word, StringComparison.Ordinal)) continue;
            bits -= wordLength * perCharacter * 0.8;
            advice.Add($"В пароле есть «{word}» — такие слова перебор пробует первыми, в том числе с заменами букв на цифры и знаки.");
        }
        // Год («2024», «1987») — сотня вариантов, а не четыре случайные цифры.
        var year = Regex.Match(lowered, "(19|20)\\d\\d");
        if (year.Success)
        {
            bits -= Math.Max(0, 4 * perCharacter - 7);
            advice.Add($"«{year.Value}» похоже на год — перебор подставляет годы первыми.");
        }
        bits = Math.Max(0, bits);

        if (length < MinimumLength) advice.Add($"Нужно не меньше {MinimumLength} символов, сейчас {length}.");
        else if (length > MaximumLength) advice.Add($"BitLocker принимает пароль не длиннее {MaximumLength} символов, сейчас {length}.");
        else if (length < RecommendedLength)
            advice.Add($"VeraCrypt советует от {RecommendedLength} символов. Проще всего — фраза из 4–6 случайных слов через пробел.");
        if ((weakCharacters + repeated) * 3 >= length) advice.Add("Много повторов и подряд идущих символов — их перебирают в первую очередь.");
        if (classes.Count == 1 && length < RecommendedLength) advice.Add("Один вид символов: добавьте слов или длины — это надёжнее, чем цифры в конце.");

        var level = bits switch
        {
            < AcceptableBits => PasswordLevel.Weak,
            < 80 => PasswordLevel.Fair,
            < 110 => PasswordLevel.Good,
            _ => PasswordLevel.Strong,
        };
        return new PasswordStrength(bits, length < MinimumLength ? PasswordLevel.Weak : level, advice, length);
    }
}
