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

    func testLargeArchiveRecognition200000Files() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_LARGE_AUDIT"] == "1" else { throw XCTSkip("Opt-in large local archive benchmark") }
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let count = 200_000
        let start = Date()
        let empty = Data()
        let fixed = Date(timeIntervalSince1970:1_700_000_000)
        for group in 0..<200 {
            let name = "group-\(group)"
            let a = f.source.appendingPathComponent(name), b = f.target.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
            for index in 0..<1000 {
                let leaf = "file-\(index).dat"
                let src = a.appendingPathComponent(leaf), dst = b.appendingPathComponent(leaf)
                try empty.write(to:src); try empty.write(to:dst)
                try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:src.path)
                try FileManager.default.setAttributes([.modificationDate:fixed],ofItemAtPath:dst.path)
            }
        }
        print("200K fixture created in \(Date().timeIntervalSince(start)) s")
        try initializeInventory(f)
        let backup = f.base.appendingPathComponent("before.sqlite")
        try ArchiveDatabaseSafety.backup(f.db,to:backup)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let tick = Date()
        let result = try session.auditAndRecognize(mode:.quick,repair:true)
        XCTAssertEqual(result.audit.sourceMetrics?.files,count)
        XCTAssertEqual(result.audit.destinationMetrics?.files,count)
        XCTAssertEqual(result.audit.bytesRead,0)
        XCTAssertEqual(result.recognition.matches.count,count+200)
        let scan = Date().timeIntervalSince(tick)
        let commitTick = Date()
        XCTAssertEqual(try session.approve(report:result.recognition),count+200)
        XCTAssertEqual(try f.journal.plannedUploadCount(),0)
        try ArchiveDatabaseSafety.verify(backup,readOnly:true)
        XCTAssertEqual(try ChangeJournal(path:backup.path).plannedUploadCount(),count+200)
        print("400,000 tiny local files; compare \(scan) s; recognition \(Date().timeIntervalSince(commitTick)) s; total \(Date().timeIntervalSince(start)) s; content bytes read 0")
    }

    func testQueueResetPersistsHoldAndAuditRebuildsOnlyRealMissingFile() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSinceNow:-600)
        try write("matching",to:f.source.appendingPathComponent("same.jpg"),date:date)
        try write("matching",to:f.target.appendingPathComponent("same.jpg"),date:date)
        try write("new",to:f.source.appendingPathComponent("missing.jpg"),date:date)
        try initializeInventory(f)
        let backup=f.base.appendingPathComponent("reset.sqlite")
        XCTAssertEqual(try f.journal.resetPendingQueue(backup:backup),2)
        let reopened=try ChangeJournal(path:f.db.path)
        let token=try XCTUnwrap(reopened.queueRebuildToken())
        XCTAssertEqual(try reopened.plannedUploadCount(),0)
        XCTAssertEqual(try LocalInventory(path:f.db.path).itemCount(rootID:"photos"),2)
        XCTAssertEqual(try ChangeJournal(path:backup.path).plannedUploadCount(),2)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result=try session.auditAndRecognize(mode:.intelligent,repair:true)
        _ = try session.approve(report:result.recognition)
        XCTAssertEqual(try reopened.pending().map(\.relativePath),["missing.jpg"])
        XCTAssertNotNil(try reopened.queueRebuildToken())
        XCTAssertThrowsError(try reopened.completeQueueRebuild(token:"wrong"))
        XCTAssertEqual(try reopened.completeQueueRebuild(token:token),0)
        XCTAssertNil(try reopened.queueRebuildToken())
    }

    func testSpecialExistingNamesReadOnlyRecognitionDoesNotRename() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let name = "roll /photo.jpg"
        try write("matching",to:f.source.appendingPathComponent(name))
        try write("matching",to:f.target.appendingPathComponent(name))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.deep)
        XCTAssertEqual(result.audit.count(.uncertain),0)
        XCTAssertEqual(try session.approve(report:result.recognition),2)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertThrowsError(try f.mapping.fileURL(relativePath:name,destination:true))
        XCTAssertTrue(FileManager.default.fileExists(atPath:f.target.appendingPathComponent(name).path))
    }

    func testTrailingSpaceNameAliasIsNotAutomaticallyAssociated() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        try write("matching",to:f.source.appendingPathComponent("roll /photo.jpg"))
        try write("matching",to:f.target.appendingPathComponent("roll/photo.jpg"))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.deep,repair:true)
        XCTAssertEqual(result.audit.count(.uncertain),4)
        XCTAssertEqual(result.recognition.verifiedCount,0)
        XCTAssertEqual(result.audit.queuedRepairs,0)
    }

    func testMatchingDirectoryAcknowledgedIndependentlyOfMissingChild() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        try write("missing",to:f.source.appendingPathComponent("roll/photo.jpg"))
        try FileManager.default.createDirectory(at:f.target.appendingPathComponent("roll"),withIntermediateDirectories:true)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent,repair:true)
        XCTAssertEqual(result.recognition.matches.map(\.relativePath),["roll"])
        var files = -1, directories = -1
        XCTAssertEqual(try session.approve(report:result.recognition,onCounts:{ files=$0; directories=$1 }),1)
        XCTAssertEqual(files,0)
        XCTAssertEqual(directories,1)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["roll/photo.jpg"])
    }

    func testMatchingDirectoryReplacedBeforeApprovalStaysPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let src = f.source.appendingPathComponent("roll"), dst = f.target.appendingPathComponent("roll")
        try FileManager.default.createDirectory(at:src,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:dst,withIntermediateDirectories:true)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent)
        try FileManager.default.moveItem(at:dst,to:f.target.appendingPathComponent("old-roll"))
        try FileManager.default.createDirectory(at:dst,withIntermediateDirectories:true)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().map(\.relativePath),["roll"])
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

    func testQuickRecognitionDoesNotReadContentAndNeverAcknowledgesDelete() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("AAAA", to: src, date: date)
        try write("BBBB", to: dst, date: date)
        try initializeInventory(f)
        _ = try f.journal.enqueue(rootID:"photos",relativePath:"old.jpg",kind:.delete)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.bytesRead,0)
        XCTAssertEqual(result.recognition.verifiedCount,1)
        XCTAssertEqual(try session.approve(report:result.recognition),1)
        XCTAssertTrue(try f.journal.pending().contains { $0.kind == .delete })
        XCTAssertEqual(try String(contentsOf:dst,encoding:.utf8),"BBBB")
    }

    func testIntelligentHashCacheReusesOnlyStableFingerprintsAndDeepAlwaysReads() throws {
        let f=try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date=Date(timeIntervalSinceNow:-600)
        let src=f.source.appendingPathComponent("a.jpg"), dst=f.target.appendingPathComponent("a.jpg")
        try write("same",to:src,date:date)
        try write("same",to:dst,date:date.addingTimeInterval(10))
        try initializeInventory(f)
        let session=try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let first=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(first.audit.bytesRead,8)
        let second=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(second.audit.bytesRead,0)
        XCTAssertEqual(second.audit.cachedHashMatches,1)
        let deep=try session.auditAndRecognize(mode:.deep)
        XCTAssertEqual(deep.audit.bytesRead,8)
        try write("DIFF",to:dst,date:date.addingTimeInterval(20))
        let changed=try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(changed.audit.count(.different),1)
        XCTAssertEqual(changed.audit.bytesRead,8)
    }

    func testIntelligentRecognitionHashesOnlyTimestampMismatch() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        try write("same", to:f.source.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.source.appendingPathComponent("b.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("b.jpg"),date:date.addingTimeInterval(120))
        try write("AAAA", to:f.source.appendingPathComponent("c.jpg"),date:date)
        try write("BBBB", to:f.target.appendingPathComponent("c.jpg"),date:date.addingTimeInterval(120))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.intelligent)
        XCTAssertEqual(result.recognition.bytesRead,16)
        XCTAssertEqual(result.recognition.verifiedCount,2)
        XCTAssertEqual(try session.approve(report:result.recognition),2)
        XCTAssertTrue(try f.journal.pending().contains { $0.relativePath == "c.jpg" })
    }

    func testQuickRecognitionLeavesChangedFingerprintPending() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at:f.base) }
        let date = Date(timeIntervalSinceNow:-600)
        let src = f.source.appendingPathComponent("a.jpg")
        let dst = f.target.appendingPathComponent("a.jpg")
        try write("same",to:src,date:date)
        try write("same",to:dst,date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertEqual(result.recognition.verifiedCount,1)
        try write("changed",to:dst)
        XCTAssertEqual(try session.approve(report:result.recognition),0)
        XCTAssertEqual(try f.journal.pending().count,1)
    }

    func testMetadataRecognitionRechecksCommitGate() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let date = Date(timeIntervalSinceNow: -600)
        try write("same", to:f.source.appendingPathComponent("a.jpg"),date:date)
        try write("same", to:f.target.appendingPathComponent("a.jpg"),date:date)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database:f.db,mappings:[f.mapping])
        let result = try session.auditAndRecognize(mode:.quick)
        XCTAssertThrowsError(try session.approve(report:result.recognition,cancellation:SeedVerificationCancellation(commitAllowed:{ false })))
        XCTAssertEqual(try f.journal.pending().count,1)
    }

    func testSessionReopensJournalForExplicitApproval() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("same.jpg")
        let dst = f.target.appendingPathComponent("same.jpg")
        try write("identical", to: src)
        try write("identical", to: dst)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        XCTAssertEqual(try f.journal.pending().count, 1)
        let before = try SeededArchiveVerifier.fingerprint(dst)
        XCTAssertEqual(try session.approve(report: report), 1)
        XCTAssertTrue(try f.journal.pending().isEmpty)
        XCTAssertEqual(try SeededArchiveVerifier.fingerprint(dst), before)
    }

    func testSessionRejectsNewDatabaseAtSamePath() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let db = f.base.appendingPathComponent("replaceable.sqlite")
        func createDatabase(_ url: URL) throws {
            let journal = try ChangeJournal(path: url.path)
            _ = try journal.databaseIdentity()
        }
        try createDatabase(db)
        let session = try SeededArchiveSession(database: db, mappings: [f.mapping])
        let report = try session.verify()
        try FileManager.default.moveItem(at: db, to: f.base.appendingPathComponent("previous.sqlite"))
        try createDatabase(db)
        XCTAssertThrowsError(try session.approve(report: report))
        XCTAssertThrowsError(try session.verify())
    }

    func testSessionDoesNotAcknowledgeNewerEventAcrossConnections() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let src = f.source.appendingPathComponent("edited.jpg")
        let dst = f.target.appendingPathComponent("edited.jpg")
        try write("original", to: src)
        try write("original", to: dst)
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        XCTAssertEqual(report.verifiedCount, 1)
        try write("changed contents", to: src)
        let inventory = try LocalInventory(path: f.db.path)
        _ = try inventory.reconcile(rootID: "photos", root: f.source, subtree: src)
        XCTAssertEqual(try session.approve(report: report), 0)
        XCTAssertTrue(try f.journal.pending().contains { $0.relativePath == "edited.jpg" })
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "original")
    }

    func testSessionApprovalCancellationLeavesQueueUnchanged() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        try write("identical", to: f.source.appendingPathComponent("same.jpg"))
        try write("identical", to: f.target.appendingPathComponent("same.jpg"))
        try initializeInventory(f)
        let session = try SeededArchiveSession(database: f.db, mappings: [f.mapping])
        let report = try session.verify()
        let cancellation = SeedVerificationCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try session.approve(report: report, cancellation: cancellation))
        XCTAssertEqual(try f.journal.pending().count, 1)
    }
}
