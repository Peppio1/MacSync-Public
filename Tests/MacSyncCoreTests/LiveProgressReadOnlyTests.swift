import Foundation
import XCTest
@testable import MacSyncCore

final class LiveProgressReadOnlyTests:XCTestCase {
    func testReadOnlyActivityConnectionCanSeeCommittedWrites() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let path=root.appendingPathComponent("log.sqlite").path
        let writer=try SyncActivityLog(path:path)
        let reader=try SyncActivityLog(path:path,readOnly:true)
        try writer.record(level:.info,rootID:"demo",action:"first",message:"synthetic")
        XCTAssertEqual(try reader.recent().first?.action,"first")
        try writer.record(level:.success,rootID:"demo",action:"second",message:"synthetic")
        XCTAssertEqual(try reader.recent().first?.action,"second")
        XCTAssertThrowsError(try reader.record(level:.info,rootID:"demo",action:"write",message:"must fail"))
    }
}
