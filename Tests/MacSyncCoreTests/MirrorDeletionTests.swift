import Foundation
import XCTest
@testable import MacSyncCore

final class MirrorDeletionTests: XCTestCase {
    func testCycleCancellationKeepsFutureSlotsButSessionStopIsPermanent() {
        let token = MirrorDeletionCancellation()
        XCTAssertFalse(token.cancelCurrentCycle())
        XCTAssertTrue(token.beginCycle())
        XCTAssertFalse(token.beginCycle())
        XCTAssertTrue(token.cancelCurrentCycle())
        XCTAssertTrue(token.isCancelled)
        XCTAssertFalse(token.isSessionCancelled)
        XCTAssertTrue(token.endCycle())
        XCTAssertTrue(token.beginCycle())
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.endCycle())
        XCTAssertTrue(token.isSessionCancelled)
        XCTAssertFalse(token.beginCycle())
    }

    private struct Fixture {
        let base: URL
        let source: URL
        let destination: URL
        let database: String
        let journal: ChangeJournal
        let log: SyncActivityLog
        let manifest: RecoveryManifest
        let mapping: MountedFolderMapping
    }

    private func fixture(fileCount: Int = 2) throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-mirror-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let file = "photo\(index).dng"
            try Data("simulated image \(index)".utf8).write(to: source.appendingPathComponent(file))
            try Data("simulated image \(index)".utf8).write(to: destination.appendingPathComponent(file))
        }
        let database = base.appendingPathComponent("state.sqlite").path
        let journal = try ChangeJournal(path: database)
        let log = try SyncActivityLog(path: database)
        let manifest = try RecoveryManifest(path: database)
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: source, target: destination
        )
        try LocalInventory(path: database).reconcile(rootID: "photos", root: source)
        // Both sides were seeded with identical fixture data above.
        // Model the completed upload baseline before testing mirror.
        while true {
            let batch = try journal.pendingUploads(limit: 1000)
            if batch.isEmpty { break }
            for job in batch { try journal.markCompleted(id: job.id) }
        }
        return Fixture(base: base, source: source, destination: destination,
                       database: database, journal: journal, log: log,
                       manifest: manifest, mapping: mapping)
    }

    private func worker(
        _ f: Fixture, recover: Bool, days: Int? = nil
    ) throws -> MirrorDeletionWorker {
        try MirrorDeletionWorker(
            journal: f.journal, manifest: f.manifest, log: f.log,
            mappings: [f.mapping],
            policy: MirrorDeletionPolicy(
                enabled: true, recoveryEnabled: recover, retentionDays: days
            )
        )
    }

    private func deleteSource(_ f: Fixture, name: String) throws {
        let file = f.source.appendingPathComponent(name)
        try FileManager.default.removeItem(at: file)
        try LocalInventory(path: f.database).reconcile(
            rootID: "photos", root: f.source, subtree: file
        )
    }

    func testQueueResetRestoresOnlyAuthorizedDeletionAndNeverReplaysIt() throws {
        let f=try fixture(fileCount:4)
        defer { try? FileManager.default.removeItem(at:f.base) }
        try deleteSource(f,name:"photo0.dng") // before consent
        let authorization=try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping])
        try deleteSource(f,name:"photo1.dng")
        try deleteSource(f,name:"photo2.dng")
        let original=try XCTUnwrap(f.journal.pending().first{$0.relativePath=="photo1.dng"})
        try Data("server only".utf8).write(to:f.destination.appendingPathComponent("independent.dng"))
        XCTAssertEqual(try f.journal.resetPendingQueue(backup:f.base.appendingPathComponent("reset.sqlite")),3)
        let reopened=try ChangeJournal(path:f.database)
        let token=try XCTUnwrap(reopened.queueRebuildToken())
        // A reappearing source path produces a new event while the hold is active.
        try Data("returned".utf8).write(to:f.source.appendingPathComponent("photo2.dng"))
        try LocalInventory(path:f.database).reconcile(rootID:"photos",root:f.source)
        let session=try SeededArchiveSession(database:URL(fileURLWithPath:f.database),mappings:[f.mapping])
        let result=try session.auditAndRecognize(mode:.intelligent,repair:true)
        _ = try session.approve(report:result.recognition)
        XCTAssertThrowsError(try authorization.completeQueueRebuild(journal:reopened,mappings:[f.mapping],token:token,report:result.audit,shouldContinue:{false}))
        XCTAssertNotNil(try reopened.queueRebuildToken())
        XCTAssertEqual(try reopened.plannedDeleteCount(afterID:0),0)
        XCTAssertEqual(try authorization.completeQueueRebuild(journal:reopened,mappings:[f.mapping],token:token,report:result.audit,shouldContinue:{true}),1)
        XCTAssertEqual(try reopened.pending().filter{$0.kind == .delete}.map(\.id),[original.id])
        XCTAssertTrue(try reopened.pending().contains{$0.kind == .upsert && $0.relativePath=="photo2.dng"})
        // Simulate a completed, verified deletion then an independent file
        // appearing at the same destination path.
        let target=f.destination.appendingPathComponent("photo1.dng")
        try FileManager.default.removeItem(at:target)
        XCTAssertTrue(try reopened.acknowledgeDeletion(id:original.id,rootID:"photos",relativePath:"photo1.dng"))
        try Data("unrelated replacement".utf8).write(to:target)
        _ = try reopened.resetPendingQueue(backup:f.base.appendingPathComponent("second-reset.sqlite"))
        let second=try XCTUnwrap(reopened.queueRebuildToken())
        let next=try session.auditAndRecognize(mode:.intelligent,repair:true)
        _ = try session.approve(report:next.recognition)
        XCTAssertEqual(try authorization.completeQueueRebuild(journal:reopened,mappings:[f.mapping],token:second,report:next.audit,shouldContinue:{true}),0)
        XCTAssertEqual(try reopened.plannedDeleteCount(afterID:0),0)
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"unrelated replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.destination.appendingPathComponent("independent.dng").path))
    }

    func testDeletionDisabledByDefaultAndInvalidRetentionRejected() throws {
        XCTAssertThrowsError(try MirrorDeletionPolicy(enabled: true, recoveryEnabled: true, retentionDays: 31))
        XCTAssertThrowsError(try MirrorDeletionPolicy(enabled: true, recoveryEnabled: true, retentionDays: -1))
        XCTAssertNoThrow(try MirrorDeletionPolicy(enabled: true, recoveryEnabled: true, retentionDays: nil))
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        XCTAssertThrowsError(try MirrorDeletionWorker(
            journal: f.journal, manifest: f.manifest, log: f.log, mappings: [f.mapping],
            policy: MirrorDeletionPolicy(enabled: false, recoveryEnabled: false, retentionDays: nil)
        ))
    }

    func testPermanentDeleteRequiresSessionArmingAndNewEvent() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        try deleteSource(f, name: "photo0.dng")
        XCTAssertEqual(try mirror.runOnce().removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo1.dng").path
        ))
        XCTAssertFalse(try f.journal.pending().contains {
            $0.kind == .delete && $0.relativePath == "photo0.dng"
        })
        XCTAssertTrue(try f.log.recent().contains { $0.action == "mirror_permanent" })
    }

    func testRenameRetainsOldTargetUntilNewFileIsSuccessfullyCopied() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        let oldSource = f.source.appendingPathComponent("photo0.dng")
        let newSource = f.source.appendingPathComponent("renamed.dng")
        let oldTarget = f.destination.appendingPathComponent("photo0.dng")
        let newTarget = f.destination.appendingPathComponent("renamed.dng")
        try FileManager.default.moveItem(at: oldSource, to: newSource)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: newSource.path
        )
        _ = try LocalInventory(path: f.database).reconcile(rootID: "photos", root: f.source)
        let blockedCopy = try MountedFolderCopyWorker(
            journal: f.journal, log: f.log, mappings: [f.mapping],
            availableCapacity: { _ in 0 }
        )
        XCTAssertEqual(try blockedCopy.runOnce(enabled: true).deferred, 1)
        XCTAssertTrue(try mirror.runOnce().blocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldTarget.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newTarget.path))
        let retry = try MountedFolderCopyWorker(
            journal: f.journal, log: f.log, mappings: [f.mapping],
            availableCapacity: { _ in nil }
        )
        XCTAssertEqual(try retry.runOnce(enabled: true).copied, 1)
        XCTAssertEqual(try mirror.runOnce().removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldTarget.path))
        XCTAssertEqual(try String(contentsOf: newTarget, encoding: .utf8), "simulated image 0")
    }

    func testPendingNameCannotBeMirroredAwayWhileIndependentDeletionProceeds() throws {
        let f = try fixture(fileCount: 20)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let fm = FileManager.default
        let old = "pending?.dng", new = "pending-.dng"
        let originalBytes = Data("outstanding name repair".utf8)
        let occupiedBytes = Data("independent destination collision".utf8)
        try originalBytes.write(to: f.source.appendingPathComponent(old))
        try originalBytes.write(to: f.destination.appendingPathComponent(old))
        _ = try LocalInventory(path: f.database).reconcile(rootID: "photos", root: f.source)
        for job in try f.journal.pendingUploads(limit: 100) {
            try f.journal.markCompleted(id: job.id)
        }
        try f.journal.verifyDirectoryBindings([f.mapping], allowNewTarget: true)
        let row=IncompatibleName(rootID:"photos",rootPath:f.source.path,
            relativePath:old,objectKind:"file",side:.source,reason:"Incompatible")
        let collision = f.destination.appendingPathComponent(new)
        try occupiedBytes.write(to:collision)
        let first=try NameRectification.executeLocal(items:[row],roots:["photos":f.source.path],
            journal:f.journal,log:f.log,shouldContinue:{
                (try? f.journal.hasPendingNameRectification()) == false
            })
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(try f.journal.hasPendingNameRectification())
        // Simulate an operator changing the local path while the persisted
        // intent remains unresolved. Its old and new paths stay protected.
        try fm.moveItem(at:f.source.appendingPathComponent(old),to:f.source.appendingPathComponent(new))
        _ = try LocalInventory(path:f.database).reconcile(rootID:"photos",root:f.source)
        let mirror = try worker(f, recover: false)
        // Source disappearance queues a valid DELETE for the renamed path;
        // the outstanding local rename intent must protect it.
        try deleteSource(f, name: new)
        try deleteSource(f, name: "photo0.dng")
        let result = try mirror.runOnce(maxFiles: 25)
        XCTAssertFalse(result.blocked)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: f.destination.appendingPathComponent("photo0.dng").path))
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent(old)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: collision), occupiedBytes)
        XCTAssertTrue(try f.journal.hasPendingNameRectification())
        XCTAssertTrue(try f.journal.pending().contains {
            $0.kind == .delete && $0.relativePath == new
        })
    }

    func testOldDeletionBeforeArmingIsNeverExecuted() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try deleteSource(f, name: "photo0.dng")
        let mirror = try worker(f, recover: false)
        let summary = try mirror.runOnce()
        XCTAssertEqual(summary.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
    }

    func testRecoverForeverMovesInsteadOfRemovingAndNeverExpires() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: true, days: nil)
        try deleteSource(f, name: "photo0.dng")
        let result = try mirror.runOnce()
        XCTAssertEqual(result.recovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
        let recovery = f.destination.appendingPathComponent(".macsync-recovery")
        let uuids = try FileManager.default.contentsOfDirectory(atPath: recovery.path)
        XCTAssertEqual(uuids.count, 1)
        let stored = recovery.appendingPathComponent(uuids[0])
            .appendingPathComponent("photo0.dng")
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "simulated image 0")
        XCTAssertEqual(
            try mirror.pruneExpiredRecovery(now: Date().addingTimeInterval(500 * 86_400)), 0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    func testOneDayRecoveryExpiresOnlyManifestOwnedFiles() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: true, days: 1)
        try deleteSource(f, name: "photo0.dng")
        XCTAssertEqual(try mirror.runOnce().recovered, 1)
        let recovery = f.destination.appendingPathComponent(".macsync-recovery")
        let uuid = try FileManager.default.contentsOfDirectory(atPath: recovery.path)[0]
        let stored = recovery.appendingPathComponent(uuid).appendingPathComponent("photo0.dng")
        XCTAssertEqual(try mirror.pruneExpiredRecovery(), 0)
        XCTAssertEqual(
            try mirror.pruneExpiredRecovery(now: Date().addingTimeInterval(2 * 86_400)), 1
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo1.dng").path
        ))
    }

    func testRecoveryExpiryAfterRestartWhenSourceIsEmpty() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let firstSession = try worker(f, recover: true, days: 1)
        try deleteSource(f, name: "photo0.dng")
        try deleteSource(f, name: "photo1.dng")
        XCTAssertEqual(try firstSession.runOnce().recovered, 2)

        // Next session sees an intentionally empty but accessible source.
        // It must NOT enable new mirror deletes without a baseline, yet it
        // should still honor the expiry of previously recovered files.
        let nextSession = try worker(f, recover: true, days: 1)
        XCTAssertEqual(
            try nextSession.pruneExpiredRecovery(
                now: Date().addingTimeInterval(2 * 86_400)
            ), 2
        )
    }

    func testModifiedRecoveryIsNotAutomaticallyPurged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: true, days: 1)
        try deleteSource(f, name: "photo0.dng")
        XCTAssertEqual(try mirror.runOnce().recovered, 1)
        let recovery = f.destination.appendingPathComponent(".macsync-recovery")
        let uuid = try FileManager.default.contentsOfDirectory(atPath: recovery.path)[0]
        let stored = recovery.appendingPathComponent(uuid).appendingPathComponent("photo0.dng")
        try Data("edited by user".utf8).write(to: stored)
        XCTAssertEqual(
            try mirror.pruneExpiredRecovery(now: Date().addingTimeInterval(2 * 86_400)), 0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    func testMassDeletionIsBlockedBeforeAnyRemoval() throws {
        let f = try fixture(fileCount: 50)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        for index in 0..<30 {
            try deleteSource(f, name: "photo\(index).dng")
        }
        let outcome = try mirror.runOnce()
        XCTAssertTrue(outcome.blocked)
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
    }

    func testSmallRepeatedBatchesCannotBypassMassDeletionThreshold() throws {
        let f = try fixture(fileCount: 200)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        for index in 0..<20 {
            try deleteSource(f, name: "photo\(index).dng")
        }
        XCTAssertEqual(try mirror.runOnce(maxFiles: 25).removed, 20)

        // A second group would exceed the protected fraction when combined
        // with the 20 deletions already applied in the SAME session.
        for index in 20..<40 {
            try deleteSource(f, name: "photo\(index).dng")
        }
        let stopped = try mirror.runOnce()
        XCTAssertTrue(stopped.blocked)
        XCTAssertEqual(stopped.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo20.dng").path
        ))
    }

    func testSourceUnavailableSuspendsDeletionWithoutLosingJob() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        try deleteSource(f, name: "photo0.dng")
        let offline = f.base.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: f.source, to: offline)
        let outcome = try mirror.runOnce()
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertGreaterThan(outcome.deferred, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
    }

    func testSymlinkDestinationIsNeverDeleted() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let external = f.base.appendingPathComponent("external.txt")
        try Data("external file".utf8).write(to: external)
        let mirrored = f.destination.appendingPathComponent("photo0.dng")
        try FileManager.default.removeItem(at: mirrored)
        try FileManager.default.createSymbolicLink(at: mirrored, withDestinationURL: external)
        let mirror = try worker(f, recover: false)
        try deleteSource(f, name: "photo0.dng")
        let outcome = try mirror.runOnce()
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertGreaterThan(outcome.deferred, 0)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "external file")
    }

    func testRecreatedSourceBlocksStaleDelete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let mirror = try worker(f, recover: false)
        try deleteSource(f, name: "photo0.dng")
        try Data("reappeared".utf8).write(to: f.source.appendingPathComponent("photo0.dng"))
        let result = try mirror.runOnce()
        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
    }

    func testStoppingMirrorSessionLeavesPendingDeletionAndTargetUnchanged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let cancel = MirrorDeletionCancellation()
        let mirror = try MirrorDeletionWorker(
            journal: f.journal, manifest: f.manifest, log: f.log,
            mappings: [f.mapping],
            policy: MirrorDeletionPolicy(enabled: true, recoveryEnabled: false,
                                         retentionDays: nil),
            cancellation: cancel
        )
        try deleteSource(f, name: "photo0.dng")
        cancel.cancel() // Simulates pressing "Ferma copie" before the next cycle.
        let outcome = try mirror.runOnce()
        XCTAssertTrue(outcome.blocked)
        XCTAssertEqual(outcome.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.destination.appendingPathComponent("photo0.dng").path
        ))
        XCTAssertTrue(try f.journal.pending().contains(where: {
            $0.kind == .delete && $0.relativePath == "photo0.dng"
        }))
        // Reinitializing the app cannot silently replay a deletion from the
        // previous session, since the new worker arms after that event.
        let restarted = try worker(f, recover: false)
        XCTAssertEqual(try restarted.runOnce().removed, 0)
    }

    func testNonEmptyDestinationFolderIsNeverRecursivelyRemoved() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let srcDir = f.source.appendingPathComponent("album")
        let dstDir = f.destination.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        // This file was created by a server user, not by the iMac.
        let untracked = dstDir.appendingPathComponent("important-server-file.txt")
        try Data("keep".utf8).write(to: untracked)
        _ = try LocalInventory(path: f.database)
            .reconcile(rootID: "photos", root: f.source)
        let mirror = try worker(f, recover: false)
        try FileManager.default.removeItem(at: srcDir)
        _ = try LocalInventory(path: f.database)
            .reconcile(rootID: "photos", root: f.source, subtree: srcDir)

        let outcome = try mirror.runOnce()
        XCTAssertEqual(outcome.directories, 0)
        XCTAssertGreaterThan(outcome.deferred, 0)
        XCTAssertEqual(try String(contentsOf: untracked, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dstDir.path))
    }

    func testDirectoriesAreRemovedOnlyWhenEmpty() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let srcDir = f.source.appendingPathComponent("album")
        let dstDir = f.destination.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: srcDir.appendingPathComponent("a.jpg"))
        try Data("image".utf8).write(to: dstDir.appendingPathComponent("a.jpg"))
        let sourceScan = try LocalScanner.scan(root: f.source)
        XCTAssertTrue(sourceScan.contains(where: { $0.relativePath == "album/a.jpg" }),
            "Scanner missed nested image: \(sourceScan.map { $0.relativePath })")
        let inventory = try LocalInventory(path: f.database)
        _ = try inventory.reconcile(rootID: "photos", root: f.source)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 4, "Nested source inventory incomplete")
        let mirror = try worker(f, recover: false)
        try FileManager.default.removeItem(at: srcDir)
        try LocalInventory(path: f.database).reconcile(rootID: "photos", root: f.source, subtree: srcDir)
        let pending = try f.journal.pending().filter { $0.kind == .delete }
        XCTAssertEqual(pending.count, 2, "Expected child and parent DELETE entries; got \(pending.map { $0.relativePath })")
        let summary = try mirror.runOnce()
        let warnings = try f.log.recent(limit: 20).map { $0.action + ": " + $0.message }.joined(separator: " | ")
        XCTAssertEqual(summary.removed, 1, "deferred=\(summary.deferred) blocked=\(summary.blocked) \(summary.detail) warnings=\(warnings)")
        XCTAssertEqual(summary.directories, 1, "deferred=\(summary.deferred) warnings=\(warnings)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dstDir.path))
    }
    private func persistentWorker(_ f: Fixture, authorization: MirrorAuthorization,
                                  protections: MirrorProtectionSettings = MirrorProtectionSettings(),
                                  mappings: [MountedFolderMapping]? = nil,
                                  cancellation: MirrorDeletionCancellation = MirrorDeletionCancellation()) throws -> MirrorDeletionWorker {
        try MirrorDeletionWorker(journal: ChangeJournal(path: f.database),
            manifest: RecoveryManifest(path: f.database), log: SyncActivityLog(path: f.database),
            mappings: mappings ?? [f.mapping],
            policy: MirrorDeletionPolicy(enabled: true, recoveryEnabled: false, retentionDays: nil),
            cancellation: cancellation, authorization: authorization, protections: protections)
    }

    func testPersistentMirrorDefaultsAllOptionalProtectionOff() throws {
        let settings = MirrorProtectionSettings()
        XCTAssertFalse(settings.absoluteEnabled)
        XCTAssertFalse(settings.fractionEnabled)
        XCTAssertFalse(settings.emptyEnabled)
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(settings.windowHours, 24)
    }

    func testPersistentMirrorProcessesMoreThanThousandDeletesWithoutLimitIncludingEmptySource() throws {
        let f = try fixture(fileCount: 1005)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        for i in 0..<1005 {
            try FileManager.default.removeItem(at: f.source.appendingPathComponent("photo\(i).dng"))
        }
        _ = try LocalInventory(path: f.database).reconcile(rootID: "photos", root: f.source)
        let mirror = try persistentWorker(f, authorization: authorization)
        let result = try mirror.runCycle(pageSize: 37)
        XCTAssertEqual(result.removed, 1005)
        XCTAssertEqual(result.deferred, 0)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    }

    func testPersistentAuthorizationResumesAfterRestartButNeverReplaysPreConsentDeletes() throws {
        let f = try fixture(fileCount: 4)
        defer { try? FileManager.default.removeItem(at: f.base) }
        try deleteSource(f, name: "photo0.dng")
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        let serialized = try JSONEncoder().encode(authorization)
        try deleteSource(f, name: "photo1.dng")
        let cancellation = MirrorDeletionCancellation()
        let first = try persistentWorker(f, authorization: authorization, cancellation: cancellation)
        cancellation.cancel()
        XCTAssertEqual(try first.runCycle().removed, 0)
        let decoded = try JSONDecoder().decode(MirrorAuthorization.self, from: serialized)
        let reopened = try MountedFolderMapping(rootID: "photos", source: f.source, target: f.destination)
        let restarted = try persistentWorker(f, authorization: decoded, mappings: [reopened])
        XCTAssertEqual(try restarted.runCycle().removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo0.dng").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo1.dng").path))
        XCTAssertEqual(try f.journal.pending().map(\.relativePath), ["photo0.dng"])
    }

    func testNewConsentDoesNotReplayDeletesCreatedWhileMirrorDisabled() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        try deleteSource(f, name: "photo0.dng")
        let newConsent = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        XCTAssertEqual(try persistentWorker(f, authorization: newConsent).runCycle().removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo0.dng").path))
    }

    func testV019AuditQueuesExtrasAndNewConsentDeletesOnlyAbsentPaths() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let dir = f.destination.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try Data("extra".utf8).write(to:dir.appendingPathComponent("child.dng"))
        try deleteSource(f,name:"photo0.dng")
        try f.journal.verifyDirectoryBindings([f.mapping],allowNewTarget:true)
        let audit = try ArchiveAudit(journal:f.journal,mappings:[f.mapping])
        let report = try audit.run(mode:.quick,repair:true,queueMirrorExtras:true)
        XCTAssertEqual(report.deletionCandidates?.count,3)
        XCTAssertEqual(report.displayCounts?.deletionFiles,2)
        XCTAssertEqual(report.displayCounts?.deletionDirectories,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.path))
        XCTAssertEqual(try f.journal.pending().filter{$0.kind == .delete}.count,3)
        let repeated = try audit.run(mode:.intelligent,repair:true,queueMirrorExtras:true)
        XCTAssertEqual(repeated.deletionCandidates?.count,3)
        XCTAssertEqual(try f.journal.pending().filter{$0.kind == .delete}.count,3)
        let consent = try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping],includePendingDeletes:true)
        let result = try persistentWorker(f,authorization:consent).runCycle()
        XCTAssertEqual(result.removed,2)
        XCTAssertEqual(result.directories,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.destination.appendingPathComponent("photo1.dng").path))
    }

    func testV0192LiteralExtrasDeleteOnlyExactVisiblePaths() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let old=f.destination.appendingPathComponent("Foto12345.")
        try FileManager.default.createDirectory(at:old,withIntermediateDirectories:true)
        try Data("old".utf8).write(to:old.appendingPathComponent("photo.jpg"))
        let alias=f.destination.appendingPathComponent("photo0.dng.")
        try Data("keep alias".utf8).write(to:alias)
        try f.journal.verifyDirectoryBindings([f.mapping],allowNewTarget:true)
        let report=try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.quick,repair:true,queueMirrorExtras:true)
        XCTAssertEqual(report.deletionCandidates,Set(["photos\0Foto12345.","photos\0Foto12345./photo.jpg"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:old.path))
        let consent=try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping],includePendingDeletes:true)
        let result=try persistentWorker(f,authorization:consent).runCycle()
        XCTAssertEqual(result.removed,1)
        XCTAssertEqual(result.directories,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:old.path))
        XCTAssertEqual(try Data(contentsOf:alias),Data("keep alias".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.destination.appendingPathComponent("photo0.dng").path))
    }

    func testV0192LiteralRecoveryAndInvisibleNamesRemainPending() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let old=f.destination.appendingPathComponent("old.")
        try Data("old".utf8).write(to:old)
        try f.journal.verifyDirectoryBindings([f.mapping],allowNewTarget:true)
        _ = try ArchiveAudit(journal:f.journal,mappings:[f.mapping]).run(mode:.quick,repair:true,queueMirrorExtras:true)
        _ = try f.journal.enqueue(rootID:"photos",relativePath:"invisible.",kind:.delete,origin:.sourceMonitor)
        let consent=try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping],includePendingDeletes:true)
        let recoveryWorker=try MirrorDeletionWorker(journal:f.journal,manifest:f.manifest,log:f.log,
            mappings:[f.mapping],policy:MirrorDeletionPolicy(enabled:true,recoveryEnabled:true,retentionDays:nil),authorization:consent)
        XCTAssertEqual(try recoveryWorker.runCycle().removed,0)
        XCTAssertTrue(FileManager.default.fileExists(atPath:old.path))
        let result=try persistentWorker(f,authorization:consent).runCycle()
        XCTAssertEqual(result.removed,1)
        XCTAssertTrue(try f.journal.pending().contains{$0.relativePath=="invisible."})
    }

    func testV019RecreatedAuditExtraSupersedesDelete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let name="returned.dng"
        try Data("old".utf8).write(to:f.destination.appendingPathComponent(name))
        try f.journal.verifyDirectoryBindings([f.mapping],allowNewTarget:true)
        let audit=try ArchiveAudit(journal:f.journal,mappings:[f.mapping])
        _ = try audit.run(mode:.quick,repair:true,queueMirrorExtras:true)
        XCTAssertEqual(try f.journal.pending().filter{$0.relativePath == name}.map(\.kind),[.delete])
        let path=f.source.appendingPathComponent(name)
        try Data("new".utf8).write(to:path)
        try LocalInventory(path:f.database).reconcile(rootID:"photos",root:f.source,subtree:path)
        XCTAssertEqual(try f.journal.pending().filter{$0.relativePath == name}.map(\.kind),[.upsert])
        let consent=try MirrorAuthorization.capture(journal:f.journal,mappings:[f.mapping],includePendingDeletes:true)
        XCTAssertEqual(try persistentWorker(f,authorization:consent).runCycle().removed,0)
        XCTAssertEqual(try Data(contentsOf:f.destination.appendingPathComponent(name)),Data("old".utf8))
    }

    func testPersistentConsentCannotBindReplacedDestinationOrDatabase() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        let secondDB = f.base.appendingPathComponent("other.sqlite").path
        _ = try LocalInventory(path: secondDB).reconcile(rootID: "photos", root: f.source)
        XCTAssertThrowsError(try MirrorDeletionWorker(journal: ChangeJournal(path: secondDB),
            manifest: RecoveryManifest(path: secondDB), log: SyncActivityLog(path: secondDB),
            mappings: [f.mapping], policy: MirrorDeletionPolicy(enabled: true, recoveryEnabled: false, retentionDays: nil),
            authorization: authorization))
        try deleteSource(f, name: "photo0.dng")
        try FileManager.default.moveItem(at: f.destination, to: f.base.appendingPathComponent("previous-destination"))
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        let unrelated = f.destination.appendingPathComponent("photo0.dng")
        try Data("unrelated".utf8).write(to: unrelated)
        let replacement = try MountedFolderMapping(rootID: "photos", source: f.source, target: f.destination)
        XCTAssertThrowsError(try persistentWorker(f, authorization: authorization, mappings: [replacement]))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated")
    }

    func testStaleLocalInventoryCannotBeAuthorized() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("photo0.dng"))
        XCTAssertThrowsError(try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping]))
    }

    func testOptionalAbsoluteLockPersistsEvenIfProtectionTurnedOffAndWindowExpires() throws {
        let f = try fixture(fileCount: 4)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        var settings = MirrorProtectionSettings()
        settings.absoluteEnabled = true
        settings.absoluteLimit = 2
        try deleteSource(f, name: "photo0.dng")
        try deleteSource(f, name: "photo1.dng")
        let first = try persistentWorker(f, authorization: authorization, protections: settings)
        XCTAssertThrowsError(try first.verifyBeforeSynchronization())
        XCTAssertNotNil(try f.journal.mirrorBlockReason())
        // Both targets remain; pre-copy verification caused no mutation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo0.dng").path))
        let restarted = try persistentWorker(f, authorization: authorization)
        XCTAssertThrowsError(try restarted.verifyBeforeSynchronization(now: Date().addingTimeInterval(72*3600)))
        try f.journal.clearMirrorBlock()
        XCTAssertEqual(try restarted.runCycle().removed, 2)
        XCTAssertNil(try f.journal.mirrorBlockReason())
    }

    func testRollingWindowIncludesRecentAttemptsButAllowsNormalOldHistory() throws {
        let f = try fixture(fileCount: 10)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        var settings = MirrorProtectionSettings()
        settings.absoluteEnabled = true
        settings.absoluteLimit = 3
        try deleteSource(f, name: "photo0.dng")
        try deleteSource(f, name: "photo1.dng")
        XCTAssertEqual(try persistentWorker(f, authorization: authorization, protections: settings).runCycle().removed, 2)
        try deleteSource(f, name: "photo2.dng")
        let restarted = try persistentWorker(f, authorization: authorization, protections: settings)
        XCTAssertNoThrow(try restarted.verifyBeforeSynchronization(now: Date().addingTimeInterval(25*3600)))
        XCTAssertThrowsError(try restarted.verifyBeforeSynchronization())
        XCTAssertNotNil(try f.journal.mirrorBlockReason())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo2.dng").path))
    }

    func testFractionAndEmptyProtectionsAreIndependent() throws {
        let f = try fixture(fileCount: 4)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        var fraction = MirrorProtectionSettings()
        fraction.fractionEnabled = true
        fraction.percentLimit = 50
        try deleteSource(f, name: "photo0.dng")
        XCTAssertNoThrow(try persistentWorker(f, authorization: authorization, protections: fraction).verifyBeforeSynchronization())
        try deleteSource(f, name: "photo1.dng")
        XCTAssertThrowsError(try persistentWorker(f, authorization: authorization, protections: fraction).verifyBeforeSynchronization())
        try f.journal.clearMirrorBlock()
        var empty = MirrorProtectionSettings()
        empty.emptyEnabled = true
        XCTAssertNoThrow(try persistentWorker(f, authorization: authorization, protections: empty).verifyBeforeSynchronization())
        try deleteSource(f, name: "photo2.dng")
        try deleteSource(f, name: "photo3.dng")
        XCTAssertThrowsError(try persistentWorker(f, authorization: authorization, protections: empty).verifyBeforeSynchronization())
        XCTAssertTrue(try XCTUnwrap(f.journal.mirrorBlockReason()).contains("vuota"))
    }

    func testProtectionEvaluatedPerPairButLatchBlocksAllPairs() throws {
        let f = try fixture(fileCount: 4)
        defer { try? FileManager.default.removeItem(at: f.base) }
        let source2 = f.base.appendingPathComponent("source2"), target2 = f.base.appendingPathComponent("target2")
        try FileManager.default.createDirectory(at: source2, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target2, withIntermediateDirectories: false)
        for i in 0..<4 {
            let name = "image\(i).psd"
            try Data("second pair".utf8).write(to: source2.appendingPathComponent(name))
            try Data("second pair".utf8).write(to: target2.appendingPathComponent(name))
        }
        let inv = try LocalInventory(path: f.database)
        _ = try inv.reconcile(rootID: "second", root: source2)
        for job in try f.journal.pendingUploads() { try f.journal.markCompleted(id: job.id) }
        let second = try MountedFolderMapping(rootID: "second", source: source2, target: target2)
        let maps = [f.mapping, second]
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: maps)
        var settings = MirrorProtectionSettings()
        settings.absoluteEnabled = true
        settings.absoluteLimit = 3
        for i in 0..<2 {
            try deleteSource(f, name: "photo\(i).dng")
            try FileManager.default.removeItem(at: source2.appendingPathComponent("image\(i).psd"))
        }
        _ = try inv.reconcile(rootID: "second", root: source2)
        let mirror = try persistentWorker(f, authorization: authorization, protections: settings, mappings: maps)
        XCTAssertNoThrow(try mirror.verifyBeforeSynchronization()) // two per pair, not four globally
        try deleteSource(f, name: "photo2.dng")
        XCTAssertThrowsError(try mirror.runCycle())
        XCTAssertTrue(FileManager.default.fileExists(atPath: target2.appendingPathComponent("image0.psd").path))
        XCTAssertTrue(try XCTUnwrap(f.journal.mirrorBlockReason()).contains("photos"))
    }

    func testPersistentMirrorStillWaitsForUploadsAndBlocksStaleOrRecreatedSource() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let authorization = try MirrorAuthorization.capture(journal: f.journal, mappings: [f.mapping])
        let mirror = try persistentWorker(f, authorization: authorization)
        try deleteSource(f, name: "photo0.dng")
        let job = try f.journal.enqueue(rootID: "photos", relativePath: "new.psd", kind: .upsert)
        XCTAssertTrue(try mirror.runCycle().blocked)
        try f.journal.markCompleted(id: job)
        try Data("recreated".utf8).write(to: f.source.appendingPathComponent("photo0.dng"))
        XCTAssertEqual(try mirror.runCycle().removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("photo0.dng").path))
    }

}
