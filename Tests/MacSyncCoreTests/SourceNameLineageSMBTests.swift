import Foundation
import XCTest
@testable import MacSyncCore

/// Real mounted SMB and the same pinned Rclone direct worker as the app.
/// All mutations are confined to a freshly created disposable CI directory.
final class SourceNameLineageSMBTests: XCTestCase {
    func testRcloneSMBRenamePreservesOldCopyUntilCorrectedPublication() throws {
        let env=ProcessInfo.processInfo.environment
        guard env["MACSYNC_V0192_REQUIRE_SMB"]=="1" else { throw XCTSkip("Disposable SMB fixture opt-in") }
        guard env["MACSYNC_TEST_SMB_HOST"]=="127.0.0.1",env["MACSYNC_TEST_SMB_SHARE"]=="MacSyncCI" else {
            XCTFail("Unexpected SMB fixture"); return
        }
        let mount=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
        let binding=try DirectoryBinding.read(mount)
        guard binding.volume.fileSystem.lowercased()=="smbfs",binding.volume.isStrongIdentity else {
            XCTFail("Genuine SMB mount required"); return
        }
        let fixture=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_ROOT"]))
        let rawPath=try String(contentsOf:fixture.appendingPathComponent("share-path"),encoding:.utf8)
            .trimmingCharacters(in:.whitespacesAndNewlines)
        guard rawPath.hasPrefix("/private/tmp/macsync-ci-share.") else { XCTFail("Unexpected disposable root"); return }
        let helper=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_RCLONE"]))
        let fm=FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath:helper.path))
        let name="macsync-ci-lineage-"+UUID().uuidString
        let target=mount.appendingPathComponent(name)
        let raw=URL(fileURLWithPath:rawPath).appendingPathComponent(name)
        let base=fm.temporaryDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:false)
        // The workflow owns the SMB share and cleans it up after the test.
        let db=base.appendingPathComponent("state.sqlite").path
        let inventory=try LocalInventory(path:db),journal=try ChangeJournal(path:db)
        let log=try SyncActivityLog(path:db)
        _=try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        inventory.experimentalSourceNameLineage=true
        inventory.experimentalLineageQueueProtection=true
        journal.experimentalSourceNameLineage=true
        let original=source.appendingPathComponent("folder")
        try fm.createDirectory(at:original,withIntermediateDirectories:false)
        let bytes=Data((0..<32768).map{UInt8($0%251)})
        try bytes.write(to:original.appendingPathComponent("child.jpg"))
        try Data("keep".utf8).write(to:source.appendingPathComponent("keep.jpg"))
        let oldDate=Date(timeIntervalSinceNow:-1000)
        for file in [original.appendingPathComponent("child.jpg"),source.appendingPathComponent("keep.jpg")] {
            try fm.setAttributes([.modificationDate:oldDate],ofItemAtPath:file.path)
        }
        _=try inventory.reconcile(rootID:"photos",root:source,eventID:1)
        let worker=try MountedFolderCopyWorker(journal:journal,log:log,mappings:[map],
            minimumStableAge:0,stageEngine:.rcloneDirect(helper))
        let first=try worker.runCycle(enabled:true)
        XCTAssertEqual(first.copied,3)
        XCTAssertEqual(first.failed,0)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("folder/child.jpg")),bytes)
        // Independently created target object must never be treated as ours.
        try Data("independent".utf8).write(to:raw.appendingPathComponent("independent.jpg"))
        let consent=try MirrorAuthorization.capture(journal:journal,mappings:[map])
        let mirror=try MirrorDeletionWorker(journal:journal,manifest:RecoveryManifest(path:db),
            log:log,mappings:[map],policy:MirrorDeletionPolicy(enabled:true,recoveryEnabled:false,retentionDays:nil),
            authorization:consent,transferEngine:.rcloneDirect(helper))
        let bad=source.appendingPathComponent("folder.")
        try fm.moveItem(at:original,to:bad)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:original,eventID:2)
        let old=try journal.pending().filter{$0.kind == .delete}
        XCTAssertEqual(old.count,2)
        for job in old { XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        let premature=try mirror.runCycle(pageSize:1)
        XCTAssertEqual(premature.removed,0)
        XCTAssertEqual(premature.directories,0)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("folder/child.jpg")),bytes)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:3)
        let corrected=source.appendingPathComponent("corrected")
        try fm.moveItem(at:bad,to:corrected)
        let update=try inventory.reconcile(rootID:"photos",root:source,eventID:4)
        XCTAssertEqual(update.queuedDeletes,0)
        XCTAssertFalse(try journal.pending().contains{$0.relativePath=="folder." || $0.relativePath.hasPrefix("folder./")})
        for job in old { XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        let second=try worker.runCycle(enabled:true)
        XCTAssertEqual(second.copied,2)
        XCTAssertEqual(second.failed,0)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("corrected/child.jpg")),bytes)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("folder/child.jpg")),bytes)
        for job in old { XCTAssertTrue(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        let completed=try mirror.runCycle(pageSize:1)
        XCTAssertFalse(completed.blocked,completed.detail)
        XCTAssertEqual(completed.removed,1)
        XCTAssertEqual(completed.directories,1)
        XCTAssertFalse(fm.fileExists(atPath:raw.appendingPathComponent("folder").path))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("corrected/child.jpg")),bytes)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("keep.jpg")),Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("independent.jpg")),Data("independent".utf8))
        XCTAssertTrue(try journal.pending().isEmpty)
        print("LINEAGE_REAL_SMB initial_copies=3 protected_deletes=2 corrected_copies=2 removed_files=1 removed_dirs=1 independent_preserved=true")
    }
}
