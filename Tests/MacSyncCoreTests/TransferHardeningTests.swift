import Foundation
import XCTest
@testable import MacSyncCore

final class TransferHardeningTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL, String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-hardening-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (base, source, target, base.appendingPathComponent("journal.sqlite").path)
    }

    func testCapacityPreflightPreventsAnyCopyWhenSpaceTooLow() throws {
        let (base, source, target, database) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = source.appendingPathComponent("very-large.psd")
        try Data("large fake PSD".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-300)], ofItemAtPath: file.path
        )
        let journal = try ChangeJournal(path: database)
        let log = try SyncActivityLog(path: database)
        try journal.enqueue(rootID: "photos", relativePath: "very-large.psd", kind: .upsert)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: log, mappings: [mapping],
            availableCapacity: { _ in 10 }
        )

        let result = try worker.runOnce(enabled: true)
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(result.copied, 0)
        XCTAssertEqual(try journal.pending().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent(".macsync-staging").path
        ))
        XCTAssertTrue(try log.recent().first!.message.contains("Spazio insufficiente"))
    }

    func testSpaceEstimateAccountsForOldBackupAndNewStaging() throws {
        let needed = TransferPreflight.requiredBytes(
            incomingSize: 2_000, existingTargetSize: 3_000, reserveBytes: 100
        )
        XCTAssertEqual(needed, 5_100)
        XCTAssertThrowsError(try TransferPreflight.requireCapacity(
            available: 5_099, incoming: 2_000, existing: 3_000, reserve: 100
        ))
        XCTAssertNoThrow(try TransferPreflight.requireCapacity(
            available: 5_100, incoming: 2_000, existing: 3_000, reserve: 100
        ))
        XCTAssertNoThrow(try TransferPreflight.requireCapacity(
            available: nil, incoming: 2_000, existing: 3_000, reserve: 100
        ))
        XCTAssertEqual(
            TransferPreflight.requiredBytes(incomingSize: Int64.max, existingTargetSize: 5),
            Int64.max
        )
    }

    func testOldMacSyncStagingPreviewAndExplicitCleanupOnly() throws {
        let (base, source, target, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let stage = target.appendingPathComponent(".macsync-staging")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

        let old = stage.appendingPathComponent(UUID().uuidString + ".partial")
        let fresh = stage.appendingPathComponent(UUID().uuidString + ".partial")
        let other = stage.appendingPathComponent("customer-original.psd")
        let backup = target.appendingPathComponent(".macsync-backup-sample")
        try Data("old partial".utf8).write(to: old)
        try Data("new partial".utf8).write(to: fresh)
        try Data("user".utf8).write(to: other)
        try Data("backup".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-9 * 86_400)],
            ofItemAtPath: old.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-9 * 86_400)],
            ofItemAtPath: other.path
        )
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: source, target: target
        )
        let inspected = try StagingMaintenance.inspect(mapping: mapping)
        XCTAssertEqual(inspected.count, 1)
        XCTAssertEqual(inspected.totalBytes, 11)
        XCTAssertEqual(try StagingMaintenance.cleanup(mapping: mapping, inspected: inspected), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try StagingMaintenance.cleanup(
            mapping: mapping, inspected: inspected, approved: true
        ), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testStagingFileChangedSinceInspectionIsNeverRemoved() throws {
        let (base, source, target, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let stage = target.appendingPathComponent(".macsync-staging")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let temporary = stage.appendingPathComponent(UUID().uuidString + ".partial")
        try Data("old".utf8).write(to: temporary)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-9 * 86_400)],
            ofItemAtPath: temporary.path
        )
        let mapping = try MountedFolderMapping(
            rootID: "photos", source: source, target: target
        )
        let examined = try StagingMaintenance.inspect(mapping: mapping)
        XCTAssertEqual(examined.count, 1)
        try Data("this file changed".utf8).write(to: temporary)
        XCTAssertEqual(
            try StagingMaintenance.cleanup(mapping: mapping, inspected: examined, approved: true),
            0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testLogFiltersSearchAndRetention() throws {
        let (base, _, _, database) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let log = try SyncActivityLog(path: database)
        for index in 0..<110 {
            try log.record(
                level: index.isMultiple(of: 2) ? .warning : .success,
                rootID: "photos",
                action: index.isMultiple(of: 2) ? "retry" : "copy",
                relativePath: "f-\(index).jpg", bytes: Int64(index),
                message: index.isMultiple(of: 2) ? "VPN interrupted" : "Copied successfully"
            )
        }
        XCTAssertEqual(try log.recent(limit: 200, level: .warning).count, 55)
        let vpn = try log.recent(limit: 200, search: "vpn")
        XCTAssertEqual(vpn.count, 55)
        XCTAssertEqual(try log.recent(limit: 200, search: "f-109").count, 1)
        XCTAssertEqual(try log.exportText(limit: 10, level: .error).components(
            separatedBy: "\n"
        ).count, 2)
        XCTAssertEqual(try log.prune(retainNewest: 100, maxAgeDays: 90), 10)
        XCTAssertEqual(try log.recent(limit: 200).count, 100)
    }
}
