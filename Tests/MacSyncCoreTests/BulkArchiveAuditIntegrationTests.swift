import Foundation
import XCTest
@testable import MacSyncCore

final class BulkArchiveAuditIntegrationTests: XCTestCase {
    private func fixture(mountedTarget: URL? = nil, incompatible: Bool = false,
                         exerciseRepair: Bool = false) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("audit-bulk-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        let target = mountedTarget ?? base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        if mountedTarget == nil {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        func put(_ root: URL, _ relative: String, _ bytes: [UInt8], _ date: Date = stamp) throws {
            let file = root.appendingPathComponent(relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes).write(to: file)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        if mountedTarget == nil {
            try put(source, "same.jpg", [1])
            try put(target, "same.jpg", [1])
            try put(source, "changed.jpg", [2], stamp.addingTimeInterval(60))
            try put(target, "changed.jpg", [3])
            try put(source, "missing.jpg", [4])
            try put(target, "extra.jpg", [5])
            if incompatible {
                try put(target, "bad.", [6])
                try put(target, "old./hidden.jpg", [7])
                try put(source, "old/hidden.jpg", [7])
                try put(source, "ordinary/same.jpg", [8])
                try put(target, "ordinary/same.jpg", [8])
            }
        } else {
            let relative = "folder-0/foto-0-é.jpg"
            let file = target.appendingPathComponent(relative)
            let date = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            try put(source, relative, [0], date)
            try put(source, "missing.jpg", [4])
        }
        let db = base.appendingPathComponent("state.sqlite").path
        let journal = try ChangeJournal(path: db)
        _ = try LocalInventory(path: db).reconcile(rootID: "photos", root: source)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        let original = try ArchiveAudit(journal: journal, mappings: [mapping])
        let candidate = try ArchiveAudit(journal: journal, mappings: [mapping])
        candidate.experimentalBulkInventory = true
        let before = try journal.pending(limit: 10000).map(\.id)
        for mode in ArchiveAuditMode.selectableModes {
            let baseline = try original.run(mode: mode)
            var phases: [String] = []
            let result = try candidate.run(mode: mode, progress: { phases.append($0.phase) })
            XCTAssertTrue(phases.contains("Analisi destinazione · metadati raggruppati · prova"))
            XCTAssertFalse(phases.contains("Analisi destinazione · POSIX · fallback"))
            if incompatible {
                let findings = Dictionary(uniqueKeysWithValues: result.findings.map { ($0.relativePath, $0) })
                XCTAssertEqual(findings["bad."]?.kind, .uncertain)
                XCTAssertEqual(findings["old."]?.kind, .uncertain)
                XCTAssertEqual(findings["old/hidden.jpg"]?.kind, .uncertain)
                XCTAssertEqual(findings["missing.jpg"]?.kind, .uncertain)
                XCTAssertEqual(findings["ordinary/same.jpg"]?.kind, .matching)
                XCTAssertFalse(result.findings.contains { $0.relativePath == "old./hidden.jpg" })
                XCTAssertFalse(result.findings.filter { $0.kind == .uncertain }.contains { $0.repairEligible == true })
            } else {
                XCTAssertEqual(result.findings, baseline.findings)
            }
            XCTAssertEqual(result.sourceMetrics?.files, baseline.sourceMetrics?.files)
            if !incompatible { XCTAssertEqual(result.destinationMetrics?.files, baseline.destinationMetrics?.files) }
            XCTAssertEqual(result.destinationMetrics?.directories, baseline.destinationMetrics?.directories)
            if !incompatible { XCTAssertEqual(result.destinationMetrics?.detectedBytes, baseline.destinationMetrics?.detectedBytes) }
            if !incompatible { XCTAssertEqual(result.metadataMatches, baseline.metadataMatches) }
            if !incompatible { XCTAssertEqual(result.bytesRead, baseline.bytesRead) }
            XCTAssertEqual(result.queuedRepairs, 0)
            XCTAssertEqual(try journal.pending(limit: 10000).map(\.id), before)
            print("BULK_AUDIT_INTEGRATION mode=\(mode.rawValue) incompatible=\(incompatible) fallback=false findings=\(result.findings.count)")
        }
        if exerciseRepair {
            var phases: [String] = []
            _ = try candidate.run(mode: .quick, repair: true, progress: { phases.append($0.phase) })
            XCTAssertFalse(phases.contains(where: { $0.contains("metadati raggruppati") }))
            phases = []
            _ = try candidate.run(mode: .quick, collectMetadataMatches: true, progress: { phases.append($0.phase) })
            XCTAssertFalse(phases.contains(where: { $0.contains("metadati raggruppati") }))
        }
    }

    func testReadOnlyQuickAndIntelligentMatchPOSIX() throws {
        try fixture(exerciseRepair: true)
    }
    func testIncompatibleNameDoesNotRestartAndUncertaintyProtectsMissing() throws {
        try fixture(incompatible: true)
    }
    func testMountedReadOnlyQuickAndIntelligentMatchPOSIX() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mount = env["MACSYNC_TEST_SMB_MOUNT"],
              let name = env["MACSYNC_TEST_BULK_PRESEEDED"] else {
            throw XCTSkip("Disposable SMB fixture not mounted")
        }
        guard name == "macsync-ci-bulk-preseeded", env["MACSYNC_TEST_SMB_HOST"] == "127.0.0.1" else {
            return XCTFail("Not the disposable loopback fixture")
        }
        try fixture(mountedTarget: URL(fileURLWithPath: mount).appendingPathComponent(name))
    }
}
