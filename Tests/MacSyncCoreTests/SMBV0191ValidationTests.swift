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
        let serverRoot=URL(fileURLWithPath:serverPath)
        let prefix = "macsync-v019-" + UUID().uuidString
        // A plain illegal wire name can be invisible to Apple's smbfs.
        // Do not treat invisibility as absence or as a successful rename.
        // Preserve this case separately from the representable SFM case.
        let rawLabel="macsync-ci-preexisting"
        let rawRoot=mount.appendingPathComponent(rawLabel)
        let rawServer=serverRoot.appendingPathComponent(rawLabel)
        let rawNames=try fm.contentsOfDirectory(atPath:rawRoot.path)
        XCTAssertTrue(rawNames.contains("compatible-control"))
        let rawOld=rawServer.appendingPathComponent("server-created - ")
        XCTAssertEqual(try Data(contentsOf:rawOld.appendingPathComponent("child.jpg")),Data("synthetic checked rename".utf8))
        if rawNames.contains(where:{$0.utf8.elementsEqual("server-created - ".utf8)}) {
            // If a newer client actually exposes the literal wire spelling,
            // require the complete protected rename, not a skipped test.
            try checkRename(root:rawRoot,server:rawServer,label:rawLabel,helper:helper,host:host,share:share,user:user,password:password,binding:binding,directoryCase:true,serverLeaf:"server-created - ")
        } else {
            XCTAssertFalse(fm.fileExists(atPath:rawServer.appendingPathComponent("server-created -").path))
            print("Raw trailing-space wire name is not enumerable by this smbfs client; preserved, not counted as a successful rename")
        }
        for label in [prefix+"-client","macsync-ci-sfm","macsync-ci-sfm-collision"] {
            let directoryCase = label != prefix+"-client"
            let root = mount.appendingPathComponent(label)
            let server = serverRoot.appendingPathComponent(label)
            if !directoryCase { try fm.createDirectory(at:root,withIntermediateDirectories:true) }
            try checkRename(root:root,server:server,label:label,helper:helper,host:host,share:share,user:user,password:password,binding:binding,directoryCase:directoryCase,serverLeaf:directoryCase ? "server-created -\u{F028}" : "old.jpg",collision:label=="macsync-ci-sfm-collision")
        }
    }

    private func checkRename(root:URL,server:URL,label:String,helper:URL,host:String,share:String,user:String,password:String,binding:DirectoryBinding,directoryCase:Bool,serverLeaf:String,collision:Bool=false) throws {
        let fm=FileManager.default
        let oldName=directoryCase ? "server-created - " : "old.jpg"
        let newName=directoryCase ? "server-created -" : "new.jpg"
        let old=root.appendingPathComponent(oldName), new=root.appendingPathComponent(newName)
        let serverOld=server.appendingPathComponent(serverLeaf), serverNew=server.appendingPathComponent(newName)
        let bytes=Data("synthetic checked rename".utf8)
        if directoryCase {
            // Fixture created before the server and the mount exist; the
            // first client lookup cannot be a stale cached negative lookup.
            XCTAssertEqual(try Data(contentsOf:serverOld.appendingPathComponent("child.jpg")),bytes)
            let deadline=ProcessInfo.processInfo.systemUptime+8
            var exactVisible=false
            var clientNames:[String]=[]
            var listingError:String?
            repeat {
                do {
                    clientNames=try fm.contentsOfDirectory(atPath:root.path)
                    listingError=nil
                } catch {
                    let ns=error as NSError
                    listingError=ns.domain+" ("+String(ns.code)+")"
                }
                exactVisible=clientNames.contains { $0.utf8.elementsEqual(oldName.utf8) }
                if exactVisible && clientNames.contains("compatible-control") { break }
                Thread.sleep(forTimeInterval:0.125)
            } while ProcessInfo.processInfo.systemUptime<deadline
            guard exactVisible,clientNames.contains("compatible-control") else {
                // Distinguish an unreadable parent from a hidden name. Only
                // fixture names and error domain/code are logged.
                let client=clientNames.map { name in name.unicodeScalars.map { String(format:"U+%04X",$0.value) }.joined(separator:" ") }
                let raw=try fm.contentsOfDirectory(atPath:server.path).map { name in name.unicodeScalars.map { String(format:"U+%04X",$0.value) }.joined(separator:" ") }
                XCTFail("Preexisting case not visible. Parent listing error: "+(listingError ?? "none")+"; compatible sibling: "+String(clientNames.contains("compatible-control"))+"; client: "+client.joined(separator:";")+" server: "+raw.joined(separator:";"))
                return
            }
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
        if collision {
            XCTAssertEqual(try rename(stale:false),3,"Two wire spellings are ambiguous; reject before mutation")
            XCTAssertEqual(try contents(serverOld),bytes)
            XCTAssertEqual(try contents(server.appendingPathComponent(oldName)),Data("distinct literal name".utf8))
            XCTAssertFalse(fm.fileExists(atPath:serverNew.path))
            return
        }
        XCTAssertEqual(try rename(stale:false),0,"Direct SMB must confirm exact new name and identity")
        XCTAssertFalse(fm.fileExists(atPath:serverOld.path))
        XCTAssertEqual(try contents(serverNew),bytes)
        XCTAssertEqual(try rename(stale:false,verifyOnly:true),0,"Independent server-side confirmation after rename")
        if !directoryCase {
            XCTAssertNotEqual(try rename(stale:true,verifyOnly:true),0,"Read-only verification must reject a wrong timestamp")
        }
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
