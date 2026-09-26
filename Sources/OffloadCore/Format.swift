import Foundation

public enum Format {
    /// Размер на диске — десятичными единицами, как в Finder: 24.5 ГБ.
    ///
    /// Точность везде одна: до 100 — один знак после точки, от 100 — целые. ByteCountFormatter
    /// показывал рядом «4.81 ГБ», «24.5 ГБ» и «168.01 ГБ», и суммы на одном экране читались вразнобой.
    public static func bytes(_ count: Int64) -> String { size(count, base: 1000) }

    /// Оперативная память считается двоичными единицами: 18 ГБ, а не 19.3.
    public static func memory(_ count: UInt64) -> String { size(Int64(clamping: count), base: 1024) }

    static let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]

    static func size(_ count: Int64, base: Double) -> String {
        let sign = count < 0 ? "−" : ""
        var value = Double(count.magnitude)
        var unit = 0
        while value >= base, unit < units.count - 1 {
            value /= base
            unit += 1
        }
        // Округление могло дать ровно base («999.96 МБ» → «1000.0») — тогда это уже следующая единица.
        if unit < units.count - 1, (value * 10).rounded() / 10 >= base {
            value /= base
            unit += 1
        }
        let text: String
        if unit == 0 || value >= 100 {
            text = String(Int(value.rounded()))
        } else {
            let rounded = (value * 10).rounded() / 10
            text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        }
        return "\(sign)\(text) \(units[unit])"
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        // «Сейчас» вместо «через 0 секунд»: у файла, изменённого только что, дата может оказаться
        // на долю секунды впереди часов, и числовой стиль показывал её как будущую.
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
