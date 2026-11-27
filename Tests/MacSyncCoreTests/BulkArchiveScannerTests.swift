import Foundation
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
        // Read a fresh no-follow fingerprint only for differences. Compare
        // all three observations, without changing production or tolerances.
        for (key, item) in expected {
            guard let other = actual[key] else { continue }
            if item != other || item.verificationFingerprint != other.verificationFingerprint {
                let live = try? SeededArchiveVerifier.fingerprint(folder.appendingPathComponent(item.relativePath),
                                                                  directory: item.kind == "directory")
                print("BULK_FINGERPRINT_DIAG label=\(label) path=\(item.relativePath) posix=\(String(describing: item.verificationFingerprint)) bulk=\(String(describing: other.verificationFingerprint)) fresh=\(String(describing: live))")
                XCTAssertEqual(item, other)
                XCTAssertEqual(item.verificationFingerprint, other.verificationFingerprint)
            }
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
    func testIncompatibleNameFailsClosed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("bad."))
        XCTAssertThrowsError(try BulkArchiveScanner.scan(root: folder)) { error in
            XCTAssertEqual(error as? BulkArchiveScanner.Failure, .unsupportedName)
        }
    }
}
