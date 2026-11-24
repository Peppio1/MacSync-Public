import Foundation
import XCTest
@testable import MacSyncCore

final class NameRectificationV019ValidationTests: XCTestCase {
    func testCoordinatedRenameReconcilesWithoutCopy() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let old = "sample?.psd", new = "sample-.psd"
        let bytes = Data("identical synthetic data".utf8)
        for root in [source,target] {
            try bytes.write(to: root.appendingPathComponent(old))
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -80)], ofItemAtPath: source.appendingPathComponent(old).path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40)], ofItemAtPath: target.appendingPathComponent(old).path)
        let db = base.appendingPathComponent("fixture.sqlite").path
        let inventory = try LocalInventory(path: db)
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let journal = try ChangeJournal(path: db)
        let map = try MountedFolderMapping(rootID: "demo", source: source, target: target)
        try journal.verifyDirectoryBindings([map], allowNewTarget: true)
        let log = try SyncActivityLog(path: db)
        let rows = IncompatibleName.Side.allCases.map { side in
            IncompatibleName(rootID: "demo", rootPath: side == .source ? source.path : target.path,
                relativePath: old, objectKind: "file", side: side, reason: "Carattere incompatibile")
        }
        let result = try NameRectification.executeCoordinated(items: rows, roots: ["demo":source.path], journal: journal,
            log: log, destinations: ["demo":map])
        XCTAssertEqual(result.renamed, 2)
        XCTAssertFalse(try journal.hasPendingNameRectification())
        _ = try inventory.reconcile(rootID: "demo", root: source)
        let audit = try ArchiveAudit(journal: journal, mappings: [map]).run(mode: .intelligent, repair: true, queueMirrorExtras: true)
        XCTAssertEqual(audit.count(.matching), 1)
        XCTAssertEqual(audit.queuedRepairs, 0)
        let worker = try MountedFolderCopyWorker(journal: journal, log: log, mappings: [map])
        let summary = try worker.runCycle(enabled: true)
        XCTAssertEqual(summary.copied, 0)
        XCTAssertEqual(summary.bytes, 0)
        XCTAssertEqual(summary.reconciled, 1)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(new)), bytes)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(new)), bytes)
        XCTAssertFalse(fm.fileExists(atPath: source.appendingPathComponent(old).path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(old).path))
    }
}
