import Foundation
import XCTest
@testable import MacSyncCore

final class DestinationAvailabilityTests: XCTestCase {
    private func fixture() throws -> (base: URL, target: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-destination-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let target = base.appendingPathComponent("destination")
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true
        )
        return (base, target)
    }

    func testUnconfiguredAndUnverifiedDestinationAreNotReady() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        XCTAssertEqual(DestinationProbe.inspect(path: "", expectedVolume: nil), .notConfigured)
        XCTAssertEqual(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: nil
        ), .unverified)
        XCTAssertFalse(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: nil
        ).isReady)
    }

    func testMountedLocalDestinationBecomesUnavailableAndRecovers() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let expected = try VolumeFingerprint.read(at: f.target)
        XCTAssertEqual(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: expected
        ), .ready)
        let offline = f.base.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: f.target, to: offline)
        XCTAssertEqual(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: expected
        ), .unavailable)
        try FileManager.default.moveItem(at: offline, to: f.target)
        XCTAssertEqual(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: expected
        ), .ready)
    }

    func testDifferentVolumeFingerprintAndSymlinkAreRejected() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let actual = try VolumeFingerprint.read(at: f.target)
        let wrong = VolumeFingerprint(
            fileSystem: actual.fileSystem + "-wrong",
            mountPath: actual.mountPath
        )
        XCTAssertEqual(DestinationProbe.inspect(
            path: f.target.path, expectedVolume: wrong
        ), .differentVolume)
        let linked = f.base.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.target)
        XCTAssertEqual(DestinationProbe.inspect(
            path: linked.path, expectedVolume: actual
        ), .unavailable)
    }
}
