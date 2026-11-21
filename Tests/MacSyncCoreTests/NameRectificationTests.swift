import Foundation
import XCTest
@testable import MacSyncCore

final class NameRectificationTests:XCTestCase {
    func testApprovedRules() {
        XCTAssertEqual(NameRectification.proposedName("photo  . "),"photo")
        XCTAssertEqual(NameRectification.proposedName("Caffè:frontale?.jpg"),"Caffè-frontale-.jpg")
        XCTAssertEqual(NameRectification.proposedName("name.psd "),"name.psd")
        for name in ["CON.jpg","NUL ","COM1.",".",".."," . ",".macsync-staging","already valid"] {
            XCTAssertNil(NameRectification.proposedName(name),name)
        }
    }

    func testSMBPreflightDoesNotDelayAlreadySettledMetadata() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("photo?.jpg")
        try Data("archive".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)],
            ofItemAtPath: file.path)
        let parent = try AnchoredDirectory(root, expectedVolume: DirectoryBinding.read(root).volume)
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try NameRectification.stableSMBSnapshot(
            parent: parent, oldName: file.lastPathComponent, shouldContinue: { true })
        XCTAssertEqual(snapshot.st_size, 7)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2,
            "Old archive files must not wait for the SMB fresh-write cache")
    }

    func testSMBPreflightCancellationStopsWithoutRecordingAResult() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("recent?.jpg")
        try Data("recent".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let parent = try AnchoredDirectory(root, expectedVolume: DirectoryBinding.read(root).volume)
        XCTAssertThrowsError(try NameRectification.stableSMBSnapshot(
            parent: parent, oldName: file.lastPathComponent, shouldContinue: { false })) { error in
                guard case SeedVerificationError.cancelled = error else {
                    return XCTFail("Cancellation must be propagated, not counted as a skip")
                }
            }
        XCTAssertEqual(try Data(contentsOf: file), Data("recent".utf8))
    }

    func testNestedRenameAndConflictPreserveData() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let root=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder "),withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:base)}
        for (name,content) in [("folder /image?.jpg","nested"),("exists.jpg","untouched"),("exists.jpg ","collision"),("same?.jpg","one"),("same*.jpg","two")] {
            try Data(content.utf8).write(to:root.appendingPathComponent(name))
        }
        let db=base.appendingPathComponent("fixture.sqlite").path
        let inventory=try LocalInventory(path:db)
        _=try inventory.reconcile(rootID:"demo",root:root)
        let rows=try inventory.incompatibleNames(rootID:"demo",sourcePath:root.path)
        let result=try NameRectification.execute(items:rows,roots:["demo":root.path],journal:ChangeJournal(path:db),log:SyncActivityLog(path:db))
        XCTAssertEqual(result.renamed,2)
        XCTAssertEqual(result.skipped,4)
        XCTAssertEqual(result.failed,0)
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("folder/image-.jpg"),encoding:.utf8),"nested")
        for (name,content) in [("exists.jpg","untouched"),("exists.jpg ","collision"),("same?.jpg","one"),("same*.jpg","two")] {
            XCTAssertEqual(try String(contentsOf:root.appendingPathComponent(name),encoding:.utf8),content)
        }
        _=try inventory.reconcile(rootID:"demo",root:root)
        XCTAssertEqual(try inventory.incompatibleNames(rootID:"demo",sourcePath:root.path).filter{$0.relativePath.hasPrefix("folder")}.count,0)
    }
    func testDestinationRequiresPreviouslyBoundRootAndPreservesExistingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let original = target.appendingPathComponent("photo?.jpg")
        let published = target.appendingPathComponent("photo-.jpg")
        try Data("original".utf8).write(to: original)
        try Data("existing".utf8).write(to: published)
        let path = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: path).reconcile(rootID: "demo", root: source)
        let journal = try ChangeJournal(path: path)
        let log = try SyncActivityLog(path: path)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let row = IncompatibleName(rootID: "demo", rootPath: target.path, relativePath: "photo?.jpg",
            objectKind: "file", side: .destination, reason: "Carattere incompatibile")
        func execute() throws -> NameRectification.Result {
            try NameRectification.execute(items: [row], roots: ["demo": source.path],
                journal: journal, log: log, destinations: ["demo": mapping])
        }
        XCTAssertEqual(try execute().renamed, 0)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        XCTAssertEqual(try execute().skipped, 1)
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "existing")
        try FileManager.default.removeItem(at: published)
        XCTAssertEqual(try execute().renamed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "original")
    }

    func testConfirmedBatchSurvivesCancellationAndReconcilesByContent() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let old = "sample?.psd", new = "sample-.psd"
        let content = Data("identical".utf8)
        try content.write(to: source.appendingPathComponent(old))
        try content.write(to: target.appendingPathComponent(old))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -80)],
            ofItemAtPath: source.appendingPathComponent(old).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40)],
            ofItemAtPath: target.appendingPathComponent(old).path)
        let db = base.appendingPathComponent("fixture.sqlite").path
        let inventory = try LocalInventory(path: db)
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let journal = try ChangeJournal(path: db)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let rows = IncompatibleName.Side.allCases.map { side in
            IncompatibleName(rootID: "demo", rootPath: side == .source ? source.path : target.path,
                relativePath: old, objectKind: "file", side: side, reason: "Carattere incompatibile")
        }
        let first = try NameRectification.execute(items: rows, roots: ["demo": source.path], journal: journal,
            log: log, destinations: ["demo": mapping],
            shouldContinue: { !FileManager.default.fileExists(atPath: target.appendingPathComponent(new).path) })
        XCTAssertTrue(first.cancelled)
        XCTAssertEqual(first.renamed, 1)
        let reopened = try ChangeJournal(path: db)
        XCTAssertTrue(try reopened.hasPendingNameRectification())
        let worker = try MountedFolderCopyWorker(journal: reopened, log: log, mappings: [mapping])
        XCTAssertTrue(try worker.runCycle(enabled: true).interrupted)
        let second = try NameRectification.execute(items: [], roots: ["demo": source.path], journal: reopened,
            log: log, destinations: ["demo": mapping])
        XCTAssertEqual(second.renamed, 1)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let copied = try worker.runCycle(enabled: true)
        XCTAssertEqual(copied.reconciled, 1)
        XCTAssertEqual(copied.bytes, 0)
        XCTAssertEqual(try log.technicalPage().first { $0.entry.action == "name_rectification_copy_avoided" }?.entry.bytes,
            Int64(content.count))
    }
    func testDeferredDestinationAtSamePathDoesNotBlockLocalSourceAndCanResume() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let fm = FileManager.default
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let original = "same?.jpg", corrected = "same-.jpg"
        let bytes = Data("original content".utf8)
        try bytes.write(to: source.appendingPathComponent(original))
        try bytes.write(to: target.appendingPathComponent(original))
        let db = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: db).reconcile(rootID: "demo", root: source)
        let map = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !map.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let journal = try ChangeJournal(path: db)
        try journal.verifyDirectoryBindings([map], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let rows = IncompatibleName.Side.allCases.map { side in
            IncompatibleName(rootID: "demo", rootPath: side == .source ? source.path : target.path,
                relativePath: original, objectKind: "file", side: side, reason: "Carattere incompatibile")
        }
        let occupied = Data("existing collision".utf8)
        let collision = target.appendingPathComponent(corrected)
        let first = try NameRectification.execute(items: rows, roots: ["demo": source.path],
            journal: journal, log: log, destinations: ["demo": map], onProgress: { done, _ in
                if done == 0 {
                    do { try occupied.write(to: collision) }
                    catch { XCTFail("Cannot create synthetic collision: \(error)") }
                }
            })
        XCTAssertEqual(first.renamed, 1)
        XCTAssertEqual(first.failed, 1)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(corrected)), bytes)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(original)), bytes)
        XCTAssertEqual(try Data(contentsOf: collision), occupied)
        try fm.removeItem(at: collision)
        let reopened = try ChangeJournal(path: db)
        let resumed = try NameRectification.execute(items: [], roots: ["demo": source.path],
            journal: reopened, log: log, destinations: ["demo": map])
        XCTAssertEqual(resumed.renamed, 1)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(corrected)), bytes)
    }

    func testFailedChildKeepsAncestorDeferredOnSameSide() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let folder = source.appendingPathComponent("folder?")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let content = Data("do not overwrite".utf8)
        try content.write(to: folder.appendingPathComponent("child?.jpg"))
        let db = base.appendingPathComponent("fixture.sqlite").path
        let inventory = try LocalInventory(path: db)
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let rows = try inventory.incompatibleNames(rootID: "demo", sourcePath: source.path)
        XCTAssertEqual(rows.count, 2)
        let occupied = Data("collision".utf8)
        let collision = folder.appendingPathComponent("child-.jpg")
        let journal = try ChangeJournal(path: db)
        let log = try SyncActivityLog(path: db)
        let first = try NameRectification.execute(items: rows, roots: ["demo": source.path],
            journal: journal, log: log, onProgress: { done, _ in
                if done == 0 {
                    do { try occupied.write(to: collision) }
                    catch { XCTFail("Cannot create synthetic collision: \(error)") }
                }
            })
        XCTAssertEqual(first.renamed, 0)
        XCTAssertEqual(first.failed, 1)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("child?.jpg").path))
        XCTAssertEqual(try Data(contentsOf: collision), occupied)
        try fm.removeItem(at: collision)
        let resumed = try NameRectification.execute(items: [], roots: ["demo": source.path],
            journal: try ChangeJournal(path: db), log: log)
        XCTAssertEqual(resumed.renamed, 2)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf:
            source.appendingPathComponent("folder-/child-.jpg")), content)
    }

    func testPreflightCacheKeepsSiblingListingAndInvalidatesOnCollision() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let count = 200
        for number in 0..<count {
            try Data([UInt8(number % 251)]).write(
                to: base.appendingPathComponent("photo\(number)?.jpg"))
        }
        let parent = try AnchoredDirectory(base, expectedVolume: DirectoryBinding.read(base).volume)
        let cache = AuditDirectoryListingCache()
        for number in 0..<count {
            let old = "photo\(number)?.jpg", new = "photo\(number)-.jpg"
            try parent.checkRectification(old: old, new: new, matching: parent.leaf(old),
                preflightCache: cache)
        }
        XCTAssertEqual(cache.enumerations, 1, "Unchanged directory must be enumerated once")
        try Data("occupied".utf8).write(to: base.appendingPathComponent("photo100-.jpg"))
        XCTAssertThrowsError(try parent.checkRectification(old: "photo100?.jpg", new: "photo100-.jpg",
            matching: parent.leaf("photo100?.jpg"), preflightCache: cache))
        XCTAssertEqual(cache.enumerations, 2, "A modified directory must invalidate its cache")
        XCTAssertEqual(try Data(contentsOf: base.appendingPathComponent("photo100-.jpg")),
            Data("occupied".utf8))
    }

    private func benchmarkLocalNameBatch(_ count: Int) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let filesPerDirectory = 40
        for index in 0..<count {
            let folder = source.appendingPathComponent(String(format: "batch-%04d", index / filesPerDirectory))
            if index % filesPerDirectory == 0 {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data([UInt8(index % 251)]).write(
                to: folder.appendingPathComponent(String(format: "photo-%05d?.jpg", index)))
        }
        let db = base.appendingPathComponent("fixture.sqlite").path
        let inventory = try LocalInventory(path: db)
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let items = try inventory.incompatibleNames(rootID: "demo", sourcePath: source.path)
        XCTAssertEqual(items.count, count)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try NameRectification.execute(items: items, roots: ["demo": source.path],
            journal: ChangeJournal(path: db), log: SyncActivityLog(path: db))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("MACSYNC_LOCAL_NAME_BATCH count=\(count) elapsed_seconds=\(elapsed)")
        XCTAssertEqual(result.renamed, count)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.failed, 0)
    }

    func testLocalNameRectificationBenchmark100() throws {
        try benchmarkLocalNameBatch(100)
    }

    func testLocalNameRectificationBenchmark1000OptIn() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_LARGE_NAME_RENAMES"] == "1" else {
            throw XCTSkip("Enable MACSYNC_LARGE_NAME_RENAMES for 1000 file benchmark")
        }
        try benchmarkLocalNameBatch(1_000)
    }

    func testLocalNameRectificationBenchmark10000OptIn() throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_STRESS_NAME_RENAMES"] == "1" else {
            throw XCTSkip("Enable MACSYNC_STRESS_NAME_RENAMES for 10000 file benchmark")
        }
        try benchmarkLocalNameBatch(10_000)
    }

    func testPendingDestinationCollisionDoesNotBlockLocalSourceAtSamePathOrIndependentRename() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let blocked = "a?.jpg", independent = "b?.jpg"
        let data = Data([1])
        for root in [source, target] { try data.write(to: root.appendingPathComponent(blocked)) }
        try data.write(to: source.appendingPathComponent(independent))
        let db = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: db).reconcile(rootID: "demo", root: source)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let journal = try ChangeJournal(path: db)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let rows = [(IncompatibleName.Side.destination, target, blocked), (.source, source, blocked),
                    (.source, source, independent)].map { side, root, name in
            IncompatibleName(rootID: "demo", rootPath: root.path, relativePath: name,
                objectKind: "file", side: side, reason: "Carattere incompatibile")
        }
        let collision = target.appendingPathComponent("a-.jpg")
        let occupied = Data([2])
        let first = try NameRectification.execute(items: rows, roots: ["demo": source.path],
            journal: journal, log: log, destinations: ["demo": mapping], onProgress: { checked, _ in
                guard checked == 0 else { return }
                do {
                    try occupied.write(to: collision)
                } catch {
                    XCTFail("Impossibile creare la collisione di prova: \(error)")
                }
            })
        XCTAssertEqual(first.renamed, 2)
        XCTAssertEqual(first.failed, 1)
        XCTAssertNotNil(first.firstFailure)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: collision), occupied)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a-.jpg")), data)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("b-.jpg")), data)

        try fm.removeItem(at: collision)
        let reopened = try ChangeJournal(path: db)
        let resumed = try NameRectification.execute(items: [], roots: ["demo": source.path],
            journal: reopened, log: log, destinations: ["demo": mapping])
        XCTAssertEqual(resumed.renamed, 1)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: collision), data)
    }

}
