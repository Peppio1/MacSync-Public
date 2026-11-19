import Foundation
import XCTest
@testable import MacSyncCore

final class StageTransferEngineTests: XCTestCase {
    func testArgumentIsolationAndStats() throws {
        let source = URL(fileURLWithPath: "/tmp/photo name à.psd")
        let stage = URL(fileURLWithPath: "/Volumes/share/.macsync-staging/9FC472D3-41CB-4B84-A77C-FE96B90F60C9.partial")
        let args = StageTransferEngine.arguments(source: source, staging: stage)
        XCTAssertEqual(args.first, "copyto")
        XCTAssertTrue(args.contains("--inplace"))
        XCTAssertTrue(args.contains("--no-traverse"))
        XCTAssertTrue(args.contains("--local-no-clone"))
        XCTAssertEqual(Array(args.suffix(3)), ["--", source.path, stage.path])
        let parsed = StageTransferEngine.parseStats(Data(#"{"stats":{"bytes":42,"elapsedTime":2.5}}"#.utf8))
        XCTAssertEqual(parsed?.0, 42)
        XCTAssertEqual(parsed?.1, 2.5)
        XCTAssertNil(StageTransferEngine.parseStats(Data("not JSON".utf8)))
    }

    func testBundledRcloneEndToEnd() throws {
        guard let helper = ProcessInfo.processInfo.environment["MACSYNC_TEST_RCLONE"] else {
            throw XCTSkip("Run CI with the verified Rclone helper")
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:base) }
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let name = "foto àè con spazi.psd"
        let input = source.appendingPathComponent(name)
        let original = Data(repeating: 0x25, count: 2_000_000)
        let changed = Data(repeating: 0x42, count: 3_000_000)
        func write(_ bytes: Data) throws {
            try bytes.write(to: input)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: input.path)
        }
        try write(original)
        let path = base.appendingPathComponent("inventory.sqlite").path
        let journal = try ChangeJournal(path:path)
        let log = try SyncActivityLog(path:path)
        let mapping = try MountedFolderMapping(rootID:"photos",source:source,target:target)
        let worker = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[mapping],
            stageEngine:.rclone(URL(fileURLWithPath:helper)))
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        XCTAssertEqual(try worker.runOnce(enabled:true).created, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), original)
        XCTAssertTrue(try journal.pending().isEmpty)
        try write(changed)
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        XCTAssertEqual(try worker.runOnce(enabled:true).updated, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), changed)
        XCTAssertTrue(try journal.pending().isEmpty)
        try write(original)
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        let failing = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[mapping],
            stageEngine:.rclone(base.appendingPathComponent("missing-helper")))
        XCTAssertEqual(try failing.runOnce(enabled:true).failed, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), changed)
        XCTAssertEqual(try journal.pending().count, 1)
        let native = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[mapping],stageEngine:.native)
        XCTAssertEqual(try native.runOnce(enabled:true).updated, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), original)
    }
}
