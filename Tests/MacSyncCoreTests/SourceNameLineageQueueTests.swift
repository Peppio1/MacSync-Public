import Foundation
import XCTest
@testable import MacSyncCore

final class SourceNameLineageQueueTests: XCTestCase {
    func testSplitRenameEventsProtectOldCopyAndRetireSpeculativeInvalidFileDelete() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent("MacSync-queue-lineage-"+UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        for root in [source,target] { try fm.createDirectory(at:root,withIntermediateDirectories:true) }
        let db=base.appendingPathComponent("state.sqlite").path
        let journal=try ChangeJournal(path:db)
        var inventory=try LocalInventory(path:db)
        let original=source.appendingPathComponent("photo.jpg")
        let remote=target.appendingPathComponent("photo.jpg")
        let ordinary=source.appendingPathComponent("ordinary.jpg")
        let fixedDate=Date(timeIntervalSinceNow:-1000)
        for file in [original,remote,ordinary,target.appendingPathComponent("ordinary.jpg")] {
            try Data("photo".utf8).write(to:file)
            try fm.setAttributes([.modificationDate:fixedDate],ofItemAtPath:file.path)
        }
        _=try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        journal.experimentalSourceNameLineage=true
        inventory.experimentalSourceNameLineage=true
        inventory.experimentalLineageQueueProtection=true
        _=try inventory.reconcile(rootID:"photos",root:source)
        _=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        let bad=source.appendingPathComponent("photo.jpg.")
        try fm.moveItem(at:original,to:bad)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:1)
        let old=try XCTUnwrap(try journal.pending().first{$0.relativePath=="photo.jpg" && $0.kind == .delete})
        let reopened=try ChangeJournal(path:db)
        XCTAssertFalse(try reopened.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        try reopened.resolveLineageMissing(rootID:"photos",rows:LocalScanner.scan(root:source),shouldContinue:{true})
        XCTAssertFalse(try reopened.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        inventory=try LocalInventory(path:db)
        inventory.experimentalSourceNameLineage=true
        inventory.experimentalLineageQueueProtection=true
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:2)
        let corrected=source.appendingPathComponent("fixed.jpg")
        try fm.moveItem(at:bad,to:corrected)
        let change=try inventory.reconcile(rootID:"photos",root:source,eventID:3)
        XCTAssertEqual(change.queuedDeletes,0)
        XCTAssertFalse(try journal.pending().contains{$0.relativePath=="photo.jpg."})
        XCTAssertFalse(try reopened.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        XCTAssertEqual(try Data(contentsOf:remote),Data("photo".utf8))
        let worker=try MountedFolderCopyWorker(journal:journal,log:SyncActivityLog(path:db),mappings:[map],minimumStableAge:0)
        XCTAssertEqual(try worker.runCycle(enabled:true).copied,1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("fixed.jpg")),Data("photo".utf8))
        XCTAssertTrue(try reopened.deletionIsCurrent(id:old.id,rootID:old.rootID,relativePath:old.relativePath))
        // Genuine removal is resolved from the already required complete
        // local scan; no extra target scan or permanent hold.
        try fm.removeItem(at:ordinary)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:ordinary,eventID:4)
        let removed=try XCTUnwrap(try journal.pending().first{$0.relativePath=="ordinary.jpg"})
        XCTAssertFalse(try reopened.deletionIsCurrent(id:removed.id,rootID:removed.rootID,relativePath:removed.relativePath))
        try reopened.resolveLineageMissing(rootID:"photos",rows:LocalScanner.scan(root:source),shouldContinue:{true})
        XCTAssertTrue(try reopened.deletionIsCurrent(id:removed.id,rootID:removed.rootID,relativePath:removed.relativePath))
        // Old copy has not been physically removed by the new code.
        XCTAssertEqual(try Data(contentsOf:remote),Data("photo".utf8))
    }
}
