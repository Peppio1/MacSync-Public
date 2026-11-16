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
    /// Independent test-only experiment: VACUUM INTO creates a compact
    /// standalone copy without manually changing the destination's mode.
    /// It is NOT used by production until separately verified.
    func testDiagnosticVacuumIntoWithOpenWALSource() throws {
        let (base,_,_,db) = try fixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let journal = try ChangeJournal(path:db.path)
        let id = try journal.enqueue(rootID:"probe",relativePath:"sample.jpg",kind:.upsert)
        let target = base.appendingPathComponent("vacuum-probe.sqlite")
        var handle: OpaquePointer?
        let openRC = sqlite3_open_v2(db.path,&handle,SQLITE_OPEN_READWRITE,nil)
        guard openRC == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            XCTFail("SQLITE_DIAG vacuum open rc=\(openRC)"); return
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle,5000)
        let literal = target.path.replacingOccurrences(of:"'",with:"''")
        let rc = sqlite3_exec(handle,"VACUUM INTO '\(literal)';",nil,nil,nil)
        print("SQLITE_DIAG vacuum-into rc=\(rc) message=\(String(cString:sqlite3_errmsg(handle)))")
        XCTAssertEqual(rc,SQLITE_OK)
        guard rc == SQLITE_OK else { return }
        let header = try Data(contentsOf:target).prefix(100)
        let modeBytes = Array(header.dropFirst(18).prefix(2))
        print("SQLITE_DIAG vacuum-header=\(modeBytes)")
        XCTAssertEqual(modeBytes,[UInt8(1),UInt8(1)])
        for suffix in ["-wal","-shm","-journal"] {
            let exists = FileManager.default.fileExists(atPath:target.path+suffix)
            print("SQLITE_DIAG vacuum-sidecar=\(suffix) exists=\(exists)")
            XCTAssertFalse(exists)
        }
        try ArchiveDatabaseSafety.verify(target,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:target.path).pending().map(\.id),[id])
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
