import Foundation
import SQLite3
import os

/// A thin, safe wrapper over the system `libsqlite3` (no third-party code). One
/// connection, opened in serialized mode and guarded by a lock, so it can be used
/// from the main actor for small reads and from a background queue for writes.
nonisolated final class SQLiteDatabase: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private var handle: OpaquePointer?
    private let lock = NSLock()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close(handle)
            throw Failure(message: message)
        }
        self.handle = handle
        // WAL: readers never block the writer, and a crash mid-write cannot corrupt the file.
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        sqlite3_close(handle)
    }

    /// A value bound to or read from a statement.
    enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    /// Runs one or more statements that return nothing.
    func execute(_ sql: String) throws {
        try withLock {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(error)
                throw Failure(message: message)
            }
        }
    }

    /// Runs a statement with bound parameters; returns nothing.
    func run(_ sql: String, _ parameters: [Value] = []) throws {
        try withLock {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
        }
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ parameters: [Value] = [], _ row: (Row) throws -> T) throws -> [T] {
        try withLock {
            let statement = try prepare(sql, parameters)
            defer { sqlite3_finalize(statement) }
            var results: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    results.append(try row(Row(statement: statement)))
                } else if result == SQLITE_DONE {
                    return results
                } else {
                    throw failure()
                }
            }
        }
    }

    /// Groups several writes into one transaction (all or nothing, and much faster).
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Rows

    struct Row {
        fileprivate let statement: OpaquePointer?

        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

        func text(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        func blob(_ index: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        }
    }

    // MARK: - Internals

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let string): result = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw failure()
            }
        }
        return statement
    }

    private func failure() -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(handle)))
    }
}
