import Foundation
import XCTest
@testable import MacSyncCore

final class SeededArchiveVerifierTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        let db: URL
        let journal: ChangeJournal
        let mapping: MountedFolderMapping
    }

    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-seed-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let db = base.appendingPathComponent("inventory.sqlite")
        let journal = try ChangeJournal(path: db.path)
        return Fixture(
            base: base, source: source, target: target, db: db,
            journal: journal,
            mapping: try MountedFolderMapping(
                rootID: "photos", source: source, target: target
            )
        )
    }

    private func initializeInventory(_ f: Fixture) throws {
        let inventory = try LocalInventory(path: f.db.path)
        try inventory.reconcile(rootID: "photos", root: f.source)
    }

    private func write(_ text: String, to url: URL, date: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        if let date {
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: url.path
            )
        }
    }

    func testPristineInventoryIsBaselineOnlyAndReplaysSubsequentLocalChanges() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let fixed=Date(timeIntervalSince1970:1_700_000_000)
        for i in 0..<800 {
            try write("original",to:f.source.appendingPathComponent("group-\(i / 40)/item-\(i).jpg"),date:fixed)
        }
        let inventory=try LocalInventory(path:f.db.path)
        let first=try inventory.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertEqual(first.inspected,820)
        XCTAssertEqual(first.queuedUpserts,0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertEqual(try inventory.itemCount(rootID:"photos"),820)

        // Unchanged restart makes no uploads, and editing during downtime
        // is detected without any destination read.
        let unchanged=try inventory.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertEqual(unchanged.queuedUpserts,0)
        let changed=f.source.appendingPathComponent("group-0/item-0.jpg")
        try write("changed after MacSync was closed",to:changed,date:fixed.addingTimeInterval(80))
        let resumed=try inventory.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertEqual(resumed.queuedUpserts,1)
        let job=try XCTUnwrap(f.journal.pending().first)
        XCTAssertEqual(job.relativePath,"group-0/item-0.jpg")
        XCTAssertEqual(try f.journal.originOfJob(id:job.id),.sourceMonitor)
    }

    func testLocalChangeDuringFirstInventoryIsReplayedAsMonitorEvent() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let original=Date(timeIntervalSince1970:1_700_000_000)
        let source=f.source.appendingPathComponent("changed-during-start.jpg")
        try write("before scan",to:source,date:original)
        let store=try LocalInventory(path:f.db.path)
        var changed=false
        let initial=try store.reconcile(rootID:"photos",root:f.source,origin:.initialInventory,
            onItem:{ item in
                guard item.relativePath == "changed-during-start.jpg" && !changed else { return }
                changed=true
                do {
                    try self.write("after scan metadata",to:source,date:original.addingTimeInterval(90))
                } catch { XCTFail("Synthetic change during inventory: \(error)") }
            })
        XCTAssertTrue(changed)
        XCTAssertEqual(initial.queuedUpserts,0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        // Startup watches from a checkpoint acquired BEFORE the scan; its
        // replay is represented by this eventID-bound local reconcile.
        let replay=try store.reconcile(rootID:"photos",root:f.source,
                                       subtree:source,eventID:777)
        XCTAssertEqual(replay.queuedUpserts,1)
        let job=try XCTUnwrap(f.journal.pending().first)
        XCTAssertEqual(job.relativePath,"changed-during-start.jpg")
        XCTAssertEqual(try f.journal.originOfJob(id:job.id),.sourceMonitor)
    }

    func testPristineInventoryFollowedByQuickQueuesOnlyRealDifferences() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let fixed=Date(timeIntervalSince1970:1_700_000_000)
        for i in 0..<100 {
            let name="set/file-\(i).dng"
            try write("identical",to:f.source.appendingPathComponent(name),date:fixed)
            if i < 97 {
                try write(i == 96 ? "different size and content" : "identical",
                          to:f.target.appendingPathComponent(name),date:fixed)
            }
        }
        _ = try LocalInventory(path:f.db.path).reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        let report=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
            .auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(report.count(.matching),97) // 96 files + matching parent directory
        XCTAssertEqual(report.count(.different),1)
        XCTAssertEqual(report.count(.missing),3)
        XCTAssertEqual(report.queuedRepairs,4)
        XCTAssertEqual(report.bytesRead,0)
        let jobs=try f.journal.pending()
        XCTAssertEqual(jobs.count,4)
        for job in jobs {
            XCTAssertEqual(try f.journal.originOfJob(id:job.id),.archiveAudit)
        }
    }

    func testFirstInventoryMatchingJobsAreAcknowledgedWithoutAnotherRemoteRead() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("same",to:f.source.appendingPathComponent("roll/same.jpg"),date:date)
        try write("same",to:f.target.appendingPathComponent("roll/same.jpg"),date:date)
        try write("needs copy",to:f.source.appendingPathComponent("missing.jpg"),date:date)
        let store = try LocalInventory(path:f.db.path)
        _ = try store.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        // The first local inventory is only a baseline, not 3 uploads.
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertEqual(try store.itemCount(rootID:"photos"),3)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let report=try session.auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertEqual(report.recognizedFiles,0)
        XCTAssertEqual(report.recognizedDirectories,0)
        XCTAssertEqual(report.queuedRepairs,1)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["missing.jpg"])
        let second=try session.auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(second.recognizedFiles,0)
        XCTAssertEqual(second.recognizedDirectories,0)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["missing.jpg"])
    }

    func testFirstInventoryEventReplacesInitialJobAndCanNeverBeClearedBySnapshot() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source=f.source.appendingPathComponent("photo.psd")
        try write("same",to:source,date:date)
        try write("same",to:f.target.appendingPathComponent("photo.psd"),date:date)
        let store=try LocalInventory(path:f.db.path)
        _ = try store.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        var changed=false
        let report=try session.auditPreservingQueuedChanges(mode:.quick,repair:true,progress:{ current in
            guard current.phase == "Confronto metadati", !changed else { return }
            changed=true
            do {
                try self.write("updated on Mac",to:source,date:date.addingTimeInterval(20))
                _ = try LocalInventory(path:f.db.path).reconcile(
                    rootID:"photos",root:f.source,subtree:source,eventID:12345
                )
            } catch { XCTFail("Source monitor update failed: \(error)") }
        })
        XCTAssertTrue(changed)
        XCTAssertEqual(report.count(.matching),1)
        XCTAssertEqual(report.recognizedFiles,0)
        let pending=try f.journal.pending()
        XCTAssertEqual(pending.count,1)
        XCTAssertEqual(pending[0].relativePath,"photo.psd")
        XCTAssertEqual(try f.journal.originOfJob(id:pending[0].id),.sourceMonitor)
    }

    func testIntelligentCanRecognizeInitialJobsOnlyAfterSelectiveHash() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("ABCD",to:f.source.appendingPathComponent("photo.dng"),date:date)
        try write("ABCD",to:f.target.appendingPathComponent("photo.dng"),date:date.addingTimeInterval(20))
        let store=try LocalInventory(path:f.db.path)
        _ = try store.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result=try session.auditPreservingQueuedChanges(mode:.intelligent,repair:true)
        XCTAssertEqual(result.count(.matching),1)
        XCTAssertEqual(result.bytesRead,8)
        XCTAssertEqual(result.recognizedFiles,0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }

    func testExistingRootNeverMislabelsRestartOrRecoveryEventsAsInitial() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source=f.source.appendingPathComponent("same.jpg")
        try write("first",to:source,date:date)
        let inventory=try LocalInventory(path:f.db.path)
        _ = try inventory.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        try write("later",to:source,date:date.addingTimeInterval(10))
        _ = try inventory.reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        let current=try XCTUnwrap(f.journal.pending().first)
        XCTAssertEqual(try f.journal.originOfJob(id:current.id),.sourceMonitor)
    }

    func testLegacyUnknownMatchingJobIsNeverAcknowledgedByQuickSnapshot() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSince1970:1_700_000_000)
        try write("same",to:f.source.appendingPathComponent("legacy.jpg"),date:date)
        try write("same",to:f.target.appendingPathComponent("legacy.jpg"),date:date)
        try initializeInventory(f)
        let id=try f.journal.enqueue(rootID:"photos",relativePath:"legacy.jpg",
                                      kind:.upsert,origin:.legacyUnknown)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let before=try f.journal.pending()
        let report=try session.auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(report.count(.matching),1)
        XCTAssertEqual(report.recognizedFiles,0)
        XCTAssertEqual(try f.journal.pending(),before)
        XCTAssertEqual(try f.journal.originOfJob(id:id),.legacyUnknown)
    }

    func testInterruptedInitialPublicationIsNeverAcknowledgedFromMatchingMetadata() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSince1970:1_700_000_000)
        try write("same",to:f.source.appendingPathComponent("pending.psd"),date:date)
        try write("same",to:f.target.appendingPathComponent("pending.psd"),date:date)
        _ = try LocalInventory(path:f.db.path).reconcile(rootID:"photos",root:f.source,origin:.initialInventory)
        // The v0.18.16 path may still have legacy initial jobs on upgrade.
        let id=try f.journal.enqueue(rootID:"photos",relativePath:"pending.psd",
                                     kind:.upsert,origin:.initialInventory)
        let job=try XCTUnwrap(f.journal.pending().first { $0.id == id })
        try f.journal.recordPublicationIntent(job)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let report=try session.auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(report.count(.matching),1)
        XCTAssertEqual(report.recognizedFiles,0)
        XCTAssertEqual(try f.journal.pending().map(\.id),[job.id])
    }

    func testOperationalQuickSnapshotLeavesMatchingFSEventsJobsPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("identical",to:f.source.appendingPathComponent("photo.dng"),date:date)
        try write("identical",to:f.target.appendingPathComponent("photo.dng"),date:date)
        try initializeInventory(f)
        let before = try f.journal.pending()
        XCTAssertEqual(before.filter { $0.relativePath == "photo.dng" && $0.kind == .upsert }.count,1)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let report = try session.auditPreservingQueuedChanges(mode:.quick,repair:true)
        XCTAssertEqual(report.count(.matching),1)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertEqual(report.queuedRepairs,0)
        XCTAssertEqual(try f.journal.pending(),before, "QUICK must not ACK or replace an FSEvents job")
    }

    func testOperationalQuickSnapshotPreservesEventRecordedDuringComparison() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let src = f.source.appendingPathComponent("photo.psd")
        try write("same",to:src,date:date)
        try write("same",to:f.target.appendingPathComponent("photo.psd"),date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        var eventInjected = false
        let report = try session.auditPreservingQueuedChanges(mode:.quick,repair:true,progress:{ progress in
            guard progress.phase == "Confronto metadati", !eventInjected else { return }
            eventInjected = true
            do {
                try self.write("new contents",to:src,date:date.addingTimeInterval(30))
                _ = try LocalInventory(path:f.db.path).reconcile(rootID:"photos",root:f.source,subtree:src)
            } catch { XCTFail("Synthetic FSEvents reconciliation failed: \(error)") }
        })
        XCTAssertTrue(eventInjected)
        XCTAssertEqual(report.count(.matching),1, "The audit reports its original snapshot, not a new server read")
        XCTAssertTrue(try f.journal.pending().contains {
            $0.relativePath == "photo.psd" && $0.kind == .upsert
        }, "A newer local change must remain pending despite the older matching snapshot")
    }

    func testOperationalIntelligentSnapshotRetainsJobsAfterSelectiveHashAndQueuesOnlyNewDifferences() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("ABCD",to:f.source.appendingPathComponent("same.dng"),date:date)
        try write("ABCD",to:f.target.appendingPathComponent("same.dng"),date:date.addingTimeInterval(15))
        try initializeInventory(f)
        let before = try f.journal.pending()
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let first = try session.auditPreservingQueuedChanges(mode:.intelligent,repair:true)
        XCTAssertEqual(first.count(.matching),1)
        XCTAssertEqual(first.bytesRead,8)
        XCTAssertEqual(try f.journal.pending(),before)
        // A source file not yet seen by the monitor is a genuine new audit repair.
        try write("missing",to:f.source.appendingPathComponent("new.jpg"),date:date)
        let second = try session.auditPreservingQueuedChanges(mode:.intelligent,repair:true)
        XCTAssertEqual(second.count(.missing),1)
        XCTAssertEqual(second.queuedRepairs,1)
        let pending = try f.journal.pending()
        XCTAssertTrue(pending.contains { $0.relativePath == "same.dng" && $0.kind == .upsert })
        XCTAssertEqual(pending.filter { $0.relativePath == "new.jpg" && $0.kind == .upsert }.count,1)
        let created=try XCTUnwrap(pending.first { $0.relativePath == "new.jpg" })
        XCTAssertEqual(try f.journal.originOfJob(id:created.id),.archiveAudit)
    }

    func testQuickAuditReusesNoFollowScanFingerprints() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow:-900)
        try write("same",to:f.source.appendingPathComponent("photos/a.jpg"),date:date)
        try write("same",to:f.target.appendingPathComponent("photos/a.jpg"),date:date)
        let source = try LocalScanner.scan(root:f.source,excludeManaged:true)
        let target = try LocalScanner.scan(root:f.target,excludeManaged:true,preferPOSIXMetadata:true)
        XCTAssertNotNil(source.first(where: { $0.relativePath == "photos/a.jpg" })?.verificationFingerprint)
        XCTAssertNotNil(target.first(where: { $0.relativePath == "photos/a.jpg" })?.verificationFingerprint)
        XCTAssertNotNil(source.first(where: { $0.relativePath == "photos" })?.verificationFingerprint)
        XCTAssertNotNil(target.first(where: { $0.relativePath == "photos" })?.verificationFingerprint)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.matches.count,2)
        XCTAssertEqual(result.audit.bytesRead,0)
        XCTAssertEqual(try session.approve(report:result.recognition),2)
    }

    func testBatchApprovalKeepsOneChangedFilePending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow:-900)
        for i in 0..<260 {
            try write("fixed",to:f.source.appendingPathComponent("photos/f\(i).jpg"),date:date)
            try write("fixed",to:f.target.appendingPathComponent("photos/f\(i).jpg"),date:date)
        }
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.matches.count,261)
        try write("changed",to:f.target.appendingPathComponent("photos/f129.jpg"))
        XCTAssertEqual(try session.approve(report:result.recognition),260)
        XCTAssertEqual(try f.journal.pending().filter { $0.kind == .upsert }.count,1)
    }

    func testBatchApprovalNeverFollowsReplacedParentSymlink() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow:-900)
        try write("same",to:f.source.appendingPathComponent("photos/photo.jpg"),date:date)
        try write("same",to:f.target.appendingPathComponent("photos/photo.jpg"),date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.matches.count,2)
        let old = f.base.appendingPathComponent("moved-photos")
        try FileManager.default.moveItem(at:f.target.appendingPathComponent("photos"),to:old)
        try FileManager.default.createSymbolicLink(
            at:f.target.appendingPathComponent("photos"),withDestinationURL:old)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().filter { $0.kind == .upsert }.count,2)
        XCTAssertEqual(try String(contentsOf:old.appendingPathComponent("photo.jpg"),encoding:.utf8),"same")
    }

    func testLargeArchiveRecognition200000Files() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_LARGE_AUDIT"] == "1" else { throw XCTSkip("Opt-in large local archive benchmark") }
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let count = 200_000
        let groups = 48_000
        let start = Date()
        let empty = Data()
        let fixed = Date(timeIntervalSince1970:1_700_000_000)
        for group in 0..<groups {
            let name = "group-\(group)"
            let a = f.source.appendingPathComponent(name), b = f.target.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
            for index in 0..<(count/groups+(group<count%groups ? 1:0)) {
                let leaf = "file-\(index).dat"
                let src = a.appendingPathComponent(leaf), dst = b.appendingPathComponent(leaf)
                try empty.write(to:src); try empty.write(to:dst)
                try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:src.path)
                try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:dst.path)
            }
        }
        print("200K fixture created in \(Date().timeIntervalSince(start)) s")
        try initializeInventory(f)
        let backup = f.base.appendingPathComponent("before.sqlite")
        try ArchiveDatabaseSafety.backup(f.db,to:backup)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let tick = Date()
        let result = try session.auditAndRecognize(mode:.quick,repair:true)
        XCTAssertEqual(result.audit.sourceMetrics?.files,count)
        XCTAssertEqual(result.audit.destinationMetrics?.files,count)
        XCTAssertEqual(result.audit.bytesRead,0)
        XCTAssertEqual(result.recognition.matches.count,count+groups)
        let scan = Date().timeIntervalSince(tick)
        let commitTick = Date()
        XCTAssertEqual(try session.approve(report:result.recognition),count+groups)
        XCTAssertEqual(try f.journal.plannedUploadCount(),0)
        try ArchiveDatabaseSafety.verify(backup,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:backup.path).plannedUploadCount(),count+groups)
        print("400,000 tiny local files and 96,000 directories; compare \(scan) s; recognition \(Date().timeIntervalSince(commitTick)) s; total \(Date().timeIntervalSince(start)) s; content bytes read 0")
    }

    func testLargeArchiveQueues50000GenuineDifferencesAfterReset() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_LARGE_AUDIT"] == "1" else { throw XCTSkip("Opt-in large differences regression") }
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let count=50_000, groups=500
        let old=Date(timeIntervalSince1970:1_700_000_000)
        for group in 0..<groups {
            let a=f.source.appendingPathComponent("group-\(group)")
            let b=f.target.appendingPathComponent("group-\(group)")
            try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
            for index in 0..<(count/groups) {
                let name="photo-\(index).dat"
                let src=a.appendingPathComponent(name),dst=b.appendingPathComponent(name)
                // Half differ by length; half by same-length content with
                // different modification times so intelligent SHA is required.
                try Data("source".utf8).write(to:src)
                try Data((index.isMultiple(of:2) ? "old" : "target").utf8).write(to:dst)
                try FileManager.default.setAttributes([.modificationDate:old],ofItemAtPath:src.path)
                try FileManager.default.setAttributes([.modificationDate:old.addingTimeInterval(-60)],ofItemAtPath:dst.path)
            }
        }
        try initializeInventory(f)
        XCTAssertEqual(try f.journal.resetPendingQueue(backup:f.base.appendingPathComponent("before-reset.sqlite")),count+groups)
        let reopened=try ChangeJournal(path:f.db.path)
        let token=try XCTUnwrap(reopened.queueRebuildToken())
        XCTAssertEqual(try reopened.plannedUploadCount(),0)
        let start=Date()
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result=try session.auditAndRecognize(mode:.intelligent,repair:true)
        XCTAssertEqual(result.audit.count(.different),count)
        XCTAssertEqual(result.audit.count(.uncertain),0)
        XCTAssertEqual(result.audit.count(.matching),groups)
        XCTAssertEqual(result.audit.findings.filter{$0.detail=="Dimensione diversa"}.count,count/2)
        XCTAssertEqual(result.audit.findings.filter{$0.detail=="Contenuto SHA-256 diverso"}.count,count/2)
        XCTAssertEqual(result.audit.bytesRead,Int64(count/2*12))
        XCTAssertEqual(result.audit.queuedRepairs,count)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try reopened.completeQueueRebuild(token:token),0)
        XCTAssertEqual(try reopened.plannedUploadCount(),count)
        XCTAssertEqual(try reopened.plannedDeleteCount(afterID:0),0)
        XCTAssertNil(try reopened.queueRebuildToken())
        XCTAssertEqual(try String(contentsOf:f.target.appendingPathComponent("group-0/photo-0.dat"),encoding:.utf8),"old")
        XCTAssertEqual(try String(contentsOf:f.target.appendingPathComponent("group-0/photo-1.dat"),encoding:.utf8),"target")
        print("50,000 genuine differences queued after reset, no destination writes; \(Date().timeIntervalSince(start)) s")
    }

    func testQueueResetPersistsHoldAndAuditRebuildsOnlyRealMissingFile() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSinceNow:-600)
        try write("matching",to:f.source.appendingPathComponent("same.jpg"),date:date)
        try write("matching",to:f.target.appendingPathComponent("same.jpg"),date:date)
        try write("new",to:f.source.appendingPathComponent("missing.jpg"),date:date)
        try initializeInventory(f)
        let backup=f.base.appendingPathComponent("reset.sqlite")
        XCTAssertEqual(try f.journal.resetPendingQueue(backup:backup),2)
        let reopened=try ChangeJournal(path:f.db.path)
        let token=try XCTUnwrap(reopened.queueRebuildToken())
        XCTAssertEqual(try reopened.plannedUploadCount(),0)
        XCTAssertEqual(try LocalInventory(path:f.db.path).itemCount(rootID:"photos"),2)
        XCTAssertEqual(try ChangeJournal(path:backup.path).plannedUploadCount(),2)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result=try session.auditAndRecognize(mode:.intelligent,repair:true)
        _ = try session.approve(report:result.recognition)
        XCTAssertEqual(try reopened.pending().map(\.relativePath),["missing.jpg"])
        XCTAssertNotNil(try reopened.queueRebuildToken())
        XCTAssertThrowsError(try reopened.completeQueueRebuild(token:"wrong"))
        XCTAssertEqual(try reopened.completeQueueRebuild(token:token),0)
        XCTAssertNil(try reopened.queueRebuildToken())
    }

    func testAuditCachesSpecialNamesButApprovalRechecksLiveAliases() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        for name in ["roll /a.jpg","roll /b.jpg","roll /c.jpg"] {
            try write("same",to:f.source.appendingPathComponent(name))
            try write("same",to:f.target.appendingPathComponent(name))
        }
        try initializeInventory(f)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result=try session.auditAndRecognize(mode:.deep)
        XCTAssertEqual(result.audit.count(.uncertain),0)
        XCTAssertGreaterThan(result.audit.directoryListingCacheHits ?? 0,0)
        XCTAssertEqual(result.recognition.verifiedCount,4)
        // A Windows-alias conflict appears AFTER the audit. Approval must
        // use uncached live directory checks, not its old comparison cache.
        try FileManager.default.createDirectory(at:f.target.appendingPathComponent("roll"),withIntermediateDirectories:false)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.plannedUploadCount(),4)
    }

    func testSpecialExistingNamesReadOnlyRecognitionDoesNotRename() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let name = "roll /photo.jpg"
        try write("matching",to:f.source.appendingPathComponent(name))
        try write("matching",to:f.target.appendingPathComponent(name))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.deep)
        XCTAssertEqual(result.audit.count(.uncertain),0)
        XCTAssertEqual(try session.approve(report:result.recognition),2)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertThrowsError(try f.mapping.fileURL(relativePath:name,destination:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.target.appendingPathComponent(name).path))
    }

    func testTrailingSpaceNameAliasIsNotAutomaticallyAssociated() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        try write("matching",to:f.source.appendingPathComponent("roll /photo.jpg"))
        try write("matching",to:f.target.appendingPathComponent("roll/photo.jpg"))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.deep,repair:true)
        XCTAssertEqual(result.audit.count(.uncertain),4)
        XCTAssertEqual(result.recognition.verifiedCount,0)
        XCTAssertEqual(result.audit.queuedRepairs,0)
    }

    func testMatchingDirectoryAcknowledgedIndependentlyOfMissingChild() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        try write("missing",to:f.source.appendingPathComponent("roll/photo.jpg"))
        try FileManager.default.createDirectory(at:f.target.appendingPathComponent("roll"),withIntermediateDirectories:true)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent,repair:true)
        XCTAssertEqual(result.recognition.matches.map(\.relativePath),["roll"])
        var files = -1, directories = -1
        XCTAssertEqual(try session.approve(report:result.recognition,onCounts:{ files=$0; directories=$1 }),1)
        XCTAssertEqual(files,0)
        XCTAssertEqual(directories,1)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["roll/photo.jpg"])
    }

    func testMatchingDirectoryReplacedBeforeApprovalStaysPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let src = f.source.appendingPathComponent("roll"), dst = f.target.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at:src,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:dst,withIntermediateDirectories:true)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent)
        try FileManager.default.moveItem(at:dst,to:f.target.appendingPathComponent("old-roll"))
        try FileManager.default.createDirectory(at:dst,withIntermediateDirectories:true)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["roll"])
    }

    func testIdenticalSeededFileIsAcknowledgedWithoutAnyDestinationWrite() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let first = f.source.appendingPathComponent("roll/photo.dng")
        let second = f.target.appendingPathComponent("roll/photo.dng")
        let date = Date(timeIntervalSinceNow: -600)
        try write("picture data", to: first, date: date)
        try write("picture data", to: second, date: date.addingTimeInterval(180))
        try initializeInventory(f)

        let pendingBefore = try f.journal.pending()
        XCTAssertTrue(pendingBefore.contains(where: { $0.relativePath == "roll/photo.dng" }))
        let dstBefore = try SeededArchiveVerifier.fingerprint(second)

        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(report.missingOrDifferent, 0)
        XCTAssertEqual(report.bytesRead, Int64(2 * "picture data".utf8.count))
        XCTAssertEqual(try f.journal.pending().count, pendingBefore.count)

        let completed = try verifier.approve(report: report)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(try f.journal.pending().contains(where: { $0.relativePath == "roll/photo.dng" }))
        XCTAssertEqual(try SeededArchiveVerifier.fingerprint(second), dstBefore)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "picture data")
    }

    func testSameSizeAndSameTimeWithDifferentContentsIsNeverAccepted() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -900)
        try write("AAAA", to: f.source.appendingPathComponent("photo.jpg"), date: date)
        try write("BBBB", to: f.target.appendingPathComponent("photo.jpg"), date: date)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(report.missingOrDifferent, 1)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains(where: { $0.relativePath == "photo.jpg" }))
    }

    func testMissingTargetAndDeletionJobsRemainPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("source only", to: f.source.appendingPathComponent("source.jpg"))
        try initializeInventory(f)
        _ = try f.journal.enqueue(rootID: "photos", relativePath: "old.jpg", kind: .delete)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(report.deferred, 1)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertEqual(try f.journal.pending().filter { $0.kind == .delete }.count, 1)
    }

    func testSourceChangedAfterHashBeforeApprovalRemainsQueued() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("edit.psd")
        let dst = f.target.appendingPathComponent("edit.psd")
        try write("VERSION01", to: src)
        try write("VERSION01", to: dst)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        try write("VERSION02 and changed length", to: src)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertEqual(try f.journal.pending().count, 1)
    }

    func testNewQueuedEventCannotBeConsumedByOldHashApproval() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("stable", to: src)
        try write("stable", to: dst)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)

        // Simulate the FSEvents journal replacing the original pending job
        // while a long seed comparison was in progress.
        let inv = try LocalInventory(path: f.db.path)
        try write("stable", to: src)
        _ = try inv.reconcile(rootID: "photos", root: f.source, subtree: src)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains(where: { $0.relativePath == "same.jpg" }))
    }

    func testSymlinkDestinationCannotBeHashedOrAcknowledged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("secret", to: f.source.appendingPathComponent("danger.txt"))
        try initializeInventory(f)
        let external = f.base.appendingPathComponent("not-owned.txt")
        try write("secret", to: external)
        try FileManager.default.createSymbolicLink(
            at: f.target.appendingPathComponent("danger.txt"), withDestinationURL: external
        )
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(try f.journal.pending().count, 1)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "secret")
    }

    func testCancelledVerificationDoesNotMarkJobsComplete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("contents", to: f.source.appendingPathComponent("foto.jpg"))
        try write("contents", to: f.target.appendingPathComponent("foto.jpg"))
        try initializeInventory(f)
        let cancellation = SeedVerificationCancellation()
        cancellation.cancel()
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        XCTAssertThrowsError(try verifier.verify(cancellation: cancellation))
        XCTAssertEqual(try f.journal.pending().count, 1)
    }

    func testApprovalCancellationDoesNotPartiallyAcknowledge() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for index in 0..<40 {
            let name = "f\(index).jpg"
            try write("same-\(index)", to: f.source.appendingPathComponent(name))
            try write("same-\(index)", to: f.target.appendingPathComponent(name))
        }
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 40)
        let cancellation = SeedVerificationCancellation()
        XCTAssertThrowsError(try verifier.approve(
            report: report, cancellation: cancellation,
            progress: { _, _ in cancellation.cancel() }
        ))
        XCTAssertEqual(try f.journal.pending().count, 40)
    }

    func testQuickRecognitionDoesNotReadContentAndNeverAcknowledgesDelete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("AAAA", to: src, date: date)
        try write("BBBB", to: dst, date: date)
        try initializeInventory(f)
        _ = try f.journal.enqueue(rootID:"photos",relativePath:"old.jpg",kind:.delete)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.bytesRead,0)
        XCTAssertEqual(result.recognition.verifiedCount,1)
        XCTAssertEqual(try session.approve(report:result.recognition),1)
        XCTAssertTrue(try f.journal.pending().contains { $0.kind == .delete })
        XCTAssertEqual(try String(contentsOf:dst,encoding:.utf8),"BBBB")
    }

    func testIntelligentHashCacheReusesOnlyStableFingerprintsAndDeepAlwaysReads() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSinceNow:-600)
        let src=f.source.appendingPathComponent("a.jpg"), dst=f.target.appendingPathComponent("a.jpg")
        try write("same",to:src,date:date)
        try write("same",to:dst,date:date.addingTimeInterval(10))
        try initializeInventory(f)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let first=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(first.audit.bytesRead,8)
        let second=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(second.audit.bytesRead,0)
        XCTAssertEqual(second.audit.cachedHashMatches,1)
        let deep=try session.auditAndRecognize(mode:.deep)
        XCTAssertEqual(deep.audit.bytesRead,8)
        try write("DIFF",to:dst,date:date.addingTimeInterval(20))
        let changed=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(changed.audit.count(.different),1)
        XCTAssertEqual(changed.audit.bytesRead,8)
    }

    func testIntelligentRecognitionHashesOnlyTimestampMismatch() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        try write("same", to:f.source.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.source.appendingPathComponent("b.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("b.jpg"),date:date.addingTimeInterval(120))
        try write("AAAA", to:f.source.appendingPathComponent("c.jpg"),date:date)
        try write("BBBB", to:f.target.appendingPathComponent("c.jpg"),date:date.addingTimeInterval(120))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(result.recognition.bytesRead,16)
        XCTAssertEqual(result.recognition.verifiedCount,2)
        XCTAssertEqual(try session.approve(report:result.recognition),2)
        XCTAssertTrue(try f.journal.pending().contains { $0.relativePath == "c.jpg" })
    }

    func testQuickRecognitionLeavesChangedFingerprintPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSinceNow:-600)
        let src = f.source.appendingPathComponent("a.jpg")
        let dst = f.target.appendingPathComponent("a.jpg")
        try write("same",to:src,date:date)
        try write("same",to:dst,date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.verifiedCount,1)
        try write("changed",to:dst)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().count,1)
    }

    func testMetadataRecognitionRechecksCommitGate() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        try write("same", to:f.source.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("a.jpg"),date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertThrowsError(try session.approve(report:result.recognition,cancellation:SeedVerificationCancellation(commitAllowed:{ false })))
        XCTAssertEqual(try f.journal.pending().count,1)
    }

    func testSessionReopensJournalForExplicitApproval() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("identical", to: src)
        try write("identical", to: dst)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(try f.journal.pending().count, 1)
        let before = try SeededArchiveVerifier.fingerprint(dst)
        XCTAssertEqual(try session.approve(report: report), 1)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertEqual(try SeededArchiveVerifier.fingerprint(dst), before)
    }

    func testSessionRejectsNewDatabaseAtSamePath() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let db = f.base.appendingPathComponent("replaceable.sqlite")
        func createDatabase(_ url: URL) throws {
            let journal = try ChangeJournal(path: url.path)
            _ = try journal.databaseIdentity()
        }
        try createDatabase(db)
        let session = try SeededArchiveSession(database: db, mappings: [f.mapping])
        let report = try session.verify()
        try FileManager.default.moveItem(at: db, to: f.base.appendingPathComponent("previous.sqlite"))
        try createDatabase(db)
        XCTAssertThrowsError(try session.approve(report: report))
        XCTAssertThrowsError(try session.verify())
    }

    func testSessionDoesNotAcknowledgeNewerEventAcrossConnections() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("edited.jpg")
        let dst = f.target.appendingPathComponent("edited.jpg")
        try write("original", to: src)
        try write("original", to: dst)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        try write("changed contents", to: src)
        let inventory = try LocalInventory(path: f.db.path)
        _ = try inventory.reconcile(rootID: "photos", root: f.source, subtree: src)
        XCTAssertEqual(try session.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains { $0.relativePath == "edited.jpg" })
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "original")
    }

    func testSessionApprovalCancellationLeavesQueueUnchanged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("identical", to: f.source.appendingPathComponent("same.jpg"))
        try write("identical", to: f.target.appendingPathComponent("same.jpg"))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        let cancellation = SeedVerificationCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try session.approve(report: report, cancellation: cancellation))
        XCTAssertEqual(try f.journal.pending().count, 1)
    }
}
