import Foundation
import XCTest
@testable import MacSyncCore

final class OfflineNamePreparationTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        let db: URL
        let inventory: LocalInventory
        let journal: ChangeJournal
    }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-offline-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let db = base.appendingPathComponent("state.sqlite")
        return Fixture(base: base, source: source, target: target, db: db,
                       inventory: try LocalInventory(path: db.path), journal: try ChangeJournal(path: db.path))
    }

    func testOneTime1200RectificationsBeforeExternalSeedAndQuickAudit() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let fm = FileManager.default
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let folders = 120, filesPerFolder = 9
        for i in 0..<folders {
            let folder = f.source.appendingPathComponent("folder-\(i) ")
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            for j in 0..<filesPerFolder {
                let file = folder.appendingPathComponent("photo-\(j)?.jpg")
                try Data([UInt8(i), UInt8(j)]).write(to: file)
                try fm.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
            }
        }
        f.inventory.experimentalOfflineNamePreparation = true
        let started = ProcessInfo.processInfo.systemUptime
        let initial = try f.inventory.reconcile(rootID: "photos", root: f.source, origin: .initialInventory)
        XCTAssertEqual(initial.queuedUpserts, 0)
        XCTAssertEqual(initial.queuedDeletes, 0)
        XCTAssertEqual(try f.inventory.pendingCount(), 0)
        let names = try f.inventory.incompatibleNames(rootID: "photos", sourcePath: f.source.path)
        XCTAssertEqual(names.count, 1200)
        let indexed = ProcessInfo.processInfo.systemUptime
        let result = try NameRectification.executeLocal(items: names, roots: ["photos": f.source.path],
            journal: f.journal, log: SyncActivityLog(path: f.db.path))
        XCTAssertEqual(result.renamed, 1200)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertFalse(try f.journal.hasPendingNameRectification())
        let renamed = ProcessInfo.processInfo.systemUptime
        let update = try f.inventory.reconcile(rootID: "photos", root: f.source, origin: .initialInventory)
        XCTAssertEqual(update.queuedUpserts, 0)
        XCTAssertEqual(update.queuedDeletes, 0)
        XCTAssertEqual(try f.inventory.pendingCount(), 0)
        XCTAssertTrue(try f.inventory.incompatibleNames(rootID: "photos", sourcePath: f.source.path).isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: f.target.path).isEmpty)
        let reconciled = ProcessInfo.processInfo.systemUptime
        // Model the one-time physical seed using disposable local directories.
        // No Rclone or SMB, no destination access during rectification.
        for i in 0..<folders {
            let folder = f.source.appendingPathComponent("folder-\(i)")
            let seeded = f.target.appendingPathComponent("folder-\(i)")
            try fm.copyItem(at: folder, to: seeded)
            for j in 0..<filesPerFolder {
                let name = "photo-\(j)-.jpg"
                let source = folder.appendingPathComponent(name)
                let target = seeded.appendingPathComponent(name)
                XCTAssertEqual(try Data(contentsOf: source), Data([UInt8(i), UInt8(j)]))
                XCTAssertEqual(try Data(contentsOf: target), Data([UInt8(i), UInt8(j)]))
                try fm.setAttributes([.modificationDate: fixed], ofItemAtPath: target.path)
            }
        }
        f.inventory.experimentalOfflineNamePreparation = false
        let mapping = try MountedFolderMapping(rootID: "photos", source: f.source, target: f.target)
        try f.journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let auditStart = ProcessInfo.processInfo.systemUptime
        let report = try SeededArchiveSession(database: f.db, mappings: [mapping])
            .auditPreservingQueuedChanges(mode: .quick, repair: true, reconcileOrdinaryJobs: true)
        XCTAssertEqual(report.queuedRepairs, 0)
        XCTAssertEqual(report.bytesRead, 0)
        XCTAssertEqual(try f.inventory.pendingCount(), 0)
        // The offline path cannot be used once a target is pinned.
        f.inventory.experimentalOfflineNamePreparation = true
        XCTAssertThrowsError(try f.inventory.reconcile(rootID: "photos", root: f.source, origin: .initialInventory))
        XCTAssertEqual(try f.inventory.pendingCount(), 0)
        print("OFFLINE_PREP_1200 folders=\(folders) files=\(folders * filesPerFolder) inventory=\(indexed-started) rectify=\(renamed-indexed) reconcile=\(reconciled-renamed) audit=\(ProcessInfo.processInfo.systemUptime-auditStart) pending=0")
    }

    func testOfflinePreparationRejectsOrdinaryEventsAndExistingQueueHistory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let file = f.source.appendingPathComponent("photo?.jpg")
        try Data([1]).write(to: file)
        f.inventory.experimentalOfflineNamePreparation = true
        XCTAssertThrowsError(try f.inventory.reconcile(rootID: "photos", root: f.source, eventID: 1))
        XCTAssertThrowsError(try f.inventory.reconcile(rootID: "photos", root: f.source, subtree: file, origin: .initialInventory))
        XCTAssertEqual(try f.inventory.pendingCount(), 0)
        f.inventory.experimentalOfflineNamePreparation = false
        _ = try f.inventory.reconcile(rootID: "photos", root: f.source)
        XCTAssertEqual(try f.inventory.pendingCount(), 1)
        f.inventory.experimentalOfflineNamePreparation = true
        XCTAssertThrowsError(try f.inventory.reconcile(rootID: "photos", root: f.source, origin: .initialInventory))
        XCTAssertEqual(try f.inventory.pendingCount(), 1)
        XCTAssertEqual(try f.journal.pending().first?.relativePath, "photo?.jpg")
    }
}
