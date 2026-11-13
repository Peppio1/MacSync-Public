import Foundation
import XCTest
@testable import MacSyncCore

final class SMBSecureProfileTests: XCTestCase {
    func testSecureEnvironmentDoesNotContainCleartextPasswordOrRemoteFilePath() throws {
        let profile = try SMBSecureProfile(
            host: "192.0.2.10", username: "test-user",
            domain: "WORKGROUP", share: "Condivisione_SMB"
        )
        let environment = try profile.environment(obscuredPassword: "OBSCURED_TEST_SECRET")
        XCTAssertEqual(profile.remoteParent, "macsync_smb:Condivisione_SMB")
        XCTAssertEqual(environment["RCLONE_CONFIG_MACSYNC_SMB_TYPE"], "smb")
        XCTAssertEqual(environment["RCLONE_CONFIG_MACSYNC_SMB_HOST"], "192.0.2.10")
        XCTAssertEqual(environment["RCLONE_CONFIG_MACSYNC_SMB_USER"], "test-user")
        XCTAssertEqual(environment["RCLONE_CONFIG_MACSYNC_SMB_PASS"], "OBSCURED_TEST_SECRET")
        XCTAssertEqual(environment["RCLONE_CONFIG"], "/dev/null")
        XCTAssertFalse(environment.values.contains("plaintext-password"))
        XCTAssertFalse(environment.keys.contains("RCLONE_SMB_PASS"))
    }

    func testDisallowUnsafeCredentialsOrShareTraversal() {
        XCTAssertThrowsError(try SMBSecureProfile(
            host: "bad\nhost", username: "admin", share: "TEST"
        ))
        XCTAssertThrowsError(try SMBSecureProfile(
            host: "server", username: "admin", share: "../C$"
        ))
        XCTAssertThrowsError(try SMBSecureProfile(
            host: "server", username: "admin", share: "TEST/other"
        ))
        XCTAssertThrowsError(try SMBSecureProfile(
            host: "server", username: "", share: "TEST"
        ))
        XCTAssertThrowsError(try SMBSecureProfile(
            host: "server", username: "admin", share: "TEST:private"
        ))
    }

    func testRejectEmptySecretForRclone() throws {
        let profile = try SMBSecureProfile(host: "server", username: "u", share: "test")
        XCTAssertThrowsError(try profile.environment(obscuredPassword: ""))
        XCTAssertThrowsError(try SMBSecretStore().save(password: ""))
    }
}
