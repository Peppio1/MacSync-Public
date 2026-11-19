import Foundation
import XCTest
@testable import MacSyncCore

final class TechnicalLogTests:XCTestCase {
    func testPagesContextAndLegacyRows() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("inventory.sqlite").path
        let writer=try SyncActivityLog(path:path)
        try writer.record(level:.info,rootID:"app",action:"session",message:"legacy")
        writer.cycleID="test-cycle"
        writer.currentJob=QueuedChange(id:42,rootID:"photos",relativePath:"test.jpg",kind:.upsert,recordedAt:Date())
        for i in 0..<125 {
            try writer.record(level:i==3 ? .error : .info,rootID:"photos",action:"rclone_start",relativePath:"test.jpg",message:"example")
        }
        let reader=try SyncActivityLog(path:path,readOnly:true)
        let first=try reader.technicalPage()
        XCTAssertEqual(first.count,100)
        XCTAssertEqual(first.first?.cycleID,"test-cycle")
        XCTAssertEqual(first.first?.jobID,42)
        XCTAssertEqual(first.first?.component,"RCLONE")
        let older=try reader.technicalPage(beforeID:first.last!.id)
        XCTAssertEqual(older.count,26)
        XCTAssertNil(older.last?.cycleID)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with:older.map(\.id)))
        XCTAssertEqual(try reader.technicalPage(level:.error,search:"42").count,1)
        try writer.record(level:.warning,rootID:"app",action:"cycle",message:"warning")
        XCTAssertEqual(try reader.technicalPage(afterID:first.first!.id).count,1)
        XCTAssertTrue(TechnicalLogRow.tsv(first).contains("cycle_id\tjob_id\tcomponent"))
        XCTAssertEqual(try reader.recent(limit:5).count,5)
    }

    func testRcloneDiagnosticDoesNotExposeRawOutput() {
        let data=Data(#"{"level":"error","msg":"failed to open /private/secret/photo.jpg: permission denied","object":"smb://user:password@server"}"#.utf8)
        let result=StageTransferEngine.classifyDiagnostic(data,verbosity:.normal)
        XCTAssertEqual(result?.0,.error)
        XCTAssertEqual(result?.1,"Rclone: permessi insufficienti")
        XCTAssertFalse(result?.1.contains("secret") ?? true)
        let debug=Data(#"{"level":"debug","msg":"sizes differ at /private/file"}"#.utf8)
        XCTAssertNil(StageTransferEngine.classifyDiagnostic(debug,verbosity:.normal))
        XCTAssertEqual(StageTransferEngine.classifyDiagnostic(debug,verbosity:.debug)?.1,"Rclone: dimensioni diverse")
    }

    func testFallbackWithoutDatabase() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path=root.appendingPathComponent("inventory.sqlite").path
        TechnicalFallbackLog.record(databasePath:path,cycleID:"sample",action:"cycle_start",message:"test")
        TechnicalFallbackLog.record(databasePath:path,cycleID:"sample",action:"sqlite_busy",message:"database is locked")
        XCTAssertFalse(FileManager.default.fileExists(atPath:path))
        XCTAssertTrue(TechnicalFallbackLog.recent(databasePath:path).contains("database is locked"))
        XCTAssertFalse(TechnicalFallbackLog.recent(databasePath:path,limit:1).contains("cycle_start"))
    }
}
