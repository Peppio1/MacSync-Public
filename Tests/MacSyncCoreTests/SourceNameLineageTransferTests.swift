import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SourceNameLineageTransferTests: XCTestCase {
    func testCombinedAuditTransferFailureAndManualRenameHistory() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacSync-lineage-transfer-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        for root in [source,target] { try fm.createDirectory(at:root,withIntermediateDirectories:true) }
        let db = base.appendingPathComponent("state.sqlite").path
        let journal = try ChangeJournal(path:db)
        let inventory = try LocalInventory(path:db)
        let fixed = Date(timeIntervalSinceNow:-1000)
        func write(_ value:String,_ path:String,_ root:URL) throws {
            let url = root.appendingPathComponent(path)
            try Data(value.utf8).write(to:url)
            try fm.setAttributes([.modificationDate:fixed],ofItemAtPath:url.path)
        }
        try write("seed","seed.jpg",source)
        try write("seed","seed.jpg",target)
        _ = try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map = try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        journal.experimentalSourceNameLineage = true
        inventory.experimentalSourceNameLineage = true
        _ = try inventory.reconcile(rootID:"photos",root:source)
        _ = try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        try write("copied","copied.jpg",source)
        try write("interrupted","interrupted.jpg",source)
        _ = try inventory.reconcile(rootID:"photos",root:source,eventID:1)
        let log = try SyncActivityLog(path:db)
        let worker = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[map],minimumStableAge:0)
        worker.checkpoint = { phase,url in
            if phase == .afterPublish, url.lastPathComponent == "interrupted.jpg" {
                throw MountedCopyError.copyFailed(5)
            }
        }
        let result = try worker.runCycle(enabled:true)
        XCTAssertEqual(result.copied,1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("copied.jpg")),Data("copied".utf8))
        XCTAssertTrue(try journal.pending().contains{$0.relativePath=="interrupted.jpg"})
        func stored(_ path:String) throws -> SourceNameLineageStore.Versioned {
            let row = try XCTUnwrap(try LocalScanner.scan(root:source,collectSourceLineageIdentity:true)
                .first{$0.relativePath==path})
            let id = try XCTUnwrap(row.sourceLineageIdentity)
            let initial = SourceNameLineage.Record(identity:id,rootID:"photos",
                sourceBinding:try DirectoryBinding.encoded(source),targetBinding:try DirectoryBinding.encoded(target),path:path)
            var connection:OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(db,&connection,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
            let handle = try XCTUnwrap(connection)
            defer { sqlite3_close(handle) }
            return try XCTUnwrap(try SourceNameLineageStore.read(handle,key:.init(initial)))
        }
        XCTAssertEqual(try stored("seed.jpg").record.recognizedPaths,["seed.jpg"])
        XCTAssertEqual(try stored("copied.jpg").record.recognizedPaths,["copied.jpg"])
        XCTAssertFalse(try stored("copied.jpg").record.uncertainPublication)
        XCTAssertTrue(try stored("interrupted.jpg").record.uncertainPublication)
        XCTAssertTrue(try stored("interrupted.jpg").record.recognizedPaths.isEmpty)
        let bad = source.appendingPathComponent("copied.jpg.")
        try fm.moveItem(at:source.appendingPathComponent("copied.jpg"),to:bad)
        _ = try inventory.reconcile(rootID:"photos",root:source,eventID:2)
        var saved = try stored("copied.jpg.").record
        XCTAssertEqual(saved.recognizedPaths,["copied.jpg"])
        let decision = saved.observe(identity:saved.identity,path:"fixed.jpg",rootID:saved.rootID,
            sourceBinding:saved.sourceBinding,targetBinding:saved.targetBinding,uniqueObservation:true)
        XCTAssertEqual(decision.deletionCandidates,["copied.jpg"])
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("copied.jpg")),Data("copied".utf8))
        // Still shadow-only: no new deletion authorization or queue suppression.
    }
}
