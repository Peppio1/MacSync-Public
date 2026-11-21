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

    func testAuditFingerprintDoesNotChangePersistedInventoryEquality() throws {
        let (base, root, _) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: folder.appendingPathComponent("a.jpg"))

        let scanned = try LocalScanner.scan(root: root, ignoreDSStore: true)
        for item in scanned where item.kind == "file" || item.kind == "directory" {
            XCTAssertNotNil(item.verificationFingerprint)
            // Reconstruct the fields actually persisted by file_inventory.
            let stored = TrackedItem(
                relativePath: item.relativePath, kind: item.kind,
                size: item.size, modifiedAt: item.modifiedAt,
                changeStamp: item.changeStamp
            )
            XCTAssertEqual(item, stored)
            XCTAssertEqual(stored, item)
            XCTAssertNotEqual(
                item,
                TrackedItem(
                    relativePath: item.relativePath, kind: item.kind,
                    size: item.size + 1, modifiedAt: item.modifiedAt,
                    changeStamp: item.changeStamp
                )
            )
        }
        XCTAssertEqual(scanned.count, 2)
    }

    func testRemotePOSIXMetadataScanPreservesFileIdentityAndExclusions() throws {
        let (base,root,_) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let folder=root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let photo=folder.appendingPathComponent("a.jpg")
        try Data("image".utf8).write(to:photo)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:photo.path)
        try Data("finder".utf8).write(to:folder.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("alias"),withDestinationURL:folder)
        let ordinary=try LocalScanner.scan(root:root,ignoreDSStore:true)
        let remote=try LocalScanner.scan(root:root,ignoreDSStore:true,preferPOSIXMetadata:true)
        XCTAssertEqual(Set(ordinary.map(\.relativePath)),Set(remote.map(\.relativePath)))
        XCTAssertEqual(remote.first(where:{$0.relativePath=="alias"})?.kind,"symlink")
        XCTAssertTrue(remote.allSatisfy { !$0.relativePath.hasPrefix("alias/") })
        XCTAssertEqual(ordinary.filter{$0.kind=="file"},remote.filter{$0.kind=="file"})
    }

    func testDSStoreExclusionRetiresWithoutCreatingDeleteOrRemovingFiles() throws {
        let key=FileExclusionPolicy.preferenceKey
        let old=UserDefaults.standard.object(forKey:key)
        defer { if let old { UserDefaults.standard.set(old,forKey:key) } else { UserDefaults.standard.removeObject(forKey:key) } }
        let (base,root,db)=try temporaryFixture()
        defer { try? FileManager.default.removeItem(at:base) }
        let ds=root.appendingPathComponent(".DS_Store")
        try Data("Finder".utf8).write(to:ds)
        try Data("photo".utf8).write(to:root.appendingPathComponent("photo.jpg"))
        UserDefaults.standard.set(false,forKey:key)
        let store=try LocalInventory(path:db.path)
        _ = try store.reconcile(rootID:"photos",root:root)
        XCTAssertEqual(try store.pendingBreakdown().files,2)
        UserDefaults.standard.set(true,forKey:key)
        let result=try store.reconcile(rootID:"photos",root:root)
        XCTAssertEqual(result.queuedDeletes,0)
        XCTAssertEqual(try store.pendingBreakdown().files,1)
        XCTAssertEqual(try store.pendingBreakdown().deletions,0)
        XCTAssertEqual(try store.pendingCount(),1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:ds.path))
        XCTAssertFalse(try LocalScanner.scan(root:root,ignoreDSStore:true).contains { $0.relativePath==".DS_Store" })
    }

    func testRetiringRootsPreservesActiveQueueAndPhysicalFiles() throws {
        let (base,root,db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at:base) }
        try Data("one".utf8).write(to:root.appendingPathComponent("keep.jpg"))
        let other = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:false)
        let file = other.appendingPathComponent("retired.jpg")
        try Data("two".utf8).write(to:file)
        let store = try LocalInventory(path:db.path)
        _ = try store.reconcile(rootID:"keep",root:root)
        _ = try store.reconcile(rootID:"retire",root:other)
        try store.retireInactiveRoots(keeping:["keep"])
        XCTAssertEqual(try store.itemCount(rootID:"keep"),1)
        XCTAssertEqual(try store.itemCount(rootID:"retire"),0)
        XCTAssertNil(try store.rootPath(rootID:"retire"))
        XCTAssertEqual(try ChangeJournal(path:db.path).pending().map(\.rootID),["keep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testCancelledInventoryScanPreservesQueueAndCheckpoint() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("keep.jpg")
        try Data("original".utf8).write(to: file)
        let inventory = try LocalInventory(path: db.path)
        _ = try inventory.reconcile(rootID: "photos", root: root, eventID: 100)
        let before = try ChangeJournal(path: db.path).pending()
        try FileManager.default.removeItem(at: file)
        try Data("new".utf8).write(to: root.appendingPathComponent("new.jpg"))
        let cancel = SeedVerificationCancellation()
        XCTAssertThrowsError(try inventory.reconcile(rootID: "photos", root: root, eventID: 101,
            shouldContinue: { !cancel.isCancelled }, onItem: { _ in cancel.cancel() }))
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 100)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 1)
        XCTAssertEqual(try ChangeJournal(path: db.path).pending(), before)
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
        XCTAssertEqual(try inventory.pendingBreakdown().files,1)
        XCTAssertEqual(try inventory.pendingBreakdown().directories,1)
        XCTAssertEqual(try inventory.pendingBreakdown().deletions,0)

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

    func testInaccessibleSubtreeDoesNotAcknowledgeDeletionOrEvent() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = root.appendingPathComponent("album")
        let file = folder.appendingPathComponent("photo.dng")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("image".utf8).write(to: file)
        let inventory = try LocalInventory(path: db.path)
        _ = try inventory.reconcile(rootID: "photos", root: root, eventID: 100)
        let before = try ChangeJournal(path: db.path).pending()
        // A file in place of an expected directory gives ENOTDIR, not ENOENT.
        try FileManager.default.removeItem(at: folder)
        try Data("unexpected object".utf8).write(to: folder)
        XCTAssertThrowsError(try inventory.reconcile(
            rootID: "photos", root: root, subtree: file, eventID: 101
        ))
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 2)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 100)
        XCTAssertEqual(try ChangeJournal(path: db.path).pending(), before)
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

    func testSubtreeReconciliationDoesNotTouchSiblingWithSimilarName() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let first = root.appendingPathComponent("before")
        let sibling = root.appendingPathComponent("before2")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: first.appendingPathComponent("old.jpg"))
        try Data("safe".utf8).write(to: sibling.appendingPathComponent("safe.jpg"))

        let inventory = try LocalInventory(path: db.path)
        try inventory.reconcile(rootID: "photos", root: root)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 4)

        try FileManager.default.removeItem(at: first)
        let outcome = try inventory.reconcile(rootID: "photos", root: root, subtree: first)
        XCTAssertEqual(outcome.queuedDeletes, 2)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 2)
        XCTAssertFalse(try ChangeJournal(path: db.path).pending()
            .contains(where: { $0.relativePath == "before2/safe.jpg" && $0.kind == .delete }))
    }

    func testRegularFilesBeforeFolderNeverSuppressNestedDescendants() throws {
        let (base, root, db) = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: base) }

        // Regression: calling enumerator.skipDescendants() after a regular
        // file previously suppressed the next folder's children on macOS.
        try Data("first".utf8).write(to: root.appendingPathComponent("first.dng"))
        try Data("second".utf8).write(to: root.appendingPathComponent("second.dng"))
        let album = root.appendingPathComponent("album")
        let nested = album.appendingPathComponent("2026")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: nested.appendingPathComponent("shot.dng"))

        let scanned = try LocalScanner.scan(root: root)
        let paths = Set(scanned.map { $0.relativePath })
        XCTAssertEqual(paths, Set([
            "first.dng", "second.dng", "album",
            "album/2026", "album/2026/shot.dng"
        ]))

        let inventory = try LocalInventory(path: db.path)
        let added = try inventory.reconcile(rootID: "photos", root: root)
        XCTAssertEqual(added.queuedUpserts, 5)

        try FileManager.default.removeItem(at: album)
        let removed = try inventory.reconcile(rootID: "photos", root: root, subtree: album)
        XCTAssertEqual(removed.queuedDeletes, 3)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 2)
        let deleted = try ChangeJournal(path: db.path).pending()
            .filter { $0.kind == .delete }
        XCTAssertEqual(Set(deleted.map { $0.relativePath }),
                       Set(["album", "album/2026", "album/2026/shot.dng"]))
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
