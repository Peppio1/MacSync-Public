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
    func testAuditCountsPaginationAndMailbox() throws {
        let findings = (0..<1250).map { i in
            AuditFinding(rootID:"photos",relativePath:"file-\(i).jpg",sourceRoot:"/source",targetRoot:"/target",objectKind:i % 5 == 0 ? "directory" : "file",bytes:1,kind:i % 2 == 0 ? .missing : .extra,detail:"")
        }
        let candidates = Set(findings.filter { $0.kind == .extra && $0.objectKind == "file" }.prefix(23).map(\.id))
        let counts = AuditFindingCounts.calculate(findings,deletionCandidates:candidates)
        XCTAssertEqual(counts.newFiles,500)
        XCTAssertEqual(counts.deletionFiles,23)
        XCTAssertEqual(counts.extra,625)
        let first = try XCTUnwrap(AuditFindingPage.load(findings:findings,kind:.missing,filesOnly:true,deletionCandidates:candidates,root:"",search:"",offset:0))
        let second = try XCTUnwrap(AuditFindingPage.load(findings:findings,kind:.missing,filesOnly:true,deletionCandidates:candidates,root:"",search:"",offset:200))
        XCTAssertEqual(first.total,500); XCTAssertEqual(first.rows.count,200); XCTAssertEqual(second.rows.count,200)
        XCTAssertTrue(Set(first.rows.map(\.id)).isDisjoint(with:Set(second.rows.map(\.id))))
        let deletes = try XCTUnwrap(AuditFindingPage.load(findings:findings,kind:.extra,filesOnly:true,deletionCandidates:candidates,root:"",search:"",offset:0))
        XCTAssertEqual(deletes.total,23)
        XCTAssertNil(AuditFindingPage.load(findings:findings,kind:nil,filesOnly:false,deletionCandidates:[],root:"",search:"",offset:0,shouldContinue:{ false }))
        let mailbox = AuditProgressMailbox()
        var progress = ArchiveAuditProgress()
        XCTAssertTrue(mailbox.offer(progress))
        for i in 1...10000 {
            progress.compared = i
            XCTAssertFalse(mailbox.offer(progress))
        }
        XCTAssertEqual(mailbox.take()?.compared,10000)
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.offer(progress))
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
        XCTAssertEqual(report.sourceMetrics?.files,3)
        XCTAssertEqual(report.destinationMetrics?.files,4)
        XCTAssertEqual(report.metadataMatches,1)
        XCTAssertEqual(report.hashMatches,0)
        let decoded = try JSONDecoder().decode(ArchiveAuditReport.self,from:JSONEncoder().encode(report))
        XCTAssertEqual(decoded,report)
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
    func testOnlyQuickAndIntelligentAreUserSelectableAndDeepReportsStillDecode() throws {
        XCTAssertEqual(ArchiveAuditMode.selectableModes, [.quick, .intelligent])
        XCTAssertFalse(ArchiveAuditMode.selectableModes.contains(.deep))
        // DEEP remains a valid historical report/diagnostic mode, but cannot
        // be selected for a new operator-triggered audit.
        let legacyReportMode = try JSONEncoder().encode(ArchiveAuditMode.deep)
        XCTAssertEqual(try JSONDecoder().decode(ArchiveAuditMode.self, from: legacyReportMode), .deep)
    }

    func testSavedDeepSelectionMigratesWithoutDiscardingScheduleOrOtherPreferences() throws {
        let suiteName = "MacSync-audit-settings-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "MacSync.archiveAuditSettings"
        defaults.set("unrelated-value", forKey: "other.macsync.preference")
        var old = ArchiveAuditSettings()
        old.enabled = true
        old.mode = .deep
        old.repair = true
        old.frequency = "monthly"
        old.weekday = 5
        old.monthDay = 19
        old.hour = 18
        old.minute = 37
        defaults.set(try JSONEncoder().encode(old), forKey: key)

        let migrated = ArchiveAuditSettings.loadMigratingLegacyDeep(
            from: defaults, key: key, at: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(migrated.mode, .intelligent)
        XCTAssertTrue(migrated.enabled)
        XCTAssertTrue(migrated.repair)
        XCTAssertEqual(migrated.frequency, "monthly")
        XCTAssertEqual(migrated.weekday, 5)
        XCTAssertEqual(migrated.monthDay, 19)
        XCTAssertEqual(migrated.hour, 18)
        XCTAssertEqual(migrated.minute, 37)
        XCTAssertEqual(defaults.string(forKey: "other.macsync.preference"), "unrelated-value")
        XCTAssertEqual(try JSONDecoder().decode(ArchiveAuditSettings.self,
            from: XCTUnwrap(defaults.data(forKey: key))), migrated)
        var loadedAgain = ArchiveAuditSettings.loadMigratingLegacyDeep(from: defaults, key: key)
        XCTAssertFalse(loadedAgain.migrateLegacyDeepSelection())
    }

    func testQuickToleranceOfTwoSecondsDoesNotReadAnyFileContent() throws {
        let f = try setup(); defer { try? FileManager.default.removeItem(at: f.base) }
        try put(f.source, "preview.jpg", "ABCD")
        try put(f.target, "preview.jpg", "WXYZ")
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sourceDate.addingTimeInterval(1.5)],
            ofItemAtPath: f.target.appendingPathComponent("preview.jpg").path)
        try baseline(f)
        let audit = try ArchiveAudit(journal: f.journal, mappings: [f.mapping])
        let within = try audit.run(mode: .quick)
        XCTAssertEqual(within.count(.matching), 1)
        XCTAssertEqual(within.bytesRead, 0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        try FileManager.default.setAttributes([.modificationDate: sourceDate.addingTimeInterval(2.5)],
            ofItemAtPath: f.target.appendingPathComponent("preview.jpg").path)
        let outside = try audit.run(mode: .quick)
        XCTAssertEqual(outside.count(.different), 1)
        XCTAssertEqual(outside.bytesRead, 0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }

    func testIntelligentHashesDifferentTimestampsAndReusesValidatedCache() throws {
        let f = try setup(); defer { try? FileManager.default.removeItem(at: f.base) }
        try put(f.source, "raw.dng", "ABCD")
        try put(f.target, "raw.dng", "ABCD")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_004)],
            ofItemAtPath: f.target.appendingPathComponent("raw.dng").path)
        try baseline(f)
        let audit = try ArchiveAudit(journal: f.journal, mappings: [f.mapping])
        let first = try audit.run(mode: .intelligent)
        XCTAssertEqual(first.count(.matching), 1)
        XCTAssertEqual(first.bytesRead, 8, "Two four-byte files must be hashed once")
        XCTAssertEqual(first.hashMatches, 1)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        let second = try audit.run(mode: .intelligent)
        XCTAssertEqual(second.count(.matching), 1)
        XCTAssertEqual(second.bytesRead, 0, "Cache must avoid re-hashing unchanged content")
        XCTAssertTrue(try f.journal.pending().isEmpty)

        try Data("WXYZ".utf8).write(to: f.target.appendingPathComponent("raw.dng"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_004)],
            ofItemAtPath: f.target.appendingPathComponent("raw.dng").path)
        let changed = try audit.run(mode: .intelligent)
        XCTAssertEqual(changed.count(.different), 1)
        XCTAssertGreaterThan(changed.bytesRead, 0, "A changed fingerprint must invalidate cached hash")
        XCTAssertTrue(try f.journal.pending().isEmpty)
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

    func testV0180SeparatedAuditMetricsAndActualReadBytes() throws {
        let f=try setup(); defer { try? FileManager.default.removeItem(at:f.base) }
        try put(f.source,"folder/same.jpg","same")
        try put(f.target,"folder/same.jpg","same")
        try put(f.source,"missing.jpg","123456")
        try put(f.target,"extra.jpg","123")
        try baseline(f)
        let audit=try ArchiveAudit(journal:f.journal,mappings:[f.mapping])
        var last:ArchiveAuditProgress?
        _ = try audit.run(mode:.quick,progress:{last=$0})
        let quick=try XCTUnwrap(last)
        XCTAssertEqual(quick.source.files,2)
        XCTAssertEqual(quick.destination.files,2)
        XCTAssertEqual(quick.source.directories,1)
        XCTAssertEqual(quick.destination.directories,1)
        XCTAssertEqual(quick.source.detectedBytes,10)
        XCTAssertEqual(quick.destination.detectedBytes,7)
        XCTAssertEqual(quick.bytesRead,0)
        XCTAssertNil(quick.compareRate)
        let report=try audit.run(mode:.deep,progress:{last=$0})
        let deep=try XCTUnwrap(last)
        XCTAssertEqual(deep.source.bytesRead,4)
        XCTAssertEqual(deep.destination.bytesRead,4)
        XCTAssertEqual(report.bytesRead,8)
        XCTAssertEqual(deep.source.detectedBytes,10)
        XCTAssertEqual(deep.destination.detectedBytes,7)
    }

    func testV0180FinishedCyclesRemainSeparateAcrossModesAndReopen() throws {
        let f=try setup(); defer { try? FileManager.default.removeItem(at:f.base) }
        let history=try SyncCycleHistory(path:f.db)
        let now=Date()
        try history.begin(id:"old",sessionID:"legacy",at:now.addingTimeInterval(-30))
        try history.finish(id:"old",at:now.addingTimeInterval(-25),seconds:5,state:"completed")
        try history.begin(id:"manual",sessionID:"manual-session",at:now.addingTimeInterval(-20),automatic:false)
        try history.finish(id:"manual",at:now.addingTimeInterval(-15),seconds:5,state:"completed")
        try history.begin(id:"auto",sessionID:"auto-session",at:now.addingTimeInterval(-10),automatic:true)
        try history.finish(id:"auto",at:now.addingTimeInterval(-5),seconds:5,state:"completed")
        try history.begin(id:"running",sessionID:"auto-session",at:now,automatic:true)
        let reopened=try SyncCycleHistory(path:f.db)
        let cycles=try reopened.cycles(finishedOnly:true)
        XCTAssertEqual(cycles.map(\.id),["auto","manual","old"])
        XCTAssertEqual(cycles[0].automatic,true)
        XCTAssertEqual(cycles[1].automatic,false)
        XCTAssertNil(cycles[2].automatic)
        XCTAssertEqual(try reopened.totals(cycleID:"auto").stats,SyncDashboardStats())
        try reopened.markInterrupted(exceptSession:"new-app")
        XCTAssertEqual(try reopened.cycles(finishedOnly:true).first?.state,"interrupted")
    }

    func testArchiveEstimateWaitsForRepresentativeSample() {
        let start = Date()
        var p = ArchiveAuditProgress(started:start.addingTimeInterval(-3600))
        p.phase = "Verifica SHA-256"; p.comparisonStarted = start
        p.total = 250_000; p.compared = 134
        XCTAssertNil(p.remaining(at:start.addingTimeInterval(60)))
        p.compared = 500
        XCTAssertEqual(p.remaining(at:start.addingTimeInterval(60)),29_940)
    }

    func testV0180EstimateHealthAndDiagnostic() throws {
        XCTAssertNil(OperationEstimate.remaining(processed:0,total:20,elapsed:10))
        XCTAssertNil(OperationEstimate.remaining(processed:3,total:0,elapsed:10))
        XCTAssertEqual(OperationEstimate.remaining(processed:5,total:20,elapsed:10),30)
        XCTAssertNil(OperationEstimate.remaining(processed:20,total:20,elapsed:10))
        let f=try setup(); defer { try? FileManager.default.removeItem(at:f.base) }
        XCTAssertEqual(FolderHealth.inspect(path:f.source.path),.ready)
        XCTAssertEqual(FolderHealth.inspect(path:f.source.appendingPathComponent("missing").path),.missing)
        XCTAssertEqual(FolderHealth.inspect(path:f.target.path,destination:true),.unverified)
        XCTAssertEqual(FolderHealth.inspect(path:f.target.path,expected:try VolumeFingerprint.read(at:f.target),destination:true),.ready)
        XCTAssertTrue(FolderHealth.classify(13).isError)
        XCTAssertTrue(SyncDiagnostic.describe(NSError(domain:NSPOSIXErrorDomain,code:13,userInfo:nil)).contains("13"))
    }


    func testV0180AuditGateDistinguishesReconciliationFromFailure() throws {
        let gate=MonitorSafetyGate()
        let generation=gate.invalidate()
        gate.setReady(true,generation:generation)
        let token=try XCTUnwrap(gate.beginAudit())
        let cancel=SeedVerificationCancellation(shouldContinue:{gate.auditBlockReason(token)==nil},commitAllowed:{gate.auditCommitAllowed(token)})
        gate.beginReconciliation(generation:generation)
        XCTAssertFalse(gate.isReady)
        XCTAssertNil(gate.beginAudit())
        XCTAssertFalse(cancel.isCancelled)
        XCTAssertFalse(cancel.mayCommit)
        gate.setReady(true,generation:generation)
        XCTAssertTrue(cancel.mayCommit)
        gate.fail(generation:generation,reason:"Errore inventario")
        gate.setReady(true,generation:generation)
        XCTAssertTrue(cancel.isCancelled)
        XCTAssertFalse(cancel.wasExplicitlyCancelled)
        XCTAssertEqual(gate.auditBlockReason(token),"Errore inventario")
        let next=try XCTUnwrap(gate.beginAudit())
        gate.invalidate()
        XCTAssertNotNil(gate.auditBlockReason(next))
        cancel.cancel()
        XCTAssertTrue(cancel.wasExplicitlyCancelled)
    }

    func testV0180DeepAuditContinuesDuringOrdinaryInventoryReconciliation() throws {
        let f=try setup(); defer {try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"one.jpg","same"); try put(f.target,"one.jpg","same")
        try put(f.source,"two.jpg","ABCD"); try put(f.target,"two.jpg","ABCD")
        try baseline(f)
        let gate=MonitorSafetyGate()
        let gen=gate.invalidate(); gate.setReady(true,generation:gen)
        let token=try XCTUnwrap(gate.beginAudit())
        let cancel=SeedVerificationCancellation(shouldContinue:{gate.auditBlockReason(token)==nil},commitAllowed:{gate.auditCommitAllowed(token)})
        var entered=false
        let report=try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.deep,cancellation:cancel,diagnostic:{ progress in
            if progress.phase=="Verifica SHA-256" && !entered {
                entered=true
                gate.beginReconciliation(generation:gen)
            }
        })
        XCTAssertTrue(entered)
        XCTAssertFalse(gate.isReady)
        XCTAssertEqual(report.count(.matching),2)
        XCTAssertEqual(report.bytesRead,16)
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }

    func testV0180AuditRepairCannotCommitWhileReconciling() throws {
        let f=try setup(); defer {try? FileManager.default.removeItem(at:f.base)}
        try put(f.source,"missing.jpg","new"); try baseline(f)
        let gate=MonitorSafetyGate()
        let gen=gate.invalidate(); gate.setReady(true,generation:gen)
        let token=try XCTUnwrap(gate.beginAudit())
        let cancel=SeedVerificationCancellation(shouldContinue:{gate.auditBlockReason(token)==nil},commitAllowed:{gate.auditCommitAllowed(token)})
        XCTAssertThrowsError(try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.deep,repair:true,cancellation:cancel,diagnostic:{progress in
            if progress.phase=="Finalizzazione" { gate.beginReconciliation(generation:gen) }
        }))
        XCTAssertTrue(try f.journal.pending().isEmpty)
    }

    func testReadonlyHistoryDoesNotInitializeOrMutateSQLite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macsync-history-readonly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let db = base.appendingPathComponent("history.sqlite").path

        XCTAssertThrowsError(try SyncCycleHistory(path:db,readOnly:true))
        XCTAssertFalse(FileManager.default.fileExists(atPath:db))

        let writer = try SyncCycleHistory(path:db)
        try writer.begin(id:"cycle",sessionID:"session",at:Date(),automatic:false)
        try writer.finish(id:"cycle",at:Date(),seconds:0.1,state:"completed")
        let reader = try SyncCycleHistory(path:db,readOnly:true)
        XCTAssertEqual(try reader.cycles(limit:10,finishedOnly:true).map(\.id),["cycle"])
        XCTAssertThrowsError(try reader.begin(id:"forbidden",sessionID:"session",at:Date()))
        XCTAssertEqual(try writer.cycles(limit:10).map(\.id),["cycle"])
    }


}
