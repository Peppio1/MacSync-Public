import Foundation
import XCTest
@testable import MacSyncCore

final class BootstrapPreviewTests: XCTestCase {
    private func remote(_ path: String, _ size: Int64, _ date: String = "2026-11-13T10:00:00Z") -> RemoteFileMetadata {
        let json = """
        [{"Path":"\(path)","Name":"test.jpg","IsDir":false,"Size":\(size),"ModTime":"\(date)"}]
        """
        return try! BootstrapPlanner.decodeRcloneJSON(Data(json.utf8))[0]
    }

    private var referenceTime: Double {
        ISO8601DateFormatter().date(from: "2026-11-13T10:00:00Z")!.timeIntervalSince1970
    }

    func testFilesAlreadySeededAreOnlyCandidateMatches() throws {
        let local = [
            TrackedItem(relativePath: "foto.jpg", kind: "file", size: 123, modifiedAt: referenceTime),
            TrackedItem(relativePath: "a/missing.dng", kind: "file", size: 50, modifiedAt: referenceTime)
        ]
        let listing = [
            remote("foto.jpg", 123),
            remote("server-only.jpg", 444),
            remote(".macsync-staging/orphan.partial", 30)
        ]
        let preview = try BootstrapPlanner.preview(local: local, remote: listing)
        XCTAssertEqual(preview.candidateMatches, 1)
        XCTAssertEqual(preview.requiresCopyOrReview.count, 1)
        XCTAssertEqual(preview.requiresCopyOrReview[0].mismatch, .missingOnServer)
        XCTAssertEqual(preview.remoteOnlyPaths, ["server-only.jpg"])
        XCTAssertEqual(preview.stagingFiles, 1)
        XCTAssertFalse(preview.isSafeForAutomaticProductionBootstrap)
    }

    func testTimestampDifferenceDoesNotProveContentMismatch() throws {
        let local = [TrackedItem(relativePath: "image.psd", kind: "file", size: 500, modifiedAt: referenceTime)]
        let listing = [remote("image.psd", 500, "2026-11-13T10:00:08Z")]
        let preview = try BootstrapPlanner.preview(local: local, remote: listing)
        XCTAssertEqual(preview.candidateMatches, 0)
        XCTAssertEqual(preview.requiresCopyOrReview[0].mismatch, .timestampMismatch)
    }

    func testCaseCollisionsOnMacAreDetectedForWindowsShare() throws {
        let local = [
            TrackedItem(relativePath: "Folder/Foto.jpg", kind: "file", size: 2, modifiedAt: referenceTime),
            TrackedItem(relativePath: "Folder/foto.jpg", kind: "file", size: 2, modifiedAt: referenceTime)
        ]
        let preview = try BootstrapPlanner.preview(local: local, remote: [])
        XCTAssertEqual(preview.macOSCaseCollisions.count, 1)
        XCTAssertEqual(preview.macOSCaseCollisions[0], ["Folder/Foto.jpg", "Folder/foto.jpg"])
    }

    func testBadRemotePathsRefused() throws {
        XCTAssertThrowsError(try BootstrapPlanner.preview(
            local: [], remote: [remote("../escape.jpg", 22)]
        ))
        XCTAssertThrowsError(try BootstrapPlanner.preview(
            local: [], remote: [remote("dup.jpg", 1), remote("dup.jpg", 1)]
        ))
    }

    func testUncertainMetadataIsNotAcceptedAsVerifiedMatch() throws {
        let local = [TrackedItem(relativePath: "source.tif", kind: "file", size: 99, modifiedAt: referenceTime)]
        let preview = try BootstrapPlanner.preview(local: local, remote: [
            remote("source.tif", 99, "")
        ])
        XCTAssertEqual(preview.candidateMatches, 0)
        XCTAssertEqual(preview.requiresCopyOrReview[0].mismatch, .unverifiedTimestamp)
    }
}
