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

    func testV019ManyToOneCollisionLeavesBothOriginals() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:base)}
        for root in [source,target] {
            try Data("question".utf8).write(to:root.appendingPathComponent("same?.jpg"))
            try Data("asterisk".utf8).write(to:root.appendingPathComponent("same*.jpg"))
        }
        let db=base.appendingPathComponent("fixture.sqlite").path
        try LocalInventory(path:db).reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let map=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        let rows=["same?.jpg","same*.jpg"].map { name in
            IncompatibleName(rootID:"demo",rootPath:source.path,
                relativePath:name,objectKind:"file",side:.source,reason:"Carattere incompatibile")
        }
        let result=try NameRectification.executeLocal(items:rows,roots:["demo":source.path],
            journal:journal,log:SyncActivityLog(path:db))
        XCTAssertEqual(result.renamed,0)
        XCTAssertEqual(result.skipped,2)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        XCTAssertTrue(try journal.nameRectificationReceipts(rootID:"demo").isEmpty)
        for root in [source,target] {
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("same?.jpg")),Data("question".utf8))
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("same*.jpg")),Data("asterisk".utf8))
            XCTAssertFalse(fm.fileExists(atPath:root.appendingPathComponent("same-.jpg").path))
        }
    }

    func testApprovedRules() {
        XCTAssertEqual(NameRectification.proposedName("photo  . "),"photo-")
        XCTAssertEqual(NameRectification.proposedName("Foto12345."),"Foto12345-")
        XCTAssertEqual(NameRectification.proposedName("Samsung A56..."),"Samsung A56---")
        XCTAssertEqual(NameRectification.proposedName("Samsung A56. "),"Samsung A56-")
        XCTAssertEqual(NameRectification.proposedName("Foto.jpg."),"Foto.jpg-")
        XCTAssertEqual(NameRectification.proposedName("Foto12345   "),"Foto12345")
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
        let result=try NameRectification.executeLocal(items:rows,roots:["demo":root.path],journal:ChangeJournal(path:db),log:SyncActivityLog(path:db))
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
    func testV0192LocalPlanCanResumeAfterCancellationWithoutTouchingDestination() throws {
        let fm=FileManager.default
        let base=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source"),target=base.appendingPathComponent("target")
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        try fm.createDirectory(at:target,withIntermediateDirectories:true)
        defer {try? fm.removeItem(at:base)}
        let old="photo?.jpg",new="photo-.jpg"
        try Data("source".utf8).write(to:source.appendingPathComponent(old))
        try Data("target".utf8).write(to:target.appendingPathComponent(old))
        let db=base.appendingPathComponent("fixture.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let log=try SyncActivityLog(path:db)
        let map=try MountedFolderMapping(rootID:"demo",source:source,target:target)
        try journal.verifyDirectoryBindings([map],allowNewTarget:true)
        let before=try journal.queueSequence()
        let rows=try inventory.incompatibleNames(rootID:"demo",sourcePath:source.path)
        let interrupted=try NameRectification.executeLocal(items:rows,roots:["demo":source.path],
            journal:journal,log:log,shouldContinue:{(try? journal.hasPendingNameRectification()) == false})
        XCTAssertTrue(interrupted.cancelled)
        XCTAssertTrue(try journal.hasPendingNameRectification())
        XCTAssertTrue(try journal.nameRectificationReceipts(rootID:"demo").isEmpty)
        let reopened=try ChangeJournal(path:db)
        let pending=try NameRectification.localMaintenanceRows(rows,journal:reopened)
        XCTAssertEqual(pending.count,1)
        XCTAssertTrue(pending[0].reason.hasPrefix("Rettifica in sospeso"))
        let result=try NameRectification.executeLocal(items:pending,roots:["demo":source.path],journal:reopened,log:log)
        XCTAssertEqual(result.sourceRenamed,1)
        XCTAssertFalse(try reopened.hasPendingNameRectification())
        let history=try ChangeJournal(path:db,readOnly:true).nameRectificationReceipts(rootID:"demo")
        XCTAssertEqual(history.count,1)
        let receipt=try XCTUnwrap(history.first?.receipt)
        XCTAssertEqual(receipt.oldPath,old)
        XCTAssertEqual(receipt.newPath,new)
        XCTAssertEqual(receipt.context.queueSequence,before)
        XCTAssertEqual(receipt.context.targetBinding,try DirectoryBinding.read(target))
        XCTAssertEqual(receipt.sourceBinding,try DirectoryBinding.read(source))
        XCTAssertFalse(receipt.isDirectory)
        _=try inventory.reconcile(rootID:"demo",root:source,eventID:42)
        let delete=try XCTUnwrap(reopened.pending().first{$0.kind == .delete && $0.relativePath==old})
        XCTAssertEqual(try reopened.rectificationMonitorLink(jobID:delete.id),history.first?.id)
        XCTAssertEqual(try reopened.originOfJob(id:delete.id),.sourceMonitor)
        XCTAssertEqual(try Data(contentsOf:source.appendingPathComponent(new)),Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(old)),Data("target".utf8))
        XCTAssertFalse(fm.fileExists(atPath:target.appendingPathComponent(new).path))
        let remote=IncompatibleName(rootID:"demo",rootPath:target.path,relativePath:old,
            objectKind:"file",side:.destination,reason:"Incompatible")
        XCTAssertThrowsError(try NameRectification.executeLocal(items:[remote],roots:["demo":target.path],
            journal:reopened,log:log))
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent(old)),Data("target".utf8))
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
        let result = try NameRectification.executeLocal(items: items, roots: ["demo": source.path],
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
