import Foundation
import XCTest
@testable import MacSyncCore

final class NameRectificationTests:XCTestCase {
    func testV019PreflightDistinguishesMissingOriginalAndCollision() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("item?.jpg")
        let new = root.appendingPathComponent("item-.jpg")
        try Data("original".utf8).write(to: old)
        let parent = try AnchoredDirectory(root, expectedVolume: DirectoryBinding.read(root).volume)
        let snapshot = try parent.leaf(old.lastPathComponent)
        try parent.checkRectification(old: old.lastPathComponent, new: new.lastPathComponent, matching: snapshot)
        try Data("occupied".utf8).write(to: new)
        XCTAssertThrowsError(try parent.checkRectification(old: old.lastPathComponent,
            new: new.lastPathComponent, matching: snapshot)) { error in
            XCTAssertEqual(error as? NameRectificationCheckError, .nameOccupied)
        }
        try fm.removeItem(at: old)
        XCTAssertThrowsError(try parent.checkRectification(old: old.lastPathComponent,
            new: new.lastPathComponent, matching: snapshot)) { error in
            XCTAssertEqual(error as? NameRectificationCheckError, .originalNotListed)
        }
        XCTAssertEqual(try Data(contentsOf: new), Data("occupied".utf8))
    }

    func testV019CoordinatedRollbackDoesNotBlockIndependentGroup() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:base)}
        let bad="a?.jpg", good="b?.jpg"
        for root in [source,target] {
            try Data("a-original".utf8).write(to:root.appendingPathComponent(bad))
            try Data("b-original".utf8).write(to:root.appendingPathComponent(good))
        }
        let db=base.appendingPathComponent("fixture.sqlite").path
        try LocalInventory(path:db).reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let mapping=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        try journal.verifyDirectoryBindings([mapping],allowNewTarget:true)
        let rows=[bad,good].flatMap { name in
            IncompatibleName.Side.allCases.map { side in
                IncompatibleName(rootID:"demo",rootPath:side == .source ? source.path : target.path,
                    relativePath:name,objectKind:"file",side:side,reason:"Carattere incompatibile")
            }
        }
        var injected=false
        let result=try NameRectification.executeCoordinated(items:rows,roots:["demo":source.path],
            journal:journal,log:SyncActivityLog(path:db),destinations:["demo":mapping],
            beforeDestination:{
                if !injected && fm.fileExists(atPath:source.appendingPathComponent("a-.jpg").path) {
                    injected=true
                    try? Data("occupied".utf8).write(to:target.appendingPathComponent("a-.jpg"))
                }
            })
        XCTAssertTrue(injected)
        XCTAssertEqual(result.renamed,2)
        XCTAssertEqual(result.failed,2)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        for root in [source,target] {
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(bad)),Data("a-original".utf8))
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("b-.jpg")),Data("b-original".utf8))
        }
        XCTAssertFalse(fm.fileExists(atPath:source.appendingPathComponent("a-.jpg").path))
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("a-.jpg")),Data("occupied".utf8))
    }

    func testV019PendingGroupDoesNotBlockNewIndependentSelection() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:base)}
        for root in [source,target] {
            try Data("a".utf8).write(to:root.appendingPathComponent("a?.jpg"))
            try Data("b".utf8).write(to:root.appendingPathComponent("b?.jpg"))
        }
        let db=base.appendingPathComponent("fixture.sqlite").path
        try LocalInventory(path:db).reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let mapping=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        try journal.verifyDirectoryBindings([mapping],allowNewTarget:true)
        func rows(_ name:String)->[IncompatibleName] {
            IncompatibleName.Side.allCases.map { side in
                IncompatibleName(rootID:"demo",rootPath:side == .source ? source.path : target.path,
                    relativePath:name,objectKind:"file",side:side,reason:"Carattere incompatibile")
            }
        }
        var stop=false
        let first=try NameRectification.executeCoordinated(items:rows("a?.jpg"),roots:["demo":source.path],
            journal:journal,log:SyncActivityLog(path:db),destinations:["demo":mapping],
            beforeDestination:{ stop=true },shouldContinue:{!stop})
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        let reopened=try ChangeJournal(path:db)
        let protection=try NameRectification.pendingProtection(journal:reopened)
        XCTAssertTrue(protection.protects(rootID:"demo",path:"a?.jpg"))
        XCTAssertTrue(protection.protects(rootID:"demo",path:"a-.jpg"))
        XCTAssertFalse(protection.protects(rootID:"demo",path:"b?.jpg"))
        let next=try NameRectification.executeCoordinated(items:rows("b?.jpg"),roots:["demo":source.path],
            journal:reopened,log:SyncActivityLog(path:db),destinations:["demo":mapping])
        XCTAssertEqual(next.renamed,2)
        XCTAssertTrue(try reopened.hasPendingNameRectification())
        let resumed=try NameRectification.executeCoordinated(items:rows("a?.jpg"),roots:["demo":source.path],
            journal:reopened,log:SyncActivityLog(path:db),destinations:["demo":mapping])
        XCTAssertEqual(resumed.renamed,0)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        XCTAssertTrue(fm.fileExists(atPath:source.appendingPathComponent("a?.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath:target.appendingPathComponent("a?.jpg").path))
    }

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
        let held = try worker.runCycle(enabled: true)
        XCTAssertFalse(held.interrupted, "Pending renames must not block unrelated jobs")
        XCTAssertEqual(held.copied, 0)
        XCTAssertGreaterThanOrEqual(held.deferred, 1)
        XCTAssertTrue(try reopened.hasPendingNameRectification())
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
        let firstSides = try NameRectification.pendingSideSummary(journal: journal)
        XCTAssertEqual(firstSides.sourceCompleted, 1)
        XCTAssertEqual(firstSides.destinationCompleted, 0)
        XCTAssertEqual(firstSides.sourcePending, 0)
        XCTAssertEqual(firstSides.destinationPending, 1)
        let persistedSides = try NameRectification.pendingSideSummary(journal: ChangeJournal(path: db))
        XCTAssertEqual(persistedSides.sourceCompleted, 1)
        XCTAssertEqual(persistedSides.destinationPending, 1)

        // The durable plan links both sides by old/new name. New paths,
        // old paths and their parent dependencies are guarded; siblings aren't.
        let protected = try NameRectification.pendingProtection(journal: journal)
        XCTAssertFalse(protected.isEmpty)
        XCTAssertTrue(protected.protects(rootID: "demo", path: original))
        XCTAssertTrue(protected.protects(rootID: "demo", path: corrected))
        XCTAssertFalse(protected.protects(rootID: "demo", path: "unrelated.jpg"))

        // Audit must report a pending rename, not a missing/extra file or a
        // reason to read SHA-256. QUICK and INTELLIGENT are both read-only.
        for mode in [ArchiveAuditMode.quick, .intelligent] {
            let audit = try ArchiveAudit(journal: journal, mappings: [map]).run(mode: mode)
            let known = audit.findings.filter {
                $0.relativePath == original || $0.relativePath == corrected
            }
            XCTAssertFalse(known.isEmpty)
            XCTAssertTrue(known.allSatisfy { $0.kind == .uncertain && !$0.detail.isEmpty })
            XCTAssertEqual(audit.bytesRead, 0)
            XCTAssertEqual(audit.queuedRepairs, 0)
        }

        // The unprotected sibling still copies while a local success and
        // remote error hold only the two affected names.
        let unrelated = Data("independent archive content".utf8)
        try unrelated.write(to: source.appendingPathComponent("unrelated.jpg"))
        _ = try LocalInventory(path: db).reconcile(rootID: "demo", root: source)
        let worker = try MountedFolderCopyWorker(journal: journal, log: log,
            mappings: [map], minimumStableAge: 0)
        _ = try worker.runCycle(enabled: true)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("unrelated.jpg")), unrelated)
        XCTAssertTrue(try journal.hasPendingNameRectification())
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

    func testPreflightDestinationOutageAvoidsRepeatedRemoteChecks() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        let unavailable = base.appendingPathComponent("unavailable")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let names = ["first?.jpg", "second?.jpg", "third?.jpg"]
        for (index, name) in names.enumerated() {
            try Data("photo-\(index)".utf8).write(to: target.appendingPathComponent(name))
        }
        try Data("independent".utf8).write(to: source.appendingPathComponent("local?.jpg"))
        let db = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: db).reconcile(rootID: "demo", root: source)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let journal = try ChangeJournal(path: db)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let remoteRows = names.map {
            IncompatibleName(rootID: "demo", rootPath: target.path,
                relativePath: $0, objectKind: "file", side: .destination, reason: "Incompatible")
        }
        let local = IncompatibleName(rootID: "demo", rootPath: source.path,
            relativePath: "local?.jpg", objectKind: "file", side: .source, reason: "Incompatible")
        try fm.moveItem(at: target, to: unavailable)
        let first = try NameRectification.execute(items: remoteRows + [local],
            roots: ["demo": source.path], journal: journal, log: log,
            destinations: ["demo": mapping])
        XCTAssertEqual(first.failed, 3)
        XCTAssertEqual(first.skipped, 0)
        XCTAssertEqual(first.renamed, 1)
        XCTAssertNotNil(first.firstFailure)
        XCTAssertFalse(try journal.hasPendingNameRectification(),
            "Unknown remote fingerprints cannot enter an approved durable plan")
        XCTAssertEqual(try log.technicalPage().filter {
            $0.entry.action == "name_rectification_preflight_destination_deferred"
        }.count, 2)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("local-.jpg")),
            Data("independent".utf8))
        for (index, name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: unavailable.appendingPathComponent(name)),
                Data("photo-\(index)".utf8))
        }

        // No unverified remote work was saved. A fresh operator-requested
        // preflight after reconnection must verify and rename each exact file.
        try fm.moveItem(at: unavailable, to: target)
        let recovered = try NameRectification.execute(items: remoteRows,
            roots: ["demo": source.path], journal: try ChangeJournal(path: db), log: log,
            destinations: ["demo": mapping])
        XCTAssertEqual(recovered.renamed, 3)
        XCTAssertEqual(recovered.failed, 0)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        for (index, name) in names.enumerated() {
            let corrected = name.replacingOccurrences(of: "?", with: "-")
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(corrected)),
                Data("photo-\(index)".utf8))
        }
    }

    func testDestinationOutageDefersSiblingsButLocalMoveContinuesAndResumes() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        let disconnected = base.appendingPathComponent("temporarily-disconnected")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let remoteNames = ["one?.jpg", "two?.jpg", "three?.jpg"]
        for (index, name) in remoteNames.enumerated() {
            try Data("remote-\(index)".utf8).write(to: target.appendingPathComponent(name))
        }
        let localName = "local?.jpg"
        let localBytes = Data("local remains independent".utf8)
        try localBytes.write(to: source.appendingPathComponent(localName))
        let db = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: db).reconcile(rootID: "demo", root: source)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let journal = try ChangeJournal(path: db)
        try journal.verifyDirectoryBindings([mapping], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let rows = remoteNames.map {
            IncompatibleName(rootID: "demo", rootPath: target.path,
                relativePath: $0, objectKind: "file", side: .destination, reason: "Incompatible")
        } + [IncompatibleName(rootID: "demo", rootPath: source.path,
                relativePath: localName, objectKind: "file", side: .source, reason: "Incompatible")]
        var simulatedOutage = false
        let first = try NameRectification.execute(items: rows, roots: ["demo": source.path],
            journal: journal, log: log, destinations: ["demo": mapping],
            onProgress: { checked, _ in
                if checked == 0 && !simulatedOutage {
                    do {
                        try fm.moveItem(at: target, to: disconnected)
                        simulatedOutage = true
                    } catch {
                        XCTFail("Cannot disconnect synthetic destination: \(error)")
                    }
                }
            })
        XCTAssertTrue(simulatedOutage)
        XCTAssertEqual(first.renamed, 1, "Independent local source must still be rectified")
        XCTAssertEqual(first.failed, 3, "Every unverified destination item must remain pending")
        XCTAssertNotNil(first.firstFailure)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("local-.jpg")), localBytes)
        let deferred = try log.technicalPage().filter {
            $0.entry.action == "name_rectification_shared_destination_deferred"
        }
        XCTAssertEqual(deferred.count, 2, "Only the first remote failure may probe this unavailable root")
        for (index, name) in remoteNames.enumerated() {
            XCTAssertEqual(try Data(contentsOf: disconnected.appendingPathComponent(name)),
                Data("remote-\(index)".utf8))
        }

        try fm.moveItem(at: disconnected, to: target)
        let reopened = try ChangeJournal(path: db)
        let resumed = try NameRectification.execute(items: [], roots: ["demo": source.path],
            journal: reopened, log: log, destinations: ["demo": mapping])
        XCTAssertEqual(resumed.renamed, 3)
        XCTAssertEqual(resumed.failed, 0)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        for (index, name) in remoteNames.enumerated() {
            XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(name).path))
            let corrected = name.replacingOccurrences(of: "?", with: "-")
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(corrected)),
                Data("remote-\(index)".utf8))
        }
    }

    func testSharedDestinationFailureClassificationIsStrict() {
        XCTAssertTrue(NameRectification.isSharedDestinationFailure(
            SMBNameRectificationError.credentialUnavailable))
        XCTAssertTrue(NameRectification.isSharedDestinationFailure(
            SMBNameRectificationError.timedOut))
        XCTAssertTrue(NameRectification.isSharedDestinationFailure(
            MountedCopyError.rootUnavailable))
        XCTAssertFalse(NameRectification.isSharedDestinationFailure(
            SMBNameRectificationError.helperFailed))
        XCTAssertFalse(NameRectification.isSharedDestinationFailure(
            MountedCopyError.destinationConflict))
        XCTAssertFalse(NameRectification.isSharedDestinationFailure(
            MountedCopyError.sourceChanging))
        XCTAssertFalse(NameRectification.isSharedDestinationFailure(
            MountedCopyError.destinationChanging))
    }

    func testIndexedPendingProtectionScalesAndGuardsNestedNames() {
        let relations = (0..<5_000).map { n in
            NameRectification.PendingProtection.Relation(
                rootID: "photos", oldPath: "batch-\(n)/folder?/raw?.dng",
                newPath: "batch-\(n)/folder?/raw-.dng",
                isDirectory: false, side: .destination)
        } + [NameRectification.PendingProtection.Relation(
                rootID: "photos", oldPath: "nested?/subfolder",
                newPath: "nested-/subfolder", isDirectory: true, side: .destination)]
        let start = ProcessInfo.processInfo.systemUptime
        let pending = NameRectification.PendingProtection(relations: relations)
        XCTAssertEqual(pending.relations.count, 5_001)
        XCTAssertTrue(pending.protects(rootID: "photos", path: "batch-2500/folder?/raw?.dng"))
        XCTAssertTrue(pending.protects(rootID: "photos", path: "batch-2500/folder?/raw-.dng"))
        XCTAssertTrue(pending.protects(rootID: "photos", path: "batch-2500/folder?"))
        XCTAssertFalse(pending.protects(rootID: "photos", path: "batch-2500/unrelated.dng"))
        XCTAssertTrue(pending.protects(rootID: "photos", path: "nested-/subfolder/dir/other.jpg"))
        XCTAssertTrue(pending.protects(rootID: "photos", path: "nested?"))
        XCTAssertFalse(pending.protects(rootID: "other-root", path: "nested-/subfolder/file.dng"))
        for i in 0..<20_000 {
            XCTAssertFalse(pending.protects(rootID: "photos",
                path: "batch-\(i % 5_000)/separate.dng"))
        }
        print("MACSYNC_PENDING_NAME_INDEX relations=5001 queries=20000 elapsed_seconds=\(ProcessInfo.processInfo.systemUptime - start)")
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


    func testIncompatibleNamePagingRetainsOrderCountsAndFullSelection() throws {
        let items = (0..<530).map { index in
            IncompatibleName(rootID:"demo",rootPath:"/Volumes/Example",
                relativePath:String(format:"folder_%04d?",index),
                objectKind:index % 2 == 0 ? "directory" : "file",
                side:index % 3 == 0 ? .destination : .source,
                reason:"Carattere incompatibile")
        }
        let first = try XCTUnwrap(IncompatibleNameListing.page(items:items,
            side:"all",directories:true,search:"",offset:0))
        let next = try XCTUnwrap(IncompatibleNameListing.page(items:items,
            side:"all",directories:true,search:"",offset:200))
        XCTAssertEqual(first.total,265)
        XCTAssertEqual(first.rows.count,200)
        XCTAssertEqual(next.rows.count,65)
        XCTAssertEqual(first.rows.first?.relativePath,items[0].relativePath)
        XCTAssertEqual(next.rows.first?.relativePath,items[400].relativePath)
        XCTAssertEqual(first.sourceFiles + first.destinationFiles,265)
        XCTAssertEqual(first.sourceFolders + first.destinationFolders,265)
        XCTAssertEqual(first.selectableIDs.count,530)
        XCTAssertEqual(first.matchingSelectableIDs.count,265)
        XCTAssertEqual(next.matchingSelectableIDs.count,265)
        let filtered = try XCTUnwrap(IncompatibleNameListing.page(items:items,
            side:"destination",directories:false,search:"FOLDER_0003?",offset:0))
        XCTAssertEqual(filtered.total,1)
        XCTAssertEqual(filtered.rows.first?.relativePath,"folder_0003?")
        XCTAssertEqual(filtered.rows.first?.side,.destination)
        XCTAssertEqual(filtered.selectableIDs.count,530)
        XCTAssertEqual(filtered.matchingSelectableIDs.count,1)
        XCTAssertTrue(try XCTUnwrap(IncompatibleNameListing.page(items:items,
            side:"all",directories:true,search:"",offset:10000)).rows.isEmpty)
    }

    func testIncompatibleNamePagingAndSelectionAreCooperativelyCancellable() {
        let items = (0..<5000).map { i in
            IncompatibleName(rootID:"demo",rootPath:"/test",
                relativePath:"bad_\(i)?.jpg",objectKind:"file",
                side:.source,reason:"Carattere incompatibile")
        }
        XCTAssertNil(IncompatibleNameListing.page(items:items,side:"all",
            directories:false,search:"",offset:0,shouldContinue:{false}))
        XCTAssertNil(IncompatibleNameSelection.resolve(items:items,
            selectedIDs:Set([items[0].id]),shouldContinue:{false}))
    }

    func testBilateralNameSelectionUsesBothSidesWithoutUnselectedSibling() throws {
        let local = IncompatibleName(rootID:"r",rootPath:"/Mac",relativePath:"bad?.jpg",
            objectKind:"file",side:.source,reason:"Carattere incompatibile")
        let remote = IncompatibleName(rootID:"r",rootPath:"/Server",relativePath:"bad?.jpg",
            objectKind:"file",side:.destination,reason:"Carattere incompatibile")
        let other = IncompatibleName(rootID:"r",rootPath:"/Mac",relativePath:"other?.jpg",
            objectKind:"file",side:.source,reason:"Carattere incompatibile")
        let selected = try XCTUnwrap(IncompatibleNameSelection.resolve(
            items:[local,remote,other],selectedIDs:Set([local.id])))
        XCTAssertEqual(selected.map(\.id),[local.id,remote.id])
        XCTAssertEqual(IncompatibleNameSelection.resolve(items:[local,remote,other],
            selectedIDs:[])?.count,0)
    }

    func testIncompatibleNameLargeFilteredPageIsBounded() throws {
        let start=ProcessInfo.processInfo.systemUptime
        let items=(0..<50000).map { index in
            IncompatibleName(rootID:"r",rootPath:"/Example",
                relativePath:"album_\(index)/bad?.jpg",
                objectKind:"file",side:.source,reason:"Carattere incompatibile")
        }
        let result=try XCTUnwrap(IncompatibleNameListing.page(items:items,side:"all",
            directories:false,search:"album_499",offset:0,limit:200))
        XCTAssertEqual(result.total,111)
        XCTAssertEqual(result.rows.count,111)
        XCTAssertEqual(result.selectableIDs.count,50000)
        XCTAssertEqual(result.matchingSelectableIDs.count,111)
        print("UI name listing synthetic 50k fixture (including creation): \(ProcessInfo.processInfo.systemUptime-start)s")
    }

}
