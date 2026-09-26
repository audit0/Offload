import Foundation
import SQLite3

/// Решения человека при разборе и итоги разборов — в SQLite на самом Mac.
///
/// Нужна, чтобы Offload в следующий раз предлагал то, что человек выбирает сам: папку,
/// которую всегда оставляют, он больше не предлагает убрать. Никуда не отправляется.
/// Пути здесь — названия папок человека, поэтому файл лежит рядом с журналом переносов,
/// в ~/Library/Application Support/Offload, и доступен только его учётной записи.
public final class DecisionStore: @unchecked Sendable {
    /// Решение по объекту и то, каким объект был в тот момент: на этом учатся привычки.
    public struct Decision: Sendable, Equatable {
        public var path: String
        public var action: CleanupAction
        public var bytes: Int64
        /// Что предлагалось, когда человек выбирал.
        public var suggested: CleanupAction?
        /// nil — решение записано версией, которая этого не хранила.
        public var kind: DecisionFeatures.Kind?
        public var modified: Date?
        public var decidedAt: Date

        public init(path: String, action: CleanupAction, bytes: Int64, suggested: CleanupAction? = nil,
                    kind: DecisionFeatures.Kind? = nil, modified: Date? = nil, decidedAt: Date = Date()) {
            self.path = path
            self.action = action
            self.bytes = bytes
            self.suggested = suggested
            self.kind = kind
            self.modified = modified
            self.decidedAt = decidedAt
        }
    }

    public struct Run: Sendable, Equatable {
        public var date: Date
        public var trashedBytes: Int64
        public var movedBytes: Int64
        public var addedToBackup: Int
        public var failures: Int

        public init(date: Date = Date(), trashedBytes: Int64, movedBytes: Int64, addedToBackup: Int, failures: Int) {
            self.date = date
            self.trashedBytes = trashedBytes
            self.movedBytes = movedBytes
            self.addedToBackup = addedToBackup
            self.failures = failures
        }
    }

    public enum StoreError: LocalizedError {
        case sqlite(String)

        public var errorDescription: String? {
            switch self {
            case .sqlite(let message): return "База решений: \(message)"
            }
        }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offload", isDirectory: true)
            .appendingPathComponent("decisions.sqlite")
    }

    private var db: OpaquePointer?
    private let lock = NSLock()
    /// Каждый разбор записывает решение по каждому показанному пути, поэтому история ограничена:
    /// по пути — последние решения, итогов — последние разборы. Иначе база растёт без конца.
    public static let decisionsPerPath = 20
    public static let keptRuns = 500

    /// `url == nil` — база в памяти: для демонстрации и проверок, на диск ничего не пишется.
    public init(url: URL?) throws {
        let path: String
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            path = url.path
        } else {
            path = ":memory:"
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "не открывается"
            sqlite3_close(handle)
            throw StoreError.sqlite(message)
        }
        db = handle
        if url != nil { chmod(path, 0o600) }
        do {
            try migrate()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Схема растёт шагами: каждый шаг добавляет своё и ставит свой номер версии, прежние данные остаются.
    private func migrate() throws {
        let version = try queryInt("PRAGMA user_version")
        if version < 1 {
            try migration(to: 1, """
                CREATE TABLE IF NOT EXISTS decisions (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL,
                    action TEXT NOT NULL,
                    bytes INTEGER NOT NULL,
                    decided_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS decisions_path ON decisions(path, decided_at);
                CREATE TABLE IF NOT EXISTS runs (
                    id INTEGER PRIMARY KEY,
                    started_at REAL NOT NULL,
                    trashed_bytes INTEGER NOT NULL,
                    moved_bytes INTEGER NOT NULL,
                    added_to_backup INTEGER NOT NULL,
                    failures INTEGER NOT NULL
                );
                """)
        }
        if version < 2 {
            // Отпечатки файлов для поиска дубликатов: неизменившийся файл второй раз не читается.
            try migration(to: 2, """
                CREATE TABLE IF NOT EXISTS fingerprints (
                    path TEXT PRIMARY KEY,
                    size INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    inode INTEGER NOT NULL,
                    edges TEXT,
                    full TEXT,
                    seen_at REAL NOT NULL
                );
                """)
        }
        if version < 3 {
            // Каким объект был при решении: вид, дата изменения и что предлагалось. На этом учатся привычки.
            try migration(to: 3, """
                ALTER TABLE decisions ADD COLUMN suggested TEXT;
                ALTER TABLE decisions ADD COLUMN kind TEXT;
                ALTER TABLE decisions ADD COLUMN modified REAL;
                """)
        }
    }

    /// Шаг схемы целиком или никак: оборванный посередине шаг оставил бы таблицы без номера версии.
    private func migration(to version: Int32, _ sql: String) throws {
        try transaction { try execute(sql + "PRAGMA user_version = \(version);") }
    }

    // MARK: - Решения

    /// Записывает решения одного разбора разом: либо все, либо ни одного.
    public func record(_ decisions: [Decision]) throws {
        try locked {
            try transaction {
                for decision in decisions {
                    try run("""
                        INSERT INTO decisions (path, action, bytes, decided_at, suggested, kind, modified)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.text(decision.path), .text(decision.action.rawValue), .int(decision.bytes),
                         .real(decision.decidedAt.timeIntervalSince1970), decision.suggested.map { .text($0.rawValue) } ?? .null,
                         decision.kind.map { .text($0.rawValue) } ?? .null, decision.modified.map { .real($0.timeIntervalSince1970) } ?? .null])
                }
                try run("""
                    DELETE FROM decisions WHERE id IN (
                        SELECT id FROM (
                            SELECT id, ROW_NUMBER() OVER (PARTITION BY path ORDER BY decided_at DESC, id DESC) AS n
                            FROM decisions
                        ) WHERE n > ?
                    )
                    """, [.int(Int64(Self.decisionsPerPath))])
            }
        }
    }

    public func record(_ decisions: [(path: String, action: CleanupAction, bytes: Int64)], at date: Date = Date()) throws {
        try record(decisions.map { Decision(path: $0.path, action: $0.action, bytes: $0.bytes, decidedAt: date) })
    }

    /// Последнее решение по каждому пути, со всем, что о нём известно. Каждый объект считается
    /// один раз: папка, которую оставляют в каждом разборе, не должна перевешивать десять разных.
    public func history() throws -> [Decision] {
        try locked {
            var result: [Decision] = []
            try select("""
                SELECT path, action, bytes, decided_at, suggested, kind, modified FROM decisions AS d
                WHERE id = (SELECT id FROM decisions WHERE path = d.path ORDER BY decided_at DESC, id DESC LIMIT 1)
                ORDER BY id
                """) { row in
                guard let path = row.text(0), let action = row.text(1).flatMap(CleanupAction.init(rawValue:)) else { return }
                result.append(Decision(path: path, action: action, bytes: row.int(2), suggested: row.text(4).flatMap(CleanupAction.init(rawValue:)),
                                       kind: row.text(5).flatMap(DecisionFeatures.Kind.init(rawValue:)),
                                       modified: row.isNull(6) ? nil : Date(timeIntervalSince1970: row.real(6)),
                                       decidedAt: Date(timeIntervalSince1970: row.real(3))))
            }
            return result
        }
    }

    /// Забывает все решения: и «как в прошлый раз», и привычки. Итоги разборов и отпечатки файлов остаются.
    public func forgetDecisions() throws {
        try locked { try execute("DELETE FROM decisions") }
    }

    /// Последнее решение по каждому пути. Неизвестные действия (из будущих версий) пропускаются.
    public func lastDecisions() throws -> [String: CleanupAction] {
        try locked {
            var result: [String: CleanupAction] = [:]
            try select("""
                SELECT path, action FROM decisions AS d
                WHERE decided_at = (SELECT MAX(decided_at) FROM decisions WHERE path = d.path)
                ORDER BY id
                """) { row in
                if let path = row.text(0), let action = row.text(1).flatMap(CleanupAction.init(rawValue:)) {
                    result[path] = action
                }
            }
            return result
        }
    }

    /// Сколько раз по пути выбирали каждое действие — для объяснений «вы трижды оставляли это».
    public func counts(for path: String) throws -> [CleanupAction: Int] {
        try locked {
            var result: [CleanupAction: Int] = [:]
            try select("SELECT action, COUNT(*) FROM decisions WHERE path = ? GROUP BY action", [.text(path)]) { row in
                if let action = row.text(0).flatMap(CleanupAction.init(rawValue:)) { result[action] = Int(row.int(1)) }
            }
            return result
        }
    }

    // MARK: - Разборы

    public func recordRun(_ run: Run) throws {
        try locked {
            try self.run("INSERT INTO runs (started_at, trashed_bytes, moved_bytes, added_to_backup, failures) VALUES (?, ?, ?, ?, ?)",
                         [.real(run.date.timeIntervalSince1970), .int(run.trashedBytes), .int(run.movedBytes),
                          .int(Int64(run.addedToBackup)), .int(Int64(run.failures))])
            try self.run("DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY started_at DESC, id DESC LIMIT ?)",
                         [.int(Int64(Self.keptRuns))])
        }
    }

    public func lastRun() throws -> Run? {
        try locked {
            var result: Run?
            try select("SELECT started_at, trashed_bytes, moved_bytes, added_to_backup, failures FROM runs ORDER BY started_at DESC, id DESC LIMIT 1") { row in
                result = Run(date: Date(timeIntervalSince1970: row.real(0)), trashedBytes: row.int(1), movedBytes: row.int(2),
                             addedToBackup: Int(row.int(3)), failures: Int(row.int(4)))
            }
            return result
        }
    }

    // MARK: - Отпечатки файлов

    /// Сохранённые отпечатки, по пути.
    public func fingerprints() throws -> [String: Fingerprint] {
        try locked {
            var result: [String: Fingerprint] = [:]
            try select("SELECT path, size, modified, inode, edges, full FROM fingerprints") { row in
                guard let path = row.text(0) else { return }
                result[path] = Fingerprint(path: path, size: row.int(1), modified: row.real(2), inode: row.int(3),
                                           edges: row.text(4), full: row.text(5))
            }
            return result
        }
    }

    /// Отпечатки одного поиска — разом: либо все, либо ни одного.
    public func saveFingerprints(_ fingerprints: [Fingerprint], at date: Date = Date()) throws {
        try locked {
            try transaction {
                for item in fingerprints {
                    try run("""
                        INSERT OR REPLACE INTO fingerprints (path, size, modified, inode, edges, full, seen_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        [.text(item.path), .int(item.size), .real(item.modified), .int(item.inode),
                         item.edges.map(Value.text) ?? .null, item.full.map(Value.text) ?? .null, .real(date.timeIntervalSince1970)])
                }
            }
        }
    }

    /// Забывает отпечатки, которых последний законченный поиск не касался: файла нет или он больше не нужен.
    public func forgetFingerprints(seenBefore date: Date) throws {
        try locked { try run("DELETE FROM fingerprints WHERE seen_at < ?", [.real(date.timeIntervalSince1970)]) }
    }

    // MARK: - SQLite

    enum Value {
        case text(String), int(Int64), real(Double), null
    }

    struct Row {
        let statement: OpaquePointer
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    /// SQLITE_TRANSIENT: SQLite копирует строку сразу, Swift может освободить её после вызова.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func error() -> StoreError {
        StoreError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "база закрыта")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let status: Int32
            switch value {
            case .text(let text): status = sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .int(let number): status = sqlite3_bind_int64(statement, position, number)
            case .real(let number): status = sqlite3_bind_double(statement, position, number)
            case .null: status = sqlite3_bind_null(statement, position)
            }
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw error()
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func select(_ sql: String, _ values: [Value] = [], row: (Row) -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error() }
            row(Row(statement: statement))
        }
    }

    private func queryInt(_ sql: String) throws -> Int32 {
        var value: Int32 = 0
        try select(sql) { value = Int32(truncatingIfNeeded: $0.int(0)) }
        return value
    }
}
