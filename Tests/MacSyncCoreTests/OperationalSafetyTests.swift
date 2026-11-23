import Foundation
import XCTest
import Darwin
import SQLite3
@testable import MacSyncCore

final class OperationalSafetyTests: XCTestCase {
    private func fixture() throws -> (URL,URL,URL,URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source = base.appendingPathComponent("Source"), target = base.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        return (base,source,target,base.appendingPathComponent("state.sqlite"))
    }
    func testAuditListingCacheReusesStableDirectoryAndClearsOnError() throws {
        let (base,_,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        try Data("a".utf8).write(to:target.appendingPathComponent("one.jpg"))
        try Data("b".utf8).write(to:target.appendingPathComponent("two.jpg"))
        let cache=AuditDirectoryListingCache()
        XCTAssertEqual(try cache.aliases(for:"one.jpg",in:target),["one.jpg"])
        XCTAssertEqual(try cache.aliases(for:"two.jpg",in:target),["two.jpg"])
        XCTAssertEqual(cache.enumerations,1)
        XCTAssertEqual(cache.hits,1)
        // Mutations change the stamp; a new alias must not be hidden.
        try Data("c".utf8).write(to:target.appendingPathComponent("one.jpg "))
        XCTAssertEqual(Set(try cache.aliases(for:"one.jpg",in:target)),Set(["one.jpg","one.jpg "]))
        XCTAssertEqual(cache.enumerations,2)
        XCTAssertThrowsError(try WindowsPathSafety.checkNames(relativePath:"one.jpg",under:target))
        let invalid=target.appendingPathComponent("absent")
        XCTAssertThrowsError(try cache.aliases(for:"one.jpg",in:invalid))
        _ = try cache.aliases(for:"two.jpg",in:target)
        XCTAssertEqual(cache.enumerations,3)
        cache.invalidate()
        _ = try cache.aliases(for:"two.jpg",in:target)
        XCTAssertEqual(cache.enumerations,4)
    }

    func testAuditListingCacheRejectsReplacedOrSymlinkDirectory() throws {
        let (base,source,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let cache=AuditDirectoryListingCache()
        try Data("first".utf8).write(to:target.appendingPathComponent("old.jpg"))
        XCTAssertEqual(try cache.aliases(for:"old.jpg",in:target),["old.jpg"])
        try FileManager.default.moveItem(at:target,to:base.appendingPathComponent("retired"))
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        try Data("new".utf8).write(to:target.appendingPathComponent("new.jpg"))
        XCTAssertEqual(try cache.aliases(for:"old.jpg",in:target),[])
        XCTAssertEqual(try cache.aliases(for:"new.jpg",in:target),["new.jpg"])
        try FileManager.default.removeItem(at:target)
        try FileManager.default.createSymbolicLink(at:target,withDestinationURL:source)
        XCTAssertThrowsError(try cache.aliases(for:"new.jpg",in:target))
    }

    func testExclusivePublicationProbeLeavesUnrelatedFilesUntouched() throws {
        let (base,_,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let unrelated=target.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to:unrelated)
        let anchor=try AnchoredDirectory(target,expectedVolume:VolumeFingerprint.read(at:target))
        _ = try anchor.probeExclusivePublication(shouldContinue:{true})
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:target.path),["keep.txt"])
        XCTAssertEqual(try String(contentsOf:unrelated,encoding:.utf8),"keep")
    }

    func testExclusiveLinkPublicationPreservesExistingTargetAndPublishesCompleteFile() throws {
        let (base,source,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let stage = source.appendingPathComponent("staged"), final = target.appendingPathComponent("photo.jpg")
        try Data("complete".utf8).write(to:stage)
        try Data("previous".utf8).write(to:final)
        let volume = try VolumeFingerprint.read(at:source)
        let a = try AnchoredDirectory(source,expectedVolume:volume)
        let b = try AnchoredDirectory(target,expectedVolume:volume)
        let original = try a.leaf("staged")
        XCTAssertThrowsError(try a.publishByLink("staged",matching:original,to:b,as:"photo.jpg",shouldContinue:{true}))
        XCTAssertEqual(try String(contentsOf:final,encoding:.utf8),"previous")
        XCTAssertEqual(try String(contentsOf:stage,encoding:.utf8),"complete")
        try FileManager.default.removeItem(at:final)
        try a.publishByLink("staged",matching:try a.leaf("staged"),to:b,as:"photo.jpg",shouldContinue:{true})
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
        XCTAssertEqual(try String(contentsOf:final,encoding:.utf8),"complete")
    }

    func testPersistentSourceBindingBlocksReplacementAfterReopen() throws {
        let (base,source,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        try Data("A".utf8).write(to:source.appendingPathComponent("a.jpg"))
        _ = try LocalInventory(path:db.path).reconcile(rootID:"r",root:source)
        let before = try ChangeJournal(path:db.path).pending()
        try FileManager.default.moveItem(at:source,to:base.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false)
        XCTAssertThrowsError(try LocalInventory(path:db.path).reconcile(rootID:"r",root:source))
        XCTAssertEqual(try ChangeJournal(path:db.path).pending(),before)
    }
    func testPersistentTargetBindingBlocksSameVolumeReplacement() throws {
        let (base,source,target,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        _ = try LocalInventory(path:db.path).reconcile(rootID:"r",root:source)
        let first = try MountedFolderMapping(rootID:"r",source:source,target:target)
        try ChangeJournal(path:db.path).verifyDirectoryBindings([first],allowNewTarget:true)
        try FileManager.default.moveItem(at:target,to:base.appendingPathComponent("old-target"))
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        let next = try MountedFolderMapping(rootID:"r",source:source,target:target)
        XCTAssertThrowsError(try ChangeJournal(path:db.path).verifyDirectoryBindings([next],allowNewTarget:true))
    }
    func testSameSizeSameModificationDateStillQueuesAfterChange() throws {
        let (base,source,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let file = source.appendingPathComponent("a.jpg")
        let fixed = Date(timeIntervalSince1970:1_700_000_000)
        try Data("AAAA".utf8).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
        let store = try LocalInventory(path:db.path), journal = try ChangeJournal(path:db.path)
        _ = try store.reconcile(rootID:"r",root:source)
        for job in try journal.pending() { try journal.markCompleted(id:job.id) }
        try Data("BBBB".utf8).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:file.path)
        _ = try store.reconcile(rootID:"r",root:source)
        XCTAssertEqual(try journal.pending().map(\.relativePath),["a.jpg"])
    }
    func testStaleMonitorGenerationCannotReenableOperations() {
        let gate = MonitorSafetyGate()
        let old = gate.invalidate()
        gate.setReady(true,generation:old)
        XCTAssertTrue(gate.isReady)
        let next = gate.invalidate()
        gate.setReady(true,generation:old)
        XCTAssertFalse(gate.isReady)
        gate.setReady(true,generation:next)
        XCTAssertTrue(gate.isReady)
    }
    func testAuditWaitsForTransientFSEventsAndNeverTreatsActiveMonitoringAsBusy() throws {
        let gate=MonitorSafetyGate()
        let generation=gate.invalidate()
        gate.setReady(true,generation:generation)
        let auditToken=try XCTUnwrap(gate.beginAudit())
        let cancellation=SeedVerificationCancellation(
            shouldContinue:{ gate.auditBlockReason(auditToken) == nil },
            commitAllowed:{ gate.auditCommitAllowed(auditToken) })
        // An ACTIVE but IDLE FSEvents monitor must not delay audit commits.
        let idleStart=ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(cancellation.awaitCommitWindow(maxSeconds:0.5))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-idleStart,0.2)

        gate.beginReconciliation(generation:generation)
        XCTAssertFalse(gate.isReady)
        XCTAssertFalse(cancellation.mayCommit)
        XCTAssertFalse(cancellation.isCancelled)
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+0.08) {
            gate.setReady(true,generation:generation)
        }
        let started=ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(cancellation.awaitCommitWindow(maxSeconds:1))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime-started,0.05)
        XCTAssertTrue(gate.isReady)
        XCTAssertTrue(cancellation.mayCommit)
    }

    func testAuditWaitStopsOnExpiredGateAndPermanentInvalidation() throws {
        let gate=MonitorSafetyGate()
        let generation=gate.invalidate()
        gate.setReady(true,generation:generation)
        let token=try XCTUnwrap(gate.beginAudit())
        let cancellation=SeedVerificationCancellation(
            shouldContinue:{ gate.auditBlockReason(token) == nil },
            commitAllowed:{ gate.auditCommitAllowed(token) })
        gate.beginReconciliation(generation:generation)
        XCTAssertFalse(cancellation.awaitCommitWindow(maxSeconds:0.04))
        XCTAssertFalse(cancellation.isCancelled)
        // Changing the root configuration revokes the old audit token:
        // it must never be retried, even if a later generation is ready.
        let next=gate.invalidate()
        gate.setReady(true,generation:next)
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertFalse(cancellation.awaitCommitWindow(maxSeconds:0.5))
    }

    func testExplicitAuditCancelInterruptsGateWait() throws {
        let gate=MonitorSafetyGate()
        let generation=gate.invalidate()
        gate.setReady(true,generation:generation)
        let token=try XCTUnwrap(gate.beginAudit())
        let cancellation=SeedVerificationCancellation(
            shouldContinue:{ gate.auditBlockReason(token) == nil },
            commitAllowed:{ gate.auditCommitAllowed(token) })
        gate.beginReconciliation(generation:generation)
        cancellation.cancel()
        XCTAssertTrue(cancellation.wasExplicitlyCancelled)
        XCTAssertFalse(cancellation.awaitCommitWindow(maxSeconds:1))
    }

    func testWindowsPathSafetyRefusesIncompatibleAndAliasNames() throws {
        XCTAssertFalse(WindowsPathSafety.validRelativePath("Photos/CON.jpg"))
        XCTAssertFalse(WindowsPathSafety.validRelativePath("Photos/file."))
        XCTAssertFalse(WindowsPathSafety.validRelativePath("Photos/a:b"))
        XCTAssertFalse(WindowsPathSafety.validRelativePath("Photos/../a"))
        XCTAssertTrue(WindowsPathSafety.validRelativePath("Photos/Foto 001.dng"))
        let (base,_,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        try Data("A".utf8).write(to:target.appendingPathComponent("Image.jpg"))
        XCTAssertThrowsError(try WindowsPathSafety.checkNames(relativePath:"image.jpg",under:target))
        XCTAssertNoThrow(try WindowsPathSafety.checkNames(relativePath:"Image.jpg",under:target))
    }
    func testCanonicalUnicodeSpellingAllowsSameFileButRejectsCaseAlias() throws {
        let (base,_,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let composed = "foto \u{00E0}\u{00E8}.dng"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8),Array(decomposed.utf8))
        try Data("image".utf8).write(to:target.appendingPathComponent(composed))
        XCTAssertNoThrow(try WindowsPathSafety.checkNames(relativePath:composed,under:target))
        // On a normalization-sensitive filesystem an alternate spelling
        // must remain blocked, rather than create a second Windows alias.
        if FileManager.default.fileExists(atPath:target.appendingPathComponent(decomposed).path) {
            XCTAssertNoThrow(try WindowsPathSafety.checkNames(relativePath:decomposed,under:target))
        } else {
            XCTAssertThrowsError(try WindowsPathSafety.checkNames(relativePath:decomposed,under:target))
        }
        XCTAssertThrowsError(try WindowsPathSafety.checkNames(relativePath:composed.uppercased(),under:target))
    }
    func testExclusiveArchiveLockRejectsSecondInstanceAndReleasesOnClose() throws {
        let (base,_,_,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let url = base.appendingPathComponent("archive.lock")
        var first: ExclusiveArchiveLock? = try ExclusiveArchiveLock(url:url)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try ExclusiveArchiveLock(url:url))
        first = nil
        XCTAssertNoThrow(try ExclusiveArchiveLock(url:url))
    }
    func testVerifiedBackupIncludesCommittedQueueAndCorruptionFailsClosed() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let journal = try ChangeJournal(path:db.path)
        _ = try journal.enqueue(rootID:"r",relativePath:"a.jpg",kind:.upsert)
        let backup = base.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:backup)
        // The backup must be a portable single file BEFORE any writer
        // reopens it and possibly changes its journal mode again.
        try ArchiveDatabaseSafety.verify(backup,readOnly:true)
        let header = try Data(contentsOf:backup).prefix(100)
        XCTAssertEqual(Array(header.dropFirst(18).prefix(2)),[UInt8(1),UInt8(1)])
        for suffix in ["-wal","-shm","-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:backup.path+suffix))
        }
        let isolated = base.appendingPathComponent("isolated",isDirectory:true)
        try FileManager.default.createDirectory(at:isolated,withIntermediateDirectories:false)
        let copy = isolated.appendingPathComponent("portable.sqlite")
        try FileManager.default.copyItem(at:backup,to:copy)
        try ArchiveDatabaseSafety.verify(copy,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:copy.path).pending(),try journal.pending())
        XCTAssertThrowsError(try ArchiveDatabaseSafety.backup(db,to:backup))
        let bad = base.appendingPathComponent("bad.sqlite")
        try Data("not a sqlite database".utf8).write(to:bad)
        XCTAssertThrowsError(try ArchiveDatabaseSafety.verify(bad))
    }
    func testBackupOfClosedWALDatabaseRetainsCommittedQueue() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let id: Int64
        do {
            let journal = try ChangeJournal(path:db.path)
            id = try journal.enqueue(rootID:"r",relativePath:"closed.jpg",kind:.upsert)
        }
        try ArchiveDatabaseSafety.verify(db)
        let backup = base.appendingPathComponent("closed-backup.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:backup)
        try ArchiveDatabaseSafety.verify(backup,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:backup.path).pending().map(\.id),[id])
    }
    func testRepeatedBackupsAreIndependentAndLeaveNoStagingFiles() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let journal = try ChangeJournal(path:db.path)
        let firstJob = try journal.enqueue(rootID:"r",relativePath:"one.jpg",kind:.upsert)
        let first = base.appendingPathComponent("first.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:first)
        let original = try Data(contentsOf:first)
        let secondJob = try journal.enqueue(rootID:"r",relativePath:"two.jpg",kind:.upsert)
        let second = base.appendingPathComponent("second.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:second)
        XCTAssertEqual(try Data(contentsOf:first),original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:base.path)
            .filter { $0.hasPrefix(".backup-") }.isEmpty)
        try ArchiveDatabaseSafety.verify(first,readOnly:true)
        try ArchiveDatabaseSafety.verify(second,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:first.path).pending().map(\.id),[firstJob])
        XCTAssertEqual(try ChangeJournal(path:second.path).pending().map(\.id),[firstJob,secondJob])
    }
    func testBackupRefusesExistingTargetSidecarWithoutRemovingIt() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let journal = try ChangeJournal(path:db.path)
        _ = try journal.enqueue(rootID:"r",relativePath:"a.jpg",kind:.upsert)
        let target = base.appendingPathComponent("conflict.sqlite")
        let sidecar = URL(fileURLWithPath:target.path+"-journal")
        let other = Data("unrelated data".utf8)
        try other.write(to:sidecar)
        XCTAssertThrowsError(try ArchiveDatabaseSafety.backup(db,to:target))
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
        XCTAssertEqual(try Data(contentsOf:sidecar),other)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:base.path)
            .filter { $0.hasPrefix(".backup-") }.isEmpty)
    }
    func testVacuumBackupRetainsIdentityCompletedJobsAndAutoincrementSequence() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let journal = try ChangeJournal(path:db.path)
        let identity = try journal.databaseIdentity()
        let completed = try journal.enqueue(rootID:"r",relativePath:"completed.jpg",kind:.upsert)
        try journal.markCompleted(id:completed)
        let pending = try journal.enqueue(rootID:"r",relativePath:"pending.jpg",kind:.upsert)
        let removed = try journal.enqueue(rootID:"r",relativePath:"purged.jpg",kind:.upsert)
        // Simulate a future legitimate purge leaving sqlite_sequence ahead
        // of MAX(id). Reusing removed IDs after restore would be unsafe.
        do {
            var handle: OpaquePointer?
            let rc = sqlite3_open_v2(db.path,&handle,SQLITE_OPEN_READWRITE,nil)
            guard rc == SQLITE_OK, let handle else {
                if let handle { sqlite3_close(handle) }
                XCTFail("Cannot open test database: \(rc)"); return
            }
            defer { sqlite3_close(handle) }
            sqlite3_busy_timeout(handle,5000)
            XCTAssertEqual(sqlite3_exec(handle,"DELETE FROM change_queue WHERE id=\(removed);",nil,nil,nil),SQLITE_OK)
        }
        let target = base.appendingPathComponent("backup dell'archivio.sqlite")
        try ArchiveDatabaseSafety.backup(db,to:target)
        try ArchiveDatabaseSafety.verify(target,readOnly:true)
        let restored = try ChangeJournal(path:target.path)
        XCTAssertEqual(try restored.databaseIdentity(),identity)
        XCTAssertEqual(try restored.pending(),try journal.pending())
        XCTAssertEqual(try restored.pending().map(\.id),[pending])
        let newID = try restored.enqueue(rootID:"r",relativePath:"restored.jpg",kind:.upsert)
        XCTAssertGreaterThan(newID,removed)
        XCTAssertEqual(try journal.pending().map(\.id),[pending])
        // Explicit completed rows and the source WAL mode are preserved.
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(target.path,&handle,SQLITE_OPEN_READONLY,nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            XCTFail("Cannot inspect restored database: \(rc)"); return
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,"SELECT completed FROM change_queue WHERE id=\(completed);",-1,&statement,nil),SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement,0),1)
        let header = try Data(contentsOf:db).prefix(100)
        XCTAssertEqual(Array(header.dropFirst(18).prefix(2)),[UInt8(2),UInt8(2)])
    }
    func testAnchoredDirectoryRefusesReplacementBeforeRemoval() throws {
        let (base,_,target,_) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let file = target.appendingPathComponent("a.jpg")
        try Data("old".utf8).write(to:file)
        let anchor = try AnchoredDirectory(target,expectedVolume:VolumeFingerprint.read(at:target))
        let original = try anchor.leaf("a.jpg")
        try FileManager.default.moveItem(at:target,to:base.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false)
        try Data("new".utf8).write(to:file)
        XCTAssertThrowsError(try anchor.remove("a.jpg",matching:original))
        XCTAssertEqual(try Data(contentsOf:file),Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:base.appendingPathComponent("old/a.jpg").path))
    }
}
