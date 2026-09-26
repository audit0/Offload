import Foundation

extension DuplicateFinder {
    /// Идентификатор содержимого, который APFS даёт файлу: у клона и оригинала он общий.
    /// Finder делает клон, когда дублирует файл или копирует его в пределах того же диска,
    /// и такая «копия» места почти не занимает — удалять её ради места незачем.
    public static let apfsContentIdentifier: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.fileContentIdentifierKey]))?.fileContentIdentifier
    }
}
