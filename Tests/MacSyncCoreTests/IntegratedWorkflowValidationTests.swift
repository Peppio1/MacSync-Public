import Foundation
import XCTest
@testable import MacSyncCore

/// Integrated motor validation on isolated macOS directories only.
/// Moving the destination parent models loss of path availability, not SMB.
final class IntegratedWorkflowValidationTests: XCTestCase {
    func testTwoMappingsOfflineChangesVerifiedRestoreReconnectAndDeepAudit() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacSync-integrated-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let sourceA = base.appendingPathComponent("source-a")
        let sourceB = base.appendingPathComponent("source-b")
        let destination = base.appendingPathComponent("destination")
        let targetA = destination.appendingPathComponent("target-a")
        let targetB = destination.appendingPathComponent("target-b")
        for url in [sourceA, sourceB, targetA, targetB] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let db = base.appendingPathComponent("state.sqlite")
        let journal = try ChangeJournal(path: db.path)
        let inventory = try LocalInventory(path: db.path)
        let log = try SyncActivityLog(path: db.path)
        let maps = try [
            MountedFolderMapping(rootID: "a", source: sourceA, target: targetA),
            MountedFolderMapping(rootID: "b", source: sourceB, target: targetB)
        ]
        func put(_ root: URL, _ name: String, _ bytes: Data) throws {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url, options: .atomic)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)], ofItemAtPath: url.path)
        }
        func reconcile() throws {
            _ = try inventory.reconcile(rootID: "a", root: sourceA)
            _ = try inventory.reconcile(rootID: "b", root: sourceB)
        }
        let original = Data(repeating: 0x41, count: 2 * 1024 * 1024)
        let changed = Data(repeating: 0x42, count: original.count)
        let other = Data("different root, same filename".utf8)
        let obsolete = Data("retain with mirror disabled".utf8)
        let newPhoto = Data(repeating: 0x43, count: 25 * 1024 * 1024)
        try put(sourceA, "shared.jpg", original)
        try put(sourceA, "obsolete.jpg", obsolete)
        try put(sourceB, "shared.jpg", other)
        try reconcile()
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: maps,
                                                 availableCapacity: { _ in nil })
        let baseline = try worker.runCycle(enabled: true)
        XCTAssertEqual(baseline.created, 3)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: targetA.appendingPathComponent("shared.jpg")), original)
        XCTAssertEqual(try Data(contentsOf: targetB.appendingPathComponent("shared.jpg")), other)

        let offline = base.appendingPathComponent("offline")
        try fm.moveItem(at: destination, to: offline)
        try put(sourceA, "shared.jpg", changed)
        try fm.removeItem(at: sourceA.appendingPathComponent("obsolete.jpg"))
        try put(sourceB, "new.dng", newPhoto)
        try reconcile()
        let pending = try journal.pending()
        XCTAssertEqual(pending.filter { $0.kind == .upsert }.count, 2)
        XCTAssertEqual(pending.filter { $0.kind == .delete }.count, 1)
        let blocked = try worker.runCycle(enabled: true)
        XCTAssertEqual(blocked.copied, 0)
        XCTAssertTrue(blocked.interrupted)
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertEqual(try journal.pending().map(\.id), pending.map(\.id))
        XCTAssertEqual(try Data(contentsOf: offline.appendingPathComponent("target-a/shared.jpg")), original)

        // Exercise a standalone backup and a separate restored journal.
        // The original archive is never overwritten during this test.
        let backup = base.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(db, to: backup)
        try ArchiveDatabaseSafety.verify(backup, readOnly: true)
        let restored = base.appendingPathComponent("restored.sqlite")
        try fm.copyItem(at: backup, to: restored)
        let resumedJournal = try ChangeJournal(path: restored.path)
        XCTAssertEqual(try resumedJournal.pending(), try journal.pending())
        try fm.moveItem(at: offline, to: destination)
        let resumedMaps = try [
            MountedFolderMapping(rootID: "a", source: sourceA, target: targetA),
            MountedFolderMapping(rootID: "b", source: sourceB, target: targetB)
        ]
        let resumed = try MountedFolderCopyWorker(journal: resumedJournal,
            log: SyncActivityLog(path: restored.path), mappings: resumedMaps,
            availableCapacity: { _ in nil })
        let result = try resumed.runCycle(enabled: true)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.deferred, 0)
        XCTAssertTrue(try resumedJournal.pendingUploads().isEmpty)
        XCTAssertEqual(try resumedJournal.pending().filter { $0.kind == .delete }.count, 1)
        XCTAssertEqual(try Data(contentsOf: targetA.appendingPathComponent("shared.jpg")), changed)
        XCTAssertEqual(try Data(contentsOf: targetB.appendingPathComponent("shared.jpg")), other)
        XCTAssertEqual(try Data(contentsOf: targetB.appendingPathComponent("new.dng")), newPhoto)
        XCTAssertEqual(try Data(contentsOf: targetA.appendingPathComponent("obsolete.jpg")), obsolete)
        XCTAssertEqual(try resumed.runCycle(enabled: true).copied, 0)

        let beforeAudit = try resumedJournal.pending()
        let report = try ArchiveAudit(journal: resumedJournal, mappings: resumedMaps).run(mode: .deep)
        XCTAssertEqual(report.count(.matching), 3)
        XCTAssertEqual(report.count(.extra), 1)
        XCTAssertEqual(report.count(.missing), 0)
        XCTAssertEqual(report.count(.different), 0)
        XCTAssertEqual(report.queuedRepairs, 0)
        XCTAssertEqual(try resumedJournal.pending(), beforeAudit)
        XCTAssertEqual(try Data(contentsOf: targetA.appendingPathComponent("obsolete.jpg")), obsolete)
        XCTAssertEqual(try journal.pending().map(\.id), pending.map(\.id))
    }
}
