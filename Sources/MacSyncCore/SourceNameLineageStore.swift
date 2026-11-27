import Foundation
import SQLite3

/// Compact candidate storage, caller-owned connection and transaction.
/// The old JSON prototype was never operational; use new tables rather than
/// interpreting or dropping its records. No runtime authorization.
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
        CREATE TABLE IF NOT EXISTS source_lineage_mapping(
            id INTEGER PRIMARY KEY,
            root_id TEXT NOT NULL,
            source_binding TEXT NOT NULL,
            target_binding TEXT NOT NULL,
            UNIQUE(root_id,source_binding,target_binding)
        );
        CREATE TABLE IF NOT EXISTS source_lineage_index(
            mapping_id INTEGER NOT NULL,
            identity BLOB NOT NULL CHECK(length(identity)=33),
            current_path TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision>0),
            evidence INTEGER NOT NULL CHECK(evidence BETWEEN 0 AND 2),
            uncertain INTEGER NOT NULL CHECK(uncertain IN (0,1)),
            recognized_paths BLOB,
            PRIMARY KEY(mapping_id,identity)
        ) WITHOUT ROWID;
        """

    private static let maximumRecordBytes = 1_048_576
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
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
    private static func reset(_ stmt: OpaquePointer) {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }
    private static func bind(_ value: String, _ i: Int32, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard !value.utf8.contains(0) else { throw Failure.invalid }
        guard value.withCString({ sqlite3_bind_text(stmt, i, $0, -1, transient) }) == SQLITE_OK else {
            throw failure(db)
        }
    }
    private static func bindBlob(_ value: Data, _ i: Int32, _ stmt: OpaquePointer, _ db: OpaquePointer) throws {
        guard value.count <= maximumRecordBytes,
              value.withUnsafeBytes({ sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32($0.count), transient) }) == SQLITE_OK else {
            throw failure(db)
        }
    }
    /// Exact, fixed-width binary identity. Never truncate a UInt64 inode.
    private static func identityBytes(_ id: SourceNameLineage.Identity) throws -> Data {
        guard id.inode != 0, id.birthSeconds > 0, (0..<1_000_000_000).contains(id.birthNanos),
              id.kind == "file" || id.kind == "directory" else { throw Failure.invalid }
        var result = Data(capacity: 33)
        for value in [id.device, id.inode, UInt64(bitPattern: id.birthSeconds), UInt64(bitPattern: id.birthNanos)] {
            var word = value.bigEndian
            withUnsafeBytes(of: &word) { result.append(contentsOf: $0) }
        }
        result.append(id.kind == "file" ? 1 : 2)
        return result
    }
    private static func validate(_ record: SourceNameLineage.Record) throws {
        let path = record.currentPath
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(0),
              record.recognizedPaths.allSatisfy({ WindowsPathSafety.validRelativePath($0) }),
              record.evidence != .neverPublished ||
                (record.recognizedPaths.isEmpty && !record.uncertainPublication),
              record.evidence != .recognized || !record.recognizedPaths.isEmpty,
              Set(record.recognizedPaths.map { Data($0.utf8) }).count == record.recognizedPaths.count else {
            throw Failure.invalid
        }
    }
    static func install(_ db: OpaquePointer) throws {
        guard sqlite3_exec(db, schemaSQL, nil, nil, nil) == SQLITE_OK else { throw failure(db) }
    }
    private static func mapping(_ db: OpaquePointer, key: Key, create: Bool) throws -> Int64? {
        guard !key.rootID.isEmpty, !key.sourceBinding.isEmpty, !key.targetBinding.isEmpty else { throw Failure.invalid }
        func bindMapping(_ stmt: OpaquePointer) throws {
            try bind(key.rootID, 1, stmt, db)
            try bind(key.sourceBinding, 2, stmt, db)
            try bind(key.targetBinding, 3, stmt, db)
        }
        if create {
            guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
            let insert = try prepare(db, "INSERT OR IGNORE INTO source_lineage_mapping(root_id,source_binding,target_binding) VALUES(?,?,?);")
            defer { sqlite3_finalize(insert) }
            try bindMapping(insert)
            guard sqlite3_step(insert) == SQLITE_DONE else { throw failure(db) }
        }
        let query = try prepare(db, "SELECT id FROM source_lineage_mapping WHERE root_id=? AND source_binding=? AND target_binding=?;")
        defer { sqlite3_finalize(query) }
        try bindMapping(query)
        let rc = sqlite3_step(query)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw failure(db) }
        let id = sqlite3_column_int64(query, 0)
        guard id > 0 else { throw Failure.invalid }
        return id
    }

    /// One mapping lookup and two prepared statements per scan, reused for
    /// every eligible observation. Ordinary records need no JSON at all.
    /// Must not outlive the caller's connection or its write transaction.
    final class Batch {
        private let db: OpaquePointer
        private let namespace: Int64
        private let rootID: String
        private let sourceBinding: String
        private let targetBinding: String
        private let query: OpaquePointer
        private let upsert: OpaquePointer

        fileprivate init(_ db: OpaquePointer, key: Key, namespace: Int64) throws {
            self.db = db
            self.namespace = namespace
            rootID = key.rootID
            sourceBinding = key.sourceBinding
            targetBinding = key.targetBinding
            let q = try prepare(db, """
                SELECT current_path,revision,evidence,uncertain,recognized_paths
                FROM source_lineage_index WHERE mapping_id=? AND identity=?;
                """)
            do {
                upsert = try prepare(db, """
                    INSERT INTO source_lineage_index(mapping_id,identity,current_path,revision,evidence,uncertain,recognized_paths)
                    VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(mapping_id,identity) DO UPDATE SET
                        current_path=excluded.current_path,revision=excluded.revision,
                        evidence=excluded.evidence,uncertain=excluded.uncertain,recognized_paths=excluded.recognized_paths;
                    """)
            } catch {
                sqlite3_finalize(q)
                throw error
            }
            query = q
        }
        deinit {
            sqlite3_finalize(query)
            sqlite3_finalize(upsert)
        }

        private func verify(_ key: Key) throws {
            guard key.rootID.utf8.elementsEqual(rootID.utf8),
                  key.sourceBinding.utf8.elementsEqual(sourceBinding.utf8),
                  key.targetBinding.utf8.elementsEqual(targetBinding.utf8) else { throw Failure.invalid }
        }
        private func bindIdentity(_ key: Key, _ stmt: OpaquePointer) throws {
            try verify(key)
            guard sqlite3_bind_int64(stmt, 1, namespace) == SQLITE_OK else { throw failure(db) }
            try bindBlob(identityBytes(key.identity), 2, stmt, db)
        }

        func read(key: Key) throws -> Versioned? {
            reset(query)
            defer { reset(query) }
            try bindIdentity(key, query)
            let rc = sqlite3_step(query)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw failure(db) }
            let revision = sqlite3_column_int64(query, 1)
            let uncertain = sqlite3_column_int(query, 3)
            guard revision > 0, let path = sqlite3_column_text(query, 0),
                  uncertain == 0 || uncertain == 1 else { throw Failure.invalid }
            let evidence: SourceNameLineage.Evidence
            switch sqlite3_column_int(query, 2) {
            case 0: evidence = .unknown
            case 1: evidence = .neverPublished
            case 2: evidence = .recognized
            default: throw Failure.invalid
            }
            var paths: [String] = []
            if sqlite3_column_type(query, 4) != SQLITE_NULL {
                let length = Int(sqlite3_column_bytes(query, 4))
                guard length > 0, length <= maximumRecordBytes,
                      let bytes = sqlite3_column_blob(query, 4) else { throw Failure.invalid }
                paths = try JSONDecoder().decode([String].self, from: Data(bytes: bytes, count: length))
            }
            let record = SourceNameLineage.Record(identity: key.identity, rootID: rootID,
                sourceBinding: sourceBinding, targetBinding: targetBinding,
                path: String(cString: path), evidence: evidence,
                recognizedPaths: paths, uncertainPublication: uncertain == 1)
            try validate(record)
            return Versioned(record: record, revision: revision)
        }

        @discardableResult
        func write(record: SourceNameLineage.Record, expectedRevision: Int64?) throws -> Versioned {
            guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
            try validate(record)
            let key = Key(record)
            let existing = try read(key: key)
            guard existing?.revision == expectedRevision else { throw Failure.stale }
            if let existing, existing.record.evidence == record.evidence,
               existing.record.uncertainPublication == record.uncertainPublication,
               existing.record.currentPath.utf8.elementsEqual(record.currentPath.utf8),
               existing.record.recognizedPaths.map({ Data($0.utf8) }) == record.recognizedPaths.map({ Data($0.utf8) }) {
                return existing
            }
            let next = (expectedRevision ?? 0).addingReportingOverflow(1)
            guard !next.overflow, next.partialValue > 0 else { throw Failure.invalid }
            reset(upsert)
            defer { reset(upsert) }
            try bindIdentity(key, upsert)
            try bind(record.currentPath, 3, upsert, db)
            let evidence: Int32 = record.evidence == .unknown ? 0 : (record.evidence == .neverPublished ? 1 : 2)
            guard sqlite3_bind_int64(upsert, 4, next.partialValue) == SQLITE_OK,
                  sqlite3_bind_int(upsert, 5, evidence) == SQLITE_OK,
                  sqlite3_bind_int(upsert, 6, record.uncertainPublication ? 1 : 0) == SQLITE_OK else { throw failure(db) }
            if record.recognizedPaths.isEmpty {
                guard sqlite3_bind_null(upsert, 7) == SQLITE_OK else { throw failure(db) }
            } else {
                try bindBlob(JSONEncoder().encode(record.recognizedPaths), 7, upsert, db)
            }
            guard sqlite3_step(upsert) == SQLITE_DONE else { throw failure(db) }
            return Versioned(record: record, revision: next.partialValue)
        }
    }

    static func batch(_ db: OpaquePointer, key: Key, create: Bool) throws -> Batch? {
        guard let id = try mapping(db, key: key, create: create) else { return nil }
        return try Batch(db, key: key, namespace: id)
    }
    static func read(_ db: OpaquePointer, key: Key) throws -> Versioned? {
        try batch(db, key: key, create: false)?.read(key: key)
    }
    @discardableResult
    static func write(_ db: OpaquePointer, record: SourceNameLineage.Record,
                      expectedRevision: Int64?) throws -> Versioned {
        guard sqlite3_get_autocommit(db) == 0 else { throw Failure.transactionRequired }
        guard let writer = try batch(db, key: Key(record), create: true) else { throw Failure.invalid }
        return try writer.write(record: record, expectedRevision: expectedRevision)
    }
}
