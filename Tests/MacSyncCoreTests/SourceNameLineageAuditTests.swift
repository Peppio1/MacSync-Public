import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageAuditTests: XCTestCase {
    func testPristineSeedWithoutPendingJobsPreservesAuditResults() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacSync-unqueued-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        for root in [source,target] {
            try fm.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
            for name in ["same.jpg","different.jpg","changed.jpg"] {
                let url = root.appendingPathComponent("folder/"+name)
                try Data((root == target && name == "different.jpg" ? "longer" : "same").utf8).write(to:url)
                try fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:url.path)
            }
        }
        let db = base.appendingPathComponent("state.sqlite")
        let journal = try ChangeJournal(path:db.path)
        let inventory = try LocalInventory(path:db.path)
        _ = try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let mapping = try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([mapping],allowNewTarget:true)
        XCTAssertTrue(try journal.pending().isEmpty)
        let audit = try ArchiveAudit(journal:journal,mappings:[mapping])
        let baseline = try audit.run(mode:.quick,repair:true)
        XCTAssertEqual(baseline.queuedRepairs,1)
        journal.experimentalSourceNameLineage = true
        // A post-scan local edit with unchanged size and mtime must not be
        // promoted to recognized by the historical observation.
        var edited = false
        let shadow = try audit.run(mode:.quick,repair:true,progress:{ p in
            if !edited && p.phase == "Finalizzazione" {
                edited = true
                let url = source.appendingPathComponent("folder/changed.jpg")
                try? Data("edit".utf8).write(to:url)
                try? fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:url.path)
            }
        })
        XCTAssertTrue(edited)
        XCTAssertEqual(shadow.bytesRead,baseline.bytesRead)
        XCTAssertEqual(shadow.findings.map{$0.relativePath+":"+$0.kind.rawValue},
                       baseline.findings.map{$0.relativePath+":"+$0.kind.rawValue})
        XCTAssertEqual(try journal.pending().map(\.relativePath),["folder/different.jpg"])
        let rows = try LocalScanner.scan(root:source,collectSourceLineageIdentity:true)
        var connection:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path,&connection,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        let handle = try XCTUnwrap(connection)
        defer { sqlite3_close(handle) }
        func observed(_ name:String) throws -> SourceNameLineageStore.Versioned? {
            let item = try XCTUnwrap(rows.first{$0.relativePath==name})
            let id = try XCTUnwrap(item.sourceLineageIdentity)
            let initial = SourceNameLineage.Record(identity:id,rootID:"photos",
                sourceBinding:try DirectoryBinding.encoded(source),targetBinding:try DirectoryBinding.encoded(target),path:name)
            return try SourceNameLineageStore.read(handle,key:.init(initial))
        }
        XCTAssertEqual(try observed("folder/same.jpg")?.record.evidence,.recognized)
        XCTAssertNil(try observed("folder/different.jpg"))
        XCTAssertNil(try observed("folder/changed.jpg"))
        XCTAssertEqual(try observed("folder")?.record.evidence,.recognized)
        print("LINEAGE_UNQUEUED baseline=\(baseline.seconds) shadow=\(shadow.seconds) target_bytes_read=\(shadow.bytesRead)")
    }

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
