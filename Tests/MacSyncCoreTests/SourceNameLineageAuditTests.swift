import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageAuditTests: XCTestCase {
    func testRealAcceptedQuickMatchesOnlyAndAtomicCancellation() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacSync-lineage-audit-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let db = base.appendingPathComponent("state.sqlite")
        let journal = try ChangeJournal(path: db.path)
        let inventory = try LocalInventory(path: db.path)
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let names = ["accepted.jpg", "generic.jpg", "superseded.jpg", "uncertain.jpg", "cancelled.jpg", "different.jpg"]
        for name in names {
            for root in [source, target] {
                let url = root.appendingPathComponent(name)
                try Data((name == "different.jpg" && root == target ? "different-longer" : "same").utf8).write(to: url)
                try fm.setAttributes([.modificationDate: fixed], ofItemAtPath: url.path)
            }
        }
        _ = try inventory.reconcile(rootID: "photos", root: source, origin: .initialInventory)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        inventory.experimentalSourceNameLineage = true
        _ = try inventory.reconcile(rootID: "photos", root: source)
        journal.experimentalSourceNameLineage = true

        var jobs: [String: Int64] = [:]
        for name in names {
            jobs[name] = try journal.enqueue(rootID: "photos", relativePath: name,
                kind: .upsert, origin: .sourceMonitor)
        }
        let generic = try XCTUnwrap(jobs["generic.jpg"])
        try journal.markCompleted(id: generic)
        let uncertain = try XCTUnwrap(try journal.pending().first { $0.relativePath == "uncertain.jpg" })
        try journal.recordPublicationIntent(uncertain)
        var matches: [SeedVerifiedMatch] = []
        let audit = try ArchiveAudit(journal: journal, mappings: [mapping])
        let report = try audit.run(mode: .quick, collectMetadataMatches: true,
            onVerifiedFile: { root, path, src, dst in
                guard let id = jobs[path] else { return }
                matches.append(SeedVerifiedMatch(jobID: id, rootID: root, relativePath: path,
                    source: src, target: dst, verifiedBytes: src.size, objectKind: "file"))
            })
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertFalse(matches.contains { $0.relativePath == "different.jpg" })
        _ = try journal.enqueue(rootID: "photos", relativePath: "superseded.jpg", kind: .upsert,
            origin: .sourceMonitor)

        func stored(_ path: String) throws -> SourceNameLineageStore.Versioned {
            let item = try XCTUnwrap(try LocalScanner.scan(root: source, collectSourceLineageIdentity: true)
                .first { $0.relativePath == path })
            let identity = try XCTUnwrap(item.sourceLineageIdentity)
            let initial = SourceNameLineage.Record(identity: identity, rootID: "photos",
                sourceBinding: try DirectoryBinding.encoded(source), targetBinding: try DirectoryBinding.encoded(target),
                path: path)
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(db.path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
            let handle = try XCTUnwrap(connection)
            defer { sqlite3_close(handle) }
            return try XCTUnwrap(try SourceNameLineageStore.read(handle,key: .init(initial)))
        }

        let cancelled = try XCTUnwrap(matches.first { $0.relativePath == "cancelled.jpg" })
        var checks = 0
        XCTAssertThrowsError(try journal.acknowledgeOperationalAuditMatches([cancelled], mappings: [mapping],
            shouldContinue: { checks += 1; return checks < 3 }))
        XCTAssertEqual(try stored("cancelled.jpg").record.evidence, .unknown)
        XCTAssertTrue(try journal.pending().contains { $0.id == cancelled.jobID })

        let results = try journal.acknowledgeOperationalAuditMatches(
            matches.filter { $0.relativePath != "cancelled.jpg" }, mappings: [mapping], shouldContinue: { true })
        XCTAssertEqual(results.files, 1)
        XCTAssertEqual(results.directories, 0)
        let accepted = try stored("accepted.jpg")
        XCTAssertEqual(accepted.record.evidence, .recognized)
        XCTAssertEqual(accepted.record.recognizedPaths, ["accepted.jpg"])
        XCTAssertEqual(accepted.revision, 2)
        for name in names where name != "accepted.jpg" {
            XCTAssertEqual(try stored(name).record.evidence, .unknown, name)
        }
        XCTAssertFalse(try journal.pending().contains { $0.relativePath == "accepted.jpg" })
        XCTAssertTrue(try journal.pending().contains { $0.relativePath == "uncertain.jpg" })
        let before = try LocalScanner.scan(root: target)
        let bad = source.appendingPathComponent("accepted.jpg ")
        try fm.moveItem(at: source.appendingPathComponent("accepted.jpg"), to: bad)
        _ = try inventory.reconcile(rootID: "photos", root: source, eventID: 1)
        let after = try stored("accepted.jpg ")
        XCTAssertEqual(after.record.recognizedPaths, ["accepted.jpg"])
        XCTAssertEqual(after.record.evidence, .recognized)
        XCTAssertEqual(after.revision, 3)
        XCTAssertEqual(try LocalScanner.scan(root: target), before)
    }
}
