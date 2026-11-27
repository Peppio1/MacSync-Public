import Foundation
import CryptoKit
import SQLite3

/// Deterministic, type-preserving comparison of the entire logical SQLite
/// archive. Physical root pages and implicit rowids are intentionally not
/// identifiers in MacSync; all explicit columns and sequence counters are.
enum LogicalArchiveDigest {
    private static func failure() -> ApplicationRollback.Failure {
        ApplicationRollback.Failure("Confronto logico SQLite non riuscito.")
    }

    private static func identifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func query(_ db: OpaquePointer, _ sql: String,
                              row: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw failure()
        }
        defer { sqlite3_finalize(stmt) }
        var result = sqlite3_step(stmt)
        while result == SQLITE_ROW {
            try row(stmt)
            result = sqlite3_step(stmt)
        }
        guard result == SQLITE_DONE else { throw failure() }
    }

    private static func string(_ stmt: OpaquePointer, _ column: Int32) throws -> String {
        guard sqlite3_column_type(stmt, column) == SQLITE_TEXT,
              let bytes = sqlite3_column_text(stmt, column) else { throw failure() }
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count),
                                 encoding: .utf8), !value.contains("\0") else { throw failure() }
        return value
    }

    private struct Encoder {
        var hash = SHA256()
        mutating func byte(_ value: UInt8) { hash.update(data: Data([value])) }
        mutating func number(_ value: UInt64) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { hash.update(bufferPointer: $0) }
        }
        mutating func bytes(_ value: Data) {
            number(UInt64(value.count))
            hash.update(data: value)
        }
        mutating func row(_ stmt: OpaquePointer) throws {
            byte(0x52)
            let count = sqlite3_column_count(stmt)
            number(UInt64(count))
            for col in 0..<count {
                let kind = sqlite3_column_type(stmt, col)
                switch kind {
                case SQLITE_NULL: byte(0)
                case SQLITE_INTEGER:
                    byte(1); number(UInt64(bitPattern: sqlite3_column_int64(stmt, col)))
                case SQLITE_FLOAT:
                    byte(2); number(sqlite3_column_double(stmt, col).bitPattern)
                case SQLITE_TEXT, SQLITE_BLOB:
                    byte(kind == SQLITE_TEXT ? 3 : 4)
                    let pointer: UnsafeRawPointer?
                    if kind == SQLITE_TEXT {
                        pointer = sqlite3_column_text(stmt, col).map { UnsafeRawPointer($0) }
                    } else { pointer = sqlite3_column_blob(stmt, col) }
                    let n = Int(sqlite3_column_bytes(stmt, col))
                    guard n >= 0, n == 0 || pointer != nil else { throw LogicalArchiveDigest.failure() }
                    if let pointer, n > 0 { bytes(Data(bytes: pointer, count: n)) }
                    else { bytes(Data()) }
                default: throw LogicalArchiveDigest.failure()
                }
            }
        }
    }

    static func compute(_ url: URL, readOnly: Bool = true) throws -> Data {
        _ = try ArchiveDatabaseSafety.fileIdentity(url)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw failure()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        // One consistent read transaction. No writes, schema migrations or
        // changes to connection journal mode. The operational lock is external.
        // A live WAL archive may need to recreate its shared-memory index.
        // READWRITE without CREATE permits SQLite recovery; query_only
        // prevents application-level writes during the logical comparison.
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN;", nil, nil, nil) == SQLITE_OK else { throw failure() }
        defer { _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil) }
        var encoder = Encoder()
        encoder.bytes(Data("MacSync logical archive digest v1".utf8))
        for pragma in ["user_version", "application_id", "encoding"] {
            encoder.bytes(Data(pragma.utf8))
            try query(db, "PRAGMA " + pragma + ";") { try encoder.row($0) }
        }
        var tables: [String] = []
        encoder.byte(0x53)
        try query(db, "SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type COLLATE BINARY,name COLLATE BINARY,tbl_name COLLATE BINARY;") { stmt in
            try encoder.row(stmt)
            if try string(stmt, 0) == "table" {
                let name = try string(stmt, 1)
                let definition = try string(stmt, 3)
                // No virtual/generated tables are part of the reviewed archive.
                guard !definition.uppercased().hasPrefix("CREATE VIRTUAL TABLE") else { throw failure() }
                tables.append(name)
            }
        }
        encoder.byte(0x45)
        for table in tables {
            encoder.byte(0x54)
            encoder.bytes(Data(table.utf8))
            var columns: [String] = []
            try query(db, "PRAGMA table_xinfo(" + identifier(table) + ");") { stmt in
                guard sqlite3_column_int(stmt, 6) == 0 else { throw failure() }
                columns.append(identifier(try string(stmt, 1)))
            }
            guard !columns.isEmpty else { throw failure() }
            // Type is part of ordering, and BINARY overrides declared collations.
            // Sorting full values retains duplicates and ignores insertion order.
            let order = columns.flatMap { ["typeof(" + $0 + ") COLLATE BINARY", $0 + " COLLATE BINARY"] }.joined(separator: ",")
            let sql = "SELECT " + columns.joined(separator: ",") + " FROM " + identifier(table) + " ORDER BY " + order + ";"
            try query(db, sql) { try encoder.row($0) }
            encoder.byte(0x45)
        }
        return Data(encoder.hash.finalize())
    }
}
