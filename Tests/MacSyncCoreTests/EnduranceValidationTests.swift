import Foundation
import Darwin
import XCTest
@testable import MacSyncCore

/// Accelerated local regression scenarios; not a timed eight-hour soak,
/// an application GUI benchmark, or an SMB throughput measurement.
final class EnduranceValidationTests: XCTestCase {
    private enum InjectedFailure: Error { case afterPublication }

    private struct ResourceSample {
        let wall: Double
        let cpu: Double
        let peakBytes: Int64
    }

    private func resources() -> ResourceSample? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ t: timeval) -> Double {
            Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        }
        // Darwin reports ru_maxrss in bytes, for the entire process lifetime.
        return ResourceSample(wall: ProcessInfo.processInfo.systemUptime,
                              cpu: seconds(usage.ru_utime) + seconds(usage.ru_stime),
                              peakBytes: Int64(usage.ru_maxrss))
    }

    private func report(_ name: String, _ start: ResourceSample?) {
        guard let start, let end = resources() else {
            print("MACSYNC_VALIDATION \(name) resource_sample_unavailable")
            return
        }
        let wall = max(0, end.wall - start.wall)
        let cpu = max(0, end.cpu - start.cpu)
        print("MACSYNC_VALIDATION \(name) wall_s=\(wall) cpu_s=\(cpu) cpu_percent_one_core=\(wall > 0 ? 100 * cpu / wall : 0) process_lifetime_peak_rss_before_bytes=\(start.peakBytes) process_lifetime_peak_rss_after_bytes=\(end.peakBytes)")
    }

    private func directory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-\(name)-" + UUID().uuidString)
            .resolvingSymlinksInPath()
    }

    private func put(_ url: URL, _ data: Data) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path)
    }

    func testNinetySixAcceleratedCyclesWithPersistentHistoryAndNoRedundantCopy() throws {
        let resourceStart = resources()
        defer { report("96_cycles", resourceStart) }
        let fm = FileManager.default
        let base = directory("endurance")
        defer { try? fm.removeItem(at: base) }
        let sources = ["source-a", "source-b"].map { base.appendingPathComponent($0) }
        let targets = ["target-a", "target-b"].map { base.appendingPathComponent($0) }
        let roots = ["a", "b"]
        for url in sources + targets { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let db = base.appendingPathComponent("state.sqlite").path
        let maps = try roots.indices.map {
            try MountedFolderMapping(rootID: roots[$0], source: sources[$0], target: targets[$0])
        }
        let inventory = try LocalInventory(path: db)
        let journal = try ChangeJournal(path: db)
        let log = try SyncActivityLog(path: db)
        let history = try SyncCycleHistory(path: db)
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: maps,
                                                 availableCapacity: { _ in nil })
        let initial = Data(repeating: 0, count: 64 * 1024)
        for i in roots.indices {
            for n in 0..<8 { try put(sources[i].appendingPathComponent("photo-\(n).jpg"), initial) }
            _ = try inventory.reconcile(rootID: roots[i], root: sources[i])
        }
        XCTAssertEqual(try worker.runCycle(enabled: true).created, 16)
        XCTAssertTrue(try journal.pending().isEmpty)

        // 48 active cycles interleaved with 48 idle cycles. The same worker
        // stays alive; history is recorded from actual engine events.
        var updates = 0
        var totalBytes: Int64 = 0
        for cycle in 0..<96 {
            try autoreleasepool {
                let active = cycle % 2 == 0
                let started = Date()
                let tick = ProcessInfo.processInfo.systemUptime
                let id = "cycle-\(cycle)"
                if active {
                    let i = (cycle / 2) % 2
                    let n = (cycle / 4) % 8
                    let url = sources[i].appendingPathComponent("photo-\(n).jpg")
                    try put(url, Data(repeating: UInt8(cycle + 1), count: initial.count))
                    _ = try inventory.reconcile(rootID: roots[i], root: sources[i], subtree: url)
                }
                try history.begin(id: id, sessionID: "endurance", at: started)
                var historyError: Error?
                worker.onEvent = { event in
                    do { try history.append(cycleID: id, event: event) }
                    catch { historyError = error }
                }
                defer { worker.onEvent = nil }
                let result = try worker.runCycle(enabled: true, pageSize: 7)
                XCTAssertNil(historyError)
                XCTAssertFalse(result.interrupted)
                XCTAssertEqual(result.failed, 0)
                XCTAssertEqual(result.deferred, 0)
                XCTAssertEqual(result.created, 0)
                XCTAssertEqual(result.updated, active ? 1 : 0)
                XCTAssertEqual(result.bytes, active ? Int64(initial.count) : 0)
                XCTAssertTrue(try journal.pending().isEmpty)
                updates += result.updated
                totalBytes += result.bytes
                try history.finish(id: id, at: Date(),
                                   seconds: ProcessInfo.processInfo.systemUptime - tick, state: "completed")
                let totals = try history.totals(cycleID: id)
                XCTAssertEqual(totals.stats.updatedFiles, result.updated)
                XCTAssertEqual(totals.stats.bytesTransferred, result.bytes)
            }
        }
        XCTAssertEqual(updates, 48)
        XCTAssertEqual(totalBytes, 48 * Int64(initial.count))
        let reopened = try SyncCycleHistory(path: db)
        let cycles = try reopened.cycles(limit: 100)
        XCTAssertEqual(cycles.count, 96)
        XCTAssertTrue(cycles.allSatisfy { $0.state == "completed" && $0.ended != nil })
        XCTAssertEqual(try reopened.totals(sessionID: "endurance").stats.updatedFiles, 48)
        let audit = try ArchiveAudit(journal: journal, mappings: maps).run(mode: .deep)
        XCTAssertEqual(audit.count(.matching), 16)
        XCTAssertEqual(audit.findings.count, 16)
        XCTAssertEqual(audit.queuedRepairs, 0)
        try ArchiveDatabaseSafety.verify(URL(fileURLWithPath: db))
    }

    func testLargeInventoryTargetedChangeCancelledScanAndPortableSnapshot() throws {
        let resourceStart = resources()
        defer { report("10000_files_inventory", resourceStart) }
        let fm = FileManager.default
        let base = directory("inventory")
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let db = base.appendingPathComponent("state.sqlite")
        let fileData = Data("synthetic metadata workload".utf8)
        for folder in 0..<100 {
            let url = source.appendingPathComponent("album-\(folder)")
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            for file in 0..<100 {
                try fileData.write(to: url.appendingPathComponent("photo-\(file).jpg"))
            }
        }
        let inventory = try LocalInventory(path: db.path)
        let journal = try ChangeJournal(path: db.path)
        let scanStart = resources()
        let initial = try inventory.reconcile(rootID: "photos", root: source, eventID: 10)
        report("10000_files_initial_scan", scanStart)
        XCTAssertEqual(initial.inspected, 10_100)
        XCTAssertEqual(initial.queuedUpserts, 10_100)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 10_100)
        XCTAssertEqual(initial.queuedDeletes, 0)
        // Only baseline inventory/queue scale, not copying ten thousand files.
        var completed = 0
        while true {
            let page = try journal.pendingUploads(limit: 250)
            if page.isEmpty { break }
            for job in page { try journal.markCompleted(id: job.id) }
            completed += page.count
        }
        XCTAssertEqual(completed, 10_100)
        let unchanged = try inventory.reconcile(rootID: "photos", root: source)
        XCTAssertEqual(unchanged.queuedUpserts, 0)
        XCTAssertEqual(unchanged.queuedDeletes, 0)
        XCTAssertTrue(try journal.pending().isEmpty)

        let changed = source.appendingPathComponent("album-50/photo-50.jpg")
        try Data("new content".utf8).write(to: changed, options: .atomic)
        let targeted = try inventory.reconcile(rootID: "photos", root: source, subtree: changed, eventID: 11)
        XCTAssertEqual(targeted.inspected, 1)
        XCTAssertEqual(targeted.queuedUpserts, 1)
        let before = try journal.pending()
        XCTAssertEqual(before.map(\.relativePath), ["album-50/photo-50.jpg"])
        // Cancel a full scan after a real item callback, without advancing
        // the event checkpoint or mutating the committed queue.
        var visited = 0
        XCTAssertThrowsError(try inventory.reconcile(rootID: "photos", root: source, eventID: 12,
            shouldContinue: { visited < 200 }, onItem: { _ in visited += 1 }))
        XCTAssertGreaterThanOrEqual(visited, 200)
        XCTAssertEqual(try inventory.lastEventID(rootID: "photos"), 11)
        XCTAssertEqual(try inventory.itemCount(rootID: "photos"), 10_100)
        XCTAssertEqual(try journal.pending(), before)

        let backup = base.appendingPathComponent("backup.sqlite")
        try ArchiveDatabaseSafety.backup(db, to: backup)
        try ArchiveDatabaseSafety.verify(backup, readOnly: true)
        let restored = base.appendingPathComponent("restored.sqlite")
        try fm.copyItem(at: backup, to: restored)
        XCTAssertEqual(try LocalInventory(path: restored.path).itemCount(rootID: "photos"), 10_100)
        XCTAssertEqual(try ChangeJournal(path: restored.path).pending(), before)
    }

    func testInterruptedPublicationAndHistoryRecoveryAfterReopeningDatabase() throws {
        let resourceStart = resources()
        defer { report("interrupted_publication", resourceStart) }
        let fm = FileManager.default
        let base = directory("restart")
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        for url in [source, target] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let db = base.appendingPathComponent("state.sqlite").path
        let file = source.appendingPathComponent("photo.psd")
        let destination = target.appendingPathComponent("photo.psd")
        let original = Data(repeating: 1, count: 1024 * 1024)
        let replacement = Data(repeating: 2, count: original.count)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        try put(file, original)
        do {
            let inventory = try LocalInventory(path: db)
            let journal = try ChangeJournal(path: db)
            let worker = try MountedFolderCopyWorker(journal: journal, log: SyncActivityLog(path: db),
                                                     mappings: [mapping], availableCapacity: { _ in nil })
            _ = try inventory.reconcile(rootID: "photos", root: source)
            XCTAssertEqual(try worker.runCycle(enabled: true).created, 1)
            try put(file, replacement)
            _ = try inventory.reconcile(rootID: "photos", root: source)
            let history = try SyncCycleHistory(path: db)
            try history.begin(id: "unfinished", sessionID: "old", at: Date())
            worker.checkpoint = { phase, _ in
                if phase == .afterPublish { throw InjectedFailure.afterPublication }
            }
            XCTAssertEqual(try worker.runCycle(enabled: true).failed, 1)
            XCTAssertEqual(try journal.pendingUploads().count, 1)
            XCTAssertEqual(try Data(contentsOf: destination), replacement)
        }
        // Reopen all database connections. This models the interrupted
        // publication boundary, not a real kill/power failure.
        let journal = try ChangeJournal(path: db)
        let history = try SyncCycleHistory(path: db)
        try history.markInterrupted(exceptSession: "new")
        let interrupted = try XCTUnwrap(history.cycles().first)
        XCTAssertEqual(interrupted.state, "interrupted")
        XCTAssertNil(interrupted.ended)
        let worker = try MountedFolderCopyWorker(journal: journal, log: SyncActivityLog(path: db),
                                                 mappings: [mapping], availableCapacity: { _ in nil })
        worker.checkpoint = { phase, _ in
            if phase == .beforeStageCopy { XCTFail("Already published content must not be transferred again") }
        }
        let recovered = try worker.runCycle(enabled: true)
        XCTAssertEqual(recovered.reconciled, 1)
        XCTAssertEqual(recovered.bytes, 0)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), replacement)
        XCTAssertEqual(try worker.runCycle(enabled: true).copied, 0)
        try ArchiveDatabaseSafety.verify(URL(fileURLWithPath: db))
    }
}
