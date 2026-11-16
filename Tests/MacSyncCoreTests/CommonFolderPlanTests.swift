import XCTest
@testable import MacSyncCore

final class CommonFolderPlanTests: XCTestCase {
    private let volume = VolumeFingerprint(fileSystem: "smbfs", mountPath: "/Volumes/share", mountSource: "//server/share")
    func testMultipleSourcesHaveSeparateTargets() {
        let sources = ["A","B","C"].map { CommonFolderSource(path: "/Photos/"+$0) }
        let plan = CommonFolderPlan(sources: sources, parent: "/Volumes/share/Archive", expected: volume)
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(sources.map {plan.target(for:$0)}, ["/Volumes/share/Archive/A","/Volumes/share/Archive/B","/Volumes/share/Archive/C"])
    }
    func testRejectsDuplicateNamesCaseInsensitiveAndOverlaps() {
        XCTAssertFalse(CommonFolderPlan(sources:[.init(path:"/One/A"),.init(path:"/Two/a")],parent:"/Volumes/share/Archive",expected:volume).isValid)
        XCTAssertFalse(CommonFolderPlan(sources:[.init(path:"/Photos"),.init(path:"/Photos/A")]).isValid)
        XCTAssertFalse(CommonFolderPlan(sources:[.init(path:"/Volumes/share")],parent:"/Volumes/share/Archive",expected:volume).isValid)
        XCTAssertFalse(CommonFolderPlan(sources:[.init(path:"/Photos/.macsync-staging")]).isValid)
        XCTAssertFalse(CommonFolderPlan(sources:[.init(path:"/Photos/A")],parent:"/Volumes/share/Archive").isValid)
    }
    func testPrepareTargetsRejectsSymlinkAndWrongVolume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let parent = root.resolvingSymlinksInPath()
        let actual = try VolumeFingerprint.read(at:parent)
        let sources = [CommonFolderSource(path:"/Example/A"),CommonFolderSource(path:"/Example/B")]
        let plan = CommonFolderPlan(sources:sources,parent:parent.path,expected:actual)
        try plan.prepareTargetDirectories()
        XCTAssertTrue(FileManager.default.fileExists(atPath:plan.target(for:sources[0])))
        XCTAssertTrue(FileManager.default.fileExists(atPath:plan.target(for:sources[1])))
        let wrong = CommonFolderPlan(sources:sources,parent:parent.path,expected:volume)
        XCTAssertThrowsError(try wrong.prepareTargetDirectories())
        let unsafe = parent.appendingPathComponent("C")
        try FileManager.default.createSymbolicLink(at:unsafe,withDestinationURL:parent.appendingPathComponent("A"))
        let collision = CommonFolderPlan(sources:[.init(path:"/Example/C")],parent:parent.path,expected:actual)
        XCTAssertThrowsError(try collision.prepareTargetDirectories())
    }
    func testIdentityAndIncompleteConfigurationRoundTrip() throws {
        let plan = CommonFolderPlan(sources:[.init(id:"stable",path:"/Photos/A")])
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.target(for:plan.sources[0]),"")
        XCTAssertEqual(try JSONDecoder().decode(CommonFolderPlan.self,from:JSONEncoder().encode(plan)),plan)
    }
}
