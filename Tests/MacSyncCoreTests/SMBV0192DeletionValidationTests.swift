import Foundation
import XCTest
@testable import MacSyncCore

final class SMBV0192DeletionValidationTests:XCTestCase {
    func testV0193HiddenLiteralJobsAndColonDiagnosticRemainNonDestructive() throws {
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
        let rawPath=try String(contentsOf:fixture.appendingPathComponent("share-path"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard rawPath.hasPrefix("/private/tmp/macsync-ci-share.") else { XCTFail("Unexpected disposable root");return }
        let raw=URL(fileURLWithPath:rawPath).appendingPathComponent("macsync-ci-colon")
        let target=mount.appendingPathComponent("macsync-ci-colon")
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        let corrected=source.appendingPathComponent("SFM-old")
        try fm.createDirectory(at:corrected,withIntermediateDirectories:true)
        let dst=target.appendingPathComponent("SFM-old/child.jpg")
        let src=corrected.appendingPathComponent("child.jpg")
        try Data(contentsOf:dst).write(to:src)
        try fm.setAttributes([.modificationDate:try XCTUnwrap(fm.attributesOfItem(atPath:dst.path)[.modificationDate] as? Date)],ofItemAtPath:src.path)
        let db=base.appendingPathComponent("queue.sqlite")
        _ = try LocalInventory(path:db.path).reconcile(rootID:"photos",root:source,origin:.initialInventory)
        let journal=try ChangeJournal(path:db.path)
        let map=try MountedFolderMapping(rootID:"photos",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        for name in ["Raw:old","SFM:old","SFM:old/child.jpg","unseen."] {
            _ = try journal.enqueue(rootID:"photos",relativePath:name,kind:.delete,origin:.sourceMonitor)
        }
        let session=try SeededArchiveSession(database:db,mappings:[map])
        let report=try session.auditPreservingQueuedChanges(mode:.quick,repair:true,reconcileOrdinaryJobs:true)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertEqual(report.recognizedAbsentDeletes,0)
        XCTAssertTrue(Set(try journal.pending().map(\.relativePath)).isSuperset(of:["Raw:old","SFM:old","SFM:old/child.jpg","unseen."]))
        let names=try fm.contentsOfDirectory(atPath:target.path)
        for name in names where name != "SFM-old" {
            print("Synthetic SMB name UTF-8: "+name.utf8.map{String(format:"%02X",$0)}.joined(separator:" "))
            if let url=try? map.verificationURL(relativePath:name,destination:true) {
                print("Exact read-only path verified: "+String(url.lastPathComponent.utf8.elementsEqual(name.utf8)))
            }
        }
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("Raw:old/child.jpg")),Data("raw colon bytes".utf8))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("SFM\u{F022}old/child.jpg")),Data("sfm colon bytes".utf8))
        XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("SFM-old/child.jpg")),Data("corrected bytes".utf8))
    }

    func testExactVisibleExtraDeletionAndHiddenOrEquivalentNameProtection() throws {
        let env=ProcessInfo.processInfo.environment
        guard env["MACSYNC_V0192_REQUIRE_SMB"]=="1" else { throw XCTSkip("Disposable SMB fixture opt-in") }
        XCTAssertEqual(env["MACSYNC_TEST_SMB_HOST"],"127.0.0.1")
        XCTAssertEqual(env["MACSYNC_TEST_SMB_SHARE"],"MacSyncCI")
        guard env["MACSYNC_TEST_SMB_HOST"]=="127.0.0.1",env["MACSYNC_TEST_SMB_SHARE"]=="MacSyncCI" else { return }
        let mount=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
        let binding=try DirectoryBinding.read(mount)
        guard binding.volume.fileSystem.lowercased()=="smbfs",binding.volume.isStrongIdentity else {
            XCTFail("Genuine SMB mount with strong identity required");return
        }
        let fixture=URL(fileURLWithPath:try XCTUnwrap(env["MACSYNC_TEST_SMB_ROOT"]))
        let serverPath=try String(contentsOf:fixture.appendingPathComponent("share-path"),encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard serverPath.hasPrefix("/private/tmp/macsync-ci-share.") else { XCTFail("Unexpected disposable root");return }
        let server=URL(fileURLWithPath:serverPath)
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }

        for label in ["macsync-ci-sfm","macsync-ci-raw","macsync-ci-alias"] {
            let source=base.appendingPathComponent(label)
            let target=mount.appendingPathComponent(label)
            let raw=server.appendingPathComponent(label)
            try fm.createDirectory(at:source.appendingPathComponent("compatible-control"),withIntermediateDirectories:true)
            if label=="macsync-ci-sfm" {
                try fm.createDirectory(at:source.appendingPathComponent("Foto12345-"),withIntermediateDirectories:true)
            }
            if label=="macsync-ci-alias" {
                let current=target.appendingPathComponent("keep")
                let local=source.appendingPathComponent("keep")
                try Data(contentsOf:current).write(to:local)
                let modified=try XCTUnwrap(fm.attributesOfItem(atPath:current.path)[.modificationDate] as? Date)
                try fm.setAttributes([.modificationDate:modified],ofItemAtPath:local.path)
            }
            let names=try fm.contentsOfDirectory(atPath:target.path)
            XCTAssertTrue(names.contains("compatible-control"))
            let oldName=label=="macsync-ci-alias" ? "keep " : "Foto12345."
            let visible=names.contains{$0.utf8.elementsEqual(oldName.utf8)}
            let serverLeaf=label=="macsync-ci-sfm" ? "Foto12345\u{F029}" :
                (label=="macsync-ci-alias" ? "keep\u{F028}" : oldName)
            let original=raw.appendingPathComponent(serverLeaf)
            XCTAssertTrue(fm.fileExists(atPath:original.path))
            let db=base.appendingPathComponent(label+".sqlite").path
            _ = try LocalInventory(path:db).reconcile(rootID:"photos",root:source,origin:.initialInventory)
            let journal=try ChangeJournal(path:db)
            let mapping=try MountedFolderMapping(rootID:"photos",source:source,target:target)
            try journal.verifyDirectoryBindings([mapping],allowNewTarget:true)
            let report=try ArchiveAudit(journal:journal,mappings:[mapping]).run(mode:.quick,repair:true,queueMirrorExtras:true)
            let candidates=try XCTUnwrap(report.deletionCandidates)
            XCTAssertTrue(fm.fileExists(atPath:original.path),"Audit must not mutate destination")
            let consent=try MirrorAuthorization.capture(journal:journal,mappings:[mapping],includePendingDeletes:true)
            let worker=try MirrorDeletionWorker(journal:journal,manifest:RecoveryManifest(path:db),
                log:SyncActivityLog(path:db),mappings:[mapping],
                policy:MirrorDeletionPolicy(enabled:true,recoveryEnabled:false,retentionDays:nil),
                authorization:consent)
            let result=try worker.runCycle()
            if label=="macsync-ci-alias" || !visible {
                XCTAssertEqual(result.removed,0)
                XCTAssertEqual(result.directories,0)
                XCTAssertTrue(fm.fileExists(atPath:original.path))
                if label=="macsync-ci-alias" {
                    XCTAssertEqual(try Data(contentsOf:raw.appendingPathComponent("keep")),Data("current bytes".utf8))
                    XCTAssertEqual(try Data(contentsOf:original),Data("ambiguous old bytes".utf8))
                } else {
                    XCTAssertEqual(try Data(contentsOf:original.appendingPathComponent("child.jpg")),Data("old raw bytes".utf8))
                    XCTAssertFalse(candidates.contains("photos\0"+oldName))
                }
                print("Preserved incompatible extra: "+label)
            } else {
                XCTAssertTrue(candidates.contains("photos\0"+oldName))
                XCTAssertEqual(result.removed,1)
                XCTAssertEqual(result.directories,1)
                XCTAssertFalse(fm.fileExists(atPath:original.path))
                print("Verified exact server-side deletion: "+label)
            }
            if label=="macsync-ci-sfm" {
                XCTAssertTrue(visible,"SFM fixture must be enumerable, not silently skipped")
                XCTAssertTrue(fm.fileExists(atPath:raw.appendingPathComponent("Foto12345-").path))
            }
            XCTAssertTrue(fm.fileExists(atPath:raw.appendingPathComponent("compatible-control").path))
        }
    }
}
