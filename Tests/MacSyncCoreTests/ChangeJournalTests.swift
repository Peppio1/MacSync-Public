import Foundation
import XCTest
@testable import MacSyncCore

final class ChangeJournalTests: XCTestCase {
    func testQueuePersistsAcrossOpenAndMarkCompleted() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let queuedID: Int64
        do {
            let journal = try ChangeJournal(path: path)
            queuedID = try journal.enqueue(
                rootID: "photo-uploads", relativePath: "folder/example.psd", kind: .upsert
            )
            XCTAssertEqual(try journal.pending().map(\.id), [queuedID])
        }

        do {
            let journal = try ChangeJournal(path: path)
            let events = try journal.pending()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events[0].relativePath, "folder/example.psd")
            XCTAssertEqual(events[0].kind, .upsert)
            try journal.markCompleted(id: queuedID)
            XCTAssertTrue(try journal.pending().isEmpty)
        }
    }

    func testRejectsPathEscape() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let journal = try ChangeJournal(path: path)
        XCTAssertThrowsError(
            try journal.enqueue(rootID: "a", relativePath: "../escaped", kind: .delete)
        )
    }

    func testDeletionFailsClosed() {
        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: false, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: false, baselineVerified: true,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: false,
            trackedFileCount: 100, pendingDeleteCount: 1
        ).allowed)
    }

    func testMassDeletionRequiresIntervention() {
        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 200, pendingDeleteCount: 25
        ).allowed)

        XCTAssertFalse(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 10_000, pendingDeleteCount: 250
        ).allowed)

        XCTAssertTrue(DeletionSafety.evaluate(
            sourceAvailable: true, serverAvailable: true, baselineVerified: true,
            trackedFileCount: 200, pendingDeleteCount: 1
        ).allowed)
    }
}
