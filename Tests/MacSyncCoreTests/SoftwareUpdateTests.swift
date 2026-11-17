import Foundation
import XCTest
@testable import MacSyncCore

final class SoftwareUpdateTests: XCTestCase {
    private func json(_ tag: String, prerelease: Bool = false, draft: Bool = false) -> Data {
        Data("{\"tag_name\":\"\(tag)\",\"prerelease\":\(prerelease),\"draft\":\(draft),\"body\":\"notes\",\"html_url\":\"https://example.invalid\"}".utf8)
    }

    func testStableOnlyNumericComparisonAndFixedReleaseHost() throws {
        let result = try StableUpdateDiscovery.interpret(status: 200, data: json("v1.10.0"), installed: "1.9.9")
        guard case .available(let release) = result else { return XCTFail("Expected newer release") }
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/Peppio1/MacSync-Public/releases/tag/v1.10.0")
        XCTAssertEqual(try StableUpdateDiscovery.interpret(status: 200, data: json("v1.9.9"), installed: "1.9.9"), .current)
        XCTAssertEqual(try StableUpdateDiscovery.interpret(status: 200, data: json("v1.0.0"), installed: "1.9.9"), .current)
        XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: 200, data: json("v2.0.0", prerelease: true), installed: "1.0.0"))
        XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: 200, data: json("v2.0.0", draft: true), installed: "1.0.0"))
        for tag in ["v2.0.0-rc.1", "v01.0.0", "v2/0.0", "v2.0", "v2.0.0.1", "v9999999999.0.0"] {
            XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: 200, data: json(tag), installed: "1.0.0"), tag)
        }
    }

    func testNoStableReleaseIsNotAnUpToDateClaimAndErrorsFailClosed() throws {
        XCTAssertEqual(try StableUpdateDiscovery.interpret(status: 404, data: Data(), installed: "0.16.0"), .noStableRelease)
        for status in [403, 429, 500] { XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: status, data: Data(), installed: "0.16.0")) }
        XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: 200, data: Data(), installed: "0.16.0"))
        XCTAssertThrowsError(try StableUpdateDiscovery.interpret(status: 200, data: Data(count: 524289), installed: "0.16.0"))
    }

    func testDailyScheduleIncludingClockChange() {
        let now = Date(timeIntervalSince1970: 1000000)
        XCTAssertTrue(StableUpdateDiscovery.isDue(lastAttempt: nil, now: now))
        XCTAssertFalse(StableUpdateDiscovery.isDue(lastAttempt: now.addingTimeInterval(-86399), now: now))
        XCTAssertTrue(StableUpdateDiscovery.isDue(lastAttempt: now.addingTimeInterval(-86400), now: now))
        XCTAssertTrue(StableUpdateDiscovery.isDue(lastAttempt: now.addingTimeInterval(100), now: now))
    }

    func testSnapshotPreservesQueuePreferencesAndBundleWithoutReplacingEarlierBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let app = base.appendingPathComponent("MacSync.app")
        let contents = app.appendingPathComponent("Contents")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("test".utf8).write(to: source.appendingPathComponent("file.txt"))
        let db = base.appendingPathComponent("live.sqlite")
        let inventory = try LocalInventory(path: db.path)
        let journal = try ChangeJournal(path: db.path)
        _ = try inventory.reconcile(rootID: "a", root: source)
        let expected = try journal.pending()
        let prefs: [String: Any] = ["MacSync.autoCopiesEnabled.v2": false, "Unrelated": "private"]
        let one = try UpdateRecoverySnapshot.create(database: db, application: app, preferences: prefs, parent: base)
        let two = try UpdateRecoverySnapshot.create(database: db, application: app, preferences: prefs, parent: base)
        XCTAssertNotEqual(one, two)
        for snapshot in [one, two] {
            let saved = snapshot.appendingPathComponent("inventory.sqlite")
            try ArchiveDatabaseSafety.verify(saved, readOnly: true)
            XCTAssertEqual(try ChangeJournal(path: saved.path).pending(), expected)
            let data = try Data(contentsOf: snapshot.appendingPathComponent("preferences.plist"))
            let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
            XCTAssertEqual(decoded["MacSync.autoCopiesEnabled.v2"] as? Bool, false)
            XCTAssertNil(decoded["Unrelated"])
            XCTAssertEqual(try Data(contentsOf: snapshot.appendingPathComponent("MacSync.app/Contents/Info.plist")), Data("fixture".utf8))
        }
        XCTAssertEqual(try journal.pending(), expected)
        XCTAssertThrowsError(try UpdateRecoverySnapshot.create(database: base.appendingPathComponent("missing.sqlite"), application: app, preferences: prefs, parent: base))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".update-stage-") })
    }
}
