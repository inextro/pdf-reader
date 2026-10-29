import Foundation
import SQLite3

/// SQL에 넘기거나 SQL에서 받는 값.
public enum SQLValue: Equatable {
    case int(Int64)
    case text(String)
    case null

    var string: String? { if case .text(let s) = self { return s }; if case .int(let i) = self { return String(i) }; return nil }
    var int: Int64? { if case .int(let i) = self { return i }; if case .text(let s) = self { return Int64(s) }; return nil }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    init(_ value: Int64?) { self = value.map(SQLValue.int) ?? .null }
    init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
}

/// 결과 행 하나. 열 이름으로 꺼낸다.
public struct SQLRow {
    let values: [String: SQLValue]
    public subscript(_ column: String) -> String? { values[column]?.string }
    public func int(_ column: String) -> Int64? { values[column]?.int }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// 시스템 SQLite3 위의 얇은 래퍼. 연결 하나는 한 스레드에서만 쓴다.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// path는 파일 경로 또는 `file:` URI(`?immutable=1` 등).
    public init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_URI
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw SQLiteError(description: "\(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close(handle) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// 값 없이 여러 문장을 실행한다(스키마 만들기 등).
    public func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(description: errorMessage) }
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        _ = try query(sql, args)
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(description: "\(errorMessage) in \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT: 바인딩한 문자열을 SQLite가 복사해 두게 한다.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(statement, index, v)
            case .text(let v): sqlite3_bind_text(statement, index, v, -1, transient)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var rows: [SQLRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw SQLiteError(description: "\(errorMessage) in \(sql)") }
            var values: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, c))
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, c))
                case SQLITE_NULL: values[name] = .null
                default: values[name] = sqlite3_column_text(statement, c).map { .text(String(cString: $0)) } ?? .null
                }
            }
            rows.append(SQLRow(values: values))
        }
        return rows
    }

    public var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// body가 던지면 되돌린다.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
