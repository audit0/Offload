import Foundation

/// Помощник на локальной модели через Ollama: ничего не уходит с Mac, обещание «сети нет» сохраняется.
/// Ollama слушает только этот компьютер (127.0.0.1:11434); другой адрес Offload не принимает.
public struct OllamaAssistant: AssistantProvider {
    public static let endpoint = URL(string: "http://127.0.0.1:11434/")!
    /// Модели, которые хорошо держат русский и формат JSON, — в порядке предпочтения, если человек не выбрал свою.
    static let preferred = ["qwen3", "qwen2.5", "gemma3", "llama3.1", "llama3.2", "mistral"]

    let preferredModel: @Sendable () -> String?
    public var title: String { "Локальная модель (Ollama)" }

    public init(preferredModel: @escaping @Sendable () -> String?) {
        self.preferredModel = preferredModel
    }

    public func problem() async -> String? {
        guard let models = await Self.installed() else {
            return "Ollama не запущена. Установите её (ollama.com), запустите и скачайте модель: ollama pull qwen2.5:7b — затем «Проверить снова»."
        }
        if models.isEmpty {
            return "В Ollama нет ни одной модели. Скачайте, например: ollama pull qwen2.5:7b — затем «Проверить снова»."
        }
        return nil
    }

    /// Какую модель спросить: выбранную человеком, иначе первую подходящую из предпочтительных, иначе любую.
    public static func choose(from list: [String], preferred chosen: String?) -> String? {
        if let chosen, !chosen.isEmpty, list.contains(chosen) { return chosen }
        for prefix in preferred {
            if let match = list.first(where: { $0.lowercased().hasPrefix(prefix) }) { return match }
        }
        return list.first
    }

    /// Установленные модели; nil — Ollama не отвечает.
    public static func installed() async -> [String]? {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"), timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (root["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    public func ask(_ facts: [FileFact], question: String?) async throws -> AssistantAnswer {
        guard let list = await Self.installed() else { throw AssistantError(.notInstalled, await problem() ?? "") }
        guard let model = Self.choose(from: list, preferred: preferredModel()) else {
            throw AssistantError(.notInstalled, await problem() ?? "")
        }
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            // Ollama сама держит ответ в схеме (структурированный вывод).
            "format": AssistantPrompt.schemaObject,
            "options": ["temperature": 0],
            "messages": [
                ["role": "system", "content": AssistantPrompt.instructions],
                ["role": "user", "content": AssistantPrompt.user(facts, question: question)],
            ],
        ]
        // Локальная модель на процессоре думает долго: ждём до десяти минут.
        var request = URLRequest(url: Self.endpoint.appendingPathComponent("api/chat"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AssistantError(.timedOut, "Локальная модель не ответила за десять минут — попробуйте модель поменьше или папку поменьше.")
        } catch let error as URLError {
            throw AssistantError(.failed, "Ollama: " + error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let said = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AssistantError(.failed, "Ollama ответила ошибкой \(status): \(said)")
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let content = (reply?["message"] as? [String: Any])?["content"] as? String ?? ""
        return try AssistantPrompt.parse(text: content, facts: facts, provider: "\(title): \(model)", cost: nil)
    }
}
