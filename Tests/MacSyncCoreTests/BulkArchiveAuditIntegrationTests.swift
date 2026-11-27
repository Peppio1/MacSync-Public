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

    // Compare the actual mounted reader with the known server-side fixture.
    // The local witness is CI-only: it is not an available production oracle.
    private func incompatibleSMB(_ name: String, probes: [String],
                                 expectedRaw: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        guard let mount = env["MACSYNC_TEST_SMB_MOUNT"],
              let basePath = env["MACSYNC_TEST_SMB_ROOT"],
              env["MACSYNC_TEST_BULK_PRESEEDED"] == "macsync-ci-bulk-preseeded" else {
            throw XCTSkip("Disposable SMB fixture not mounted")
        }
        let allowed = ["macsync-ci-raw", "macsync-ci-sfm", "macsync-ci-alias",
                       "macsync-ci-colon", "macsync-ci-dot-duplicates", "macsync-ci-space"]
        guard allowed.contains(name), env["MACSYNC_TEST_SMB_HOST"] == "127.0.0.1" else {
            return XCTFail("Not the disposable loopback fixture")
        }
        let fm = FileManager.default
        let marker = URL(fileURLWithPath: basePath).appendingPathComponent("share-path")
        let share = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard share.hasPrefix("/private/tmp/macsync-ci-share.") else {
            return XCTFail("Not the disposable server directory")
        }
        let witness = URL(fileURLWithPath: share).appendingPathComponent(name)
        let target = URL(fileURLWithPath: mount).appendingPathComponent(name)
        let base = fm.temporaryDirectory.appendingPathComponent("bulk-unsafe-smb-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = try XCTUnwrap(fm.enumerator(at: witness, includingPropertiesForKeys: [.isDirectoryKey]))
            for case let file as URL in enumerator {
                let relative = String(file.path.dropFirst(witness.path.count + 1))
                if try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    result[relative + "/"] = Data()
                } else {
                    result[relative] = try Data(contentsOf: file)
                }
            }
            return result
        }
        let before = try snapshot()
        for raw in expectedRaw {
            XCTAssertTrue(before.keys.contains(raw), "Missing independent fixture entry: \(raw)")
        }
        let serverNames = try fm.contentsOfDirectory(atPath: witness.path).sorted()
        let mountedNames = try fm.contentsOfDirectory(atPath: target.path).sorted()
        func exact(_ name: String) -> String {
            "\(name.debugDescription) [\(name.utf8.map { String(format: "%02x", $0) }.joined())]"
        }
        print("BULK_SMB_NAMES fixture=\(name) server=\(serverNames.map(exact)) mount=\(mountedNames.map(exact))")
        let control = "compatible-control/sentinel.jpg"
        let controlURL = source.appendingPathComponent(control)
        try fm.createDirectory(at: controlURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: witness.appendingPathComponent(control)).write(to: controlURL)
        let date = try XCTUnwrap(try target.appendingPathComponent(control)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: controlURL.path)
        for probe in probes {
            let file = source.appendingPathComponent(probe)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        let db = base.appendingPathComponent("state.sqlite").path
        let journal = try ChangeJournal(path: db)
        _ = try LocalInventory(path: db).reconcile(rootID: "photos", root: source)
        let mapping = try MountedFolderMapping(rootID: "photos", source: source, target: target)
        let candidate = try ArchiveAudit(journal: journal, mappings: [mapping])
        candidate.experimentalBulkInventory = true
        let pendingBefore = try journal.pending(limit: 10000).map(\.id)
        for mode in ArchiveAuditMode.selectableModes {
            var phases: [String] = []
            do {
                let result = try candidate.run(mode: mode, progress: { phases.append($0.phase) })
                let findings = Dictionary(grouping: result.findings, by: \.relativePath)
                for finding in result.findings {
                    print("BULK_SMB_FINDING fixture=\(name) mode=\(mode.rawValue) path=\(exact(finding.relativePath)) kind=\(finding.kind.rawValue) detail=\(finding.detail)")
                }
                XCTAssertTrue(phases.contains("Analisi destinazione · metadati raggruppati · prova"))
                XCTAssertFalse(phases.contains("Analisi destinazione · POSIX · fallback"))
                XCTAssertEqual(findings[control]?.first?.kind, .matching, "Compatible sibling must remain usable")
                for probe in probes {
                    XCTAssertEqual(findings[probe]?.first?.kind, .uncertain,
                        "Potential hidden/aliased entry must not be called missing or matching: \(probe)")
                }
                XCTAssertFalse(result.findings.filter { $0.kind == .uncertain }.contains { $0.repairEligible == true })
                XCTAssertEqual(result.queuedRepairs, 0)
                print("BULK_SMB_UNSAFE_RESULT fixture=\(name) mode=\(mode.rawValue) findings=\(result.findings.count) uncertain=\(result.count(.uncertain)) fallback=false")
            } catch {
                // A failed read is safe, but fails this continuation gate.
                print("BULK_SMB_UNSAFE_ABORT fixture=\(name) mode=\(mode.rawValue) error=\(error)")
                XCTFail("Cannot continue compatible siblings: \(error)")
            }
            XCTAssertEqual(try journal.pending(limit: 10000).map(\.id), pendingBefore)
            XCTAssertEqual(try snapshot(), before, "Read-only diagnostic changed server content")
        }
    }

    func testSMBRawTrailingDot() throws {
        try incompatibleSMB("macsync-ci-raw", probes: ["Foto12345/child.jpg"],
                            expectedRaw: ["Foto12345./child.jpg"])
    }
    func testSMBSFMTrailingDot() throws {
        try incompatibleSMB("macsync-ci-sfm", probes: ["Foto12345/child.jpg"],
                            expectedRaw: ["Foto12345\u{F029}/child.jpg"])
    }
    func testSMBSFMSpaceAlias() throws {
        try incompatibleSMB("macsync-ci-alias", probes: ["keep"],
                            expectedRaw: ["keep", "keep\u{F028}"])
    }
    func testSMBRawAndSFMColon() throws {
        try incompatibleSMB("macsync-ci-colon", probes: ["Raw:old/child.jpg", "SFM:old/child.jpg"],
                            expectedRaw: ["Raw:old/child.jpg", "SFM\u{F022}old/child.jpg"])
    }
    func testSMBHiddenDotAlongsideCorrectedNames() throws {
        try incompatibleSMB("macsync-ci-dot-duplicates", probes: ["Hidden/child.jpg", "Equal/child.jpg", "Different/child.jpg"],
                            expectedRaw: ["Hidden./child.jpg", "Hidden-/child.jpg",
                                          "Equal\u{F029}/child.jpg", "Different\u{F029}/child.jpg"])
    }
    func testSMBRawTrailingSpace() throws {
        try incompatibleSMB("macsync-ci-space", probes: ["Space/child.jpg"],
                            expectedRaw: ["Space /child.jpg"])
    }
}
