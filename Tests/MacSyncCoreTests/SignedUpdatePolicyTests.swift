import Foundation
import XCTest
@testable import MacSyncCore

final class SignedUpdatePolicyTests: XCTestCase {
    func testExactStableAssetAndVersionOnly() {
        let url = SignedUpdatePolicy.assetURL(version: "0.16.1")
        XCTAssertTrue(SignedUpdatePolicy.accepts(installed: "0.16.0", requested: "0.16.1", offered: "0.16.1", channel: nil, asset: url))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed: "0.16.1", requested: "0.16.1", offered: "0.16.1", channel: nil, asset: url))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed: "0.16.0", requested: "0.16.1", offered: "0.16.2", channel: nil, asset: url))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed: "0.16.0", requested: "0.16.1", offered: "0.16.1", channel: "beta", asset: url))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed: "0.16.0", requested: "0.16.1", offered: "0.16.1", channel: nil, asset: URL(string: "https://example.com/update.zip")))
        XCTAssertNil(SignedUpdatePolicy.assetURL(version: "0.16.1-rc.1"))
        XCTAssertNil(SignedUpdatePolicy.assetURL(version: "v0.16.1"))
        // An installed 0.18.13 discovers only the published stable 0.18.15
        // with the exact canonical ZIP, never a pre-release or alternate URL.
        let release = SignedUpdatePolicy.assetURL(version: "0.18.15")
        XCTAssertTrue(SignedUpdatePolicy.accepts(installed: "0.18.13", requested: "0.18.15",
            offered: "0.18.15", channel: nil, asset: release))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed: "0.18.13", requested: "0.18.15",
            offered: "0.18.15", channel: "beta", asset: release))
        XCTAssertNil(SignedUpdatePolicy.assetURL(version: "0.18.15-rc.1"))
        XCTAssertEqual(Data(base64Encoded: SignedUpdatePolicy.publicKey)?.count, 32)
    }

    func testPersistentMarkerRoundTripAndNoOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = try UpdateTransactionMarker(previousVersion: "0.16.0", requestedVersion: "0.16.1",
                                                 snapshotName: "update-backup-" + UUID().uuidString)
        let path = directory.appendingPathComponent("update-pending.json")
        try marker.write(to: path)
        XCTAssertEqual(try UpdateTransactionMarker.read(from: path), marker)
        XCTAssertThrowsError(try marker.write(to: path))
        XCTAssertThrowsError(try UpdateTransactionMarker(previousVersion: "0.16.0", requestedVersion: "0.16.1", snapshotName: "../archive"))
        XCTAssertThrowsError(try UpdateTransactionMarker(previousVersion: "0.16.1", requestedVersion: "0.16.0", snapshotName: "update-backup-" + UUID().uuidString))
        let forged = directory.appendingPathComponent("bad.json")
        try Data("{\"previousVersion\":\"0.16.0\",\"requestedVersion\":\"0.16.1\",\"snapshotName\":\"../archive\"}".utf8).write(to: forged)
        XCTAssertThrowsError(try UpdateTransactionMarker.read(from: forged))
    }
}
