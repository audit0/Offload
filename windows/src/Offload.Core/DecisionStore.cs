using System.Runtime.InteropServices;
using System.Text;

namespace Offload.Core;

/// <summary>Решения человека при разборе и итоги разборов — в SQLite на самом компьютере.
///
/// Нужна, чтобы Offload в следующий раз предлагал то, что человек выбирает сам: папку, которую всегда
/// оставляют, он больше не предлагает убрать. Никуда не отправляется. Пути здесь — названия папок человека,
/// поэтому файл лежит рядом с журналом переносов, в %LOCALAPPDATA%\Offload, куда есть доступ только у его
/// учётной записи. SQLite — системная (winsqlite3.dll из состава Windows), своей библиотеки Offload не везёт.</summary>
public sealed class DecisionStore : IDisposable
{
    /// <summary>Решение по объекту и то, каким объект был в тот момент: на этом учатся привычки.</summary>
    public sealed record Decision(string Path, CleanupAction Action, long Bytes, CleanupAction? Suggested = null,
                                  DecisionKind? Kind = null, DateTime? Modified = null, DateTime? DecidedAt = null)
    {
        public DateTime At => DecidedAt ?? DateTime.UtcNow;

        /// <summary>Выбор человека, а не согласие с предложенным по умолчанию. «Оставить» считается, только если
        /// предлагалось другое: оставляемое показывается свёрнутым, и строку человек мог и не видеть.</summary>
        public bool IsChoice => Action != CleanupAction.Keep || (Suggested is { } suggested && suggested != CleanupAction.Keep);

        /// <summary>Признаки объекта на момент решения. У решений без вида объекта вид угадывается по имени.</summary>
        public DecisionFeatures Features(string home)
        {
            var kind = Kind ?? (System.IO.Path.GetExtension(Path).Length == 0 ? DecisionKind.Folder : DecisionKind.File);
            return DecisionFeatures.Of(Path, home, kind, Bytes, Modified, At);
        }
    }

    public sealed record Run(DateTime Date, long TrashedBytes, long MovedBytes, int AddedToBackup, int Failures);

    public sealed class StoreException(string message) : Exception("База решений: " + message);

    public static string DefaultPath => System.IO.Path.Combine(Paths.LocalAppData, "Offload", "decisions.sqlite");

    /// <summary>Каждый разбор записывает решение по каждому показанному пути, поэтому история ограничена.</summary>
    public const int DecisionsPerPath = 20;
    public const int KeptRuns = 500;

    IntPtr db;
    readonly Lock gate = new();

    /// <summary>path == null — база в памяти: для демонстрации и проверок, на диск ничего не пишется.</summary>
    public DecisionStore(string? path)
    {
        string name = ":memory:";
        if (path != null)
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            name = path;
        }
        const int SQLITE_OPEN_READWRITE = 0x2, SQLITE_OPEN_CREATE = 0x4, SQLITE_OPEN_FULLMUTEX = 0x10000;
        int status = sqlite3_open_v2(Utf8(name), out db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, IntPtr.Zero);
        if (status != 0)
        {
            var message = db != IntPtr.Zero ? ErrorMessage() : "не открывается";
            sqlite3_close(db);
            db = IntPtr.Zero;
            throw new StoreException(message);
        }
        try { Migrate(); }
        catch
        {
            sqlite3_close(db);
            db = IntPtr.Zero;
            throw;
        }
    }

    public void Dispose()
    {
        if (db != IntPtr.Zero) sqlite3_close(db);
        db = IntPtr.Zero;
    }

    /// <summary>Схема растёт шагами — та же, что у версии для Mac.</summary>
    void Migrate()
    {
        long version = QueryInt("PRAGMA user_version");
        if (version < 1)
            Migration(1, """
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
                """);
        if (version < 2)
            Migration(2, """
                CREATE TABLE IF NOT EXISTS fingerprints (
                    path TEXT PRIMARY KEY,
                    size INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    inode INTEGER NOT NULL,
                    edges TEXT,
                    full TEXT,
                    seen_at REAL NOT NULL
                );
                """);
        if (version < 3)
            Migration(3, """
                ALTER TABLE decisions ADD COLUMN suggested TEXT;
                ALTER TABLE decisions ADD COLUMN kind TEXT;
                ALTER TABLE decisions ADD COLUMN modified REAL;
                """);
        if (version < 4)
            Migration(4, """
                CREATE TABLE IF NOT EXISTS ignored (
                    path TEXT PRIMARY KEY,
                    added_at REAL NOT NULL
                );
                """);
    }

    /// <summary>Шаг схемы целиком или никак.</summary>
    void Migration(int version, string sql) => Transaction(() => Execute(sql + $"PRAGMA user_version = {version};"));

    static double Stamp(DateTime date) => (date.ToUniversalTime() - DateTime.UnixEpoch).TotalSeconds;
    static DateTime FromStamp(double seconds) => DateTime.UnixEpoch.AddSeconds(seconds);

    // MARK: Решения

    /// <summary>Записывает решения одного разбора разом: либо все, либо ни одного.</summary>
    public void Record(IEnumerable<Decision> decisions)
    {
        lock (gate)
        {
            Transaction(() =>
            {
                foreach (var decision in decisions)
                    RunSql("INSERT INTO decisions (path, action, bytes, decided_at, suggested, kind, modified) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           decision.Path, decision.Action.Raw(), decision.Bytes, Stamp(decision.At), decision.Suggested?.Raw(),
                           decision.Kind?.Raw(), decision.Modified is { } modified ? Stamp(modified) : null);
                // Старше последних DecisionsPerPath решений по пути — лишнее.
                RunSql("""
                    DELETE FROM decisions WHERE id IN (
                        SELECT d.id FROM decisions AS d
                        WHERE (SELECT COUNT(*) FROM decisions AS e
                               WHERE e.path = d.path AND (e.decided_at > d.decided_at OR (e.decided_at = d.decided_at AND e.id > d.id))) >= ?
                    )
                    """, (long)DecisionsPerPath);
            });
        }
    }

    /// <summary>Последнее решение по каждому пути, со всем, что о нём известно.</summary>
    public List<Decision> History()
    {
        lock (gate)
        {
            var result = new List<Decision>();
            Select("""
                SELECT path, action, bytes, decided_at, suggested, kind, modified FROM decisions AS d
                WHERE id = (SELECT id FROM decisions WHERE path = d.path ORDER BY decided_at DESC, id DESC LIMIT 1)
                ORDER BY id
                """, row =>
            {
                if (row.Text(0) is not { } path || CleanupActionNames.Parse(row.Text(1)) is not { } action) return;
                result.Add(new Decision(path, action, row.Int(2), CleanupActionNames.Parse(row.Text(4)), DecisionKindNames.Parse(row.Text(5)),
                                        row.IsNull(6) ? null : FromStamp(row.Real(6)), FromStamp(row.Real(3))));
            });
            return result;
        }
    }

    /// <summary>Забывает все решения: и «как в прошлый раз», и привычки. Итоги разборов и отпечатки файлов остаются.</summary>
    public void ForgetDecisions()
    {
        lock (gate) Execute("DELETE FROM decisions");
    }

    /// <summary>Последнее решение по каждому пути. Неизвестные действия (из будущих версий) пропускаются.</summary>
    public Dictionary<string, CleanupAction> LastDecisions()
    {
        lock (gate)
        {
            var result = new Dictionary<string, CleanupAction>(Paths.Comparer);
            Select("""
                SELECT path, action FROM decisions AS d
                WHERE decided_at = (SELECT MAX(decided_at) FROM decisions WHERE path = d.path)
                ORDER BY id
                """, row =>
            {
                if (row.Text(0) is { } path && CleanupActionNames.Parse(row.Text(1)) is { } action) result[path] = action;
            });
            return result;
        }
    }

    public Dictionary<CleanupAction, int> Counts(string path)
    {
        lock (gate)
        {
            var result = new Dictionary<CleanupAction, int>();
            Select("SELECT action, COUNT(*) FROM decisions WHERE path = ? GROUP BY action", row =>
            {
                if (CleanupActionNames.Parse(row.Text(0)) is { } action) result[action] = (int)row.Int(1);
            }, path);
            return result;
        }
    }

    // MARK: Не предлагать

    public void Ignore(string path, DateTime? date = null)
    {
        lock (gate) RunSql("INSERT OR REPLACE INTO ignored (path, added_at) VALUES (?, ?)", path, Stamp(date ?? DateTime.UtcNow));
    }

    public void Unignore(string path)
    {
        lock (gate) RunSql("DELETE FROM ignored WHERE path = ?", path);
    }

    public List<string> IgnoredPaths()
    {
        lock (gate)
        {
            var result = new List<string>();
            Select("SELECT path FROM ignored ORDER BY added_at DESC, path", row => { if (row.Text(0) is { } path) result.Add(path); });
            return result;
        }
    }

    // MARK: Разборы

    public void RecordRun(Run run)
    {
        lock (gate)
        {
            RunSql("INSERT INTO runs (started_at, trashed_bytes, moved_bytes, added_to_backup, failures) VALUES (?, ?, ?, ?, ?)",
                   Stamp(run.Date), run.TrashedBytes, run.MovedBytes, (long)run.AddedToBackup, (long)run.Failures);
            RunSql("DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY started_at DESC, id DESC LIMIT ?)", (long)KeptRuns);
        }
    }

    public Run? LastRun()
    {
        lock (gate)
        {
            Run? result = null;
            Select("SELECT started_at, trashed_bytes, moved_bytes, added_to_backup, failures FROM runs ORDER BY started_at DESC, id DESC LIMIT 1",
                   row => result = new Run(FromStamp(row.Real(0)), row.Int(1), row.Int(2), (int)row.Int(3), (int)row.Int(4)));
            return result;
        }
    }

    // MARK: Отпечатки файлов

    public Dictionary<string, Fingerprint> Fingerprints()
    {
        lock (gate)
        {
            var result = new Dictionary<string, Fingerprint>(Paths.Comparer);
            Select("SELECT path, size, modified, inode, edges, full FROM fingerprints", row =>
            {
                if (row.Text(0) is { } path) result[path] = new Fingerprint(path, row.Int(1), row.Real(2), row.Int(3), row.Text(4), row.Text(5));
            });
            return result;
        }
    }

    public void SaveFingerprints(IEnumerable<Fingerprint> fingerprints, DateTime? date = null)
    {
        var stamp = Stamp(date ?? DateTime.UtcNow);
        lock (gate)
        {
            Transaction(() =>
            {
                foreach (var item in fingerprints)
                    RunSql("INSERT OR REPLACE INTO fingerprints (path, size, modified, inode, edges, full, seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           item.Path, item.Size, item.Modified, item.Inode, item.Edges, item.Full, stamp);
            });
        }
    }

    public void ForgetFingerprints(DateTime seenBefore)
    {
        lock (gate) RunSql("DELETE FROM fingerprints WHERE seen_at < ?", Stamp(seenBefore));
    }

    // MARK: SQLite

    const string Library = "winsqlite3.dll";
    const int SQLITE_ROW = 100, SQLITE_DONE = 101, SQLITE_NULL = 5;
    static readonly IntPtr Transient = new(-1);

    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] name, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_exec(IntPtr db, byte[] sql, IntPtr callback, IntPtr arg, IntPtr error);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int length, out IntPtr statement, IntPtr tail);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_text(IntPtr statement, int index, byte[] text, int length, IntPtr destructor);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_int64(IntPtr statement, int index, long value);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_double(IntPtr statement, int index, double value);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_null(IntPtr statement, int index);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr statement);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_column_int64(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern double sqlite3_column_double(IntPtr statement, int column);
    [DllImport(Library, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_type(IntPtr statement, int column);

    static byte[] Utf8(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        Array.Resize(ref bytes, bytes.Length + 1);
        return bytes;
    }

    string ErrorMessage() => db == IntPtr.Zero ? "база закрыта" : Marshal.PtrToStringUTF8(sqlite3_errmsg(db)) ?? "ошибка";

    void Execute(string sql)
    {
        if (sqlite3_exec(db, Utf8(sql), IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0) throw new StoreException(ErrorMessage());
    }

    void Transaction(Action body)
    {
        Execute("BEGIN");
        try
        {
            body();
            Execute("COMMIT");
        }
        catch
        {
            try { Execute("ROLLBACK"); } catch (StoreException) { }
            throw;
        }
    }

    IntPtr Prepare(string sql, object?[] values)
    {
        if (sqlite3_prepare_v2(db, Utf8(sql), -1, out var statement, IntPtr.Zero) != 0) throw new StoreException(ErrorMessage());
        for (int i = 0; i < values.Length; i++)
        {
            int status = values[i] switch
            {
                null => sqlite3_bind_null(statement, i + 1),
                string text => sqlite3_bind_text(statement, i + 1, Encoding.UTF8.GetBytes(text), Encoding.UTF8.GetByteCount(text), Transient),
                long number => sqlite3_bind_int64(statement, i + 1, number),
                int number => sqlite3_bind_int64(statement, i + 1, number),
                double number => sqlite3_bind_double(statement, i + 1, number),
                _ => throw new StoreException("неизвестный тип значения"),
            };
            if (status != 0)
            {
                sqlite3_finalize(statement);
                throw new StoreException(ErrorMessage());
            }
        }
        return statement;
    }

    void RunSql(string sql, params object?[] values)
    {
        var statement = Prepare(sql, values);
        try
        {
            if (sqlite3_step(statement) != SQLITE_DONE) throw new StoreException(ErrorMessage());
        }
        finally { sqlite3_finalize(statement); }
    }

    readonly struct Row(IntPtr statement)
    {
        public string? Text(int column)
        {
            var pointer = sqlite3_column_text(statement, column);
            if (pointer == IntPtr.Zero) return null;
            int length = sqlite3_column_bytes(statement, column);
            return Marshal.PtrToStringUTF8(pointer, length);
        }
        public long Int(int column) => sqlite3_column_int64(statement, column);
        public double Real(int column) => sqlite3_column_double(statement, column);
        public bool IsNull(int column) => sqlite3_column_type(statement, column) == SQLITE_NULL;
    }

    void Select(string sql, Action<Row> row, params object?[] values)
    {
        var statement = Prepare(sql, values);
        try
        {
            while (true)
            {
                int status = sqlite3_step(statement);
                if (status == SQLITE_DONE) return;
                if (status != SQLITE_ROW) throw new StoreException(ErrorMessage());
                row(new Row(statement));
            }
        }
        finally { sqlite3_finalize(statement); }
    }

    long QueryInt(string sql)
    {
        long value = 0;
        Select(sql, row => value = row.Int(0));
        return value;
    }
}
