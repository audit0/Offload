import Foundation

public enum Format {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Оперативная память считается двоичными единицами: 18 ГБ, а не 19,33.
    public static func memory(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .memory)
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
