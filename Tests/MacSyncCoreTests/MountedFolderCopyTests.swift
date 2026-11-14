import Foundation
import XCTest
@testable import MacSyncCore

final class MountedFolderCopyTests: XCTestCase {
    private func setup() throws -> (base: URL, source: URL, target: URL, db: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-Mounted-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (base, source, target, base.appendingPathComponent("inventory.sqlite").path)
    }

    private func oldFile(_ url: URL, data: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(data.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)],
            ofItemAtPath: url.path
        )
    }

    func testLocalToLocalCopyUpdatesJournalAndHistory() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let image = fixture.source.appendingPathComponent("set 1/foto àè.dng")
        try oldFile(image, data: "image content")
        let journal = try ChangeJournal(path: fixture.db)
        let logger = try SyncActivityLog(path: fixture.db)
        try journal.enqueue(rootID: "photos", relativePath: "set 1/foto àè.dng", kind: .upsert)
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: logger, mappings: [mapping]
        )

        XCTAssertTrue(try worker.runOnce().disabled)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.target.appendingPathComponent("set 1/foto àè.dng").path
        ))
        let outcome = try worker.runOnce(enabled: true)
        XCTAssertEqual(outcome.copied, 1)
        XCTAssertEqual(outcome.failed, 0)
        XCTAssertEqual(outcome.bytes, 13)
        let target = fixture.target.appendingPathComponent("set 1/foto àè.dng")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "image content")
        XCTAssertEqual(try journal.pending().count, 0)
        let history = try logger.recent()
        XCTAssertEqual(history.first?.action, "copy")
        XCTAssertEqual(history.first?.relativePath, "set 1/foto àè.dng")
        XCTAssertTrue(try logger.exportText().contains("Nuovo file copiato"))
        XCTAssertEqual(outcome.created, 1)
        XCTAssertEqual(outcome.updated, 0)
    }

    func testStoppedSessionLeavesRemainingJobsForNextRun() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        for name in ["first.dng", "second.dng"] {
            try oldFile(fixture.source.appendingPathComponent(name), data: name)
        }
        let journal = try ChangeJournal(path: fixture.db)
        let log = try SyncActivityLog(path: fixture.db)
        for name in ["first.dng", "second.dng"] {
            try journal.enqueue(rootID: "photos", relativePath: name, kind: .upsert)
        }
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: log, mappings: [mapping]
        )
        var allowed = 1
        let first = try worker.runOnce(enabled: true, shouldContinue: {
            defer { allowed -= 1 }
            return allowed > 0
        })
        XCTAssertEqual(first.copied, 1)
        XCTAssertEqual(try journal.pending().count, 1)
        XCTAssertEqual(try worker.runOnce(enabled: true).copied, 1)
        XCTAssertTrue(try journal.pending().isEmpty)
    }

    func testMirrorDeletionJobsRemainPending() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try oldFile(fixture.source.appendingPathComponent("new.jpg"), data: "new")
        let journal = try ChangeJournal(path: fixture.db)
        let logger = try SyncActivityLog(path: fixture.db)
        try journal.enqueue(rootID: "photos", relativePath: "old.jpg", kind: .delete)
        try journal.enqueue(rootID: "photos", relativePath: "new.jpg", kind: .upsert)
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: logger, mappings: [mapping]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).copied, 1)
        XCTAssertEqual(try journal.pending().count, 1)
        XCTAssertEqual(try journal.pending()[0].kind, .delete)
    }

    func testSourceCannotContainDestinationOrBeInsideDestination() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        XCTAssertThrowsError(try MountedFolderMapping(
            rootID: "a", source: fixture.source,
            target: fixture.source.appendingPathComponent("child")
        ))
        XCTAssertThrowsError(try MountedFolderMapping(
            rootID: "a", source: fixture.source, target: fixture.source
        ))
        XCTAssertThrowsError(try MountedFolderMapping(
            rootID: "a", source: fixture.source, target: fixture.base
        ))
    }

    func testDestinationVolumeChangesAreRefused() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let identity = try VolumeFingerprint.read(at: fixture.target)
        XCTAssertFalse(identity.fileSystem.isEmpty)
        let wrong = VolumeFingerprint(
            fileSystem: "smbfs", mountPath: "/Volumes/not-attached"
        )
        XCTAssertThrowsError(try MountedFolderMapping(
            rootID: "a", source: fixture.source, target: fixture.target,
            expectedTargetVolume: wrong
        ))
        let valid = try MountedFolderMapping(
            rootID: "a", source: fixture.source, target: fixture.target,
            expectedTargetVolume: identity
        )
        XCTAssertNoThrow(try valid.verify())
    }

    func testMissingTargetCannotBecomeAnUnintendedLocalFolder() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try oldFile(fixture.source.appendingPathComponent("file.psd"), data: "important")
        let journal = try ChangeJournal(path: fixture.db)
        let log = try SyncActivityLog(path: fixture.db)
        try journal.enqueue(rootID: "photos", relativePath: "file.psd", kind: .upsert)
        let map = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: [map])
        try FileManager.default.removeItem(at: fixture.target)
        let outcome = try worker.runOnce(enabled: true)
        XCTAssertEqual(outcome.deferred, 1)
        XCTAssertEqual(try journal.pending().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.target.path))
        // Simulate the SAME destination becoming available again. A failed
        // attempt must not discard the job or invent a fallback folder.
        try FileManager.default.createDirectory(
            at: fixture.target, withIntermediateDirectories: true
        )
        let resumed = try worker.runOnce(enabled: true)
        XCTAssertEqual(resumed.created, 1)
        XCTAssertEqual(resumed.failed, 0)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(
            try String(contentsOf: fixture.target.appendingPathComponent("file.psd"),
                       encoding: .utf8), "important"
        )
    }

    func testUnsafeRelativePathsAreRejected() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let map = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        XCTAssertThrowsError(try map.fileURL(relativePath: "../outside", destination: true))
        XCTAssertThrowsError(try map.fileURL(relativePath: "photos/../../outside", destination: true))
        XCTAssertThrowsError(try map.fileURL(relativePath: "bad:filename.jpg", destination: true))
    }

    func testReconfigureSourceClearsOnlyThatRootsLocalQueue() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let next = fixture.base.appendingPathComponent("new-source")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try oldFile(fixture.source.appendingPathComponent("old.jpg"), data: "old")
        try oldFile(next.appendingPathComponent("new.jpg"), data: "new")
        let inventory = try LocalInventory(path: fixture.db)
        _ = try inventory.reconcile(rootID: "photo-uploads", root: fixture.source)
        XCTAssertEqual(try inventory.itemCount(rootID: "photo-uploads"), 1)
        try inventory.resetRootForNewSource(rootID: "photo-uploads", newRoot: next)
        XCTAssertEqual(try inventory.itemCount(rootID: "photo-uploads"), 0)
        _ = try inventory.reconcile(rootID: "photo-uploads", root: next)
        XCTAssertEqual(try inventory.itemCount(rootID: "photo-uploads"), 1)
        XCTAssertEqual(try ChangeJournal(path: fixture.db).pending().count, 1)
    }

    func testChangingTargetRequeuesCompleteLocalInventory() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try oldFile(fixture.source.appendingPathComponent("photo.jpg"), data: "one")
        let inventory = try LocalInventory(path: fixture.db)
        try inventory.reconcile(rootID: "photos", root: fixture.source)
        let journal = try ChangeJournal(path: fixture.db)
        for entry in try journal.pending() {
            try journal.markCompleted(id: entry.id)
        }
        XCTAssertTrue(try journal.pending().isEmpty)
        try inventory.requeueAllForNewDestination(rootID: "photos")
        let pending = try journal.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].kind, .upsert)
        XCTAssertEqual(pending[0].relativePath, "photo.jpg")
    }
    func testReplacingExistingFileKeepsOldBackup() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.source.appendingPathComponent("same-name.psd")
        let destination = fixture.target.appendingPathComponent("same-name.psd")
        try oldFile(source, data: "new version")
        try oldFile(destination, data: "old version")
        let journal = try ChangeJournal(path: fixture.db)
        let log = try SyncActivityLog(path: fixture.db)
        try journal.enqueue(rootID: "photos", relativePath: "same-name.psd", kind: .upsert)
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: [mapping])
        let outcome = try worker.runOnce(enabled: true)
        XCTAssertEqual(outcome.copied, 1)
        XCTAssertEqual(outcome.created, 0)
        XCTAssertEqual(outcome.updated, 1)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new version")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.target.path)
        XCTAssertTrue(names.contains(where: { $0.hasPrefix(".macsync-backup-") }))
    }

    func testReadOnlyMountedBaselineDoesNotAlterFilesOrQueue() throws {
        let fixture = try setup()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.source.appendingPathComponent("same.jpg")
        try oldFile(file, data: "same content")
        try FileManager.default.copyItem(
            at: file, to: fixture.target.appendingPathComponent("same.jpg")
        )
        try oldFile(fixture.target.appendingPathComponent("target-only.jpg"), data: "untouched")
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: fixture.source, target: fixture.target
        )
        let preview = try MountedBootstrapPreview.inspect(mapping: mapping)
        XCTAssertEqual(preview.candidateMatches, 1)
        XCTAssertEqual(preview.remoteOnlyPaths, ["target-only.jpg"])
        XCTAssertFalse(preview.isSafeForAutomaticProductionBootstrap)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.target.appendingPathComponent("target-only.jpg").path
        ))
        XCTAssertEqual(try ChangeJournal(path: fixture.db).pending().count, 0)
    }

}
