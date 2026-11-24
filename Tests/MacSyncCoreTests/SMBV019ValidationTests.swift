import Darwin
import Foundation
import XCTest
@testable import MacSyncCore

final class SMBV019ValidationTests: XCTestCase {
    func testRealSMBHelperPreMutationRejectionAndSuccessfulRename() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACSYNC_V019_REQUIRE_SMB"] == "1" else { throw XCTSkip("Disposable SMB fixture opt-in") }
        let mount = URL(fileURLWithPath: try XCTUnwrap(env["MACSYNC_TEST_SMB_MOUNT"]))
        let helper = URL(fileURLWithPath: try XCTUnwrap(env["MACSYNC_TEST_SMB_HELPER"]))
        let user = try XCTUnwrap(env["MACSYNC_TEST_SMB_USER"])
        let password = try XCTUnwrap(env["MACSYNC_TEST_SMB_PASSWORD"])
        let host = try XCTUnwrap(env["MACSYNC_TEST_SMB_HOST"])
        let share = try XCTUnwrap(env["MACSYNC_TEST_SMB_SHARE"])
        guard host == "127.0.0.1", share == "MacSyncCI" else { XCTFail("Only disposable loopback fixture allowed"); return }
        let binding = try DirectoryBinding.read(mount)
        guard binding.volume.fileSystem.lowercased() == "smbfs", binding.volume.isStrongIdentity else {
            XCTFail("Genuine strongly identified SMB mount required"); return
        }
        let fm = FileManager.default
        let fixtureRoot = URL(fileURLWithPath: try XCTUnwrap(env["MACSYNC_TEST_SMB_ROOT"]))
        let serverPath = try String(contentsOf: fixtureRoot.appendingPathComponent("share-path"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard serverPath.hasPrefix("/private/tmp/macsync-ci-share.") else { XCTFail("Unexpected fixture root"); return }
        let label = "macsync-v019-" + UUID().uuidString
        let root = mount.appendingPathComponent(label)
        let server = URL(fileURLWithPath: serverPath).appendingPathComponent(label)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("old.jpg"), new = root.appendingPathComponent("new.jpg")
        let bytes = Data("synthetic checked rename".utf8)
        try bytes.write(to: old)
        let directory = try AnchoredDirectory(root, expectedVolume: binding.volume)
        let snapshot = try NameRectification.stableSMBSnapshot(parent: directory, oldName: old.lastPathComponent, shouldContinue: { true })
        func rename(stale: Bool) throws -> Int32 {
            let request: [String:Any] = [
                "host":host, "port":"445", "share":share, "user":user, "domain":"", "password":password,
                "oldPath":label+"/old.jpg", "newPath":label+"/new.jpg",
                "fileID":UInt64(snapshot.st_ino),
                "createdSeconds":Int64(snapshot.st_birthtimespec.tv_sec),
                "createdNanos":Int64(snapshot.st_birthtimespec.tv_nsec),
                "size":Int64(snapshot.st_size),
                "modifiedSeconds":Int64(snapshot.st_mtimespec.tv_sec) - (stale ? 60 : 0),
                "modifiedNanos":Int64(snapshot.st_mtimespec.tv_nsec), "isDirectory":false
            ]
            let process = Process(), input = Pipe()
            process.executableURL = helper
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ["PATH":"/usr/bin:/bin"]
            try process.run()
            defer { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
            try input.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while process.isRunning {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CocoaError(.fileReadUnknown) }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return process.terminationStatus
        }
        XCTAssertEqual(try rename(stale: true), 3, "Must explicitly reject before mutation")
        XCTAssertEqual(try Data(contentsOf: server.appendingPathComponent("old.jpg")), bytes)
        XCTAssertFalse(fm.fileExists(atPath: server.appendingPathComponent("new.jpg").path))
        XCTAssertEqual(try rename(stale: false), 0)
        XCTAssertFalse(fm.fileExists(atPath: server.appendingPathComponent("old.jpg").path))
        XCTAssertEqual(try Data(contentsOf: server.appendingPathComponent("new.jpg")), bytes)
        let deadline = ProcessInfo.processInfo.systemUptime + 3.5
        var visible = false
        repeat {
            let names = try fm.contentsOfDirectory(atPath: root.path)
            visible = !names.contains("old.jpg") && names.contains("new.jpg")
            if visible { break }
            Thread.sleep(forTimeInterval: 0.125)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTAssertTrue(visible)
        if visible { XCTAssertEqual(try Data(contentsOf: new), bytes) }
    }
}
