import XCTest
import Foundation
import SQLite3
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
    func testLogicalDigestIgnoresPhysicalOrderButDetectsEveryLogicalChange() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a.sqlite")
        let b = root.appendingPathComponent("b.sqlite")
        func sql(_ url: URL, _ text: String) throws {
            var db: OpaquePointer?
            guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                throw ApplicationRollback.Failure("Test SQLite open failed")
            }
            defer { sqlite3_close(db) }
            guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else {
                throw ApplicationRollback.Failure(String(cString: sqlite3_errmsg(db)))
            }
        }
        let schema = "CREATE TABLE a(id INTEGER PRIMARY KEY AUTOINCREMENT, v); CREATE TABLE b(id INTEGER PRIMARY KEY AUTOINCREMENT, v); CREATE TABLE bag(v COLLATE NOCASE); CREATE INDEX bag_idx ON bag(v);"
        try sql(a, schema + "INSERT INTO a VALUES(8,1); INSERT INTO b VALUES(7,2); INSERT INTO bag VALUES('A'),('a'),(NULL),(X'00FF'),(CAST(X'610062' AS TEXT)),(1),(1.0),('A');")
        try sql(b, schema + "INSERT INTO b VALUES(7,2); INSERT INTO a VALUES(8,1); INSERT INTO bag VALUES('A'),(1.0),(1),(CAST(X'610062' AS TEXT)),(X'00FF'),(NULL),('a'),('A');")
        func digest(_ url: URL) throws -> Data { try ApplicationRollback.databaseDigest(url, scratch: root) }
        let baseline = try digest(a)
        XCTAssertEqual(baseline, try digest(b))
        let backup = root.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(a, to: backup)
        XCTAssertEqual(baseline, try digest(backup))
        try sql(b, "UPDATE sqlite_sequence SET seq=seq+1 WHERE name='a';")
        XCTAssertNotEqual(baseline, try digest(b))
        try sql(b, "UPDATE sqlite_sequence SET seq=seq-1 WHERE name='a'; UPDATE a SET v=1.0 WHERE id=8;")
        XCTAssertNotEqual(baseline, try digest(b))
        try sql(b, "UPDATE a SET v=1 WHERE id=8;")
        XCTAssertEqual(baseline, try digest(b))
        try sql(b, "UPDATE bag SET v=CAST(X'610063' AS TEXT) WHERE typeof(v)='text' AND hex(v)='610062';")
        XCTAssertNotEqual(baseline, try digest(b))
        try sql(b, "UPDATE bag SET v=CAST(X'610062' AS TEXT) WHERE typeof(v)='text' AND hex(v)='610063';")
        XCTAssertEqual(baseline, try digest(b))
        try sql(b, "DELETE FROM bag WHERE rowid=(SELECT min(rowid) FROM bag WHERE v='A' COLLATE BINARY);")
        XCTAssertNotEqual(baseline, try digest(b))
        try sql(b, "INSERT INTO bag VALUES('A');")
        XCTAssertEqual(baseline, try digest(b))
        try sql(b, "CREATE INDEX extra ON a(v);")
        XCTAssertNotEqual(baseline, try digest(b))
        try sql(b, "DROP INDEX extra; PRAGMA user_version=1;")
        XCTAssertNotEqual(baseline, try digest(b))
    }
    func testProductionInstallLocationRestriction() {
        XCTAssertFalse(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/tmp/MacSync.app")))
        XCTAssertFalse(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/Applications/Other.app")))
        XCTAssertTrue(ApplicationRollback.allowedInstallLocation(URL(fileURLWithPath: "/Applications/MacSync.app")))
    }
}
