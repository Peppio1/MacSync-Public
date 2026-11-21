import Darwin
import Foundation
import XCTest
@testable import MacSyncCore

/// Opt-in integration tests: require a real mount of a disposable Samba
/// share, not a local fixture disguised as smbfs. No production endpoints.
final class SMBIntegrationTests: XCTestCase {
    private struct Environment {
        let mount: URL
        let rclone: URL
        let helper: URL
        let user: String
        let password: String
        let host: String
        let share: String

        init() throws {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["MACSYNC_TEST_SMB_MOUNT"],
                  let rclonePath = env["MACSYNC_TEST_RCLONE"],
                  let helperPath = env["MACSYNC_TEST_SMB_HELPER"],
                  let user = env["MACSYNC_TEST_SMB_USER"],
                  let password = env["MACSYNC_TEST_SMB_PASSWORD"],
                  let host = env["MACSYNC_TEST_SMB_HOST"],
                  let share = env["MACSYNC_TEST_SMB_SHARE"] else {
                throw XCTSkip("Real disposable smbfs fixture not configured")
            }
            self.mount = URL(fileURLWithPath: path)
            self.rclone = URL(fileURLWithPath: rclonePath)
            self.helper = URL(fileURLWithPath: helperPath)
            self.user = user
            self.password = password
            self.host = host
            self.share = share
            let binding = try DirectoryBinding.read(mount)
            XCTAssertEqual(binding.volume.fileSystem.lowercased(), "smbfs",
                           "Real macOS SMB mount required, never silently use a local directory")
            XCTAssertTrue(binding.volume.isNetworkVolume)
            XCTAssertTrue(binding.volume.isStrongIdentity, "Cannot safely bind test SMB volume")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: rclone.path))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        }

        func workspace(_ label: String) throws -> URL {
            let root = mount.appendingPathComponent("macsync-test-\(label)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
    }

    private func fixtureSource() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (root, source)
    }

    func testRealSMBFilesystemIsMountedAndWritable() throws {
        let env = try Environment()
        let root = try env.workspace("mount")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("smbfs integration - do not use real files".utf8)
        let file = root.appendingPathComponent("roundtrip.txt")
        try bytes.write(to: file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["roundtrip.txt"])
    }

    func testRealSMBRcloneDirectWorkerCreatesAndUpdatesFile() throws {
        let env = try Environment()
        let (base, source) = try fixtureSource()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = try env.workspace("worker")
        defer { try? FileManager.default.removeItem(at: target) }
        let name = "nested/photo àè.jpg"
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent(name)
        let first = Data(repeating: 0x24, count: 256 * 1024)
        let second = Data(repeating: 0x51, count: 512 * 1024)
        try first.write(to: file)

        let db = base.appendingPathComponent("inventory.sqlite").path
        let journal = try ChangeJournal(path: db)
        let log = try SyncActivityLog(path: db)
        let mapping = try MountedFolderMapping(rootID: "smb-test", source: source, target: target)
        XCTAssertTrue(mapping.targetVolume.isStrongIdentity)
        let worker = try MountedFolderCopyWorker(
            journal: journal, log: log, mappings: [mapping],
            stageEngine: .rcloneDirect(env.rclone))
        let started = ProcessInfo.processInfo.systemUptime
        try journal.enqueue(rootID: "smb-test", relativePath: name, kind: .upsert)
        XCTAssertEqual(try worker.runOnce(enabled: true).created, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), first)
        XCTAssertTrue(try journal.pending().isEmpty)
        try second.write(to: file)
        try journal.enqueue(rootID: "smb-test", relativePath: name, kind: .upsert)
        XCTAssertEqual(try worker.runOnce(enabled: true).updated, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), second)
        XCTAssertTrue(try journal.pending().isEmpty)
        print("MACSYNC_SMB_INTEGRATION worker_create_update_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }

    private func helperRename(_ env: Environment, old: URL, new: URL, shouldSucceed: Bool) throws {
        var st = stat()
        XCTAssertEqual(old.path.withCString { Darwin.lstat($0, &st) }, 0)
        let request: [String: Any] = [
            "host": env.host, "port": "445", "share": env.share,
            "user": env.user, "domain": "", "password": env.password,
            "oldPath": old.lastPathComponent == old.path ? old.path :
                String(old.path.dropFirst(env.mount.path.count + 1)),
            "newPath": String(new.path.dropFirst(env.mount.path.count + 1)),
            "fileID": UInt64(st.st_ino),
            "createdSeconds": Int64(st.st_birthtimespec.tv_sec),
            "createdNanos": Int64(st.st_birthtimespec.tv_nsec),
            "size": Int64(st.st_size),
            "modifiedSeconds": Int64(st.st_mtimespec.tv_sec),
            "modifiedNanos": Int64(st.st_mtimespec.tv_nsec),
            "isDirectory": false
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let input = Pipe()
        let process = Process()
        process.executableURL = env.helper
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("MACSYNC_SMB_INTEGRATION helper_rename_seconds=\(elapsed) expected_success=\(shouldSucceed)")
        if shouldSucceed {
            XCTAssertEqual(process.terminationStatus, 0,
                           "The REAL helper rejected SMB identity or failed the server rename")
        } else {
            XCTAssertNotEqual(process.terminationStatus, 0,
                              "Protected SMB rename must not replace an occupied target")
        }
    }

    func testRealSMBProtectedHelperRenameAndCollision() throws {
        let env = try Environment()
        let root = try env.workspace("helper")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("old-name.jpg")
        let target = root.appendingPathComponent("new-name.jpg")
        let preserved = Data("protected original".utf8)
        try preserved.write(to: first)
        try helperRename(env, old: first, new: target, shouldSucceed: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: target), preserved)

        let occupied = Data("do not overwrite".utf8)
        try occupied.write(to: root.appendingPathComponent("another-old-name.jpg"))
        try helperRename(env, old: root.appendingPathComponent("another-old-name.jpg"),
                         new: target, shouldSucceed: false)
        XCTAssertEqual(try Data(contentsOf: target), preserved)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("another-old-name.jpg")), occupied)
    }
}
