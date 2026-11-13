import Foundation
import XCTest
@testable import MacSyncCore

final class AutomaticCopyReadinessTests: XCTestCase {
    private let verified = VolumeFingerprint(
        fileSystem: "smbfs", mountPath: "/Volumes/Condivisione_SMB",
        mountSource: "//server/Condivisione_SMB"
    )
    private let legacy = VolumeFingerprint(
        fileSystem: "smbfs", mountPath: "/Volumes/Condivisione_SMB"
    )

    private func pair(_ expected: VolumeFingerprint?) -> AutomaticCopyPair {
        AutomaticCopyPair(
            sourcePath: "/Users/sample/Cartella_2",
            destinationPath: "/Volumes/Condivisione_SMB/Cartella_2",
            expectedVolume: expected
        )
    }

    func testOffByDefaultAndNeverAutostartWhileMonitorUnavailable() {
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: false, monitorRunning: true, copyActive: false,
            pairs: [pair(verified)], probe: { _, _ in .ready }
        ), .disabled)
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: false, copyActive: false,
            pairs: [pair(verified)], probe: { _, _ in .ready }
        ), .monitoringNotReady)
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: true,
            pairs: [pair(verified)], probe: { _, _ in .ready }
        ), .alreadyActive)
    }

    func testEmptyAndIncompleteConfigurationAreRejected() {
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: []
        ), .missingConfiguration)
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [AutomaticCopyPair(
                sourcePath: "/tmp/source", destinationPath: "",
                expectedVolume: verified
            )]
        ), .missingConfiguration)
    }

    func testLegacySMBFingerprintRequiresExplicitReselection() {
        XCTAssertFalse(legacy.isStrongIdentity)
        XCTAssertTrue(verified.isStrongIdentity)
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(legacy)], probe: { _, _ in .ready }
        ), .legacyVolumeIdentity)
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(nil)], probe: { _, _ in .ready }
        ), .legacyVolumeIdentity)
    }

    func testUnavailableShareWillWaitAndAutomaticallyReevaluateWhenRemounted() {
        var smbMounted = false
        let probe: (String, VolumeFingerprint?) -> DestinationAvailability = { _, _ in
            smbMounted ? .ready : .unavailable
        }
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(verified)], probe: probe
        ), .waitingForDestination)

        smbMounted = true
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(verified)], probe: probe
        ), .ready)
    }

    func testWrongMountedVolumeNeverApproved() {
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(verified)], probe: { _, _ in .differentVolume }
        ), .unsafeDestination)
        let second = AutomaticCopyPair(
            sourcePath: "/Users/sample/Cartella_1",
            destinationPath: "/Volumes/Condivisione_SMB/Cartella_1",
            expectedVolume: verified
        )
        XCTAssertEqual(AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: [pair(verified), second],
            probe: { path, _ in
                path.hasSuffix("Cartella_1") ? .unavailable : .ready
            }
        ), .waitingForDestination)
    }

    func testSavedMountSourceSurvivesEncodingAndLegacyProfileIsNotStrong() throws {
        let encoded = try JSONEncoder().encode(verified)
        let decoded = try JSONDecoder().decode(VolumeFingerprint.self, from: encoded)
        XCTAssertEqual(decoded, verified)
        XCTAssertTrue(decoded.isStrongIdentity)
        let oldJSON = #"{"fileSystem":"smbfs","mountPath":"/Volumes/Condivisione_SMB"}"#
        let old = try JSONDecoder().decode(
            VolumeFingerprint.self, from: Data(oldJSON.utf8)
        )
        XCTAssertFalse(old.isStrongIdentity)
    }
}
