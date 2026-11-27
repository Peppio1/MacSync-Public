import Foundation
import Darwin
import XCTest
@testable import MacSyncCore

final class SourceNameLineageTests: XCTestCase {
    private func fixture(_ body: (URL, SourceNameLineage.Identity) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: file)
        try body(file, identity(file))
    }
    private func identity(_ file: URL) throws -> SourceNameLineage.Identity {
        var st = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &st) }, 0)
        return try XCTUnwrap(SourceNameLineage.Identity(stat: st))
    }
    private func record(_ id: SourceNameLineage.Identity, path: String,
                        new: Bool = false) -> SourceNameLineage.Record {
        .init(identity: id, rootID: "photos", sourceBinding: "local", targetBinding: "remote",
              path: path, provenNew: new)
    }
    private func observe(_ record: inout SourceNameLineage.Record,
                         _ id: SourceNameLineage.Identity, _ path: String,
                         unique: Bool = true, target: String = "remote") -> SourceNameLineage.Decision {
        record.observe(identity: id, path: path, rootID: "photos", sourceBinding: "local",
                       targetBinding: target, uniqueObservation: unique)
    }
    func testNeverPublishedManualCorrection() throws {
        try fixture { file, id in
            let bad = file.deletingLastPathComponent().appendingPathComponent("photo.jpg.")
            try FileManager.default.moveItem(at: file, to: bad)
            XCTAssertEqual(try identity(bad), id)
            var history = record(id, path: "photo.jpg.", new: true)
            try FileManager.default.moveItem(at: bad, to: file)
            let plan = observe(&history, try identity(file), "photo.jpg")
            XCTAssertEqual(plan.upload, .copy("photo.jpg"))
            XCTAssertTrue(plan.suppressPreviousDelete)
            XCTAssertTrue(plan.deletionCandidates.isEmpty)
        }
    }
    func testRecognizedPathSurvivesIntermediateInvalidNamesAndRestart() throws {
        try fixture { file, id in
            var history = record(id, path: "photo.jpg")
            history.recognize(path: "photo.jpg")
            let bad = file.deletingLastPathComponent().appendingPathComponent("photo.jpg ")
            try FileManager.default.moveItem(at: file, to: bad)
            let hold = observe(&history, try identity(bad), "photo.jpg ")
            XCTAssertNil(hold.upload)
            XCTAssertEqual(hold.protectedPaths, ["photo.jpg"])
            XCTAssertTrue(hold.deletionCandidates.isEmpty)
            let data = try JSONEncoder().encode(history)
            history = try JSONDecoder().decode(SourceNameLineage.Record.self, from: data)
            let next = file.deletingLastPathComponent().appendingPathComponent("other.jpg.")
            try FileManager.default.moveItem(at: bad, to: next)
            XCTAssertEqual(observe(&history, try identity(next), "other.jpg.").protectedPaths, ["photo.jpg"])
            let corrected = file.deletingLastPathComponent().appendingPathComponent("other.jpg")
            try FileManager.default.moveItem(at: next, to: corrected)
            let plan = observe(&history, try identity(corrected), "other.jpg")
            XCTAssertEqual(plan.upload, .copy("other.jpg"))
            XCTAssertEqual(plan.deletionCandidates, ["photo.jpg"])
            XCTAssertFalse(plan.deletionCandidates.contains("other.jpg."))
        }
    }
    func testRestoreOriginalAndOrdinaryRename() throws {
        try fixture { _, id in
            var history = record(id, path: "photo.jpg")
            history.recognize(path: "photo.jpg")
            _ = observe(&history, id, "photo.jpg.")
            let restored = observe(&history, id, "photo.jpg")
            XCTAssertEqual(restored.upload, .revalidate("photo.jpg"))
            XCTAssertTrue(restored.deletionCandidates.isEmpty)
            let next = observe(&history, id, "next.jpg")
            XCTAssertEqual(next.upload, .copy("next.jpg"))
            XCTAssertEqual(next.deletionCandidates, ["photo.jpg"])
        }
    }
    func testUnknownAndInterruptedPublicationNeverSuppressDelete() throws {
        try fixture { _, id in
            var unknown = record(id, path: "old.")
            let a = observe(&unknown, id, "old")
            XCTAssertTrue(a.uncertain)
            XCTAssertFalse(a.suppressPreviousDelete)
            var interrupted = record(id, path: "old.", new: true)
            interrupted.publicationStarted()
            let b = observe(&interrupted, id, "old")
            XCTAssertTrue(b.uncertain)
            XCTAssertFalse(b.suppressPreviousDelete)
        }
    }
    func testIdentityAndBindingMismatchHardLinkAndAlias() throws {
        try fixture { file, id in
            var history = record(id, path: "photo.jpg")
            history.recognize(path: "photo.jpg")
            let before = history
            XCTAssertEqual(observe(&history, id, "other.jpg", unique: false), .unresolved)
            XCTAssertEqual(observe(&history, id, "other.jpg", target: "wrong"), .unresolved)
            let other = file.deletingLastPathComponent().appendingPathComponent("other.jpg")
            try Data([2]).write(to: other)
            XCTAssertEqual(observe(&history, try identity(other), "other.jpg"), .unresolved)
            XCTAssertEqual(history, before)
            let alias = observe(&history, id, "PHOTO.jpg")
            XCTAssertTrue(alias.uncertain)
            XCTAssertTrue(alias.deletionCandidates.isEmpty)
            let hard = file.deletingLastPathComponent().appendingPathComponent("hard.jpg")
            try FileManager.default.linkItem(at: file, to: hard)
            var st = stat()
            XCTAssertEqual(file.path.withCString { lstat($0, &st) }, 0)
            XCTAssertNil(SourceNameLineage.Identity(stat: st))
        }
    }
    func testInvalidAncestorProtectsRecognizedDescendant() throws {
        try fixture { _, id in
            var history = record(id, path: "folder/photo.jpg")
            history.recognize(path: "folder/photo.jpg")
            let hold = observe(&history, id, "folder./photo.jpg")
            XCTAssertNil(hold.upload)
            XCTAssertEqual(hold.protectedPaths, ["folder/photo.jpg"])
            XCTAssertTrue(hold.deletionCandidates.isEmpty)
            let fixed = observe(&history, id, "corrected/photo.jpg")
            XCTAssertEqual(fixed.deletionCandidates, ["folder/photo.jpg"])
        }
    }
}
