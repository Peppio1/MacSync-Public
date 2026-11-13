import Foundation
import XCTest
@testable import MacSyncCore

private final class FakeRclone: RcloneCommandExecuting {
    var commands: [[String]] = []
    var fail = false
    var onRun: (() -> Void)?

    func run(arguments: [String], timeout: TimeInterval) throws {
        commands.append(arguments)
        onRun?()
        if fail { throw UploadError.commandFailed(77) }
    }
}

final class SelectiveSMBCopyTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL, ChangeJournal) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-smb-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("Cartella_1")
        let dbPath = base.appendingPathComponent("state.sqlite")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (base, source, dbPath, try ChangeJournal(path: dbPath.path))
    }

    private func mapping(_ root: URL) throws -> SMBUploadMapping {
        try SMBUploadMapping(
            rootID: "photos", localRoot: root,
            remoteRoot: "macsync_smb:Condivisione_SMB/Cartella_1"
        )
    }

    private func oldFile(_ url: URL, contents: String = "file") throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-180)],
            ofItemAtPath: url.path
        )
    }

    func testNeverExecutesByDefault() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("image.dng")
        try oldFile(file)
        try journal.enqueue(rootID: "photos", relativePath: "image.dng", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        let outcome = try worker.runOnce()
        XCTAssertTrue(outcome.disabled)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(try journal.pending().count, 1)
    }

    func testSingleFileCopyDoesNotTraverseDestination() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = root.appendingPathComponent("set 2026")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = folder.appendingPathComponent("foto àè 😀.dng")
        try oldFile(image)
        try journal.enqueue(rootID: "photos", relativePath: "set 2026/foto àè 😀.dng", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        let outcome = try worker.runOnce(enabled: true)
        XCTAssertEqual(outcome.succeeded, 1)
        XCTAssertEqual(fake.commands.count, 1)
        XCTAssertEqual(fake.commands[0][0], "copyto")
        XCTAssertEqual(fake.commands[0][1], image.path)
        XCTAssertEqual(fake.commands[0][2], "macsync_smb:Condivisione_SMB/Cartella_1/set 2026/foto àè 😀.dng")
        XCTAssertFalse(fake.commands[0].contains("sync"))
        XCTAssertFalse(fake.commands[0].contains("delete"))
        XCTAssertTrue(try journal.pending().isEmpty)
    }

    func testRemoteFailureLeavesUploadInDurableQueue() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try oldFile(root.appendingPathComponent("file.psd"))
        try journal.enqueue(rootID: "photos", relativePath: "file.psd", kind: .upsert)
        let fake = FakeRclone()
        fake.fail = true
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).failed, 1)
        XCTAssertEqual(try journal.pending().count, 1)
        fake.fail = false
        XCTAssertEqual(try worker.runOnce(enabled: true).succeeded, 1)
        XCTAssertTrue(try journal.pending().isEmpty)
    }

    func testDeletesAreNeverSentAndDoNotStarveUploads() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        for index in 0..<60 {
            try journal.enqueue(rootID: "photos", relativePath: "deleted\(index).jpg", kind: .delete)
        }
        try oldFile(root.appendingPathComponent("new.jpg"))
        try journal.enqueue(rootID: "photos", relativePath: "new.jpg", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true, maxJobs: 1).succeeded, 1)
        XCTAssertEqual(fake.commands.map { $0[0] }, ["copyto"])
        XCTAssertEqual(try journal.pending().filter { $0.kind == .delete }.count, 60)
    }

    func testMissingSourceDoesNotTriggerDelete() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try journal.enqueue(rootID: "photos", relativePath: "missing.psd", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).deferred, 1)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(try journal.pending().count, 1)
    }

    func testActiveFileIsDeferred() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("recent".utf8).write(to: root.appendingPathComponent("busy.psd"))
        try journal.enqueue(rootID: "photos", relativePath: "busy.psd", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)],
            minimumStableAge: 300
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).deferred, 1)
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testFileChangingMidTransferStaysQueued() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("edit.psd")
        try oldFile(file)
        try journal.enqueue(rootID: "photos", relativePath: "edit.psd", kind: .upsert)
        let fake = FakeRclone()
        fake.onRun = {
            try? Data("completely different length".utf8).write(to: file)
        }
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).deferred, 1)
        XCTAssertEqual(try journal.pending().count, 1)
    }

    func testDirectoriesCreatedWithoutRecursion() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("New Folder"), withIntermediateDirectories: true
        )
        try journal.enqueue(rootID: "photos", relativePath: "New Folder", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).succeeded, 1)
        XCTAssertEqual(fake.commands[0][0], "mkdir")
        XCTAssertFalse(fake.commands[0].contains("sync"))
    }

    func testBlockedEarlyUploadDoesNotStarveLaterReadyFile() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        try journal.enqueue(rootID: "photos", relativePath: "unavailable.psd", kind: .upsert)
        try oldFile(root.appendingPathComponent("ready.jpg"))
        try journal.enqueue(rootID: "photos", relativePath: "ready.jpg", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )

        XCTAssertEqual(try worker.runOnce(enabled: true, maxJobs: 1).deferred, 1)
        XCTAssertEqual(try worker.runOnce(enabled: true, maxJobs: 1).succeeded, 1)
        XCTAssertEqual(fake.commands.count, 1)
        XCTAssertEqual(fake.commands[0][0], "copyto")
        XCTAssertEqual(try journal.pending().count, 1)
    }

    func testMappingRejectsTraversalAndInvalidRemote() throws {
        let (base, root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertThrowsError(
            try SMBUploadMapping(rootID: "photos", localRoot: root, remoteRoot: "remote:")
        )
        XCTAssertThrowsError(
            try SMBUploadMapping(rootID: "photos", localRoot: root, remoteRoot: "remote:../secret")
        )
        let valid = try mapping(root)
        XCTAssertThrowsError(try valid.destination(for: "../secret"))
        XCTAssertThrowsError(try valid.destination(for: "folder/../../secret"))
        XCTAssertThrowsError(try valid.destination(for: "bad:colon.jpg"))
        XCTAssertNoThrow(try valid.destination(for: "Foto 2026/äöü.png"))
    }

    func testSymlinkLeafIsNeverCopied() throws {
        let (base, root, _, journal) = try fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside.txt")
        try oldFile(outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside
        )
        try journal.enqueue(rootID: "photos", relativePath: "link.txt", kind: .upsert)
        let fake = FakeRclone()
        let worker = try SelectiveSMBCopyWorker(
            journal: journal, runner: fake, mappings: [mapping(root)]
        )
        XCTAssertEqual(try worker.runOnce(enabled: true).failed, 1)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertEqual(try journal.pending().count, 1)
    }
}
