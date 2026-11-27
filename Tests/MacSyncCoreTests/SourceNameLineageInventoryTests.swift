import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageInventoryTests: XCTestCase {
    private func fixture(_ body: (URL, URL, String, String) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try body(source, target, base.appendingPathComponent("shadow.sqlite").path,
            base.appendingPathComponent("baseline.sqlite").path)
    }

    private func bind(_ inventory: LocalInventory, _ journal: ChangeJournal,
                      source: URL, target: URL) throws {
        _ = try inventory.reconcile(rootID: "photos", root: source)
        try journal.verifyDirectoryBindings([try MountedFolderMapping(rootID: "photos", source: source, target: target)],
            allowNewTarget: true)
    }

    private func records(_ path: String, source: URL, target: URL) throws -> [SourceNameLineageStore.Versioned] {
        let rows = try LocalScanner.scan(root: source, collectSourceLineageIdentity: true)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        defer { sqlite3_close(db) }
        let a = try DirectoryBinding.encoded(source), b = try DirectoryBinding.encoded(target)
        return try rows.compactMap { row in
            guard let id = row.sourceLineageIdentity else { return nil }
            let record = SourceNameLineage.Record(identity: id, rootID: "photos",
                sourceBinding: a, targetBinding: b, path: row.relativePath)
            return try SourceNameLineageStore.read(db, key: .init(record))
        }
    }

    func testRealInventoryPartialRenameDeleteFirstAndReopenPreservesQueueSemantics() throws {
        try fixture { source, target, shadow, baseline in
            let a = try ChangeJournal(path: shadow), b = try ChangeJournal(path: baseline)
            var observed = try LocalInventory(path: shadow)
            let original = try LocalInventory(path: baseline)
            let old = source.appendingPathComponent("photo.jpg")
            try Data([1]).write(to: old)
            try bind(observed, a, source: source, target: target)
            try bind(original, b, source: source, target: target)
            observed.experimentalSourceNameLineage = true
            func compare() throws {
                XCTAssertEqual(try a.pending(limit: 100).map { $0.kind.rawValue + ":" + $0.relativePath },
                    try b.pending(limit: 100).map { $0.kind.rawValue + ":" + $0.relativePath })
            }
            _ = try observed.reconcile(rootID: "photos", root: source)
            _ = try original.reconcile(rootID: "photos", root: source)
            let first = try XCTUnwrap(try records(shadow, source: source, target: target).first)
            XCTAssertEqual(first.record.evidence, .unknown)
            XCTAssertEqual(first.revision, 1)
            _ = try observed.reconcile(rootID: "photos", root: source)
            XCTAssertEqual(try records(shadow, source: source, target: target).first?.revision, 1)
            let bad = source.appendingPathComponent("photo.jpg.")
            try FileManager.default.moveItem(at: old, to: bad)
            // Model two separate FSEvents reconciliations, with the old
            // path's disappearance committed before the new path appears.
            _ = try observed.reconcile(rootID: "photos", root: source, subtree: old, eventID: 1)
            _ = try original.reconcile(rootID: "photos", root: source, subtree: old, eventID: 1)
            try compare()
            observed = try LocalInventory(path: shadow)
            observed.experimentalSourceNameLineage = true
            _ = try observed.reconcile(rootID: "photos", root: source, subtree: bad, eventID: 2)
            _ = try original.reconcile(rootID: "photos", root: source, subtree: bad, eventID: 2)
            try compare()
            let renamed = try XCTUnwrap(try records(shadow, source: source, target: target).first)
            XCTAssertEqual(renamed.record.identity, first.record.identity)
            XCTAssertEqual(renamed.record.currentPath, "photo.jpg.")
            XCTAssertEqual(renamed.record.evidence, .unknown)
            XCTAssertEqual(renamed.revision, 2)
            let fixed = source.appendingPathComponent("corrected.jpg")
            try FileManager.default.moveItem(at: bad, to: fixed)
            _ = try observed.reconcile(rootID: "photos", root: source, eventID: 3)
            _ = try original.reconcile(rootID: "photos", root: source, eventID: 3)
            try compare()
            XCTAssertEqual(try observed.lastEventID(rootID: "photos"), 3)
            let last = try XCTUnwrap(try records(shadow, source: source, target: target).first)
            XCTAssertEqual(last.record.currentPath, "corrected.jpg")
            XCTAssertEqual(last.revision, 3)
            XCTAssertTrue(last.record.recognizedPaths.isEmpty)
        }
    }

    func testHardLinkedFilesDoNotCreateIdentityRecords() throws {
        try fixture { source, target, shadow, _ in
            let journal = try ChangeJournal(path: shadow)
            let inventory = try LocalInventory(path: shadow)
            let file = source.appendingPathComponent("one.jpg")
            try Data([1]).write(to: file)
            try FileManager.default.linkItem(at: file, to: source.appendingPathComponent("two.jpg"))
            try bind(inventory, journal, source: source, target: target)
            inventory.experimentalSourceNameLineage = true
            _ = try inventory.reconcile(rootID: "photos", root: source)
            XCTAssertTrue(try records(shadow, source: source, target: target).isEmpty)
            XCTAssertEqual(try journal.pending(limit: 100).count, 2)
        }
    }

    func testSmallRepresentativeCostAndNoOpReconciliation() throws {
        try fixture { source, target, shadow, baseline in
            let count = 1000
            for i in 0..<count {
                try Data([1]).write(to: source.appendingPathComponent("photo-\(i).jpg"))
            }
            let a = try ChangeJournal(path: shadow), b = try ChangeJournal(path: baseline)
            let observed = try LocalInventory(path: shadow), original = try LocalInventory(path: baseline)
            try bind(observed, a, source: source, target: target)
            try bind(original, b, source: source, target: target)
            observed.experimentalSourceNameLineage = true
            func time(_ inventory: LocalInventory) throws -> Double {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try inventory.reconcile(rootID: "photos", root: source)
                XCTAssertEqual(result.queuedUpserts, 0)
                XCTAssertEqual(result.queuedDeletes, 0)
                return ProcessInfo.processInfo.systemUptime - start
            }
            let baseTime = try time(original)
            let seedTime = try time(observed)
            let repeatTime = try time(observed)
            let saved = try records(shadow, source: source, target: target)
            XCTAssertEqual(saved.count, count)
            XCTAssertTrue(saved.allSatisfy { $0.revision == 1 && $0.record.evidence == .unknown })
            XCTAssertEqual(try a.pending(limit: 2000).map(\.relativePath),
                           try b.pending(limit: 2000).map(\.relativePath))
            func logicalBytes(_ path: String) throws -> Int64 {
                var connection: OpaquePointer?
                XCTAssertEqual(sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
                let db = try XCTUnwrap(connection)
                defer { sqlite3_close(db) }
                var stmt: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(db,
                    "SELECT page_count*page_size FROM pragma_page_count(),pragma_page_size();", -1, &stmt, nil), SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
                return sqlite3_column_int64(stmt, 0)
            }
            print("LINEAGE_SHADOW_COST count=\(count) baseline=\(baseTime) seed=\(seedTime) repeat=\(repeatTime) baseline_bytes=\(try logicalBytes(baseline)) shadow_bytes=\(try logicalBytes(shadow))")
        }
    }
}
