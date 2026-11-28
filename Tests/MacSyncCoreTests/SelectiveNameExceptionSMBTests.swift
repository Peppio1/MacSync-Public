import Foundation
import SQLite3
import XCTest
@testable import MacSyncCore

final class SelectiveNameExceptionSMBTests:XCTestCase {
    private func scalar(_ path:String,_ sql:String)throws->Int64 {
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        let db=try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        var q:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db,sql,-1,&q,nil),SQLITE_OK)
        let statement=try XCTUnwrap(q)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement),SQLITE_ROW)
        return sqlite3_column_int64(statement,0)
    }
    func testRestoredCompatibleNameReleasesOnlyValidPathAndPreservesLiteralQuarantine()throws {
        let env=ProcessInfo.processInfo.environment
        guard env["MACSYNC_V0192_REQUIRE_SMB"]=="1" else { throw XCTSkip("Disposable SMB fixture opt-in") }
        guard env["MACSYNC_TEST_SMB_HOST"]=="127.0.0.1",env["MACSYNC_TEST_SMB_SHARE"]=="MacSyncCI" else {
            XCTFail("Unexpected SMB fixture");return
        }
        let mount=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
        let binding=try DirectoryBinding.read(mount)
        guard binding.volume.fileSystem.lowercased()=="smbfs",binding.volume.isStrongIdentity else {
            XCTFail("Genuine SMB mount required");return
        }
        let fixture=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_ROOT"]))
        let rawPath=try String(contentsOf:fixture.appendingPathComponent("share-path"),encoding:.utf8)
            .trimmingCharacters(in:.whitespacesAndNewlines)
        guard rawPath.hasPrefix("/private/tmp/macsync-ci-share.") else { XCTFail("Unexpected disposable root");return }
        let helper=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_RCLONE"]))
        let fm=FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath:helper.path))
        let name="macsync-ci-selective-"+UUID().uuidString
        let target=mount.appendingPathComponent(name),raw=URL(fileURLWithPath:rawPath).appendingPathComponent(name)
        let base=fm.temporaryDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source=base.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:false)
        let path=base.appendingPathComponent("state.sqlite").path
        let inventory=try LocalInventory(path:path),journal=try ChangeJournal(path:path),log=try SyncActivityLog(path:path)
        inventory.experimentalSourceNameLineage=false
        inventory.experimentalLineageQueueProtection=false
        inventory.experimentalSelectiveNameExceptions=true
        journal.experimentalSourceNameLineage=false
        _=try inventory.reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        let folder=source.appendingPathComponent("phone"),bad=source.appendingPathComponent("phone.")
        try fm.createDirectory(at:folder,withIntermediateDirectories:false)
        let bytes=Data((0..<32768).map{UInt8($0%251)})
        try bytes.write(to:folder.appendingPathComponent("child.jpg"))
        try Data("keep".utf8).write(to:source.appendingPathComponent("keep.jpg"))
        let oldDate=Date(timeIntervalSinceNow:-1000)
        for file in [folder.appendingPathComponent("child.jpg"),source.appendingPathComponent("keep.jpg")] {
            try fm.setAttributes([.modificationDate:oldDate],ofItemAtPath:file.path)
        }
        _=try inventory.reconcile(rootID:"photos",root:source,eventID:1)
        let worker=try MountedFolderCopyWorker(journal:journal,log:log,mappings:[map],minimumStableAge:0,stageEngine:.rcloneDirect(helper))
        let first=try worker.runCycle(enabled:true)
        XCTAssertEqual(first.copied,3)
        XCTAssertEqual(first.failed,0)
        XCTAssertTrue(try journal.pending().isEmpty)
        let initial=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        XCTAssertEqual(initial.bytesRead,0)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_clean_baseline;"),1)
        let consent=try MirrorAuthorization.capture(journal:journal,mappings:[map])
        let mirror=try MirrorDeletionWorker(journal:journal,manifest:RecoveryManifest(path:path),log:log,mappings:[map],
            policy:MirrorDeletionPolicy(enabled:true,recoveryEnabled:false,retentionDays:nil),
            authorization:consent,transferEngine:.rcloneDirect(helper))
        try fm.moveItem(at:folder,to:bad)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:folder,eventID:2)
        for job in try journal.pending() where job.kind == .delete {
            XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath))
        }
        let held=try mirror.runCycle(pageSize:1)
        XCTAssertEqual(held.removed,0)
        XCTAssertEqual(held.directories,0)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("phone/child.jpg")),bytes)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:3)
        try fm.moveItem(at:bad,to:folder)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:bad,eventID:4)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:folder,eventID:5)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_retired_invalid;"),1)
        XCTAssertFalse(try journal.pending().contains{$0.relativePath.hasPrefix("phone.")})
        let restored=try worker.runCycle(enabled:true)
        XCTAssertEqual(restored.copied,0)
        XCTAssertEqual(restored.reconciled,2)
        XCTAssertEqual(restored.bytes,0)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM sync_activity WHERE action='selective_restore_avoided';"),2)
        XCTAssertTrue(try journal.pending().isEmpty)
        let report=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.intelligent,repair:true)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_name_exception;"),0)
        XCTAssertEqual(try scalar(path,"SELECT COUNT(*) FROM selective_smb_quarantine WHERE path='phone.';"),1)
        // Reopening retains literal-only veto, not a compatible path veto.
        var handle:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path,&handle,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        let db=try XCTUnwrap(handle)
        defer { sqlite3_close(db) }
        XCTAssertTrue(try SelectiveNameExceptionStore.protects(db,root:"photos",path:"phone./child.jpg"))
        XCTAssertFalse(try SelectiveNameExceptionStore.protects(db,root:"photos",path:"phone/child.jpg"))
        // Actual later deletion requires all ordinary mirror gates.
        try fm.removeItem(at:folder)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:folder,eventID:6)
        let result=try mirror.runCycle(pageSize:1)
        XCTAssertFalse(result.blocked,result.detail)
        XCTAssertEqual(result.removed,1)
        XCTAssertEqual(result.directories,1)
        XCTAssertFalse(fm.fileExists(atPath:raw.appendingPathComponent("phone").path))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("keep.jpg")),Data("keep".utf8))
        XCTAssertTrue(try journal.pending().isEmpty)
        print("SELECTIVE_REAL_SMB restored=2 zero_copy=2 literal_quarantine=1 later_removed_files=1 later_removed_dirs=1")

        // A second independent excursion chooses a genuinely different
        // compatible name. Old remote data survives until copies and audit.
        let secondFolder=source.appendingPathComponent("second"),secondBad=source.appendingPathComponent("second."),
            corrected=source.appendingPathComponent("different")
        try fm.createDirectory(at:secondFolder,withIntermediateDirectories:false)
        try bytes.write(to:secondFolder.appendingPathComponent("child.jpg"))
        try fm.setAttributes([.modificationDate:oldDate],ofItemAtPath:secondFolder.appendingPathComponent("child.jpg").path)
        _=try inventory.reconcile(rootID:"photos",root:source,eventID:7)
        XCTAssertEqual(try worker.runCycle(enabled:true).copied,2)
        _=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        try fm.moveItem(at:secondFolder,to:secondBad)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:secondFolder,eventID:8)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:secondBad,eventID:9)
        try fm.moveItem(at:secondBad,to:corrected)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:secondBad,eventID:10)
        _=try inventory.reconcile(rootID:"photos",root:source,subtree:corrected,eventID:11)
        let secondDeletes=try journal.pending().filter{$0.kind == .delete}
        XCTAssertEqual(secondDeletes.count,2)
        for job in secondDeletes { XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        XCTAssertEqual(try worker.runCycle(enabled:true).copied,2)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("second/child.jpg")),bytes)
        for job in secondDeletes { XCTAssertFalse(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        let movedAudit=try ArchiveAudit(journal:journal,mappings:[map]).run(mode:.quick,repair:true)
        XCTAssertEqual(movedAudit.bytesRead,0)
        for job in secondDeletes { XCTAssertTrue(try journal.deletionIsCurrent(id:job.id,rootID:job.rootID,relativePath:job.relativePath)) }
        let movedMirror=try mirror.runCycle(pageSize:1)
        XCTAssertFalse(movedMirror.blocked,movedMirror.detail)
        XCTAssertEqual(movedMirror.removed,1)
        XCTAssertEqual(movedMirror.directories,1)
        XCTAssertFalse(fm.fileExists(atPath:raw.appendingPathComponent("second").path))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("different/child.jpg")),bytes)
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("keep.jpg")),Data("keep".utf8))
        XCTAssertTrue(try journal.pending().isEmpty)
        print("SELECTIVE_REAL_SMB_MOVED copies=2 old_removed=2 corrected_preserved=true")
    }
}
