import XCTest
import Foundation
@testable import MacSyncCore

final class ApplicationRollbackTests: XCTestCase {
    private func fixture(_ url: URL, text: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url.appendingPathComponent("version"))
    }
    func testAtomicExchangePreservesBothBundlesAndNeverEditsArchive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("MacSync.app")
        let backup = root.appendingPathComponent("saved.app")
        let db = root.appendingPathComponent("inventory.sqlite")
        try fixture(target, text: "new")
        try fixture(backup, text: "old")
        try Data("archive unchanged".utf8).write(to: db)
        let preserved = try ApplicationRollback.replaceApplication(target: target, backup: backup) { app in
            guard try Data(contentsOf: app.appendingPathComponent("version")) == Data("old".utf8) else {
                throw ApplicationRollback.Failure("bad fixture")
            }
        }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("version")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: preserved.appendingPathComponent("MacSync.app/version")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("version")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: db), Data("archive unchanged".utf8))
    }
    func testVerificationFailureAndSymlinkNeverReplaceDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("MacSync.app")
        let backup = root.appendingPathComponent("saved.app")
        try fixture(target, text: "new")
        try fixture(backup, text: "old")
        XCTAssertThrowsError(try ApplicationRollback.replaceApplication(target: target, backup: backup) { _ in
            throw ApplicationRollback.Failure("invalid signature")
        })
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("version")), Data("new".utf8))
        let link = root.appendingPathComponent("link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ApplicationRollback.replaceApplication(target: link, backup: backup) { _ in })
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("version")), Data("new".utf8))
    }
    func testMissingApplicationCanBeRecreatedAndChangedDatabaseIsDetected() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("MacSync.app")
        let backup = root.appendingPathComponent("backup.app")
        try fixture(backup, text: "old")
        _ = try ApplicationRollback.replaceApplication(target: target, backup: backup) { _ in }
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        let live = root.appendingPathComponent("live.sqlite")
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        let journal = try ChangeJournal(path: live.path)
        _ = try LocalInventory(path: live.path)
        try ArchiveDatabaseSafety.backup(live, to: snapshot)
        XCTAssertEqual(try ApplicationRollback.databaseDigest(live, scratch: root),
                       try ApplicationRollback.databaseDigest(snapshot, scratch: root))
        let source = root.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("new".utf8).write(to: source.appendingPathComponent("new.txt"))
        let inventory = try LocalInventory(path: live.path)
        _ = try inventory.reconcile(rootID: "fixture", root: source)
        _ = try journal.pending()
        XCTAssertNotEqual(try ApplicationRollback.databaseDigest(live, scratch: root),
                          try ApplicationRollback.databaseDigest(snapshot, scratch: root))
    }
    func testProductionInstallLocationRestriction() {
        XCTAssertFalse(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/tmp/MacSync.app")))
        XCTAssertFalse(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/Applications/Other.app")))
        XCTAssertTrue(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/Applications/MacSync.app")))
    }
}
