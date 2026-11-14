import Foundation
import CryptoKit
import XCTest
@testable import MacSyncCore

final class UploadCyclePerformanceTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let source: URL
        let target: URL
        let db: String
        let journal: ChangeJournal
        let worker: MountedFolderCopyWorker
    }
    private func fixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-batch-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let db = base.appendingPathComponent("state.sqlite").path
        let journal = try ChangeJournal(path: db)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: SyncActivityLog(path: db), mappings: [mapping],
            availableCapacity: { _ in nil }
        )
        return Fixture(base: base, source: source, target: target, db: db, journal: journal, worker: worker)
    }
    private func add(_ f: Fixture, name: String, content: String = "test image") throws {
        let url = f.source.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path
        )
        try f.journal.enqueue(rootID: "photos", relativePath: name, kind: .upsert)
    }

    func testSingleCycleProcessesMoreThanFiftyFilesAndPages() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for n in 0..<235 { try add(f, name: "photo-\(n).dng") }
        var progress: [Int] = []
        let result = try f.worker.runCycle(enabled: true, pageSize: 100,
            onProgress: { progress.append($0.copied) })
        XCTAssertEqual(result.created, 235)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.deferred, 0)
        XCTAssertEqual(progress, [100, 200, 235])
        XCTAssertTrue(try f.journal.pendingUploads().isEmpty)
        XCTAssertEqual(try String(contentsOf: f.target.appendingPathComponent("photo-234.dng"), encoding: .utf8), "test image")
        XCTAssertEqual(try f.worker.runCycle(enabled: true).copied, 0)
    }

    func testNewEventsWaitUntilNextCycleAndFailedJobDoesNotLoop() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        // Missing source is deferred, never retried repeatedly in this cycle.
        try f.journal.enqueue(rootID: "photos", relativePath: "missing.dng", kind: .upsert)
        try add(f, name: "one.dng")
        try add(f, name: "two.dng")
        var added = false
        var callbackError: Error?
        let result = try f.worker.runCycle(enabled: true, pageSize: 1, onProgress: { _ in
            if !added {
                added = true
                do { try self.add(f, name: "later.dng") }
                catch { callbackError = error }
            }
        })
        XCTAssertNil(callbackError)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(result.copied, 2)
        XCTAssertEqual(Set(try f.journal.pendingUploads().map(\.relativePath)), Set(["missing.dng", "later.dng"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("later.dng").path))
        try Data("restored".utf8).write(to: f.source.appendingPathComponent("missing.dng"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: f.source.appendingPathComponent("missing.dng").path)
        XCTAssertEqual(try f.worker.runCycle(enabled: true).copied, 2)
        XCTAssertTrue(try f.journal.pendingUploads().isEmpty)
    }

    func testCancellationAndRestartDoNotLoseQueuedItems() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for n in 0..<125 { try add(f, name: "photo-\(n).psd") }
        var stop = false
        let first = try f.worker.runCycle(enabled: true, pageSize: 25,
            shouldContinue: { !stop }, onProgress: { _ in stop = true })
        XCTAssertTrue(first.interrupted)
        XCTAssertEqual(first.copied, 25)
        XCTAssertEqual(try f.journal.pendingUploads(limit: 1000).count, 100)
        let mapping = try MountedFolderMapping(rootID: "photos", source: f.source, target: f.target)
        let restarted = try MountedFolderCopyWorker(journal: ChangeJournal(path: f.db),
            log: SyncActivityLog(path: f.db), mappings: [mapping], availableCapacity: { _ in nil })
        XCTAssertEqual(try restarted.runCycle(enabled: true).copied, 100)
        XCTAssertTrue(try f.journal.pendingUploads().isEmpty)
    }

    func testMissingTargetInterruptsCycleInsteadOfTryingEveryFile() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        for n in 0..<65 { try add(f, name: "photo-\(n).psd") }
        try FileManager.default.removeItem(at: f.target)
        let result = try f.worker.runCycle(enabled: true, pageSize: 10)
        XCTAssertTrue(result.interrupted)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(try f.journal.pendingUploads().count, 65)
        try FileManager.default.createDirectory(at: f.target, withIntermediateDirectories: false)
        XCTAssertEqual(try f.worker.runCycle(enabled: true).copied, 65)
    }

    func testLargeSyntheticFileTransfersIntact() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let source = f.source.appendingPathComponent("large.psd")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let writer = try FileHandle(forWritingTo: source)
        var expected = SHA256()
        // 64 MiB, created and checked with a 1 MiB working chunk.
        for i in 0..<64 {
            let chunk = Data(repeating: UInt8(i), count: 1024 * 1024)
            try writer.write(contentsOf: chunk)
            expected.update(data: chunk)
        }
        try writer.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: source.path)
        try f.journal.enqueue(rootID: "photos", relativePath: "large.psd", kind: .upsert)
        let result = try f.worker.runCycle(enabled: true)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.bytes, 64 * 1024 * 1024)
        XCTAssertTrue(try f.journal.pendingUploads().isEmpty)
        let reader = try FileHandle(forReadingFrom: f.target.appendingPathComponent("large.psd"))
        defer { try? reader.close() }
        var actual = SHA256()
        while let bytes = try reader.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            actual.update(data: bytes)
        }
        XCTAssertEqual(Data(actual.finalize()), Data(expected.finalize()))
    }

    func testLargeQueuePagesAreBoundedAndExcludeNewEvents() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        // Queue scalability simulation only: this does not create 20,000
        // photos or measure the throughput of a real SMB connection.
        for n in 0..<20_000 {
            try f.journal.enqueue(rootID: "photos", relativePath: "album/photo-\(n).dng", kind: .upsert)
        }
        let upper = try XCTUnwrap(f.journal.pendingUploadUpperBound())
        let later = try f.journal.enqueue(rootID: "photos", relativePath: "later.dng", kind: .upsert)
        XCTAssertGreaterThan(later, upper)
        var count = 0
        var cursor: Int64 = 0
        while true {
            let page = try f.journal.pendingUploads(limit: 100, afterID: cursor, throughID: upper)
            if page.isEmpty { break }
            XCTAssertLessThanOrEqual(page.count, 100)
            XCTAssertTrue(page.allSatisfy { $0.id > cursor && $0.id <= upper })
            count += page.count
            cursor = try XCTUnwrap(page.last).id
        }
        XCTAssertEqual(count, 20_000)
        XCTAssertEqual(try f.journal.pendingUploads(afterID: upper).map(\.id), [later])
    }
}
