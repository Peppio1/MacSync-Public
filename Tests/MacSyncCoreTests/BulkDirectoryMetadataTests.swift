import Foundation
import Darwin
import XCTest
@testable import MacSyncCore

final class BulkDirectoryMetadataTests: XCTestCase {
    private func fixture(_ root: URL) throws {
        let folder = root.appendingPathComponent("bulk-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("foto-é.jpg")
        try Data([1, 2, 3]).write(to: file)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("directory"),
                                                withIntermediateDirectories: false)
        func withFD<T>(_ body: (Int32) throws -> T) throws -> T {
            let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw BulkDirectoryMetadata.Failure.filesystem(errno) }
            defer { close(fd) }
            return try body(fd)
        }
        let result = try withFD { try BulkDirectoryMetadata.read(fd: $0) }
        guard case let .complete(rows) = result else { return XCTFail("Bulk unavailable on fixture") }
        XCTAssertEqual(rows.count, 2)
        let item = try XCTUnwrap(rows.first { $0.kind == "file" })
        XCTAssertEqual(item.fileFingerprint, try SeededArchiveVerifier.fingerprint(file))
        let directory = try XCTUnwrap(rows.first { $0.kind == "directory" })
        XCTAssertNil(directory.fileFingerprint)
        XCTAssertNil(directory.size)
        let fingerprint = try SeededArchiveVerifier.fingerprint(folder.appendingPathComponent("directory"), directory: true)
        XCTAssertEqual(directory.inode, fingerprint.inode)
        XCTAssertEqual(directory.device, fingerprint.device)
        XCTAssertEqual(directory.ctimeSeconds, fingerprint.ctimeSeconds)
        XCTAssertEqual(directory.ctimeNanos, fingerprint.ctimeNanos)
        XCTAssertThrowsError(try withFD { try BulkDirectoryMetadata.read(fd: $0, maximumEntries: 1) }) { error in
            XCTAssertEqual(error as? BulkDirectoryMetadata.Failure, .incomplete)
        }
        XCTAssertThrowsError(try withFD { try BulkDirectoryMetadata.read(fd: $0, shouldContinue: { false }) })
        print("BULK_ADAPTER_COMPLETE entries=\(rows.count)")
    }
    func testNativeLocalAdapterAndPartialDiscard() throws {
        try fixture(FileManager.default.temporaryDirectory)
    }
    func testMountedSMBAdapterAndPartialDiscard() throws {
        guard let mount = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_MOUNT"] else {
            throw XCTSkip("Disposable SMB fixture not mounted")
        }
        try fixture(URL(fileURLWithPath: mount))
    }
}
