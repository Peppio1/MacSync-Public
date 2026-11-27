import Foundation
import XCTest
@testable import MacSyncCore

/// Same existing local rectification function before and after the archive
/// is seeded. The benchmark is not an operating mode or a size limit.
final class RepeatableNameRectificationTests: XCTestCase {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    private func addBatch(root: URL, prefix: String, folders: Int) throws {
        for i in 0..<folders {
            let folder = root.appendingPathComponent("\(prefix)-\(i) ")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            for j in 0..<9 {
                let file = folder.appendingPathComponent("photo-\(j)?.jpg")
                try Data([UInt8(i), UInt8(j)]).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
            }
        }
    }

    private func verifyBatch(root: URL, prefix: String, folders: Int) throws {
        for i in 0..<folders {
            let folder = root.appendingPathComponent("\(prefix)-\(i)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(prefix)-\(i) ").path))
            for j in 0..<9 {
                XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("photo-\(j)-.jpg")),
                    Data([UInt8(i), UInt8(j)]))
            }
        }
    }

    private func rectify(_ inventory: LocalInventory, root: URL, db: URL, expected: Int) throws -> Double {
        let journal = try ChangeJournal(path: db.path)
        let items = try inventory.incompatibleNames(rootID: "photos", sourcePath: root.path)
        XCTAssertEqual(items.count, expected)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try NameRectification.executeLocal(items: items, roots: ["photos": root.path],
            journal: journal, log: SyncActivityLog(path: db.path))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(result.renamed, expected)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        return elapsed
    }

    func testRepeatableMassRectificationBeforeAndAfterBinding() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("MacSync-repeat-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let db = base.appendingPathComponent("state.sqlite")
        let journal = try ChangeJournal(path: db.path)
        var inventory = try LocalInventory(path: db.path)

        try addBatch(root: source, prefix: "initial", folders: 120)
        let first = try inventory.reconcile(rootID: "photos", root: source, origin: .initialInventory)
        XCTAssertEqual(first.queuedUpserts, 0)
        XCTAssertEqual(first.queuedDeletes, 0)
        let firstTime = try rectify(inventory, root: source, db: db, expected: 1200)
        let firstUpdate = try inventory.reconcile(rootID: "photos", root: source)
        // Existing queue behavior remains conservative until publication
        // evidence is connected. This test must NOT bypass it just to make
        // the initial queue empty.
        XCTAssertEqual(firstUpdate.queuedUpserts, 1200)
        XCTAssertEqual(firstUpdate.queuedDeletes, 1200)
        XCTAssertTrue(try inventory.incompatibleNames(rootID: "photos", sourcePath: source.path).isEmpty)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
        try verifyBatch(root: source, prefix: "initial", folders: 120)

        // Simulate the external seed using a disposable local destination.
        // This is not a test of real SMB or disk transport.
        for folder in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = target.appendingPathComponent(folder.lastPathComponent)
            try fm.copyItem(at: folder, to: destination)
            for file in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
                try fm.setAttributes([.modificationDate: fixed], ofItemAtPath: file.path)
            }
        }
        try verifyBatch(root: target, prefix: "initial", folders: 120)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let report = try SeededArchiveSession(database: db, mappings: [mapping])
            .auditPreservingQueuedChanges(mode: .quick, repair: true, reconcileOrdinaryJobs: true)
        XCTAssertEqual(report.bytesRead, 0)

        // Same function, same root, same database, after binding and after
        // actual queue history exists. No new operating mode or reset.
        inventory = try LocalInventory(path: db.path)
        inventory.experimentalSourceNameLineage = true
        _ = try inventory.reconcile(rootID: "photos", root: source, eventID: 1)
        try addBatch(root: source, prefix: "daily", folders: 35)
        _ = try inventory.reconcile(rootID: "photos", root: source, eventID: 2)
        // A historical incompatible target may exist. Keep it physically
        // unchanged during local rectification; unknown is not absence.
        let legacy = target.appendingPathComponent("daily-0 ")
        try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
        let sentinel = legacy.appendingPathComponent("photo-0?.jpg")
        try Data("legacy sentinel".utf8).write(to: sentinel)
        let before = try LocalScanner.scan(root: target)
        let secondTime = try rectify(inventory, root: source, db: db, expected: 350)
        let second = try inventory.reconcile(rootID: "photos", root: source, eventID: 3)
        XCTAssertEqual(second.queuedUpserts, 350)
        XCTAssertEqual(second.queuedDeletes, 350)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 3)
        XCTAssertTrue(try inventory.incompatibleNames(rootID: "photos", sourcePath: source.path).isEmpty)
        try verifyBatch(root: source, prefix: "daily", folders: 35)
        try verifyBatch(root: source, prefix: "initial", folders: 120)
        XCTAssertEqual(try LocalScanner.scan(root: target), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("legacy sentinel".utf8))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("daily-0").path))
        print("REPEATABLE_NAME_BATCH initial=1200 initial_seconds=\(firstTime) subsequent=350 subsequent_seconds=\(secondTime) target_unchanged=true")
    }
}
