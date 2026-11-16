import Foundation
import XCTest
import Darwin
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
        XCTAssertEqual(try ChangeJournal(path:backup.path).pending(),try journal.pending())
        XCTAssertThrowsError(try ArchiveDatabaseSafety.backup(db,to:backup))
        let bad = base.appendingPathComponent("bad.sqlite")
        try Data("not a sqlite database".utf8).write(to:bad)
        XCTAssertThrowsError(try ArchiveDatabaseSafety.verify(bad))
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
