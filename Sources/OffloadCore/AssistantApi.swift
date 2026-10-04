import Foundation
import Security

/// Помощник по ключу Anthropic API, который человек вставил сам: Claude Code не нужен, платит он по счёту API.
/// Официального SDK Anthropic для Swift нет, поэтому — прямой запрос HTTPS к Messages API.
/// Ключ хранится в связке ключей macOS, а не в настройках программы.
public struct ApiKeyAssistant: AssistantProvider {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let key: @Sendable () -> String?
    let hasKey: @Sendable () -> Bool
    public let model: String
    public var title: String { tr("Claude по ключу API") }

    /// `hasKey` — есть ли ключ, не читая его: чтение из связки ключей может спросить разрешение, а проверка — нет.
    public init(model: String = "claude-opus-5", key: @escaping @Sendable () -> String?, hasKey: (@Sendable () -> Bool)? = nil) {
        self.model = model
        self.key = key
        self.hasKey = hasKey ?? { key()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }

    public func problem() async -> String? {
        hasKey() ? nil
            : tr("Вставьте ключ Anthropic API (console.anthropic.com → API Keys) — он хранится в связке ключей и только на этом Mac.")
    }

    /// Тело запроса: инструкции — системой, схема — структурированным выводом.
    func body(_ facts: [FileFact], question: String?) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 16000,
            "system": AssistantPrompt.instructions,
            // Разложить список по трём корзинам — работа несложная: средних усилий хватает, а ответ быстрее и дешевле.
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": AssistantPrompt.schemaObject]],
            "messages": [["role": "user", "content": AssistantPrompt.user(facts, question: question)]],
        ] as [String: Any])
    }

    public func ask(_ facts: [FileFact], question: String?) async throws -> AssistantAnswer {
        guard let apiKey = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw AssistantError(.notSignedIn, await problem() ?? "")
        }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try body(facts, question: question)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AssistantError(.timedOut, tr("Claude не ответил за десять минут — попробуйте позже или папку поменьше."))
        } catch is URLError {
            throw AssistantError(.failed, tr("Нет связи с Anthropic — проверьте интернет."))
        }
        return try read(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, facts: facts)
    }

    /// Ответ Messages API: ошибки — по коду, отказ — по stop_reason, ответ — из текстовых блоков.
    public func read(data: Data, status: Int, facts: [FileFact]) throws -> AssistantAnswer {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let said = (root?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 200: break
        case 401, 403: throw AssistantError(.notSignedIn, tr("Ключ API не подошёл — проверьте, что он скопирован целиком и не отозван."))
        case 429: throw AssistantError(.failed, tr("Слишком много запросов к Claude — подождите минуту и повторите."))
        case 500...: throw AssistantError(.failed, tr("Anthropic сейчас не отвечает (ошибка \(status)) — попробуйте через минуту."))
        default: throw AssistantError(.failed, "Claude: " + (said ?? tr("ошибка \(status).")))
        }
        if root?["stop_reason"] as? String == "refusal" {
            throw AssistantError(.badAnswer, tr("Claude отказался разбирать этот список. Попробуйте другую папку."))
        }
        let blocks = root?["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return try AssistantPrompt.parse(text: text, facts: facts, provider: title, cost: nil)
    }
}

/// Ключ API — в связке ключей macOS: общая запись «OffLoadAI assistant» этой учётной записи.
public enum AssistantKeychain {
    public static let service = "OffLoadAI assistant"
    static let account = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static var exists: Bool {
        var request = query
        request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    /// Сохранить ключ (пустой — убрать). Ответ — получилось ли.
    @discardableResult
    public static func save(_ key: String?) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "OffLoadAI: ключ Anthropic API для помощника"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
