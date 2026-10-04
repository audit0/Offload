import Foundation

/// Сообщение о новой версии — только если человек его включил.
///
/// Раз в сутки OffLoadAI спрашивает у GitHub номер последнего выпуска. В запросе нет ничего о компьютере,
/// файлах и версии программы: GitHub видит только адрес сети, как при открытии любой страницы.
/// Скачивает и ставит обновление сам человек — той же командой установки, что сверяет архив.
public enum UpdateCheck {
    public static let endpoint = URL(string: "https://api.github.com/repos/audit0/Offload/releases/latest")!
    public static let interval: TimeInterval = 24 * 60 * 60

    public struct Release: Equatable, Sendable {
        /// Три числа без «v»: 0.4.1.
        public let version: String
        /// Страница выпуска. Строится из номера, а не берётся из ответа: другой адрес программа не откроет.
        public var page: URL { URL(string: "https://github.com/audit0/Offload/releases/tag/v" + version)! }

        public init(version: String) { self.version = version }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Разбор ответа GitHub. Черновики, предварительные выпуски и непонятные номера не считаются.
    public static func parse(_ data: Data) throws -> Release {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: tr("GitHub ответил не так, как ожидалось."))
        }
        guard object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, let numbers = numbers(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, strict: true)
        else { throw Failure(message: tr("У последнего выпуска на GitHub непонятный номер версии.")) }
        return Release(version: numbers.map(String.init).joined(separator: "."))
    }

    /// Новее ли `candidate`, чем `current`. Номер сборки для разработки (0.4.0-ci) сравнивается по трём числам;
    /// непонятный номер — не новее: лучше промолчать, чем звать обновляться зря.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate, strict: true), let old = numbers(current, strict: false) else { return false }
        return old.lexicographicallyPrecedes(new)
    }

    /// Пора ли спросить снова: раз в сутки. Часы, переведённые назад, проверку не останавливают.
    public static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now < lastCheck || now.timeIntervalSince(lastCheck) >= interval
    }

    /// Спросить GitHub о последнем выпуске. Без cookies, кеша и номера этой версии в запросе.
    public static func fetch() async throws -> Release {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OffLoadAI", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(message: tr("Нет связи с GitHub: \(error.localizedDescription)"))
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            throw Failure(message: tr("GitHub не ответил на вопрос о версии (код \((response as? HTTPURLResponse)?.statusCode ?? 0))."))
        }
        return try parse(data)
    }

    /// «1.2.3» → [1, 2, 3]. Строго — только три числа; иначе допускается хвост сборки: 1.2.3-ci, 1.2.3.beta.
    static func numbers(_ text: String, strict: Bool) -> [Int]? {
        var head = Substring(text)
        if !strict, let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) { head = text[..<cut] }
        let parts = head.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || (!strict && parts.count > 3) else { return nil }
        var result: [Int] = []
        for part in parts.prefix(3) {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
}
