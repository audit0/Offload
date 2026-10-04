import Darwin
import Foundation

/// Помощник через Claude Code, установленный на этом Mac: работает под подпиской пользователя,
/// своего ключа и сервера OffLoadAI не нужно.
///
/// Claude Code запускается наглухо: без инструментов (--tools "") — не читает файлы, не запускает команды и не ходит
/// в интернет сам; без настроек и перехватчиков пользователя (--setting-sources project, а папка — пустая временная),
/// без MCP и команд; без сохранения сессии. Вход — учётная запись Claude, как у самого Claude Code.
/// Всё, что он знает, — сведения, которые OffLoadAI передаёт во входном потоке.
public struct ClaudeCodeAssistant: AssistantProvider {
    public let model: String
    public var title: String { tr("Claude Code на этом Mac") }
    public static let timeout: TimeInterval = 4 * 60

    public init(model: String = "sonnet") {
        self.model = model
    }

    public func problem() async -> String? {
        Runner.locate("claude") == nil
            ? tr("Claude Code не найден. Установите его (claude.com/claude-code) и войдите своей учётной записью Claude — затем «Проверить снова».")
            : nil
    }

    var arguments: [String] {
        ["-p", "--output-format", "json", "--model", model,
         "--tools", "", "--setting-sources", "project", "--strict-mcp-config", "--disable-slash-commands",
         "--no-session-persistence", "--permission-mode", "dontAsk",
         "--system-prompt", AssistantPrompt.instructions, "--json-schema", AssistantPrompt.schema]
    }

    public func ask(_ facts: [FileFact], question: String?) async throws -> AssistantAnswer {
        if let problem = await problem() { throw AssistantError(.notInstalled, problem) }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("offloadai-assistant-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let process = try Runner.makeProcess("claude", arguments)
        process.currentDirectoryURL = scratch
        // Окружение Runner — без чужих переменных. Вложенный запуск из другой сессии Claude Code и чужой прокси
        // Anthropic не должны мешать: вход — подписка пользователя. Прокси сети, если он нужен, — остаётся.
        var environment = process.environment ?? [:]
        for name in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "ANTHROPIC_BASE_URL"] { environment[name] = nil }
        for name in ["USER", "LOGNAME", "TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
                     "https_proxy", "http_proxy", "no_proxy", "all_proxy"] {
            if let value = ProcessInfo.processInfo.environment[name] { environment[name] = value }
        }
        environment["CLAUDE_CODE_ENTRYPOINT"] = "offloadai"
        process.environment = environment

        let input = Data(AssistantPrompt.user(facts, question: question).utf8)
        let stop = StopFlag()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.execute(process, input: input, timeout: Self.timeout, stop: stop)
            }.value
        } onCancel: {
            stop.set()
        }
        try Task.checkCancellation()
        guard let result else {
            throw AssistantError(.timedOut, tr("Помощник не ответил за четыре минуты. Попробуйте папку поменьше."))
        }
        return try read(output: result.output, errors: result.stderr, facts: facts)
    }

    /// Запуск с входом, пределом времени и отменой. nil — не уложился во время.
    static func execute(_ process: Process, input: Data, timeout: TimeInterval, stop: StopFlag) throws -> CommandResult? {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        // Оба канала читаются параллельно: иначе большой вывод заполнит буфер и процесс зависнет.
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { collected.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { collected.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            throw error
        }
        // Вход пишется отдельно: пока Claude Code не дочитал его, запись ждёт, а отмена должна срабатывать.
        DispatchQueue.global().async {
            try? inPipe.fileHandleForWriting.write(contentsOf: input)
            try? inPipe.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if stop.isSet || Date() >= deadline {
                timedOut = !stop.isSet
                process.terminate()
                let grace = Date().addingTimeInterval(5)
                while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 5)
        if stop.isSet { throw CancellationError() }
        if timedOut { return nil }
        return CommandResult(status: process.terminationStatus, stdout: collected.out,
                             stderr: String(decoding: collected.err, as: UTF8.self))
    }

    /// Ответ `claude -p --output-format json`: структурированный вывод по схеме, цена, ошибка входа.
    public func read(output: String, errors: String, facts: [FileFact]) throws -> AssistantAnswer {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
            throw AssistantError(.failed, tr("Claude Code не ответил: ") + Self.firstLine(errors.isEmpty ? output : errors))
        }
        let text = root["result"] as? String ?? ""
        if root["is_error"] as? Bool == true {
            if text.range(of: "Unable to connect", options: .caseInsensitive) != nil
                || text.range(of: "ConnectionRefused", options: .caseInsensitive) != nil {
                throw AssistantError(.failed, tr("Claude Code не может связаться с Anthropic — проверьте интернет (или прокси, если он нужен)."))
            }
            let signIn = ["login", "API key", "authenticat"].contains { text.range(of: $0, options: .caseInsensitive) != nil }
            throw signIn
                ? AssistantError(.notSignedIn, tr("Claude Code не вошёл в учётную запись. Откройте Терминал, запустите claude и войдите (/login) — затем «Проверить снова»."))
                : AssistantError(.failed, "Claude Code: " + Self.firstLine(text))
        }
        let cost = (root["total_cost_usd"] as? NSNumber)?.doubleValue
        if let structured = root["structured_output"], !(structured is NSNull) {
            return try AssistantPrompt.parse(structured, facts: facts, provider: title, cost: cost)
        }
        return try AssistantPrompt.parse(text: text, facts: facts, provider: title, cost: cost)
    }

    static func firstLine(_ text: String) -> String {
        guard let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return tr("без объяснений") }
        return line.count > 200 ? line.prefix(200) + "…" : line
    }
}

/// Флаг отмены, который безопасно выставлять из обработчика отмены задачи.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
