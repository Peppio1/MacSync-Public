import Darwin
import Foundation
import XCTest
@testable import MacSyncCore

final class SMBV0191ValidationTests: XCTestCase {
    func testRealSMBHelperPreMutationRejectionAndSuccessfulRename() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACSYNC_V0191_REQUIRE_SMB"] == "1" else { throw XCTSkip("Disposable SMB fixture opt-in") }
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
        try checkRename(root:root,server:server,label:label,helper:helper,host:host,share:share,user:user,password:password,binding:binding,directoryCase:false)
        try checkRename(root:root,server:server,label:label,helper:helper,host:host,share:share,user:user,password:password,binding:binding,directoryCase:true)
    }

    private func checkRename(root:URL,server:URL,label:String,helper:URL,host:String,share:String,user:String,password:String,binding:DirectoryBinding,directoryCase:Bool) throws {
        let fm=FileManager.default
        let oldName=directoryCase ? "server-created - " : "old.jpg"
        let newName=directoryCase ? "server-created -" : "new.jpg"
        let old=root.appendingPathComponent(oldName), new=root.appendingPathComponent(newName)
        let serverOld=server.appendingPathComponent(oldName), serverNew=server.appendingPathComponent(newName)
        let bytes=Data("synthetic checked rename".utf8)
        if directoryCase {
            // Create this directory directly in the server filesystem, not
            // through the macOS SMB client; preserve the literal final space.
            try fm.createDirectory(at:serverOld,withIntermediateDirectories:false)
            try bytes.write(to:serverOld.appendingPathComponent("child.jpg"))
            let deadline=ProcessInfo.processInfo.systemUptime+5
            var exactVisible=false
            repeat {
                let names=try fm.contentsOfDirectory(atPath:root.path)
                exactVisible=names.contains { $0.utf8.elementsEqual(oldName.utf8) }
                if exactVisible { break }
                Thread.sleep(forTimeInterval:0.125)
            } while ProcessInfo.processInfo.systemUptime<deadline
            guard exactVisible else { XCTFail("Server-created trailing-space directory not exposed with its exact spelling by smbfs"); return }
        } else {
            try bytes.write(to:old)
        }
        func contents(_ path:URL) throws -> Data {
            try Data(contentsOf:directoryCase ? path.appendingPathComponent("child.jpg") : path)
        }
        let directory = try AnchoredDirectory(root, expectedVolume: binding.volume)
        let snapshot = try NameRectification.stableSMBSnapshot(parent: directory, oldName: old.lastPathComponent, shouldContinue: { true })
        func rename(stale: Bool,verifyOnly:Bool=false) throws -> Int32 {
            let request: [String:Any] = [
                "host":host, "port":"445", "share":share, "user":user, "domain":"", "password":password,
                "oldPath":label+"/"+oldName, "newPath":label+"/"+newName,
                "fileID":UInt64(snapshot.st_ino),
                "createdSeconds":Int64(snapshot.st_birthtimespec.tv_sec),
                "createdNanos":Int64(snapshot.st_birthtimespec.tv_nsec),
                "size":Int64(snapshot.st_size),
                "modifiedSeconds":Int64(snapshot.st_mtimespec.tv_sec) - (stale ? 60 : 0),
                "modifiedNanos":Int64(snapshot.st_mtimespec.tv_nsec), "isDirectory":directoryCase, "verifyOnly":verifyOnly
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
        XCTAssertNotEqual(try rename(stale:false,verifyOnly:true),0,"Cannot confirm a rename before it happened")
        if !directoryCase {
            XCTAssertEqual(try rename(stale:true),3,"Explicit refusal before mutation")
        }
        XCTAssertEqual(try contents(serverOld),bytes)
        XCTAssertFalse(fm.fileExists(atPath:serverNew.path))
        XCTAssertEqual(try rename(stale:false),0,"Direct SMB must confirm exact new name and identity")
        XCTAssertFalse(fm.fileExists(atPath:serverOld.path))
        XCTAssertEqual(try contents(serverNew),bytes)
        XCTAssertEqual(try rename(stale:false,verifyOnly:true),0,"Independent server-side confirmation after rename")
        let deadline=ProcessInfo.processInfo.systemUptime+3.5
        var visible=false
        repeat {
            let names=try fm.contentsOfDirectory(atPath:root.path)
            visible = !names.contains(where:{$0.utf8.elementsEqual(oldName.utf8)}) &&
                names.contains(where:{$0.utf8.elementsEqual(newName.utf8)})
            if visible { break }
            Thread.sleep(forTimeInterval:0.125)
        } while ProcessInfo.processInfo.systemUptime<deadline
        XCTAssertTrue(visible)
        if visible { XCTAssertEqual(try contents(new),bytes) }
    }
}
