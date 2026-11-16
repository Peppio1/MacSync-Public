import Foundation
import XCTest
@testable import MacSyncCore

/// Synthetic scenario for a network share disappearing at login and
/// returning later. Uses TWO LOCAL test directories only. Actual SMB
/// credential reuse, mount reconnect and network latency still require Mac.
final class AutomaticCopyRecoveryScenarioTests: XCTestCase {
    func testLoginOfflineThenReconnectCopiesOnlyWithoutMirrorDeletion() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("MacSync-auto-scenario-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let destination = base.appendingPathComponent("destination")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("photo.psd")
        try Data("simulated work".utf8).write(to: file)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: file.path
        )
        let serverOnly = destination.appendingPathComponent("file-previously-deleted.jpg")
        try Data("server keeps this".utf8).write(to: serverOnly)

        let db = base.appendingPathComponent("state.sqlite").path
        _ = try LocalInventory(path: db).reconcile(rootID: "photos", root: source)
        let journal = try ChangeJournal(path: db)
        let log = try SyncActivityLog(path: db)
        try journal.enqueue(
            rootID: "photos", relativePath: "file-previously-deleted.jpg", kind: .delete
        )
        let expected = try VolumeFingerprint.read(at: destination)
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: source, target: destination,
            expectedTargetVolume: expected
        )
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: log, mappings: [mapping]
        )

        // A pending COPY and a DELETE exist when the user logs in.
        // Only the COPY worker is started by the automatic mode.
        let configured = AutomaticCopyPair(
            sourcePath: source.path, destinationPath: destination.path,
            expectedVolume: expected
        )
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: false, monitorRunning: true, copyActive: false,
            pairs: [configured]
        ), .disabled)

        let offlineDirectory = base.appendingPathComponent("temporarily-offline")
        try fm.moveItem(at:destination,to:offlineDirectory)
        XCTAssertEqual(
            DestinationProbe.inspect(path: destination.path, expectedVolume: expected),
            .unavailable
        )
        // A stale worker cannot silently recreate the remote mount path.
        let offline = try worker.runOnce(enabled: true)
        XCTAssertEqual(offline.created, 0)
        XCTAssertEqual(offline.deferred, 1)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))

        // Restore the exact same local directory and data. Deleting and
        // recreating it would simulate replacement, not reconnection.
        try fm.moveItem(at:offlineDirectory,to:destination)
        XCTAssertEqual(DestinationProbe.inspect(
            path: destination.path, expectedVolume: expected
        ), .ready)
        let copied = try worker.runOnce(enabled: true)
        XCTAssertEqual(copied.created, 1)
        XCTAssertEqual(copied.updated, 0)
        XCTAssertEqual(copied.failed, 0)
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("photo.psd"),
                       encoding: .utf8),
            "simulated work"
        )
        // Auto mode never consumes a deletion, regardless of a persisted
        // mirror setting. Previously deleted server file remains intact.
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent(
                    "file-previously-deleted.jpg"
                ), encoding: .utf8),
            "server keeps this"
        )
        let pending = try journal.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.kind, .delete)
    }
}
