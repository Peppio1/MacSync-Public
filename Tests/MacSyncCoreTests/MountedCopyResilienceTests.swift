import Foundation
import XCTest
@testable import MacSyncCore

final class MountedCopyResilienceTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let src: URL
        let dst: URL
        let db: String
        let mapping: MountedFolderMapping
    }
    private enum SimulatedFailure: Error { case connectionLost }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-resilience-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let src = base.appendingPathComponent("source")
        let dst = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let db = base.appendingPathComponent("state.sqlite").path
        try write("new image content", to: src.appendingPathComponent("photo.psd"))
        let journal = try ChangeJournal(path: db)
        try journal.enqueue(rootID: "photos", relativePath: "photo.psd", kind: .upsert)
        return Fixture(base: base, src: src, dst: dst, db: db,
            mapping: try MountedFolderMapping(rootID: "photos", source: src, target: dst))
    }
    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: url.path
        )
    }
    private func worker(_ f: Fixture, capacity: Int64? = nil) throws -> MountedFolderCopyWorker {
        try MountedFolderCopyWorker(journal: ChangeJournal(path: f.db),
            log: SyncActivityLog(path: f.db), mappings: [f.mapping],
            availableCapacity: { _ in capacity })
    }
    private func pending(_ f: Fixture) throws -> [QueuedChange] {
        try ChangeJournal(path: f.db).pending()
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testInterruptedStagingPreservesOldFileAndReopensQueue() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        do {
            let w = try worker(f)
            w.checkpoint = { phase, path in
                if phase == .beforeStageCopy {
                    try Data("partial".utf8).write(to: path)
                    throw SimulatedFailure.connectionLost
                }
            }
            XCTAssertEqual(try w.runOnce(enabled: true).failed, 1)
        }
        XCTAssertEqual(try read(target), "old original")
        XCTAssertEqual(try pending(f).count, 1)
        let stage = f.dst.appendingPathComponent(".macsync-staging")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path).count, 0)
        // A fresh worker + fresh SQLite connection emulate restart.
        XCTAssertEqual(try worker(f).runOnce(enabled: true).updated, 1)
        XCTAssertEqual(try read(target), "new image content")
        XCTAssertTrue(try pending(f).isEmpty)
    }

    func testRepeatedInterruptedCopiesDoNotAccumulateCurrentAttemptPartials() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        let stage = f.dst.appendingPathComponent(".macsync-staging")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let unrelated = stage.appendingPathComponent(UUID().uuidString + ".partial")
        try write("historical temporary", to: unrelated)
        for _ in 0..<3 {
            let w = try worker(f)
            w.checkpoint = { phase, url in
                if phase == .beforeStageCopy {
                    try Data("incomplete".utf8).write(to: url)
                    throw SimulatedFailure.connectionLost
                }
            }
            XCTAssertEqual(try w.runCycle(enabled: true).failed, 1)
            XCTAssertEqual(try pending(f).count, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.path), [unrelated.lastPathComponent])
            XCTAssertEqual(try read(target), "old original")
        }
        XCTAssertEqual(try worker(f).runCycle(enabled: true).updated, 1)
        XCTAssertTrue(try pending(f).isEmpty)
        XCTAssertEqual(try read(target), "new image content")
        XCTAssertEqual(try read(unrelated), "historical temporary")
    }

    func testStageChangedBeforeFailedCleanupIsRetained() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let w = try worker(f)
        var partial: URL?
        w.checkpoint = { phase, url in
            if phase == .beforeStageCopy {
                partial = url
                try Data("incomplete".utf8).write(to: url)
                throw SimulatedFailure.connectionLost
            }
            if phase == .beforeFailedStageCleanup {
                try self.write("externally changed temporary", to: url)
            }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).failed, 1)
        XCTAssertEqual(try read(XCTUnwrap(partial)), "externally changed temporary")
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertTrue(try SyncActivityLog(path: f.db).recent().contains { $0.action == "staging_retained" })
    }

    func testStageDirectoryReplacedBeforeCleanupIsNotTouched() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let stage = f.dst.appendingPathComponent(".macsync-staging")
        let detached = f.base.appendingPathComponent("detached")
        let w = try worker(f)
        var name: String?
        w.checkpoint = { phase, url in
            if phase == .beforeStageCopy {
                name = url.lastPathComponent
                try Data("incomplete".utf8).write(to: url)
                throw SimulatedFailure.connectionLost
            }
            if phase == .beforeFailedStageCleanup {
                try FileManager.default.moveItem(at: stage, to: detached)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                try self.write("unrelated replacement", to: stage.appendingPathComponent(url.lastPathComponent))
            }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).failed, 1)
        let expected = try XCTUnwrap(name)
        XCTAssertEqual(try read(stage.appendingPathComponent(expected)), "unrelated replacement")
        XCTAssertEqual(try read(detached.appendingPathComponent(expected)), "incomplete")
        XCTAssertEqual(try pending(f).count, 1)
    }

    func testUncertainPublicationDoesNotAttemptStageCleanup() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterPublish { throw SimulatedFailure.connectionLost }
            if phase == .beforeFailedStageCleanup { XCTFail("Publication was already attempted") }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).failed, 1)
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertEqual(try read(f.dst.appendingPathComponent("photo.psd")), "new image content")
    }

    func testSourceChangesAfterStageAreNeverPublished() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterStageCopy {
                try self.write("newer file under edit", to: f.src.appendingPathComponent("photo.psd"))
            }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try read(target), "old original")
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertEqual(try worker(f).runOnce(enabled: true).updated, 1)
        XCTAssertEqual(try read(target), "newer file under edit")
    }

    func testTargetChangesAfterBackupAreNotOverwritten() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterBackup { try self.write("another client's edit", to: target) }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try read(target), "another client's edit")
        XCTAssertEqual(try pending(f).count, 1)
        let backups = try FileManager.default.contentsOfDirectory(at: f.dst,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".macsync-backup-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try read(XCTUnwrap(backups.first)), "old original")
    }

    func testTargetAppearsWhileStagingDoesNotOverwrite() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterStageCopy { try self.write("arrived during copy", to: target) }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try read(target), "arrived during copy")
        XCTAssertEqual(try pending(f).count, 1)
    }

    func testDestinationReplacedMidTransferDoesNotWriteToNewRoot() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let old = f.base.appendingPathComponent("old-destination")
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterStageCopy {
                try FileManager.default.moveItem(at: f.dst, to: old)
                try FileManager.default.createDirectory(at: f.dst, withIntermediateDirectories: false)
            }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dst.path), [])
        XCTAssertEqual(try pending(f).count, 1)
    }

    func testSourceRootReplacementBlocksExistingMapping() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try FileManager.default.moveItem(at: f.src, to: f.base.appendingPathComponent("old-source"))
        try FileManager.default.createDirectory(at: f.src, withIntermediateDirectories: false)
        try write("unrelated photo", to: f.src.appendingPathComponent("photo.psd"))
        XCTAssertEqual(try worker(f).runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.dst.path), [])
    }

    func testDiskFullDefersWithoutCreatingStageOrOverwriting() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        XCTAssertEqual(try worker(f, capacity: 0).runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try read(target), "old original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dst.appendingPathComponent(".macsync-staging").path))
        XCTAssertEqual(try pending(f).count, 1)
    }

    func testFailedAcknowledgmentAfterPublicationKeepsQueueAndCanRetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterPublish { throw SimulatedFailure.connectionLost }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).failed, 1)
        XCTAssertEqual(try read(target), "new image content")
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertEqual(try worker(f).runOnce(enabled: true).updated, 1)
        XCTAssertTrue(try pending(f).isEmpty)
        XCTAssertEqual(try read(target), "new image content")
    }

    private func backups(_ f: Fixture) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: f.dst, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".macsync-backup-") }
    }

    func testCleanupRunsOnlyAfterDatabaseAcknowledgmentAndLeavesLegacyBackups() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("old original", to: f.dst.appendingPathComponent("photo.psd"))
        let legacy = f.dst.appendingPathComponent(".macsync-backup-" + UUID().uuidString)
        try write("legacy recovery", to: legacy)
        let w = try worker(f)
        var cleanupReached = false
        w.checkpoint = { phase, url in
            if phase == .beforeBackupCleanup {
                cleanupReached = true
                XCTAssertTrue(try self.pending(f).isEmpty)
                XCTAssertEqual(try self.read(url), "old original")
            }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).updated, 1)
        XCTAssertTrue(cleanupReached)
        XCTAssertEqual(try backups(f).map(\.lastPathComponent), [legacy.lastPathComponent])
        XCTAssertEqual(try read(legacy), "legacy recovery")
        XCTAssertEqual(try read(f.dst.appendingPathComponent("photo.psd")), "new image content")
    }

    func testInterruptedOverwriteRetainsBackupEvenAfterRetrySucceeds() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("old original", to: f.dst.appendingPathComponent("photo.psd"))
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterPublish { throw SimulatedFailure.connectionLost }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).failed, 1)
        let retained = try XCTUnwrap(backups(f).first)
        XCTAssertEqual(try read(retained), "old original")
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertEqual(try worker(f).runCycle(enabled: true).updated, 1)
        XCTAssertEqual(try backups(f).map(\.lastPathComponent), [retained.lastPathComponent])
        XCTAssertEqual(try read(retained), "old original")
    }

    func testSupersededAcknowledgmentCannotAuthorizeBackupDeletion() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("old original", to: f.dst.appendingPathComponent("photo.psd"))
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterPublish {
                try ChangeJournal(path: f.db).enqueue(rootID: "photos", relativePath: "photo.psd", kind: .upsert)
            }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).deferred, 1)
        XCTAssertEqual(try pending(f).count, 2)
        XCTAssertEqual(try read(XCTUnwrap(backups(f).first)), "old original")
    }

    func testCleanupFailureDoesNotRetryConfirmedTransfer() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("old original", to: f.dst.appendingPathComponent("photo.psd"))
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .beforeBackupCleanup { throw SimulatedFailure.connectionLost }
        }
        let outcome = try w.runCycle(enabled: true)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertTrue(try pending(f).isEmpty)
        XCTAssertEqual(try read(XCTUnwrap(backups(f).first)), "old original")
        XCTAssertTrue(try SyncActivityLog(path: f.db).recent().contains { $0.action == "backup_retained" })
        XCTAssertEqual(try worker(f).runCycle(enabled: true).copied, 0)
    }

    func testBackupChangedBeforeCleanupIsPreserved() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("old original", to: f.dst.appendingPathComponent("photo.psd"))
        let w = try worker(f)
        w.checkpoint = { phase, path in
            if phase == .beforeBackupCleanup { try self.write("externally changed backup", to: path) }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).updated, 1)
        XCTAssertEqual(try read(XCTUnwrap(backups(f).first)), "externally changed backup")
        XCTAssertTrue(try pending(f).isEmpty)
    }

    func testPublishedFileChangedBeforeCleanupPreservesBackup() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try write("old original", to: target)
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .beforeBackupCleanup { try self.write("external change", to: target) }
        }
        XCTAssertEqual(try w.runCycle(enabled: true).updated, 1)
        XCTAssertEqual(try read(XCTUnwrap(backups(f).first)), "old original")
        XCTAssertEqual(try read(target), "external change")
    }

    func testNewQueueEventDuringStagingPreventsOldPublication() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let w = try worker(f)
        w.checkpoint = { phase, _ in
            if phase == .afterStageCopy {
                try ChangeJournal(path: f.db).enqueue(rootID: "photos", relativePath: "photo.psd", kind: .delete)
            }
        }
        XCTAssertEqual(try w.runOnce(enabled: true).deferred, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.dst.appendingPathComponent("photo.psd").path))
        XCTAssertEqual(try pending(f).count, 2)
    }

    func testDanglingSymlinkAndReservedNamesAreBlocked() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let target = f.dst.appendingPathComponent("photo.psd")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.base.appendingPathComponent("missing"))
        XCTAssertEqual(try worker(f).runOnce(enabled: true).failed, 1)
        XCTAssertEqual(try pending(f).count, 1)
        XCTAssertThrowsError(try f.mapping.fileURL(relativePath: ".MACSYNC-staging/intruder", destination: true))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), f.base.appendingPathComponent("missing").path)
    }
}
