import Foundation

/// Результат запуска внешней программы.
public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public enum RunnerError: LocalizedError, Equatable {
    case toolNotFound(String)
    case timedOut(String)
    case failed(tool: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool): return "Не найдена программа «\(tool)»."
        case .timedOut(let tool): return "Программа «\(tool)» не ответила вовремя."
        case .failed(let tool, let status, let message): return "«\(tool)» завершилась с кодом \(status): \(message)"
        }
    }
}

/// Запуск внешних программ без оболочки.
///
/// Аргументы всегда передаются массивом, поэтому пробелы, кавычки, `;` и `$()` в путях
/// и именах не могут превратиться в команды. PATH окружения не используется:
/// программы ищутся только в известных каталогах.
public enum Runner {
    /// Системные каталоги: только отсюда берутся hdiutil, lsof, du, ssh-keygen.
    public static let systemDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    /// Каталоги сторонних инструментов. Они доступны пользователю на запись,
    /// поэтому системные программы оттуда никогда не берутся.
    public static let thirdPartyDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/Applications/Docker.app/Contents/Resources/bin"]
    public static let thirdPartyTools: Set<String> = ["docker", "zstd"]

    /// Запись в закрытый канал иначе убивает приложение сигналом SIGPIPE.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public static func locate(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        let directories = thirdPartyTools.contains(name) ? thirdPartyDirectories : systemDirectories
        for directory in directories {
            let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public static var environment: [String: String] {
        var env = [
            "PATH": (systemDirectories + thirdPartyDirectories).joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
        for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"] {
            if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
        }
        return env
    }

    /// Готовит процесс, не запуская его. Нужен для конвейеров вроде docker → zstd.
    public static func makeProcess(_ tool: String, _ arguments: [String]) throws -> Process {
        _ = ignoreSigpipe
        guard let executable = locate(tool) else { throw RunnerError.toolNotFound(tool) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        return process
    }

    @discardableResult
    public static func run(_ tool: String, _ arguments: [String], stdin: Data? = nil, timeout: TimeInterval? = nil,
                           currentDirectory: URL? = nil) throws -> CommandResult {
        let process = try makeProcess(tool, arguments)
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        // Оба канала читаются параллельно: иначе большой вывод заполнит буфер и процесс зависнет.
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { collected.out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { collected.err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        try process.run()
        if let inPipe, let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                throw RunnerError.timedOut(tool)
            }
        }
        process.waitUntilExit()
        group.wait()
        return CommandResult(status: process.terminationStatus, stdout: collected.out,
                             stderr: String(decoding: collected.err, as: UTF8.self))
    }

    /// Как `run`, но ненулевой код завершения считается ошибкой.
    @discardableResult
    public static func check(_ tool: String, _ arguments: [String], stdin: Data? = nil, timeout: TimeInterval? = nil,
                             currentDirectory: URL? = nil) throws -> CommandResult {
        let result = try run(tool, arguments, stdin: stdin, timeout: timeout, currentDirectory: currentDirectory)
        guard result.succeeded else {
            throw RunnerError.failed(tool: tool, status: result.status,
                                     message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }
}

final class Collected: @unchecked Sendable {
    var out = Data()
    var err = Data()
}
