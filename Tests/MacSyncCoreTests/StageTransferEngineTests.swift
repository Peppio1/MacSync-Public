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

    func testDirectArguments() {
        let src=URL(fileURLWithPath:"/tmp/source/a")
        let dst=URL(fileURLWithPath:"/tmp/target/a")
        let args=StageTransferEngine.directArguments(source:src,destination:dst,newFile:true)
        XCTAssertFalse(args.contains("--inplace"))
        XCTAssertTrue(args.contains("--immutable"))
        XCTAssertTrue(args.contains("--no-traverse"))
        XCTAssertFalse(StageTransferEngine.directArguments(source:src,destination:dst,newFile:false).contains("--immutable"))
    }

    func testDirectRcloneEndToEnd() throws {
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
        let name = "nested/foto àè con spazi.psd"
        try fm.createDirectory(at:source.appendingPathComponent("nested"),withIntermediateDirectories:true)
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
            stageEngine:.rcloneDirect(URL(fileURLWithPath:helper)))
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        XCTAssertEqual(try worker.runOnce(enabled:true).created, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), original)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent(".macsync-staging").path))
        try write(changed)
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        XCTAssertEqual(try worker.runOnce(enabled:true).updated, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), changed)
        XCTAssertTrue(try journal.pending().isEmpty)
        try write(original)
        try journal.enqueue(rootID:"photos",relativePath:name,kind:.upsert)
        let failing = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[mapping],
            stageEngine:.rcloneDirect(base.appendingPathComponent("missing-helper")))
        XCTAssertEqual(try failing.runOnce(enabled:true).failed, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), changed)
        XCTAssertEqual(try journal.pending().count, 1)
        let native = try MountedFolderCopyWorker(journal:journal,log:log,mappings:[mapping],stageEngine:.native)
        XCTAssertEqual(try native.runOnce(enabled:true).updated, 1)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(name)), original)
    }

    func testDirectPathOperations() throws {
        guard let helper=ProcessInfo.processInfo.environment["MACSYNC_TEST_RCLONE"] else { throw XCTSkip("Rclone helper required") }
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:base) }
        let engine=StageTransferEngine.rcloneDirect(URL(fileURLWithPath:helper))
        let directory=base.appendingPathComponent("nested/dir")
        try engine.pathOperation("mkdir",url:directory,shouldContinue:{true})
        let file=directory.appendingPathComponent("photo.jpg")
        try Data([1,2,3]).write(to:file)
        XCTAssertThrowsError(try engine.pathOperation("rmdir",url:directory,shouldContinue:{true}))
        XCTAssertTrue(fm.fileExists(atPath:file.path))
        try engine.pathOperation("deletefile",url:file,shouldContinue:{true})
        XCTAssertFalse(fm.fileExists(atPath:file.path))
        try engine.pathOperation("rmdir",url:directory,shouldContinue:{true})
        XCTAssertFalse(fm.fileExists(atPath:directory.path))
        XCTAssertThrowsError(try engine.pathOperation("purge",url:base,shouldContinue:{true}))
        XCTAssertTrue(fm.fileExists(atPath:base.path))
    }
    /// A fake subprocess that does not emit stderr: the old blocking reader
    /// could not notice a cancellation until the process eventually exited.
    func testCancelSilentRcloneSubprocessWithoutWaitingForOutput() throws {
        let base=FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-rclone-cancel-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let helper=base.appendingPathComponent("silent-helper.sh")
        try "#!/bin/sh\nexec /bin/sleep 12\n".write(to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let token=SeedVerificationCancellation()
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.2) {
            token.cancel()
        }
        let begin=ProcessInfo.processInfo.systemUptime
        do {
            try StageTransferEngine.rcloneDirect(helper).pathOperation("mkdir",url:base,
                shouldContinue:{ !token.isCancelled })
            XCTFail("A silent cancelled subprocess must not be reported as successful")
        } catch SeedVerificationError.cancelled {
            let elapsed=ProcessInfo.processInfo.systemUptime-begin
            XCTAssertLessThan(elapsed,3.0,"Cancellation should not wait for the 12-second helper")
        }
    }

    func testSilentSuccessfulRcloneSubprocessExitsNormally() throws {
        let base=FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-rclone-silent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let helper=base.appendingPathComponent("silent-helper.sh")
        try "#!/bin/sh\nexec /bin/sleep 0.1\n".write(to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        try StageTransferEngine.rcloneDirect(helper).pathOperation("mkdir",url:base,
            shouldContinue:{ true })
    }


    func testCancelStubbornSilentRcloneSubprocessHasBoundedShutdown() throws {
        let base=FileManager.default.temporaryDirectory
            .appendingPathComponent("macsync-rclone-stubborn-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let helper=base.appendingPathComponent("stubborn-helper.sh")
        try "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 12\n".write(
            to:helper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let token=SeedVerificationCancellation()
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.2) { token.cancel() }
        let started=ProcessInfo.processInfo.systemUptime
        do {
            try StageTransferEngine.rcloneDirect(helper).pathOperation("mkdir",url:base,
                shouldContinue:{ !token.isCancelled })
            XCTFail("Ignored termination must not be reported as success")
        } catch SeedVerificationError.cancelled {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,5.0)
        }
    }


}
