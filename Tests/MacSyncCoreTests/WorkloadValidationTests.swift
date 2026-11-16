import Foundation
import XCTest
@testable import MacSyncCore

/// Synthetic local workload, not a performance benchmark of SMB or VPN.
/// File counts match a representative working day; file sizes are scaled.
final class WorkloadValidationTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-workload-" + UUID().uuidString)
            .resolvingSymlinksInPath()
    }
    private func put(_ url: URL, _ data: Data) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -300)],
                                              ofItemAtPath: url.path)
    }

    func testDailyWorkloadAcrossTwoMappingsWithInterruptionAndRepeatedCycles() throws {
        let fm = FileManager.default
        let base = temporaryRoot()
        defer { try? fm.removeItem(at: base) }
        let sources = [base.appendingPathComponent("source-a"), base.appendingPathComponent("source-b")]
        let targets = [base.appendingPathComponent("target-a"), base.appendingPathComponent("target-b")]
        for url in sources + targets { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let db = base.appendingPathComponent("state.sqlite").path
        let roots = ["a", "b"]
        let maps = try roots.indices.map {
            try MountedFolderMapping(rootID: roots[$0], source: sources[$0], target: targets[$0])
        }
        let inventory = try LocalInventory(path: db)
        let journal = try ChangeJournal(path: db)
        let log = try SyncActivityLog(path: db)
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: maps,
                                                 availableCapacity: { _ in nil })
        let specs = (0..<4).map { ("raw-\($0).dng", 1536 * 1024) }
            + (0..<4).map { ("image-\($0).jpg", 160 * 1024) }
            + [("edited.psd", 3 * 1024 * 1024)]
        var expectedBytes: Int64 = 0
        for folder in 0..<40 {
            let root = sources[folder % 2].appendingPathComponent("album-\(folder)")
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            for (index, spec) in specs.enumerated() {
                try put(root.appendingPathComponent(spec.0),
                        Data(repeating: UInt8((folder * 9 + index) % 251), count: spec.1))
                expectedBytes += Int64(spec.1)
            }
        }
        for i in roots.indices { _ = try inventory.reconcile(rootID: roots[i], root: sources[i]) }
        var stopped = false
        let partial = try worker.runCycle(enabled: true, pageSize: 37,
            shouldContinue: { !stopped }, onProgress: { _ in stopped = true })
        XCTAssertTrue(partial.interrupted)
        XCTAssertGreaterThan(partial.created, 0)
        XCTAssertLessThan(partial.created, 360)
        XCTAssertEqual(partial.failed, 0)
        let reopened = try ChangeJournal(path: db)
        XCTAssertFalse(try reopened.pendingUploads().isEmpty)
        let resumed = try MountedFolderCopyWorker(journal: reopened, log: SyncActivityLog(path: db),
                                                  mappings: maps, availableCapacity: { _ in nil })
        let remaining = try resumed.runCycle(enabled: true, pageSize: 61)
        XCTAssertEqual(partial.created + remaining.created, 360)
        XCTAssertEqual(partial.bytes + remaining.bytes, expectedBytes)
        XCTAssertEqual(remaining.failed, 0)
        XCTAssertEqual(remaining.deferred, 0)
        XCTAssertTrue(try reopened.pending().isEmpty)
        for folder in 0..<40 {
            for (name, _) in specs {
                let relative = "album-\(folder)/\(name)"
                XCTAssertEqual(try Data(contentsOf: sources[folder % 2].appendingPathComponent(relative)),
                               try Data(contentsOf: targets[folder % 2].appendingPathComponent(relative)),
                               relative)
            }
        }

        // Four further working cycles, changing one file in ten albums
        // each time, including same-size and same-mtime replacement.
        for cycle in 0..<4 {
            for folder in (cycle * 10)..<((cycle + 1) * 10) {
                let relative = "album-\(folder)/edited.psd"
                try put(sources[folder % 2].appendingPathComponent(relative),
                        Data(repeating: 0xFF, count: 3 * 1024 * 1024))
            }
            for i in roots.indices { _ = try inventory.reconcile(rootID: roots[i], root: sources[i]) }
            let update = try resumed.runCycle(enabled: true, pageSize: 7)
            XCTAssertEqual(update.created, 0)
            XCTAssertEqual(update.updated, 10)
            XCTAssertEqual(update.failed, 0)
            XCTAssertEqual(update.deferred, 0)
            XCTAssertTrue(try reopened.pending().isEmpty)
            XCTAssertEqual(try resumed.runCycle(enabled: true).copied, 0)
        }
        let report = try ArchiveAudit(journal: reopened, mappings: maps).run(mode: .deep)
        XCTAssertEqual(report.findings.filter { $0.kind == .matching && $0.objectKind == "file" }.count, 360)
        XCTAssertEqual(report.findings.filter { $0.kind == .matching && $0.objectKind == "directory" }.count, 40)
        XCTAssertEqual(report.count(.matching), 400)
        XCTAssertEqual(report.count(.uncertain), 0)
        XCTAssertEqual(report.count(.missing), 0)
        XCTAssertEqual(report.count(.different), 0)
        XCTAssertEqual(report.count(.extra), 0)
        XCTAssertEqual(report.queuedRepairs, 0)
        XCTAssertTrue(try reopened.pending().isEmpty)
    }

    func testPersistentMirrorAfterRealCopyWithAndWithoutRecovery() throws {
        for recover in [false, true] {
            let fm = FileManager.default
            let base = temporaryRoot()
            defer { try? fm.removeItem(at: base) }
            let source = base.appendingPathComponent("source")
            let target = base.appendingPathComponent("target")
            for url in [source, target] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
            let db = base.appendingPathComponent("state.sqlite").path
            let inventory = try LocalInventory(path: db)
            let journal = try ChangeJournal(path: db)
            let log = try SyncActivityLog(path: db)
            let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
            let movedData = Data("original image".utf8)
            let retained = Data("retained image".utf8)
            let removedData = Data("removed image".utf8)
            try put(source.appendingPathComponent("old.jpg"), movedData)
            try put(source.appendingPathComponent("keep.jpg"), retained)
            try put(source.appendingPathComponent("delete.jpg"), removedData)
            _ = try inventory.reconcile(rootID: "photos", root: source)
            let copies = try MountedFolderCopyWorker(journal: journal, log: log, mappings: [mapping],
                                                     availableCapacity: { _ in nil })
            XCTAssertEqual(try copies.runCycle(enabled: true).created, 3)
            let authorization = try MirrorAuthorization.capture(journal: journal, mappings: [mapping])
            let saved = try JSONEncoder().encode(authorization)
            try fm.moveItem(at: source.appendingPathComponent("old.jpg"),
                            to: source.appendingPathComponent("new.jpg"))
            try fm.removeItem(at: source.appendingPathComponent("delete.jpg"))
            _ = try inventory.reconcile(rootID: "photos", root: source)
            let reopened = try ChangeJournal(path: db)
            let mirror = try MirrorDeletionWorker(journal: reopened, manifest: RecoveryManifest(path: db),
                log: SyncActivityLog(path: db), mappings: [mapping],
                policy: MirrorDeletionPolicy(enabled: true, recoveryEnabled: recover, retentionDays: nil),
                authorization: JSONDecoder().decode(MirrorAuthorization.self, from: saved),
                protections: MirrorProtectionSettings())
            let blocked = try mirror.runCycle()
            XCTAssertTrue(blocked.blocked)
            XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("old.jpg").path))
            XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("delete.jpg").path))
            XCTAssertEqual(try copies.runCycle(enabled: true).created, 1)
            let result = try mirror.runCycle()
            XCTAssertEqual(result.removed, recover ? 0 : 2)
            XCTAssertEqual(result.recovered, recover ? 2 : 0)
            XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("old.jpg").path))
            XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("delete.jpg").path))
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("new.jpg")), movedData)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("keep.jpg")), retained)
            XCTAssertTrue(try reopened.pending().isEmpty)
            let recovery = target.appendingPathComponent(".macsync-recovery")
            if recover {
                let folders = try fm.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
                var recovered: [String: Data] = [:]
                for folder in folders {
                    for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                        recovered[file.lastPathComponent] = try Data(contentsOf: file)
                    }
                }
                XCTAssertEqual(recovered, ["old.jpg": movedData, "delete.jpg": removedData])
                XCTAssertEqual(try mirror.pruneExpiredRecovery(now: Date().addingTimeInterval(365 * 86400)), 0)
            } else {
                XCTAssertFalse(fm.fileExists(atPath: recovery.path))
            }
            let report = try ArchiveAudit(journal: reopened, mappings: [mapping]).run(mode: .deep)
            XCTAssertEqual(report.count(.matching), 2)
            XCTAssertEqual(report.count(.missing), 0)
            XCTAssertEqual(report.count(.different), 0)
            XCTAssertEqual(report.count(.extra), 0)
        }
    }
}
