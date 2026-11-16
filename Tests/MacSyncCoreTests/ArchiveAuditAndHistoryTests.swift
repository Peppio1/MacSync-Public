import Foundation
import XCTest
@testable import MacSyncCore

final class ArchiveAuditAndHistoryTests:XCTestCase {
    private struct Fixture {
        let base:URL
        let source:URL
        let target:URL
        let db:String
        let journal:ChangeJournal
        let mapping:MountedFolderMapping
    }
    private func setup() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MacSync-audit-"+UUID().uuidString)
            .resolvingSymlinksInPath()
        let a=base.appendingPathComponent("source"), b=base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
        let db=base.appendingPathComponent("state.sqlite").path
        let journal=try ChangeJournal(path:db)
        let mapping=try MountedFolderMapping(rootID:"photos",source:a,target:b)
        try LocalInventory(path:db).reconcile(rootID:"photos",root:a)
        return Fixture(base:base,source:a,target:b,db:db,journal:journal,mapping:mapping)
    }
    private func put(_ root:URL,_ path:String,_ text:String) throws {
        let url=root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(text.utf8).write(to:url)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:url.path)
    }
    private func baseline(_ f:Fixture) throws {
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        for job in try f.journal.pending(limit:10000) { try f.journal.markCompleted(id:job.id) }
    }
    func testUnifiedAuditHashesOnlyOnceAndRequiresApproval() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"same.jpg","same"); try put(f.target,"same.jpg","same")
        try put(f.source,"different.jpg","1234"); try put(f.target,"different.jpg","5678")
        try put(f.source,"missing.jpg","absent"); try put(f.target,"extra.jpg","extra")
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        let session=try SeededArchiveSession(database:URL(fileURLWithPath:f.db),mappings:[f.mapping])
        let result=try session.auditAndRecognize(repair:true)
        XCTAssertEqual(result.audit.bytesRead,16)
        XCTAssertEqual(result.audit.count(.matching),1)
        XCTAssertEqual(result.recognition.matches.map(\.relativePath),["same.jpg"])
        XCTAssertEqual(try f.journal.pending().count,3)
        XCTAssertEqual(try session.approve(report:result.recognition),1)
        XCTAssertEqual(Set(try f.journal.pending().map(\.relativePath)),["different.jpg","missing.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.target.appendingPathComponent("extra.jpg").path))
    }
    func testUnifiedRecognitionRejectsChangedFileBeforeApproval() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"same.jpg","same"); try put(f.target,"same.jpg","same")
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        let session=try SeededArchiveSession(database:URL(fileURLWithPath:f.db),mappings:[f.mapping])
        let result=try session.auditAndRecognize()
        try put(f.target,"same.jpg","DIFF")
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().count,1)
    }
    func testUnifiedRecognitionCancellationPreservesQueue() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"same.jpg","same"); try put(f.target,"same.jpg","same")
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        let session=try SeededArchiveSession(database:URL(fileURLWithPath:f.db),mappings:[f.mapping])
        let c=SeedVerificationCancellation()
        XCTAssertThrowsError(try session.auditAndRecognize(repair:true,cancellation:c,progress:{_ in c.cancel()}))
        XCTAssertEqual(try f.journal.pending().count,1)
    }
    func testQuickDiagnosticFindsAllCategoriesExcludingManagedFiles() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"same.jpg","same"); try put(f.target,"same.jpg","same")
        try put(f.source,"missing.jpg","missing")
        try put(f.source,"different.psd","12345"); try put(f.target,"different.psd","123")
        try put(f.target,"extra.jpg","extra")
        try put(f.target,".macsync-staging/x.partial","temp")
        try put(f.target,".macsync-backup-test","backup")
        try put(f.target,"normal-after.jpg","not skipped")
        try baseline(f)
        let report=try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.quick)
        XCTAssertEqual(report.count(.matching),1)
        XCTAssertEqual(report.count(.missing),1)
        XCTAssertEqual(report.count(.different),1)
        XCTAssertEqual(report.count(.extra),2)
        XCTAssertEqual(report.queuedRepairs,0)
        XCTAssertEqual(report.bytesRead,0)
        XCTAssertTrue(report.findings.allSatisfy{!$0.relativePath.hasPrefix(".macsync-")})
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }
    func testDeepAuditDetectsSameSizeSameTimestampChangedContent() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"file.psd","ABCD"); try put(f.target,"file.psd","EFGH")
        try baseline(f)
        let audit=try ArchiveAudit(journal:f.journal,mappings:[f.mapping])
        XCTAssertEqual(try audit.run(mode:.quick).count(.matching),1)
        let report=try audit.run(mode:.deep)
        XCTAssertEqual(report.count(.different),1)
        XCTAssertEqual(report.bytesRead,8)
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }
    func testOptInRepairOnlyEnqueuesMissingAndDifferentNotExtraOrConflicts() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"missing.jpg","missing")
        try put(f.source,"changed.dng","new data"); try put(f.target,"changed.dng","old")
        try put(f.target,"extra.jpg","extra")
        try put(f.source,"conflict","file"); try put(f.target,"conflict/extra.jpg","child")
        try put(f.source,"Name.jpg","source"); try put(f.target,"name.jpg","target")
        try baseline(f)
        let audit=try ArchiveAudit(journal:f.journal,mappings:[f.mapping])
        let report=try audit.run(mode:.quick,repair:true)
        XCTAssertEqual(report.queuedRepairs,2)
        let jobs=try f.journal.pending()
        XCTAssertEqual(Set(jobs.map(\.relativePath)),["missing.jpg","changed.dng"])
        XCTAssertTrue(jobs.allSatisfy{$0.kind == .upsert})
        XCTAssertEqual(try String(contentsOf:f.target.appendingPathComponent("changed.dng"),encoding:.utf8),"old")
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.target.appendingPathComponent("extra.jpg").path))
        XCTAssertGreaterThanOrEqual(report.count(.uncertain),3)
        XCTAssertEqual(try audit.run(mode:.quick,repair:true).queuedRepairs,0)
    }
    func testAuditCancelledDoesNotQueueRepair() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"missing.jpg","missing")
        try baseline(f)
        let cancel=SeedVerificationCancellation()
        XCTAssertThrowsError(try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.quick,repair:true,
            cancellation:cancel,progress:{_ in cancel.cancel()}))
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }
    func testAuditNeverSupersedesPendingDelete() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"missing.jpg","missing")
        try baseline(f)
        let id=try f.journal.enqueue(rootID:"photos",relativePath:"missing.jpg",kind:.delete)
        let report=try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.quick,repair:true)
        XCTAssertEqual(report.queuedRepairs,0)
        XCTAssertEqual(try f.journal.pending().map(\.id),[id])
    }
    func testAuditScheduleDefaultsDiagnosticAndDisabled() throws {
        var settings=ArchiveAuditSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.repair)
        XCTAssertEqual(settings.mode,.quick)
        var cal=Calendar(identifier:.gregorian); cal.timeZone=TimeZone(secondsFromGMT:0)!
        let start=try XCTUnwrap(cal.date(from:DateComponents(year:2026,month:11,day:15,hour:4)))
        settings.frequency="monthly"; settings.monthDay=15; settings.hour=3
        let next=try XCTUnwrap(settings.next(after:start,calendar:cal))
        let p=cal.dateComponents([.year,.month,.day,.hour],from:next)
        XCTAssertEqual(p.month,12); XCTAssertEqual(p.day,15); XCTAssertEqual(p.hour,3)
    }
    func testHistoryPersistedCountsRecoveryAsSubsetAndNoTechnicalDeletes() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        let start=Date(timeIntervalSinceNow:-60)
        let store=try SyncCycleHistory(path:f.db)
        try store.begin(id:"cycle",sessionID:"session",at:start)
        let job=QueuedChange(id:1,rootID:"photos",relativePath:"photo.dng",kind:.delete,recordedAt:start)
        for (kind,bytes,seconds) in [(SyncEventKind.deleted,Int64(25),0.0),(.recovered,25,0),(.missing,0,0),
            (.directoryRemoved,0,0),(.recoveryExpired,100,0),(.backupCopy,50,2),(.stageCopy,100,4),(.newFile,100,4)] {
            try store.append(cycleID:"cycle",event:SyncCycleEvent(kind:kind,job:job,mapping:f.mapping,bytes:bytes,seconds:seconds))
        }
        try store.finish(id:"cycle",at:start.addingTimeInterval(20),seconds:20,state:"completed")
        let reopened=try SyncCycleHistory(path:f.db)
        let totals=try reopened.totals(cycleID:"cycle")
        XCTAssertEqual(totals.stats.permanentlyDeleted+totals.stats.movedToRecovery,2)
        XCTAssertEqual(totals.stats.movedToRecovery,1)
        XCTAssertEqual(totals.stats.expiredRecovery,1)
        XCTAssertEqual(totals.stats.removedDirectories,1)
        XCTAssertEqual(totals.stats.bytesTransferred,100)
        XCTAssertEqual(totals.backupBytes,50)
        XCTAssertEqual(totals.meanCopyRate,25)
        XCTAssertEqual(try reopened.events(cycleID:"cycle",kinds:[.deleted,.recovered]).count,2)
        let cycle=try XCTUnwrap(reopened.cycles().first)
        // SQLite stores Unix timestamps as REAL; Date uses a different epoch internally.
        XCTAssertEqual(cycle.started.timeIntervalSince(start), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cycle.ended).timeIntervalSince(start.addingTimeInterval(20)), 0, accuracy: 0.001)
        XCTAssertEqual(cycle.seconds,20)
        // Retention cascades details, not the operational queue.
        try reopened.prune(before:Date())
        XCTAssertTrue(try reopened.cycles().isEmpty)
        XCTAssertTrue(try reopened.events().isEmpty)
    }
    func testCopyTelemetryDoesNotMistakeBackupCleanupForDeletion() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"photo.psd","new contents")
        try put(f.target,"photo.psd","old")
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        let worker=try MountedFolderCopyWorker(journal:f.journal,log:SyncActivityLog(path:f.db),mappings:[f.mapping],
            minimumStableAge:0)
        var events:[SyncCycleEvent]=[]
        worker.onEvent={events.append($0)}
        let summary=try worker.runCycle(enabled:true)
        XCTAssertEqual(summary.updated,1)
        XCTAssertEqual(events.filter{$0.kind == .updatedFile}.count,1)
        XCTAssertEqual(events.filter{$0.kind == .backupCopy}.first?.bytes,3)
        XCTAssertFalse(events.contains{$0.kind == .deleted || $0.kind == .recovered})
    }
    func testRecoveredMirrorTelemetryIncludesActualRecoveryPathAndExpiryExcluded() throws {
        let f=try setup(); defer{try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"photo.psd","data"); try put(f.target,"photo.psd","data")
        try baseline(f)
        let auth=try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping])
        let mirror=try MirrorDeletionWorker(journal:f.journal,manifest:RecoveryManifest(path:f.db),
            log:SyncActivityLog(path:f.db),mappings:[f.mapping],
            policy:MirrorDeletionPolicy(enabled:true,recoveryEnabled:true,retentionDays:nil),
            authorization:auth)
        try FileManager.default.removeItem(at:f.source.appendingPathComponent("photo.psd"))
        _ = try LocalInventory(path:f.db).reconcile(rootID:"photos",root:f.source)
        var events:[SyncCycleEvent]=[]
        mirror.onEvent={events.append($0)}
        XCTAssertEqual(try mirror.runCycle().recovered,1)
        let row=try XCTUnwrap(events.first(where:{$0.kind == .recovered}))
        let path=try XCTUnwrap(row.recoveryPath)
        XCTAssertTrue(path.hasPrefix(f.target.path+"/.macsync-recovery/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.target.appendingPathComponent("photo.psd").path))
    }
    func testLiveRateUsesWeightedTimeAndExcludesBackup() {
        let job=QueuedChange(id:1,rootID:"photos",relativePath:"a",kind:.upsert,recordedAt:Date())
        var p=SyncLiveProgress(started:Date(),planned:2)
        p.observe(SyncCycleEvent(kind:.stageCopy,job:job,mapping:nil,bytes:100,seconds:1))
        p.observe(SyncCycleEvent(kind:.stageCopy,job:job,mapping:nil,bytes:300,seconds:3))
        p.observe(SyncCycleEvent(kind:.backupCopy,job:job,mapping:nil,bytes:1000,seconds:1))
        p.observe(SyncCycleEvent(kind:.newFile,job:job,mapping:nil,bytes:100))
        XCTAssertEqual(p.processed,1)
        XCTAssertEqual(p.meanCopyRate,100)
        XCTAssertEqual(p.fraction,0.5)
        XCTAssertTrue(SyncLiveProgress.formatRate(1_250_000_000).hasSuffix("GB/s"))
    }
}
