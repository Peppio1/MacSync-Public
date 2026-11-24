import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class V0191MaintenanceTests: XCTestCase {
    func testUnilateralRenameLeavesOppositeAndQueueUntouchedAndPersistsHold() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"), target=base.appendingPathComponent("target")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        let old="folder - ", new="folder -"
        let content=Data("synthetic archive".utf8)
        for root in [source,target] {
            let dir=root.appendingPathComponent(old)
            try fm.createDirectory(at:dir,withIntermediateDirectories:true)
            try content.write(to:dir.appendingPathComponent("content.jpg"))
        }
        let db=base.appendingPathComponent("inventory.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let map=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        try journal.enqueue(rootID:"demo",relativePath:"existing.jpg",kind:.upsert)
        let before=try journal.pending()
        let log=try SyncActivityLog(path:db)
        let rows=IncompatibleName.Side.allCases.map { side in
            IncompatibleName(rootID:"demo",rootPath:side == .source ? source.path : target.path,
                relativePath:old,objectKind:"directory",side:side,reason:"Spazio finale")
        }
        // An unmounted/unavailable destination is represented by no mapping.
        let local=try NameRectification.executeCoordinated(items:rows,roots:["demo":source.path],
            journal:journal,log:log,destinations:[:],onlySide:.source)
        XCTAssertEqual(local.sourceRenamed,1)
        XCTAssertEqual(local.destinationRenamed,0)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(new).appendingPathComponent("content.jpg")),content)
        XCTAssertTrue(fm.fileExists(atPath:target.appendingPathComponent(old).path))
        XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent(new).path))
        XCTAssertEqual(try journal.pending(),before)
        XCTAssertTrue(try ChangeJournal(path:db,readOnly:true).unilateralNameAuditRequired())
        XCTAssertFalse(try journal.hasPendingNameRectification())

        let stopped=expectation(description:"Automatic startup does not reconcile during unilateral maintenance")
        let monitor=LocalMonitorService { _ in }
        monitor.start(roots:[MonitorRoot(id:"demo",url:source)],databasePath:db)
        monitor.afterStopped { stopped.fulfill() }
        wait(for:[stopped],timeout:10)
        XCTAssertFalse(monitor.safetyGate.isReady)
        XCTAssertEqual(try journal.pending(),before)

        let remote=try NameRectification.executeCoordinated(items:rows,roots:["demo":source.path],
            journal:journal,log:log,destinations:["demo":map],onlySide:.destination)
        XCTAssertEqual(remote.sourceRenamed,0)
        XCTAssertEqual(remote.destinationRenamed,1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(new).appendingPathComponent("content.jpg")),content)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(new).appendingPathComponent("content.jpg")),content)
        XCTAssertEqual(try journal.pending(),before)
        XCTAssertTrue(try journal.unilateralNameAuditRequired())
        XCTAssertTrue(try journal.nameRectificationScopes().isEmpty)
        XCTAssertFalse(try journal.hasPendingNameRectification())
    }

    func testV0192LocalRectificationCreatesOrdinaryMonitorChangesWithoutAuditHold() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        defer { try? fm.removeItem(at:base) }
        let old = "Foto12345.", new = "Foto12345-"
        for root in [source, target] {
            let dir = root.appendingPathComponent(old)
            try fm.createDirectory(at:dir, withIntermediateDirectories:true)
            try Data("fixture".utf8).write(to:dir.appendingPathComponent("photo.jpg"))
        }
        let db = base.appendingPathComponent("inventory.sqlite").path
        let inventory = try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo", root:source, origin:.initialInventory)
        let journal = try ChangeJournal(path:db)
        let log = try SyncActivityLog(path:db)
        XCTAssertTrue(try journal.pending().isEmpty)
        let items = try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path)
        XCTAssertEqual(items.map(\.relativePath), [old])
        let result = try NameRectification.executeCoordinated(items:items, roots:["demo":source.path],
            journal:journal, log:log, destinations:[:], onlySide:.source, normalLocalRename:true)
        XCTAssertEqual(result.sourceRenamed,1)
        XCTAssertFalse(try journal.unilateralNameAuditRequired())
        XCTAssertFalse(try journal.hasPendingNameRectification())
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertTrue(fm.fileExists(atPath:target.appendingPathComponent(old).path))
        XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent(new).path))
        _ = try inventory.reconcile(rootID:"demo", root:source)
        let pending = try journal.pending()
        XCTAssertTrue(pending.contains { $0.kind == .upsert && $0.relativePath == new + "/photo.jpg" })
        XCTAssertTrue(pending.contains { $0.kind == .delete && $0.relativePath == old + "/photo.jpg" })
        XCTAssertTrue(try inventory.incompatibleNames(rootID:"demo", sourcePath:source.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(new).appendingPathComponent("photo.jpg")),Data("fixture".utf8))
    }

    func testV0192NameIndexTracksManualChangesAndNestedPaths() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source")
        let old=source.appendingPathComponent("parent.")
        try fm.createDirectory(at:old,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        try Data("a".utf8).write(to:old.appendingPathComponent("bad?.jpg"))
        let db=base.appendingPathComponent("inventory.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo",root:source,origin:.initialInventory)
        let rows=try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path)
        XCTAssertEqual(Set(rows.map(\.relativePath)),Set(["parent.","parent./bad?.jpg"]))
        XCTAssertEqual(rows.first(where:{$0.isDirectory})?.affectedDescendants,1)
        let renamed=source.appendingPathComponent("parent-")
        try fm.moveItem(at:old,to:renamed)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:old)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:renamed)
        XCTAssertEqual(try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path).map(\.relativePath),["parent-/bad?.jpg"])
        let oldFile=renamed.appendingPathComponent("bad?.jpg")
        let newFile=renamed.appendingPathComponent("bad-.jpg")
        try fm.moveItem(at:oldFile,to:newFile)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:oldFile)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:newFile)
        XCTAssertTrue(try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path).isEmpty)
        let fresh=source.appendingPathComponent("new. ")
        try Data("b".utf8).write(to:fresh)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:fresh)
        XCTAssertEqual(try LocalInventory(path:db).incompatibleNames(rootID:"demo",sourcePath:source.path).map(\.relativePath),["new. "])
        try fm.removeItem(at:fresh)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:fresh)
        XCTAssertTrue(try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path).isEmpty)
    }

    func testV0192DedicatedNameQueueIncludesInvalidAncestorsAndExcludesBaselineOnly() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"), target=base.appendingPathComponent("target")
        let bad=source.appendingPathComponent("blocked.")
        try fm.createDirectory(at:bad,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        try Data("baseline".utf8).write(to:source.appendingPathComponent("baseline?"))
        let db=base.appendingPathComponent("inventory.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo",root:source,origin:.initialInventory)
        let journal=try ChangeJournal(path:db)
        XCTAssertTrue(try journal.pendingLocalNameRectifications().isEmpty)
        let child=bad.appendingPathComponent("child.jpg")
        let independent=source.appendingPathComponent("good.jpg")
        try Data("blocked".utf8).write(to:child)
        try Data("good".utf8).write(to:independent)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:child)
        _ = try inventory.reconcile(rootID:"demo",root:source,subtree:independent)
        XCTAssertEqual(try ChangeJournal(path:db,readOnly:true).pendingLocalNameRectifications().map(\.relativePath),["blocked."])
        let map=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        let worker=try MountedFolderCopyWorker(journal:journal,log:SyncActivityLog(path:db),
            mappings:[map],minimumStableAge:0)
        let result=try worker.runCycle(enabled:true)
        XCTAssertGreaterThanOrEqual(result.deferred,1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("good.jpg")),Data("good".utf8))
        XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent("blocked.").path))
        XCTAssertEqual(try journal.pendingLocalNameRectifications().map(\.relativePath),["blocked."])
    }

    func testFinalizedTotalsSurviveMissingDetailRow() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let db=base.appendingPathComponent("history.sqlite").path
        let history=try SyncCycleHistory(path:db)
        let at=Date()
        try history.begin(id:"cycle",sessionID:"session",at:at)
        let job=QueuedChange(id:1,rootID:"demo",relativePath:"actual.jpg",kind:.delete,recordedAt:at)
        let deleted=SyncCycleEvent(kind:.deleted,job:job,mapping:nil,bytes:42)
        let cleanup=SyncCycleEvent(kind:.recoveryExpired,job:job,mapping:nil)
        var totals=SyncHistoryTotals()
        totals.add(deleted); totals.add(cleanup)
        // Simulate the detail INSERT failing while the observed deletion
        // remains in the worker's final totals.
        try history.append(cycleID:"cycle",event:cleanup)
        try history.finish(id:"cycle",at:at,seconds:1,state:"completed_history_incomplete",totals:totals)
        let reader=try SyncCycleHistory(path:db,readOnly:true)
        XCTAssertEqual(try reader.totals(cycleID:"cycle"),totals)
        XCTAssertEqual(try reader.totals(cycleID:"cycle").stats.permanentlyDeleted,1)
        XCTAssertEqual(try reader.events(cycleID:"cycle").count,1)
        XCTAssertEqual(try reader.cycles().first?.state,"completed_history_incomplete")
    }

    func testExistingSchemaOpensWhileAnotherConnectionHoldsWriteTransaction() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let db=base.appendingPathComponent("inventory.sqlite").path
        _ = try LocalInventory(path:db)
        let journal=try ChangeJournal(path:db)
        _ = try SyncActivityLog(path:db)
        _ = try SyncCycleHistory(path:db)
        _ = try journal.enqueue(rootID:"demo",relativePath:"preserved.jpg",kind:.upsert)
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open(db,&handle),SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle,"BEGIN IMMEDIATE;",nil,nil,nil),SQLITE_OK)
        defer { sqlite3_exec(handle,"ROLLBACK;",nil,nil,nil) }
        // No migration write transaction should be acquired on an existing schema.
        let reopened=try ChangeJournal(path:db)
        _ = try LocalInventory(path:db)
        XCTAssertEqual(try reopened.pending(),try journal.pending())
    }
}
