import Foundation
import XCTest
@testable import MacSyncCore

final class BulkArchiveScannerTests: XCTestCase {
    private func fixture(_ root: URL, links: Bool) throws {
        let folder = root.appendingPathComponent("bulk-tree-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
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
        if links {
            try fm.createSymbolicLink(at: folder.appendingPathComponent("link"),
                                      withDestinationURL: folder.appendingPathComponent("folder-0"))
        }
        let legacy = try LocalScanner.scan(root: folder, excludeManaged: true,
                                           ignoreDSStore: true, preferPOSIXMetadata: true)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try BulkArchiveScanner.scan(root: folder, excludeManaged: true, ignoreDSStore: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        guard case let .complete(rows) = result else { return XCTFail("Bulk unavailable") }
        let expected = Dictionary(uniqueKeysWithValues: legacy.map { (Data($0.relativePath.utf8), $0) })
        let actual = Dictionary(uniqueKeysWithValues: rows.map { (Data($0.relativePath.utf8), $0) })
        XCTAssertEqual(Set(expected.keys), Set(actual.keys))
        for (key, item) in expected {
            let other = try XCTUnwrap(actual[key])
            XCTAssertEqual(item, other)
            XCTAssertEqual(item.verificationFingerprint, other.verificationFingerprint)
        }
        XCTAssertEqual(rows.count, links ? 105 : 104)
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
        try fixture(FileManager.default.temporaryDirectory, links: true)
    }
    func testSMBTreeEquivalenceAndConcurrentReplacement() throws {
        guard let mount = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_MOUNT"] else {
            throw XCTSkip("Disposable SMB fixture not mounted")
        }
        try fixture(URL(fileURLWithPath: mount), links: false)
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
