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
    func testPendingDestinationCollisionDoesNotBlockAnIndependentLocalRename() throws {
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
                if checked == 0 { XCTAssertNoThrow(try occupied.write(to: collision)) }
            })
        XCTAssertEqual(first.renamed, 1)
        XCTAssertEqual(first.failed, 1)
        XCTAssertNotNil(first.firstFailure)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: collision), occupied)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(blocked)), data)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("b-.jpg")), data)

        try fm.removeItem(at: collision)
        let reopened = try ChangeJournal(path: db)
        let resumed = try NameRectification.execute(items: [], roots: ["demo": source.path],
            journal: reopened, log: log, destinations: ["demo": mapping])
        XCTAssertEqual(resumed.renamed, 2)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: collision), data)
    }

}
