import Foundation
import CryptoKit
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

    func testV0193RollbackOnlySupportsPinnedPredecessor() throws {
        let package=try XCTUnwrap(SignedRollbackPackage.previous(for:"0.19.3"))
        XCTAssertEqual(package.version,"0.19.2")
        XCTAssertEqual(package.build,"200")
        XCTAssertEqual(package.byteCount,74_640_583)
        XCTAssertEqual(package.sha256,"4aa29fd358f837365bc17aca05a3aeba5c0882589e950cd0295195842d88d0dd")
        XCTAssertEqual(package.archiveURL,SignedUpdatePolicy.assetURL(version:"0.19.2"))
        XCTAssertEqual(package.signatureURL.absoluteString,package.archiveURL.absoluteString+".edsignature")
        XCTAssertNil(SignedRollbackPackage.previous(for:"0.19.1"))
        XCTAssertNil(SignedRollbackPackage.previous(for:"0.19.2"))
        XCTAssertNil(SignedRollbackPackage.previous(for:"0.19.3-rc.1"))
        XCTAssertFalse(SignedUpdatePolicy.accepts(installed:"0.19.3",requested:"0.19.2",
            offered:"0.19.2",channel:nil,asset:package.archiveURL))
    }

    func testV0192RollbackSignatureRejectsTamperedPayloadAndWrongKey() throws {
        let key=Curve25519.Signing.PrivateKey()
        let original=Data("signed payload".utf8)
        let signature=try key.signature(for:original)
        XCTAssertNoThrow(try SignedRollbackPackage.verify(bytes:original,signature:signature,publicKey:key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try SignedRollbackPackage.verify(bytes:Data("tampered".utf8),signature:signature,publicKey:key.publicKey.rawRepresentation))
        XCTAssertThrowsError(try SignedRollbackPackage.verify(bytes:original,signature:signature,publicKey:Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    }

    func testV0192RollbackCompatibilityPreservesQueueAndInvalidatesOnlyDerivedIndex() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let db=base.appendingPathComponent("inventory.sqlite")
        let inventory=try LocalInventory(path:db.path)
        let journal=try ChangeJournal(path:db.path)
        try Data("photo".utf8).write(to:source.appendingPathComponent("photo.jpg"))
        _ = try inventory.reconcile(rootID:"photos",root:source)
        let id=try journal.enqueue(rootID:"photos",relativePath:"photo.jpg",kind:.upsert,origin:.sourceMonitor)
        let before=try journal.pending()
        XCTAssertTrue(before.contains{$0.id==id})
        XCTAssertNoThrow(try SignedRollbackTransaction.validateCompatibility(database:db))
        try SignedRollbackTransaction.invalidateDerivedNameIndex(database:db)
        XCTAssertEqual(try journal.pending(),before)
        try journal.requireUnilateralNameAudit()
        XCTAssertThrowsError(try SignedRollbackTransaction.validateCompatibility(database:db))
        XCTAssertEqual(try journal.pending(),before)
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
