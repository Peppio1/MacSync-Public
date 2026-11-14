import Foundation
import XCTest
@testable import MacSyncCore

final class MirrorDeletionTests: XCTestCase {
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
}
