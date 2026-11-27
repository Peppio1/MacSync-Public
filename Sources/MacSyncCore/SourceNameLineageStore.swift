import Foundation
import SQLite3

/// Candidate additive SQLite storage. Uses the caller's connection and
/// transaction, never opens a remote path or starts its own transaction.
/// No production callers until monitor/publication evidence is integrated.
enum SourceNameLineageStore {
    struct Key: Equatable, Sendable {
        let rootID: String
        let sourceBinding: String
        let targetBinding: String
        let identity: SourceNameLineage.Identity

        init(_ record: SourceNameLineage.Record) {
            rootID = record.rootID
            sourceBinding = record.sourceBinding
            targetBinding = record.targetBinding
            identity = record.identity
        }
    }

    struct Versioned: Equatable, Sendable {
        let record: SourceNameLineage.Record
        let revision: Int64
    }

    enum Failure: Error, Equatable { case stale, invalid, transactionRequired }

    static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS source_name_lineage(
            root_id TEXT NOT NULL,
            source_binding TEXT NOT NULL,
            target_binding TEXT NOT NULL,
            identity TEXT NOT NULL,
            current_path TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision>0),
            record BLOB NOT NULL,
            PRIMARY KEY(root_id,source_binding,target_binding,identity)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS idx_source_lineage_path
            ON source_name_lineage(root_id,source_binding,target_binding,current_path);
        """

    private static func failure(_ db: OpaquePointer) -> JournalError {
        .database(String(cString: sqlite3_errmsg(db)))
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw failure(db)
        }
        return stmt
    }
    private static let maximumRecordBytes = 1_048_576
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func bind(_ value: String, _ i: Int32, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard !value.utf8.contains(0) else { throw Failure.invalid }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard value.withCString({ sqlite3_bind_text(stmt, i, $0, -1, transient) }) == SQLITE_OK else {
            throw failure(db)
        }
    }
    private static func bindKey(_ key: Key, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard !key.rootID.isEmpty, !key.sourceBinding.isEmpty, !key.targetBinding.isEmpty else {
            throw Failure.invalid
        }
        try bind(key.rootID, 1, stmt, db)
        try bind(key.sourceBinding, 2, stmt, db)
        try bind(key.targetBinding, 3, stmt, db)
        try bind(String(decoding: try encode(key.identity), as: UTF8.self), 4, stmt, db)
    }
    private static func validate(_ record: SourceNameLineage.Record) throws {
        let path = record.currentPath
        // Incompatible Windows characters are permitted in observed local
        // names; absolute paths, empty components and traversal are not.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(0),
              record.recognizedPaths.allSatisfy({ WindowsPathSafety.validRelativePath($0) }),
              record.evidence != .neverPublished ||
                (record.recognizedPaths.isEmpty && !record.uncertainPublication) else {
            throw Failure.invalid
        }
    }
    static func install(_ db: OpaquePointer) throws {
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    static func read(_ db: OpaquePointer, key: Key) throws -> Versioned? {
        let stmt = try prepare(db, """
            SELECT current_path,revision,record FROM source_name_lineage
            WHERE root_id=? AND source_binding=? AND target_binding=? AND identity=?;
            """)
        defer { sqlite3_finalize(stmt) }
        try bindKey(key, stmt, db)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw failure(db) }
        let revision = sqlite3_column_int64(stmt, 1)
        let length = Int(sqlite3_column_bytes(stmt, 2))
        guard revision > 0, length > 0, length <= maximumRecordBytes,
              let path = sqlite3_column_text(stmt, 0), let bytes = sqlite3_column_blob(stmt, 2) else {
            throw Failure.invalid
        }
        let record = try JSONDecoder().decode(SourceNameLineage.Record.self,
            from: Data(bytes: bytes, count: length))
        guard Key(record) == key,
              record.currentPath.utf8.elementsEqual(String(cString: path).utf8) else { throw Failure.invalid }
        try validate(record)
        return Versioned(record: record, revision: revision)
    }
    /// Optimistic compare-and-swap. A stale monitor observation must never
    /// overwrite newer publication evidence from another SQLite writer.
    /// The caller commits inventory, checkpoint and evidence atomically.
    @discardableResult
    static func write(_ db: OpaquePointer, record: SourceNameLineage.Record,
                      expectedRevision: Int64?) throws -> Versioned {
        guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
        try validate(record)
        let key = Key(record)
        let existing = try read(db, key: key)
        guard existing?.revision == expectedRevision else { throw Failure.stale }
        let payload = try encode(record)
        guard payload.count <= maximumRecordBytes else { throw Failure.invalid }
        // Compare encoded bytes, not Unicode-canonical Swift String equality.
        if let existing, try encode(existing.record) == payload { return existing }
        let next = (expectedRevision ?? 0).addingReportingOverflow(1)
        guard !next.overflow, next.partialValue > 0 else { throw Failure.invalid }
        let stmt = try prepare(db, """
            INSERT INTO source_name_lineage(root_id,source_binding,target_binding,identity,current_path,revision,record)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(root_id,source_binding,target_binding,identity) DO UPDATE SET
                current_path=excluded.current_path,revision=excluded.revision,record=excluded.record;
            """)
        defer { sqlite3_finalize(stmt) }
        try bindKey(key, stmt, db)
        try bind(record.currentPath, 5, stmt, db)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_int64(stmt, 6, next.partialValue) == SQLITE_OK,
              payload.withUnsafeBytes({ sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else { throw failure(db) }
        return Versioned(record: record, revision: next.partialValue)
    }
}
