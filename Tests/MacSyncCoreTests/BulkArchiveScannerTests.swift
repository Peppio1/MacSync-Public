import Foundation
import Darwin
import XCTest
@testable import MacSyncCore

final class BulkArchiveScannerTests: XCTestCase {
    private func fixture(_ root: URL, links: Bool, precreatedName: String? = nil,
                         label: String) throws {
        let name = precreatedName ?? ("bulk-tree-" + UUID().uuidString)
        let folder = root.appendingPathComponent(name)
        let fm = FileManager.default
        let external = root.appendingPathComponent("bulk-external-" + UUID().uuidString)
        defer {
            if precreatedName == nil { try? fm.removeItem(at: folder) }
            if links { try? fm.removeItem(at: external) }
        }
        if precreatedName == nil {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            for d in 0..<8 {
                let sub = folder.appendingPathComponent("folder-\(d)")
                try fm.createDirectory(at: sub, withIntermediateDirectories: false)
                for i in 0..<12 {
                    try Data([UInt8(i)]).write(to: sub.appendingPathComponent("foto-\(i)-é.jpg"))
                }
                try Data([1]).write(to: sub.appendingPathComponent(".DS_Store"))
            }
            let managed = folder.appendingPathComponent(".macsync-temp")
            try fm.createDirectory(at: managed, withIntermediateDirectories: false)
            try Data([1]).write(to: managed.appendingPathComponent("ignored"))
        }
        if links {
            try fm.createDirectory(at: external, withIntermediateDirectories: false)
            try Data([9]).write(to: external.appendingPathComponent("outside-sentinel.jpg"))
            try fm.createSymbolicLink(at: folder.appendingPathComponent("link"),
                                      withDestinationURL: folder.appendingPathComponent("folder-0"))
            try fm.createSymbolicLink(at: folder.appendingPathComponent("outside-link"),
                                      withDestinationURL: external)
            try fm.createSymbolicLink(at: folder.appendingPathComponent("dangling-link"),
                                      withDestinationURL: external.appendingPathComponent("missing"))
        }
        // Independent server witness for the fresh-write experiment only.
        var witnessRoot: URL?
        if label == "smb-fresh-mount" {
            let env = ProcessInfo.processInfo.environment
            let base = try XCTUnwrap(env["MACSYNC_TEST_SMB_ROOT"])
            let marker = URL(fileURLWithPath: base).appendingPathComponent("share-path")
            let share = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard share.hasPrefix("/private/tmp/macsync-ci-share."), env["MACSYNC_TEST_SMB_HOST"] == "127.0.0.1" else {
                return XCTFail("Not the disposable loopback fixture")
            }
            witnessRoot = URL(fileURLWithPath: share).appendingPathComponent(name)
        }
        func serverWitness() throws -> [String: SeedFileFingerprint] {
            guard let witnessRoot else { return [:] }
            var result: [String: SeedFileFingerprint] = [:]
            for d in 0..<8 {
                for i in 0..<12 {
                    let relative = "folder-\(d)/foto-\(i)-é.jpg"
                    var value = stat()
                    guard witnessRoot.appendingPathComponent(relative).path.withCString({ lstat($0, &value) }) == 0,
                          value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                        throw BulkArchiveScanner.Failure.filesystem(errno)
                    }
                    result[relative] = SeedFileFingerprint(fileStat: value)
                }
            }
            return result
        }
        let serverBefore = try serverWitness()
        let legacy = try LocalScanner.scan(root: folder, excludeManaged: true,
                                           ignoreDSStore: true, preferPOSIXMetadata: true)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try BulkArchiveScanner.scan(root: folder, excludeManaged: true, ignoreDSStore: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard case let .complete(rows) = result else { return XCTFail("Bulk unavailable") }
        let expected = Dictionary(uniqueKeysWithValues: legacy.map { (Data($0.relativePath.utf8), $0) })
        let actual = Dictionary(uniqueKeysWithValues: rows.map { (Data($0.relativePath.utf8), $0) })
        let missing = Set(expected.keys).subtracting(actual.keys)
        let extra = Set(actual.keys).subtracting(expected.keys)
        func describe(_ key: Data) -> String {
            "\(String(decoding: key, as: UTF8.self)) [\(key.map { String(format: "%02x", $0) }.joined())]"
        }
        print("BULK_DIAG label=\(label) baseline=\(legacy.count) bulk=\(rows.count) missing=\(missing.count) extra=\(extra.count)")
        for key in missing.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            print("BULK_PATH_ONLY_POSIX \(describe(key))")
        }
        for key in extra.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            print("BULK_PATH_ONLY_BULK \(describe(key))")
        }
        // Independent expected topology, not a normalization-based replacement
        // for the original byte-exact equivalence gate.
        var planned = Set<String>()
        for d in 0..<8 {
            planned.insert("folder-\(d)")
            for i in 0..<12 { planned.insert("folder-\(d)/foto-\(i)-é.jpg") }
        }
        if links {
            planned.formUnion(["link", "outside-link", "dangling-link"])
            for item in legacy + rows {
                XCTAssertFalse(item.relativePath.hasPrefix("link/"))
                XCTAssertFalse(item.relativePath.hasPrefix("outside-link/"))
                XCTAssertFalse(item.relativePath.hasPrefix("dangling-link/"))
                XCTAssertFalse(item.relativePath.contains("outside-sentinel.jpg"))
            }
        }
        XCTAssertEqual(Set(rows.map(\.relativePath)), planned)
        XCTAssertEqual(Set(legacy.map(\.relativePath)), planned, "Legacy topology differs")
        XCTAssertTrue(missing.isEmpty && extra.isEmpty, "Exact path mismatch; see BULK_PATH_ONLY logs")
        let serverAfter = try serverWitness()
        XCTAssertEqual(serverBefore, serverAfter, "Server changed during scanner comparison")
        var observedDifferences = 0
        for (key, item) in expected {
            guard let other = actual[key] else { continue }
            if item != other || item.verificationFingerprint != other.verificationFingerprint {
                observedDifferences += 1
                let live = try? SeededArchiveVerifier.fingerprint(folder.appendingPathComponent(item.relativePath),
                                                                  directory: item.kind == "directory")
                print("BULK_FINGERPRINT_DIAG label=\(label) path=\(item.relativePath) posix=\(String(describing: item.verificationFingerprint)) bulk=\(String(describing: other.verificationFingerprint)) fresh=\(String(describing: live))")
                // Only classify a stale first observation in the explicitly
                // fresh-write experiment, with an independent stable witness.
                // All other cases still require strict first-pass equality.
                guard witnessRoot != nil, item.kind == "file",
                      let old = item.verificationFingerprint,
                      let candidate = other.verificationFingerprint,
                      let fresh = live,
                      let server = serverAfter[item.relativePath] else {
                    XCTAssertEqual(item, other)
                    XCTAssertEqual(item.verificationFingerprint, other.verificationFingerprint)
                    continue
                }
                XCTAssertEqual(old.device, candidate.device)
                XCTAssertEqual(old.inode, candidate.inode)
                XCTAssertEqual(old.size, candidate.size)
                XCTAssertEqual(candidate, fresh, "Bulk must equal exact no-follow reread")
                XCTAssertEqual(server.size, candidate.size)
                // FILETIME has 100ns resolution. Only the server-local
                // witness comparison allows representation precision.
                func sameWireTime(_ s: Int64, _ n: Int64, _ t: Int64, _ m: Int64) -> Bool {
                    guard s == t else { return false }
                    return abs(n - m) < 100
                }
                XCTAssertTrue(sameWireTime(server.mtimeSeconds, server.mtimeNanos,
                                           candidate.mtimeSeconds, candidate.mtimeNanos), "Server mtime differs")
                XCTAssertTrue(sameWireTime(server.ctimeSeconds, server.ctimeNanos,
                                           candidate.ctimeSeconds, candidate.ctimeNanos), "Server ctime differs")
            }
        }
        if witnessRoot != nil {
            // Require a second complete POSIX scan to agree EXACTLY with the
            // candidate; no per-file tolerance or omission of mismatches.
            let repeatLegacy = try LocalScanner.scan(root: folder, excludeManaged: true,
                                                     ignoreDSStore: true, preferPOSIXMetadata: true)
            let repeated = Dictionary(uniqueKeysWithValues: repeatLegacy.map { (Data($0.relativePath.utf8), $0) })
            XCTAssertEqual(Set(repeated.keys), Set(actual.keys))
            for (key, item) in actual {
                let other = try XCTUnwrap(repeated[key])
                XCTAssertEqual(item, other)
                XCTAssertEqual(item.verificationFingerprint, other.verificationFingerprint)
            }
            XCTAssertEqual(try serverWitness(), serverAfter, "Server changed before final comparison")
            print("BULK_FRESH_WRITE_DIAG initial_differences=\(observedDifferences) strict_repeat_checked=\(repeatLegacy.count)")
        }
        XCTAssertEqual(rows.count, links ? 107 : 104)
        var cancelled = false
        XCTAssertThrowsError(try BulkArchiveScanner.scan(root: folder, excludeManaged: true,
            ignoreDSStore: true, shouldContinue: { !cancelled }, onVisit: { _ in cancelled = true }))
        // Deterministic replacement while processing the initial listing.
        var replaced = false
        XCTAssertThrowsError(try BulkArchiveScanner.scan(root: folder, excludeManaged: true,
            ignoreDSStore: true, onVisit: { path in
                guard !replaced, path.hasPrefix("folder-"), !path.contains("/") else { return }
                replaced = true
                let child = folder.appendingPathComponent(path)
                do {
                    try fm.moveItem(at: child, to: folder.appendingPathComponent("replaced"))
                    try fm.createDirectory(at: child, withIntermediateDirectories: false)
                } catch { XCTFail("Fixture replacement failed: \(error)") }
            }))
        XCTAssertTrue(replaced)
        print("BULK_SWIFT_TREE_COMPLETE entries=\(rows.count) seconds=\(elapsed)")
    }
    func testLocalTreeEquivalenceAndConcurrentReplacement() throws {
        try fixture(FileManager.default.temporaryDirectory, links: true, label: "local-link")
    }
    func testSMBTreeEquivalenceAndConcurrentReplacement() throws {
        guard let mount = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_MOUNT"] else {
            throw XCTSkip("Disposable SMB fixture not mounted")
        }
        try fixture(URL(fileURLWithPath: mount), links: false, label: "smb-fresh-mount")
    }
    func testLocalTreeWithoutSymlink() throws {
        try fixture(FileManager.default.temporaryDirectory, links: false, label: "local-no-link")
    }
    func testStableServerCreatedSMBTree() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mount = env["MACSYNC_TEST_SMB_MOUNT"],
              let name = env["MACSYNC_TEST_BULK_PRESEEDED"] else {
            throw XCTSkip("Preseeded disposable SMB fixture not mounted")
        }
        guard name == "macsync-ci-bulk-preseeded", env["MACSYNC_TEST_SMB_HOST"] == "127.0.0.1" else {
            return XCTFail("Not the disposable loopback fixture")
        }
        try fixture(URL(fileURLWithPath: mount), links: false, precreatedName: name,
                    label: "smb-server-preseeded")
    }
    func testIncompatibleNamesRemainVisibleWithoutTraversingUnsafeDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("bad."))
        let unsafe = folder.appendingPathComponent("old.")
        try fm.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try Data([2]).write(to: unsafe.appendingPathComponent("hidden-child.jpg"))
        try Data([3]).write(to: folder.appendingPathComponent("normal.jpg"))
        let result = try BulkArchiveScanner.scan(root: folder)
        guard case .complete(let rows) = result else { return XCTFail("Unexpected fallback") }
        XCTAssertEqual(Set(rows.map(\.relativePath)), ["bad.", "old.", "normal.jpg"])
        XCTAssertNotNil(rows.first { $0.relativePath == "bad." }?.verificationUncertainty)
        XCTAssertEqual(rows.first { $0.relativePath == "bad." }?.size, 1)
        XCTAssertNil(rows.first { $0.relativePath == "bad." }?.verificationFingerprint)
        XCTAssertNotNil(rows.first { $0.relativePath == "old." }?.verificationUncertainty)
        XCTAssertNil(rows.first { $0.relativePath == "normal.jpg" }?.verificationUncertainty)
    }
}
