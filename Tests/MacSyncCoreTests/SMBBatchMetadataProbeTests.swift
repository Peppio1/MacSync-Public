import Foundation
import XCTest
@testable import MacSyncCore

/// Read-only measurement on a disposable fixture, never an operational ACK.
final class SMBBatchMetadataProbeTests: XCTestCase {
    private struct Item {
        let path: String
        let kind: String
        let size: Int64
        let modified: Double?
    }
    private func scan(_ root: URL) throws -> [Item] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var pending: [(URL, String)] = [(root, "")]
        var result: [Item] = []
        while let (folder, prefix) = pending.popLast() {
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: []) {
                let name = file.lastPathComponent
                if name == ".DS_Store" || name.lowercased().hasPrefix(".macsync-") { continue }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let v = try file.resourceValues(forKeys: keys)
                let kind: String
                if v.isSymbolicLink == true { kind = "symlink" }
                else if v.isDirectory == true { kind = "directory" }
                else if v.isRegularFile == true { kind = "file" }
                else { throw JournalError.database("Unknown metadata type") }
                if kind == "file" && (v.fileSize == nil || v.contentModificationDate == nil) { throw JournalError.database("Incomplete metadata") }
                result.append(Item(path: path, kind: kind, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate?.timeIntervalSince1970))
                if kind == "directory" { pending.append((file, path)) }
            }
        }
        return result
    }
    private func compare(_ root: URL, label: String, reverse: Bool) throws {
        var baseline: [TrackedItem] = []
        var candidate: [Item] = []
        var baselineTime = 0.0, candidateTime = 0.0
        func measureBaseline() throws {
            let start = ProcessInfo.processInfo.systemUptime
            baseline = try LocalScanner.scan(root: root, excludeManaged: true, ignoreDSStore: true, preferPOSIXMetadata: true)
            baselineTime = ProcessInfo.processInfo.systemUptime - start
        }
        func measureCandidate() throws {
            let start = ProcessInfo.processInfo.systemUptime
            candidate = try scan(root)
            candidateTime = ProcessInfo.processInfo.systemUptime - start
        }
        if reverse { try measureCandidate(); try measureBaseline() }
        else { try measureBaseline(); try measureCandidate() }
        let a = Dictionary(grouping: baseline, by: { Data($0.relativePath.utf8) })
        let b = Dictionary(grouping: candidate, by: { Data($0.path.utf8) })
        XCTAssertEqual(baseline.count, 312)
        XCTAssertEqual(Set(a.keys), Set(b.keys))
        XCTAssertEqual(baseline.count, candidate.count)
        var maxDelta = 0.0
        for (key, values) in a {
            XCTAssertEqual(values.count, 1)
            guard let x = values.first, let matches = b[key], matches.count == 1, let y = matches.first else {
                XCTFail("Missing or duplicate exact path"); continue
            }
            XCTAssertEqual(x.kind, y.kind)
            if x.kind == "file" {
                XCTAssertEqual(x.size, y.size)
                let delta = abs(x.modifiedAt - (try XCTUnwrap(y.modified)))
                maxDelta = max(maxDelta, delta)
                XCTAssertLessThan(delta, 0.002)
            }
        }
        print("SMB_BATCH_METADATA medium=\(label) reverse=\(reverse) entries=\(baseline.count) baselineSeconds=\(baselineTime) candidateSeconds=\(candidateTime) maxMtimeDelta=\(maxDelta)")
    }
    func testPrefetchedMetadataAgainstCurrentScanner() throws {
        let mount = try XCTUnwrap(ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_MOUNT"])
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = URL(fileURLWithPath: mount).appendingPathComponent("macsync-batch-probe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: local); try? FileManager.default.removeItem(at: remote) }
        for root in [local, remote] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for d in 0..<24 {
                let folder = root.appendingPathComponent("cartella-\(d)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                for f in 0..<12 {
                    try Data(repeating: UInt8(f), count: 128 + f).write(to: folder.appendingPathComponent("foto-\(f)-é.jpg"))
                }
                try Data([1]).write(to: folder.appendingPathComponent(".DS_Store"))
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".macsync-hidden"), withIntermediateDirectories: false)
            try Data([2]).write(to: root.appendingPathComponent(".macsync-hidden/ignored.jpg"))
        }
        try compare(local, label: "local", reverse: false)
        try compare(local, label: "local", reverse: true)
        try compare(remote, label: "mounted-smb", reverse: false)
        try compare(remote, label: "mounted-smb", reverse: true)
    }
}
