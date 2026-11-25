import Foundation
import XCTest
@testable import MacSyncCore

final class IncompatibleNamesTests:XCTestCase {
    func testV0193LocalProposalsExcludeSelfAndDetectOccupiedAndManyToOneNames() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source=base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        for name in ["Solo ", "Punto.", "M.Y", "Collisione:", "Collisione-", "Doppio:", "Doppio?"] {
            try FileManager.default.createDirectory(at:source.appendingPathComponent(name),withIntermediateDirectories:false)
        }
        let db=base.appendingPathComponent("inventory.sqlite").path
        let inventory=try LocalInventory(path:db)
        _ = try inventory.reconcile(rootID:"demo",root:source)
        let journal=try ChangeJournal(path:db)
        let rows=try journal.classifyLocalNameProposals(inventory.incompatibleNames(rootID:"demo",sourcePath:source.path))
        func available(_ name:String)->Bool? { rows.first{$0.name==name}?.proposedNameAvailable }
        XCTAssertEqual(available("Solo "),true)
        XCTAssertEqual(available("Punto."),true)
        XCTAssertEqual(available("Collisione:"),false)
        XCTAssertEqual(available("Doppio:"),false)
        XCTAssertEqual(available("Doppio?"),false)
        XCTAssertFalse(rows.contains{$0.name=="M.Y"})
        XCTAssertTrue(WindowsPathSafety.validComponent("M.Y"))
        XCTAssertEqual(NameRectification.proposedName("Punto."),"Punto-")
    }

    func testDirectNamesAndDescendantsSeparated() {
        let items=[("bad ","directory"),("bad /okay.jpg","file"),("bad /nested.","directory"),("bad /nested./okay.jpg","file"),("bad /CON.png","file"),("regular.jpg","file")].map{
            TrackedItem(relativePath:$0.0,kind:$0.1,size:0,modifiedAt:0)
        }
        let rows=IncompatibleName.collect(rootID:"demo",rootPath:"/example",side:.source,items:items)
        XCTAssertEqual(rows.filter{$0.isDirectory}.count,2)
        XCTAssertEqual(rows.filter{!$0.isDirectory}.count,1)
        XCTAssertEqual(rows.first{$0.relativePath=="bad "}?.affectedDescendants,4)
        XCTAssertEqual(rows.first{$0.relativePath=="bad /nested."}?.affectedDescendants,1)
        XCTAssertFalse(rows.contains{$0.relativePath.hasSuffix("okay.jpg")})
        XCTAssertEqual(rows.first{$0.relativePath=="bad "}?.displayName,"bad␠")
    }
    func testSiblingConflictsDoNotFlagOrdinaryChildren() {
        let items=[("Group","directory"),("group","directory"),("Group/file.jpg","file"),("group/file.jpg","file")].map{
            TrackedItem(relativePath:$0.0,kind:$0.1,size:0,modifiedAt:0)
        }
        let rows=IncompatibleName.collect(rootID:"demo",rootPath:"/example",side:.source,items:items)
        XCTAssertEqual(rows.count,2)
        XCTAssertTrue(rows.allSatisfy{$0.isDirectory && $0.affectedDescendants==1})
    }
    func testRevealSelectsExactNameAndRejectsMissingOrSymlink() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let leaf=root.appendingPathComponent("example ")
        try Data("sample".utf8).write(to:leaf)
        let issue=IncompatibleName(rootID:"demo",rootPath:root.path,relativePath:"example ",objectKind:"file",side:.source,reason:"Spazio finale")
        XCTAssertEqual(try issue.revealURL(expectedRoot:root.path),leaf)
        XCTAssertThrowsError(try issue.revealURL(expectedRoot:"/"))
        try FileManager.default.removeItem(at:leaf)
        try FileManager.default.createSymbolicLink(at:leaf,withDestinationURL:root.appendingPathComponent("other"))
        XCTAssertThrowsError(try issue.revealURL(expectedRoot:root.path))
    }
    func testAuditCollectsOnlySourceNamesAndSourceCacheSurvivesReopen() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source")
        let target = base.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("source".utf8).write(to: source.appendingPathComponent("source "))
        try Data("target".utf8).write(to: target.appendingPathComponent("target?"))
        let database = base.appendingPathComponent("fixture.sqlite").path
        _ = try LocalInventory(path: database).reconcile(rootID: "demo", root: source)
        let journal = try ChangeJournal(path: database)
        let mapping = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        if !mapping.targetVolume.isStrongIdentity { throw XCTSkip("Volume identity unavailable") }
        let audit = try ArchiveAudit(journal: journal, mappings: [mapping]).run(mode: .quick)
        let snapshots = try XCTUnwrap(audit.nameScans)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.side, .source)
        XCTAssertTrue(audit.findings.contains { $0.relativePath == "target?" && $0.kind == .extra })
        for snapshot in snapshots {
            let standalone = try NameScanSnapshot.scan(rootID: "demo", side: snapshot.side,
                root: snapshot.side == .source ? source : target, volume: snapshot.volume,
                shouldContinue: { true })
            XCTAssertEqual(standalone.rows, snapshot.rows)
            try journal.saveNameScan(snapshot)
            XCTAssertEqual(try ChangeJournal(path: database).nameScan(rootID: "demo", side: snapshot.side), snapshot)
        }
        XCTAssertEqual(snapshots.flatMap(\.rows).map(\.relativePath), ["source "])
        try journal.invalidateNameScan(rootID: "demo", side: .destination)
        XCTAssertNil(try journal.nameScan(rootID: "demo", side: .destination))
        XCTAssertNotNil(try journal.nameScan(rootID: "demo", side: .source))
        XCTAssertThrowsError(try NameScanSnapshot.scan(rootID: "demo", side: .destination,
            root: target, volume: nil, shouldContinue: { true }))
    }

    func testBlockedJobIsLoggedOnceAcrossRestartAndRemainsPending() throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let src=base.appendingPathComponent("src"), dst=base.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at:src,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:dst,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:base)}
        let db=base.appendingPathComponent("test.sqlite").path
        let journal=try ChangeJournal(path:db)
        try journal.enqueue(rootID:"demo",relativePath:"bad /file.jpg",kind:.upsert)
        let map=try MountedFolderMapping(rootID:"demo",source:src,target:dst)
        for _ in 0..<2 {
            let worker=try MountedFolderCopyWorker(journal:ChangeJournal(path:db),log:SyncActivityLog(path:db),mappings:[map])
            let report=try worker.runCycle(enabled:true)
            XCTAssertEqual(report.deferred,1)
            XCTAssertEqual(report.failed,0)
        }
        XCTAssertEqual(try journal.plannedUploadCount(),1)
        XCTAssertEqual(try SyncActivityLog(path:db).recent().filter{$0.action=="name_blocked"}.count,1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:dst.path).isEmpty)
    }
}
