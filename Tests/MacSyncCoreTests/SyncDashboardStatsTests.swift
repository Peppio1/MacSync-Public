import Foundation
import XCTest
@testable import MacSyncCore

final class SyncDashboardStatsTests: XCTestCase {
    func testMetricMappingSeparatesNewUpdatesDeletionAndRecovery() {
        var copy = MountedCopySummary()
        copy.copied = 6
        copy.created = 2
        copy.updated = 3
        copy.directoriesCreated = 1
        copy.deferred = 4
        copy.failed = 2
        copy.bytes = 4096

        var mirror = MirrorDeletionSummary()
        mirror.removed = 5
        mirror.recovered = 6
        mirror.directories = 1
        mirror.deferred = 3
        mirror.blocked = true

        let stats = SyncDashboardStats(copy: copy, mirror: mirror, expiredRecovery: 2)
        XCTAssertEqual(stats.newFiles, 2)
        XCTAssertEqual(stats.updatedFiles, 3)
        XCTAssertEqual(stats.permanentlyDeleted, 5)
        XCTAssertEqual(stats.movedToRecovery, 6)
        XCTAssertEqual(stats.failed, 2)
        XCTAssertEqual(stats.deferred, 7)
        XCTAssertEqual(stats.createdDirectories, 1)
        XCTAssertEqual(stats.removedDirectories, 1)
        XCTAssertEqual(stats.expiredRecovery, 2)
        XCTAssertEqual(stats.bytesTransferred, 4096)
        XCTAssertTrue(stats.deletionsBlocked)
    }

    func testSessionTotalsAggregateCyclesWithoutCountingQueuedAsSuccess() {
        var total = SyncDashboardStats()
        total.accumulate(SyncDashboardStats(
            newFiles: 1, updatedFiles: 2, failed: 1,
            deferred: 3, bytesTransferred: 2048
        ))
        total.accumulate(SyncDashboardStats(
            newFiles: 2, updatedFiles: 1, permanentlyDeleted: 1,
            movedToRecovery: 2, deferred: 1, bytesTransferred: 1024,
            deletionsBlocked: true
        ))
        XCTAssertEqual(total.newFiles, 3)
        XCTAssertEqual(total.updatedFiles, 3)
        XCTAssertEqual(total.permanentlyDeleted, 1)
        XCTAssertEqual(total.movedToRecovery, 2)
        XCTAssertEqual(total.failed, 1)
        XCTAssertEqual(total.deferred, 4)
        XCTAssertEqual(total.bytesTransferred, 3072)
        XCTAssertTrue(total.deletionsBlocked)
    }
}
