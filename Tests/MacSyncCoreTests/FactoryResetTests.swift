import Foundation
import XCTest
@testable import MacSyncCore

final class FactoryResetTests: XCTestCase {
    func testConfirmedResetDeletesOnlyInternalDataAndKeepsTheArchiveLock() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let storage = base.appendingPathComponent("MacSync")
        let photos = base.appendingPathComponent("photos")
        let backups = storage.appendingPathComponent("database-backups")
        let fm = FileManager.default
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for name in ["inventory.sqlite", "inventory.sqlite-wal", "archive.lock", "last-audit.json"] {
            try Data().write(to: storage.appendingPathComponent(name))
        }
        try Data().write(to: backups.appendingPathComponent("last.sqlite"))
        let original = photos.appendingPathComponent("original.jpg")
        try Data([1]).write(to: original)

        try FactoryReset.completeIfScheduled(in: storage) { XCTFail("No reset was confirmed") }
        XCTAssertTrue(fm.fileExists(atPath: storage.appendingPathComponent("inventory.sqlite").path))
        XCTAssertThrowsError(try FactoryReset.schedule(in: storage, configuredPaths: [backups.path]))
        try FactoryReset.schedule(in: storage, configuredPaths: [photos.path])
        var preferencesCleared = false
        try FactoryReset.completeIfScheduled(in: storage) { preferencesCleared = true }
        XCTAssertTrue(preferencesCleared)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: storage.path), ["archive.lock"])
        XCTAssertEqual(try Data(contentsOf: original), Data([1]))
        try FactoryReset.completeIfScheduled(in: storage) { XCTFail("The reset must not repeat") }
    }
}
