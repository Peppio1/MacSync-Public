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
        let first = Data(repeating: 0x24, count: 2_000_000)
        let second = Data(repeating: 0x51, count: 3_000_000)
        try first.write(to: file)
        // Respect production stability delay; a fresh source is intentionally deferred.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: file.path)

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
        let firstCycle = try worker.runOnce(enabled: true)
        if firstCycle.created != 1 {
            for row in try log.technicalPage(limit: 20) {
                print("MACSYNC_SMB_DIAGNOSTIC action=\(row.entry.action) detail=\(row.entry.message)")
            }
            print("MACSYNC_SMB_DIAGNOSTIC firstCycle created=\(firstCycle.created) failed=\(firstCycle.failed) deferred=\(firstCycle.deferred)")
        }
        XCTAssertEqual(firstCycle.created, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), first)
        XCTAssertTrue(try journal.pending().isEmpty)
        try second.write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: file.path)
        try journal.enqueue(rootID: "smb-test", relativePath: name, kind: .upsert)
        XCTAssertEqual(try worker.runOnce(enabled: true).updated, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), second)
        XCTAssertTrue(try journal.pending().isEmpty)
        print("MACSYNC_SMB_INTEGRATION worker_create_update_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }


    private func helperRename(_ env: Environment, old: URL, new: URL,
                              diagnostic: Bool = false, modifiedSecondsOverride: Int64? = nil) throws -> (Int32, Double) {
        var source = stat()
        guard old.path.withCString({ Darwin.lstat($0, &source) }) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        let request: [String: Any] = [
            "host": env.host, "port": "445", "share": env.share,
            "user": env.user, "domain": "", "password": env.password,
            "oldPath": String(old.path.dropFirst(env.mount.path.count + 1)),
            "newPath": String(new.path.dropFirst(env.mount.path.count + 1)),
            "fileID": UInt64(source.st_ino),
            "createdSeconds": Int64(source.st_birthtimespec.tv_sec),
            "createdNanos": Int64(source.st_birthtimespec.tv_nsec),
            "size": Int64(source.st_size),
            "modifiedSeconds": modifiedSecondsOverride ?? Int64(source.st_mtimespec.tv_sec),
            "modifiedNanos": Int64(source.st_mtimespec.tv_nsec),
            "isDirectory": source.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        ]
        let input = Pipe()
        let process = Process()
        let diagnosticTool = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_DIAGNOSTIC_HELPER"]
        process.executableURL = diagnostic && diagnosticTool != nil ?
            URL(fileURLWithPath: diagnosticTool!) : env.helper
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let diagnosticOutput = Pipe()
        process.standardError = diagnostic ? diagnosticOutput : FileHandle.nullDevice
        let started = ProcessInfo.processInfo.systemUptime
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if diagnostic {
            let raw = String(decoding: diagnosticOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // Print only an enumerated test-only category. The raw helper
            // stderr may contain paths and must never reach CI logs.
            let categories: Set<String> = ["source-identity", "source-metadata",
                "source-size", "source-mtime",
                "destination-exists", "access-denied", "source-not-found",
                "request-invalid", "not-supported", "rename-io", "other", "success"]
            let observed = raw.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let prefix = "MACSYNC_SMB_HELPER_DIAGNOSTIC category="
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }.first
            print("MACSYNC_SMB_HELPER_DIAGNOSTIC category=\(observed.flatMap { categories.contains($0) ? $0 : nil } ?? "unavailable")")
        }
        print("MACSYNC_SMB_INTEGRATION helper_rename_seconds=\(elapsed) status=\(process.terminationStatus) diagnostic=\(diagnostic)")
        return (process.terminationStatus, elapsed)
    }

    private func serverSees(_ env: Environment, file: URL) -> Bool {
        let prefix = env.mount.path + "/"
        guard file.path.hasPrefix(prefix),
              let root = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_ROOT"] else {
            return false
        }
        let executable = URL(fileURLWithPath: root)
            .appendingPathComponent("metadata-probe/smb-metadata-probe")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let process = Process()
        process.executableURL = executable
        var variables = ProcessInfo.processInfo.environment
        variables["MACSYNC_TEST_SMB_OBJECT"] = String(file.path.dropFirst(prefix.count))
        process.environment = variables
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// Read server-side metadata of only the synthetic test fixture. This
    /// isolates Finder's cached timestamp from the SMB2 authoritative value.
    private func serverModifiedNanos(_ env: Environment, file: URL) -> Int64? {
        let prefix = env.mount.path + "/"
        guard file.path.hasPrefix(prefix),
              let fixtureRoot = ProcessInfo.processInfo.environment["MACSYNC_TEST_SMB_ROOT"] else {
            return nil
        }
        let executable = URL(fileURLWithPath: fixtureRoot)
            .appendingPathComponent("metadata-probe/smb-metadata-probe")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let p = Process()
        p.executableURL = executable
        var vars = ProcessInfo.processInfo.environment
        vars["MACSYNC_TEST_SMB_OBJECT"] = String(file.path.dropFirst(prefix.count))
        p.environment = vars
        p.standardInput = FileHandle.nullDevice
        let output = Pipe()
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count == 5 else { return nil }
        return Int64(parts[2])
    }

    /// The operating case: a just-created file must be renamed safely, not
    /// left pending merely because smbfs metadata publication was delayed.
    func testRealSMBProtectedHelperRenameAndPreserveContents() throws {
        let env = try Environment()
        let root = try env.workspace("helper-success")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old-name.jpg")
        let new = root.appendingPathComponent("new-name.jpg")
        let bytes = Data("checked rename preserves original".utf8)
        try bytes.write(to: old)
        let directory = try AnchoredDirectory(root,
            expectedVolume: DirectoryBinding.read(root).volume)
        let settleStarted = ProcessInfo.processInfo.systemUptime
        let prepared = try NameRectification.stableSMBSnapshot(
            parent: directory, oldName: old.lastPathComponent, shouldContinue: { true })
        let settleSeconds = ProcessInfo.processInfo.systemUptime - settleStarted
        var before = stat()
        XCTAssertEqual(old.path.withCString { Darwin.lstat($0, &before) }, 0)
        XCTAssertEqual(prepared.st_ino, before.st_ino)
        XCTAssertEqual(prepared.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(prepared.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        let beforeNs = Int64(before.st_mtimespec.tv_sec) * 1_000_000_000 +
            Int64(before.st_mtimespec.tv_nsec)
        let (status, duration) = try helperRename(env, old: old, new: new)
        guard status == 0 else {
            XCTAssertEqual(try Data(contentsOf: old), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
            var after = stat()
            XCTAssertEqual(old.path.withCString { Darwin.lstat($0, &after) }, 0)
            let afterNs = Int64(after.st_mtimespec.tv_sec) * 1_000_000_000 +
                Int64(after.st_mtimespec.tv_nsec)
            if let serverNs = serverModifiedNanos(env, file: old) {
                print("MACSYNC_SMB_MTIME_DIAGNOSTIC requested_vs_server_ns=\(beforeNs - serverNs) mounted_now_vs_server_ns=\(afterNs - serverNs) requested_vs_mounted_now_ns=\(beforeNs - afterNs)")
            } else {
                print("MACSYNC_SMB_MTIME_DIAGNOSTIC server_metadata_unavailable=true")
            }
            XCTFail("A fresh, unchanged file should be renamed by the protected helper")
            return
        }
        XCTAssertFalse(serverSees(env, file: old), "Server must no longer expose old path")
        XCTAssertTrue(serverSees(env, file: new), "Server must expose exact new path")
        let started = ProcessInfo.processInfo.systemUptime
        var visible = false
        repeat {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            visible = !names.contains("old-name.jpg") && names.contains("new-name.jpg")
            if visible { break }
            Thread.sleep(forTimeInterval: 0.125)
        } while ProcessInfo.processInfo.systemUptime - started < 3.5
        XCTAssertTrue(visible, "Mounted smbfs must eventually reflect the checked server rename")
        if visible { XCTAssertEqual(try Data(contentsOf: new), bytes) }
        print("MACSYNC_SMB_RENAME_REGRESSION preflight_settle_seconds=\(settleSeconds) fresh_helper_seconds=\(duration) local_visibility_seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    }

    /// A forged source timestamp is never a reason to rename. This regression
    /// explicitly tests the timeout path without changing bytes or paths.
    func testRealSMBProtectedHelperRejectsStaleTimestampWithoutWriting() throws {
        let env = try Environment()
        let root = try env.workspace("wrong-timestamp")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old.jpg")
        let new = root.appendingPathComponent("new.jpg")
        let bytes = Data("stale metadata must not authorize rename".utf8)
        try bytes.write(to: old)
        var snapshot = stat()
        XCTAssertEqual(old.path.withCString { Darwin.lstat($0, &snapshot) }, 0)
        let (status, seconds) = try helperRename(env, old: old, new: new,
            modifiedSecondsOverride: Int64(snapshot.st_mtimespec.tv_sec) - 20)
        XCTAssertNotEqual(status, 0)
        XCTAssertEqual(try Data(contentsOf: old), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        XCTAssertLessThan(seconds, 12, "Pre-rename metadata waits must be bounded")
        print("MACSYNC_SMB_RENAME_REGRESSION rejected_wrong_timestamp_seconds=\(seconds)")
    }

    /// Direct server-side directory rename must preserve its children.
    func testRealSMBProtectedHelperRenamesDirectoryWithoutRecopy() throws {
        let env = try Environment()
        let root = try env.workspace("directory")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old folder")
        let new = root.appendingPathComponent("new folder")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let content = Data("keep nested data".utf8)
        try content.write(to: old.appendingPathComponent("photo.dng"))
        let (status, _) = try helperRename(env, old: old, new: new)
        XCTAssertEqual(status, 0)
        guard status == 0 else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var moved = false
        repeat {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            moved = !names.contains("old folder") && names.contains("new folder")
            if moved { break }
            Thread.sleep(forTimeInterval: 0.125)
        } while ProcessInfo.processInfo.systemUptime - started < 3.5
        XCTAssertTrue(moved)
        if moved {
            XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("photo.dng")), content)
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        }
    }

    func testRealSMBProtectedHelperNeverReplacesOccupiedDestination() throws {
        let env = try Environment()
        let root = try env.workspace("helper-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old-name.jpg")
        let occupied = root.appendingPathComponent("new-name.jpg")
        let oldBytes = Data("source must remain".utf8)
        let targetBytes = Data("existing destination must remain".utf8)
        try oldBytes.write(to: old)
        try targetBytes.write(to: occupied)
        // Force stable source metadata, so a nonzero status cannot be
        // explained away by the unrelated fresh-file timestamp issue.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: old.path)
        Thread.sleep(forTimeInterval: 1.25)
        let (status, _) = try helperRename(env, old: old, new: occupied)
        XCTAssertNotEqual(status, 0, "An occupied SMB destination may never be replaced")
        XCTAssertEqual(try Data(contentsOf: old), oldBytes)
        XCTAssertEqual(try Data(contentsOf: occupied), targetBytes)
    }

    func testRealSMBDescriptorMetadataCapability() throws {
        let env = try Environment()
        let root = try env.workspace("descriptor-metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata.bin")
        try Data([1, 2, 3, 4]).write(to: file)
        let fd = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        if fd < 0 {
            let code = errno
            print("MACSYNC_SMB_CAPABILITY directory_open=no errno=\(code)")
            XCTAssertTrue([ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL].contains(code),
                "Unexpected failure opening the directory descriptor")
            return
        }
        defer { Darwin.close(fd) }
        var anchored = stat()
        let rc = "metadata.bin".withCString {
            Darwin.fstatat(fd, $0, &anchored, AT_SYMLINK_NOFOLLOW)
        }
        if rc < 0 {
            let code = errno
            print("MACSYNC_SMB_CAPABILITY fstatat=no errno=\(code)")
            XCTAssertTrue([ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL].contains(code),
                "Unexpected failure of read-only fstatat")
            return
        }
        var pathStat = stat()
        XCTAssertEqual(file.path.withCString { Darwin.lstat($0, &pathStat) }, 0)
        XCTAssertEqual(anchored.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(anchored.st_size, 4)
        XCTAssertEqual(anchored.st_ino, pathStat.st_ino)
        print("MACSYNC_SMB_CAPABILITY directory_open=yes fstatat=yes")
    }


    func testRealSMBArchiveQuickAndDeepAuditDoNotMutateDestinationOrQueue() throws {
        let env = try Environment()
        let (base, source) = try fixtureSource()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = try env.workspace("audit")
        defer { try? FileManager.default.removeItem(at: target) }
        let matching = Data("synthetic raw data".utf8)
        let unmatched = Data("synthetic missing data".utf8)
        let untouched = Data("synthetic destination extra".utf8)
        let sourceMatch = source.appendingPathComponent("same.dng")
        let targetMatch = target.appendingPathComponent("same.dng")
        let extra = target.appendingPathComponent("extra.jpg")
        try matching.write(to: sourceMatch)
        try matching.write(to: targetMatch)
        try unmatched.write(to: source.appendingPathComponent("missing.psd"))
        try untouched.write(to: extra)
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sourceMatch.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: targetMatch.path)
        // Test a settled archive rather than a file modified milliseconds
        // before its first SMB read; fresh-file safety is tested separately.
        XCTAssertEqual(try Data(contentsOf: targetMatch), matching)
        Thread.sleep(forTimeInterval: 0.7)

        let database = base.appendingPathComponent("audit.sqlite")
        let inventory = try LocalInventory(path: database.path)
        _ = try inventory.reconcile(rootID: "smb-audit", root: source)
        let journal = try ChangeJournal(path: database.path)
        let queueBefore = try journal.pending().map(\.relativePath).sorted()
        let mapping = try MountedFolderMapping(rootID: "smb-audit", source: source, target: target)
        let audit = try ArchiveAudit(journal: journal, mappings: [mapping])
        let sourceAtStart = try SeededArchiveVerifier.fingerprint(sourceMatch)
        let targetAtStart = try SeededArchiveVerifier.fingerprint(targetMatch)
        func logFingerprintState(_ phase: String) {
            guard let local = try? SeededArchiveVerifier.fingerprint(sourceMatch),
                  let remote = try? SeededArchiveVerifier.fingerprint(targetMatch) else {
                print("MACSYNC_SMB_AUDIT_FINGERPRINT phase=\(phase) read=failed")
                return
            }
            // Test-only measurements of synthetic files, with no paths,
            // credentials or content in the CI logs.
            print("MACSYNC_SMB_AUDIT_FINGERPRINT phase=\(phase) source_unchanged=\(local == sourceAtStart) target_unchanged=\(remote == targetAtStart) source_ctime_ns=\(local.ctimeNanos) target_ctime_ns=\(remote.ctimeNanos) source_mtime_ns=\(local.mtimeNanos) target_mtime_ns=\(remote.mtimeNanos)")
        }
        logFingerprintState("before")
        let quickStart = ProcessInfo.processInfo.systemUptime
        let quick = try audit.run(mode: .quick)
        let quickSeconds = ProcessInfo.processInfo.systemUptime - quickStart
        logFingerprintState("after-quick")
        XCTAssertEqual(quick.bytesRead, 0, "Quick mode must never hash file contents")
        XCTAssertEqual(quick.queuedRepairs, 0)
        XCTAssertEqual(quick.count(.missing), 1)
        XCTAssertEqual(quick.count(.extra), 1)
        XCTAssertEqual(try journal.pending().map(\.relativePath).sorted(), queueBefore)
        let deepStart = ProcessInfo.processInfo.systemUptime
        let deep = try audit.run(mode: .deep)
        let deepSeconds = ProcessInfo.processInfo.systemUptime - deepStart
        logFingerprintState("after-deep")
        if deep.count(.matching) != 1 {
            // Emit only sanitized, synthetic finding categories and metadata.
            // A remote smbfs timestamp/alias mismatch must not be mistaken
            // for successful recognition or silently removed from the queue.
            for finding in deep.findings where finding.relativePath == "same.dng" {
                print("MACSYNC_SMB_DIAGNOSTIC audit_kind=\(finding.kind.label) detail=\(finding.detail) source_mtime=\(finding.sourceModifiedAt ?? -1) target_mtime=\(finding.targetModifiedAt ?? -1)")
            }
        }
        XCTAssertEqual(deep.count(.matching), 1)
        XCTAssertEqual(deep.count(.missing), 1)
        XCTAssertEqual(deep.count(.extra), 1)
        XCTAssertEqual(deep.queuedRepairs, 0)
        XCTAssertGreaterThan(deep.bytesRead, 0, "Deep mode must actually read content")
        XCTAssertEqual(try journal.pending().map(\.relativePath).sorted(), queueBefore)
        XCTAssertEqual(try Data(contentsOf: targetMatch), matching)
        XCTAssertEqual(try Data(contentsOf: extra), untouched)
        print("MACSYNC_SMB_BENCHMARK audit_quick_seconds=\(quickSeconds) source_scan_seconds=\(quick.sourceMetrics?.scanSeconds ?? -1) destination_scan_seconds=\(quick.destinationMetrics?.scanSeconds ?? -1) compare_seconds=\(quick.comparisonSeconds ?? -1)")
        print("MACSYNC_SMB_BENCHMARK audit_deep_seconds=\(deepSeconds) source_scan_seconds=\(deep.sourceMetrics?.scanSeconds ?? -1) destination_scan_seconds=\(deep.destinationMetrics?.scanSeconds ?? -1) compare_seconds=\(deep.comparisonSeconds ?? -1)")
    }

    func testRealSMBDirectoryListingBenchmark200() throws {
        let env = try Environment()
        let root = try env.workspace("metadata-benchmark")
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 200
        let prepared = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            let path = root.appendingPathComponent(String(format: "entry-%04d.jpg", index))
            try Data([UInt8(index % 251)]).write(to: path)
        }
        let setupSeconds = ProcessInfo.processInfo.systemUptime - prepared
        let started = ProcessInfo.processInfo.systemUptime
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var checked = 0
        for name in names {
            var metadata = stat()
            let path = root.appendingPathComponent(name)
            XCTAssertEqual(path.path.withCString { Darwin.lstat($0, &metadata) }, 0)
            XCTAssertEqual(metadata.st_size, 1)
            checked += 1
        }
        let verifySeconds = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(checked, count)
        print("MACSYNC_SMB_BENCHMARK files=\(count) create_seconds=\(setupSeconds) list_and_lstat_seconds=\(verifySeconds)")
    }

}
