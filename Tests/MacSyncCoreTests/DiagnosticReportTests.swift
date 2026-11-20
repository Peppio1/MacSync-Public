import Foundation
import XCTest
@testable import MacSyncCore

final class DiagnosticReportTests: XCTestCase {
    func testExportPaginatesAndRemovesFreeTextAndIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = directory.appendingPathComponent("fixture.sqlite").path
        let writer = try SyncActivityLog(path: db)
        writer.cycleID = "private-cycle"
        for index in 1...501 {
            try writer.record(level: .info, rootID: "private-root", action: "copy",
                relativePath: "private-name.psd", bytes: Int64(index), message: "private-host")
        }
        let data = try DiagnosticReport.make(databasePath: db, since: .distantPast, appVersion: "0.18.9")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-"))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(report["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 501)
        XCTAssertEqual(events.first?["bytes"] as? Int, 501)
        XCTAssertEqual(events.last?["bytes"] as? Int, 1)
        XCTAssertEqual(events.first?["item"] as? Int, events.last?["item"] as? Int)
    }
}
