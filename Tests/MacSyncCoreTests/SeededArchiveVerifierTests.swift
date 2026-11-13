import Foundation
import XCTest
@testable import MacSyncCore

final class SeededArchiveVerifierTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        let db: URL
        let journal: ChangeJournal
        let mapping: MountedFolderMapping
    }

    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-seed-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let db = base.appendingPathComponent("inventory.sqlite")
        let journal = try ChangeJournal(path: db.path)
        return Fixture(
            base: base, source: source, target: target, db: db,
            journal: journal,
            mapping: try MountedFolderMapping(
                rootID: "photos", source: source, target: target
            )
        )
    }

    private func initializeInventory(_ f: Fixture) throws {
        let inventory = try LocalInventory(path: f.db.path)
        try inventory.reconcile(rootID: "photos", root: f.source)
    }

    private func write(_ text: String, to url: URL, date: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        if let date {
            try FileManager.default.setAttributes(
                [.modificationDate: date], ofItemAtPath: url.path
            )
        }
    }

    func testIdenticalSeededFileIsAcknowledgedWithoutAnyDestinationWrite() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let first = f.source.appendingPathComponent("roll/photo.dng")
        let second = f.target.appendingPathComponent("roll/photo.dng")
        let date = Date(timeIntervalSinceNow: -600)
        try write("picture data", to: first, date: date)
        try write("picture data", to: second, date: date.addingTimeInterval(180))
        try initializeInventory(f)

        let pendingBefore = try f.journal.pending()
        XCTAssertTrue(pendingBefore.contains(where: { $0.relativePath == "roll/photo.dng" }))
        let dstBefore = try SeededArchiveVerifier.fingerprint(second)

        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(report.missingOrDifferent, 0)
        XCTAssertEqual(report.bytesRead, Int64(2 * "picture data".utf8.count))
        XCTAssertEqual(try f.journal.pending().count, pendingBefore.count)

        let completed = try verifier.approve(report: report)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(try f.journal.pending().contains(where: { $0.relativePath == "roll/photo.dng" }))
        XCTAssertEqual(try SeededArchiveVerifier.fingerprint(second), dstBefore)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "picture data")
    }

    func testSameSizeAndSameTimeWithDifferentContentsIsNeverAccepted() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -900)
        try write("AAAA", to: f.source.appendingPathComponent("photo.jpg"), date: date)
        try write("BBBB", to: f.target.appendingPathComponent("photo.jpg"), date: date)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(report.missingOrDifferent, 1)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains(where: { $0.relativePath == "photo.jpg" }))
    }

    func testMissingTargetAndDeletionJobsRemainPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("source only", to: f.source.appendingPathComponent("source.jpg"))
        try initializeInventory(f)
        _ = try f.journal.enqueue(rootID: "photos", relativePath: "old.jpg", kind: .delete)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(report.deferred, 1)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertEqual(try f.journal.pending().filter { $0.kind == .delete }.count, 1)
    }

    func testSourceChangedAfterHashBeforeApprovalRemainsQueued() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("edit.psd")
        let dst = f.target.appendingPathComponent("edit.psd")
        try write("VERSION01", to: src)
        try write("VERSION01", to: dst)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        try write("VERSION02 and changed length", to: src)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertEqual(try f.journal.pending().count, 1)
    }

    func testNewQueuedEventCannotBeConsumedByOldHashApproval() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("stable", to: src)
        try write("stable", to: dst)
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 1)

        // Simulate the FSEvents journal replacing the original pending job
        // while a long seed comparison was in progress.
        let inv = try LocalInventory(path: f.db.path)
        try write("stable", to: src)
        _ = try inv.reconcile(rootID: "photos", root: f.source, subtree: src)
        XCTAssertEqual(try verifier.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains(where: { $0.relativePath == "same.jpg" }))
    }

    func testSymlinkDestinationCannotBeHashedOrAcknowledged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("secret", to: f.source.appendingPathComponent("danger.txt"))
        try initializeInventory(f)
        let external = f.base.appendingPathComponent("not-owned.txt")
        try write("secret", to: external)
        try FileManager.default.createSymbolicLink(
            at: f.target.appendingPathComponent("danger.txt"), withDestinationURL: external
        )
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(try f.journal.pending().count, 1)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "secret")
    }

    func testCancelledVerificationDoesNotMarkJobsComplete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("contents", to: f.source.appendingPathComponent("foto.jpg"))
        try write("contents", to: f.target.appendingPathComponent("foto.jpg"))
        try initializeInventory(f)
        let cancellation = SeedVerificationCancellation()
        cancellation.cancel()
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        XCTAssertThrowsError(try verifier.verify(cancellation: cancellation))
        XCTAssertEqual(try f.journal.pending().count, 1)
    }

    func testApprovalCancellationDoesNotPartiallyAcknowledge() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for index in 0..<40 {
            let name = "f\(index).jpg"
            try write("same-\(index)", to: f.source.appendingPathComponent(name))
            try write("same-\(index)", to: f.target.appendingPathComponent(name))
        }
        try initializeInventory(f)
        let verifier = try SeededArchiveVerifier(journal: f.journal, mappings: [f.mapping])
        let report = try verifier.verify()
        XCTAssertEqual(report.verifiedCount, 40)
        let cancellation = SeedVerificationCancellation()
        XCTAssertThrowsError(try verifier.approve(
            report: report, cancellation: cancellation,
            progress: { _, _ in cancellation.cancel() }
        ))
        XCTAssertEqual(try f.journal.pending().count, 40)
    }
}
