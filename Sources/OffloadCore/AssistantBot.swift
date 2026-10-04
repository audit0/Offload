import Foundation

/// Помощник через сервер OffLoadAI (тот же, что у бота @OffLoadAIbot): ни Claude Code, ни ключа API не нужно —
/// доступ открывает ключ OffLoadAI Pro. Сервер сам добавляет инструкции и схему и зовёт модель; программа отправляет
/// ровно то же сообщение со сведениями о файлах, что и другим вариантам.
///
/// Договор с сервером (версия 1):
///   POST {адрес}/v1/assistant, заголовок Authorization: Bearer <ключ OffLoadAI Pro>,
///   тело {"v":1,"client":"offloadai-mac/<версия>","input":"<сообщение со сведениями>"}.
///   Ответ 200: {"answer":{"summary":…,"items":[…]},"remaining":<сколько вопросов осталось>}.
///   Ошибки: 401 — ключ не подошёл, 402 — нужен Pro или кончились вопросы, 429 — слишком часто; тело {"error":"<фраза для человека>"}.
public struct BotAssistant: AssistantProvider {
    let license: @Sendable () -> String?
    let endpointText: @Sendable () -> String?
    let client: String
    public var title: String { tr("Сервер OffLoadAI") }

    public init(client: String, license: @escaping @Sendable () -> String?, endpoint: @escaping @Sendable () -> String?) {
        self.client = client
        self.license = license
        self.endpointText = endpoint
    }

    public func problem() async -> String? {
        if endpoint == nil {
            return tr("Помощник через сервер OffLoadAI ещё не запущен — он появится в одном из обновлений. Пока выберите другой вариант.")
        }
        if license()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return tr("Помощник через сервер OffLoadAI входит в OffLoadAI Pro: введите ключ в окне «OffLoadAI Pro».")
        }
        return nil
    }

    /// Только https: сведения о файлах не должны идти по сети открытым текстом.
    var endpoint: URL? {
        guard let text = endpointText(), let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    public func ask(_ facts: [FileFact], question: String?) async throws -> AssistantAnswer {
        if let problem = await problem() { throw AssistantError(.notInstalled, problem) }
        guard let endpoint, let key = license()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AssistantError(.notInstalled, await problem() ?? "")
        }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/assistant"), timeoutInterval: 4 * 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "v": 1, "client": client, "input": AssistantPrompt.user(facts, question: question),
        ] as [String: Any])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AssistantError(.timedOut, tr("Сервер OffLoadAI не ответил за четыре минуты — попробуйте позже."))
        } catch is URLError {
            throw AssistantError(.failed, tr("Нет связи с сервером OffLoadAI — проверьте интернет."))
        }
        return try read(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, facts: facts)
    }

    public func read(data: Data, status: Int, facts: [FileFact]) throws -> AssistantAnswer {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let said = body?["error"] as? String
        switch status {
        case 200: break
        case 401: throw AssistantError(.notSignedIn, said ?? tr("Сервер не принял ключ OffLoadAI Pro."))
        case 402: throw AssistantError(.notSignedIn, said ?? tr("Нужен OffLoadAI Pro, или вопросы на этот месяц закончились."))
        case 429: throw AssistantError(.failed, said ?? tr("Слишком много вопросов подряд — подождите минуту."))
        default: throw AssistantError(.failed, said ?? tr("Сервер OffLoadAI ответил ошибкой \(status)."))
        }
        return try AssistantPrompt.parse(body?["answer"], facts: facts, provider: title, cost: nil)
    }
}
