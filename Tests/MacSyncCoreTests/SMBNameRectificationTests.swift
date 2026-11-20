import Foundation
import XCTest
@testable import MacSyncCore

final class SMBNameRectificationTests: XCTestCase {
    func testFinderMountMapsAnExactNameWithinTheSelectedSubdirectory() throws {
        let volume = VolumeFingerprint(fileSystem: "smbfs", mountPath: "/Volumes/Share",
            mountSource: "//DOMAIN%3Buser@server.example:1445/Share%20Name")
        let target = try SMBNameRectificationTarget(volume: volume,
            parent: URL(fileURLWithPath: "/Volumes/Share/Archive/Folder"))
        XCTAssertEqual(target.host, "server.example")
        XCTAssertEqual(target.port, 1445)
        XCTAssertEqual(target.share, "Share Name")
        XCTAssertEqual(target.mountedAccount, "DOMAIN;user")
        XCTAssertEqual(try target.path(for: "sample - "), "Archive/Folder/sample - ")
        XCTAssertThrowsError(try target.path(for: "../other"))
        XCTAssertThrowsError(try target.path(for: "bad\\path"))
    }

    func testRejectsParentOutsideTheMountedVolume() {
        let volume = VolumeFingerprint(fileSystem: "smbfs", mountPath: "/Volumes/Share",
            mountSource: "//server.example/Share")
        XCTAssertThrowsError(try SMBNameRectificationTarget(volume: volume,
            parent: URL(fileURLWithPath: "/Volumes/Share2/Archive")))
    }
}
