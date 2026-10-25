import Foundation
import SQLite3

struct DatabaseError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal wrapper over the system SQLite C API.
final class Database {
    private let handle: OpaquePointer

    init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        // FULLMUTEX (serialized mode): the store is also used from the player's background file
        // locator, and macOS's SQLite otherwise defaults to multi-thread mode, where a single
        // connection must never be used by two threads at once.
        let flags = (readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX
        let target = readOnly ? Database.readOnlyURI(for: path) : path
        guard sqlite3_open_v2(target, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError(message: "Can't open \(path): \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit { sqlite3_close(handle) }

    /// `mode=ro` guarantees SQLite never writes to (or creates a journal for) the file.
    private static func readOnlyURI(for path: String) -> String {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return components.string ?? "file:\(path)?mode=ro"
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorPointer)
            throw DatabaseError(message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(message: "\(lastErrorMessage)\n\(sql)")
        }
        return Statement(handle: statement, database: self)
    }

    /// Runs `body` in a transaction. Nested calls become savepoints, so a change made of several
    /// store calls that each use a transaction can still be saved all or nothing.
    func transaction(_ body: () throws -> Void) throws {
        let savepoint = transactionDepth > 0 ? "nested\(transactionDepth)" : nil
        try execute(savepoint.map { "SAVEPOINT \($0)" } ?? "BEGIN IMMEDIATE")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            try body()
            try execute(savepoint.map { "RELEASE \($0)" } ?? "COMMIT")
        } catch {
            if let savepoint {
                try? execute("ROLLBACK TO \(savepoint)")
                try? execute("RELEASE \(savepoint)")
            } else {
                try? execute("ROLLBACK")
            }
            throw error
        }
    }
    private var transactionDepth = 0

    func tableExists(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        try statement.bind([name])
        return try statement.step()
    }

    func columnNames(of table: String) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))")
        var names = Set<String>()
        while try statement.step() {
            if let name = statement.string(1) { names.insert(name) }
        }
        return names
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    fileprivate var lastErrorMessage: String { String(cString: sqlite3_errmsg(handle)) }
}

final class Statement {
    private let handle: OpaquePointer
    private let database: Database
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [Any?]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case nil:
                result = sqlite3_bind_null(handle, index)
            case let value as Int64:
                result = sqlite3_bind_int64(handle, index, value)
            case let value as Int:
                result = sqlite3_bind_int64(handle, index, Int64(value))
            case let value as Bool:
                result = sqlite3_bind_int(handle, index, value ? 1 : 0)
            case let value as Double:
                result = sqlite3_bind_double(handle, index, value)
            case let value as String:
                result = sqlite3_bind_text(handle, index, value, -1, Statement.transient)
            case let value as Data:
                result = value.withUnsafeBytes {
                    sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Statement.transient)
                }
            default:
                throw DatabaseError(message: "Unsupported bind type \(type(of: value!))")
            }
            guard result == SQLITE_OK else { throw DatabaseError(message: database.lastErrorMessage) }
        }
    }

    /// Returns true while rows are available.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(message: database.lastErrorMessage)
        }
    }

    func run(_ values: [Any?]) throws {
        try bind(values)
        try step()
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: text)
    }

    func int(_ column: Int32) -> Int64? {
        isNull(column) ? nil : sqlite3_column_int64(handle, column)
    }

    func double(_ column: Int32) -> Double? {
        isNull(column) ? nil : sqlite3_column_double(handle, column)
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
