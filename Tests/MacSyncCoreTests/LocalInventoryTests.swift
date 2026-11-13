import Foundation
import XCTest
@testable import MacSyncCore

final class LocalInventoryTests: XCTestCase {
    private func temporaryFixture() throws -> (URL, URL, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-test-" + UUID().uuidString)
        let source = base.appendingPathComponent("Source")
        let database = base.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (base, source, database)
    }

    func testIncrementalChangesAndDeletionAreStored() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("sample.dng")
        try Data("first".utf8).write(to: file)

        let inventory = try LocalInventory(path: db.path)
        let journal = try ChangeJournal(path: db.path)

        let initial = try inventory.reconcile(rootID: "photos", root: root, eventID: 100)
        XCTAssertEqual(initial.queuedDeletes, 0)
        XCTAssertEqual(initial.inspected, 2)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 2)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 100)
        XCTAssertEqual(try inventory.pendingCount(), 2)

        let unchanged = try inventory.reconcile(rootID: "photos", root: root, eventID: 101)
        XCTAssertEqual(unchanged.queuedUpserts, 0)
        XCTAssertEqual(unchanged.queuedDeletes, 0)
        XCTAssertEqual(try inventory.pendingCount(), 2)

        try Data("an updated DNG file".utf8).write(to: file)
        let changed = try inventory.reconcile(
            rootID: "photos", root: root, subtree: file, eventID: 102
        )
        XCTAssertEqual(changed.queuedUpserts, 1)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 102)
        XCTAssertEqual(try inventory.pendingCount(), 2) // coalesced pending changes

        try FileManager.default.removeItem(at: file)
        let removed = try inventory.reconcile(
            rootID: "photos", root: root, subtree: file, eventID: 103
        )
        XCTAssertEqual(removed.queuedDeletes, 1)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 1)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 103)
        let pending = try journal.pending()
        XCTAssertEqual(pending.first(where: { $0.relativePath == "session/sample.dng" })?.kind, .delete)
    }

    func testUnreachableSourceDoesNotProduceDeletions() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("keep.psd")
        try Data("important data".utf8).write(to: file)

        let inventory = try LocalInventory(path: db.path)
        try inventory.reconcile(rootID: "photos", root: root)
        let originalCount = try inventory.itemCount(rootID: "photos")
        let originalQueued = try inventory.pendingCount()

        let moved = base.appendingPathComponent("TemporarilyOffline")
        try FileManager.default.moveItem(at: root, to: moved)
        XCTAssertThrowsError(try inventory.reconcile(rootID: "photos", root: root))
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), originalCount)
        XCTAssertEqual(try inventory.pendingCount(), originalQueued)
    }

    func testDirectoryRenameDiscoversBothSides() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = root.appendingPathComponent("before")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: old.appendingPathComponent("a.jpg"))
        let inventory = try LocalInventory(path: db.path)
        try inventory.reconcile(rootID: "photos", root: root)

        let new = root.appendingPathComponent("after")
        try FileManager.default.moveItem(at: old, to: new)
        let oldResult = try inventory.reconcile(rootID: "photos", root: root, subtree: old)
        let newResult = try inventory.reconcile(rootID: "photos", root: root, subtree: new)
        XCTAssertEqual(oldResult.queuedDeletes, 2)
        XCTAssertEqual(newResult.queuedUpserts, 2)

        let changes = try ChangeJournal(path: db.path).pending()
        XCTAssertEqual(changes.first(where: { $0.relativePath == "before/a.jpg" })?.kind, .delete)
        XCTAssertEqual(changes.first(where: { $0.relativePath == "after/a.jpg" })?.kind, .upsert)
    }

    func testChangingTheRootMappingFailsSafely() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let other = base.appendingPathComponent("DifferentFolder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let inventory = try LocalInventory(path: db.path)
        try inventory.reconcile(rootID: "photos", root: root)
        XCTAssertThrowsError(try inventory.reconcile(rootID: "photos", root: other))
        XCTAssertEqual(try inventory.rootPath(rootID: "photos"), root.resolvingSymlinksInPath().path)
    }

    func testRefusesOutOfRootScanWithoutTouchingInventory() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let foreign = base.appendingPathComponent("unrelated")
        let inventory = try LocalInventory(path: db.path)
        XCTAssertThrowsError(try inventory.reconcile(rootID: "photos", root: root, subtree: foreign))
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 0)
    }
}
