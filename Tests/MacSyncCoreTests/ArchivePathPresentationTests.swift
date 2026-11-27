import Foundation
import XCTest
@testable import MacSyncCore

final class ArchivePathPresentationTests:XCTestCase {
    func testNestedFileDirectoryAndRootDisplay() {
        let path=ArchivePathPresentation(root:"/Users/Foto/Desktop/Prova 2",relative:"vetro - 47253/nuovo originale/oca pro.jpg",side:.source,kind:.file)
        XCTAssertEqual(path.lines,["Sorgente: /Users/Foto/Desktop/Prova 2","Cartella: vetro - 47253/nuovo originale/","File: oca pro.jpg"])
        XCTAssertEqual(path.originalFullPath,"/Users/Foto/Desktop/Prova 2/vetro - 47253/nuovo originale/oca pro.jpg")
        let folder=ArchivePathPresentation(root:"/Volumes/Share",relative:"Album./nested ",side:.destination,kind:.directory)
        XCTAssertEqual(folder.lines,["Destinazione: /Volumes/Share","Cartella: Album./nested␠/"])
        XCTAssertNil(folder.leaf)
        XCTAssertEqual(folder.originalFullPath,"/Volumes/Share/Album./nested ")
        let root=ArchivePathPresentation(root:"/source",relative:"file.jpg ",side:.source,kind:.file)
        XCTAssertEqual(root.folder,"Radice")
        XCTAssertEqual(root.leaf,"file.jpg␠")
        let unknown=ArchivePathPresentation(root:"",relative:"dir/leaf",side:.unknown,kind:.unknown)
        XCTAssertEqual(unknown.lines,["Radice: Non registrata","Cartella: dir/","Elemento: leaf"])
    }
    func testFinderResolutionExactNamesMissingParentAndRefusesUnsafePaths() throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at:root) }
        let parent=root.appendingPathComponent("Album")
        try fm.createDirectory(at:parent,withIntermediateDirectories:true)
        let file=parent.appendingPathComponent("photo.jpg")
        try Data("fixture".utf8).write(to:file)
        let exact=try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"Album/photo.jpg",side:.source,kind:.file),expectedVolume:nil)
        XCTAssertTrue(exact.exact)
        XCTAssertEqual(exact.url.path,file.path)
        let missing=try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"Album/photo.jpg.",side:.source,kind:.file),expectedVolume:nil)
        XCTAssertFalse(missing.exact)
        XCTAssertEqual(missing.url.path,parent.path)
        XCTAssertThrowsError(try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"../outside",side:.source,kind:.file),expectedVolume:nil))
        try fm.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:parent)
        XCTAssertThrowsError(try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"link/photo.jpg",side:.source,kind:.file),expectedVolume:nil))
        XCTAssertThrowsError(try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"Album/photo.jpg",side:.destination,kind:.file),expectedVolume:nil))
        let volume=try VolumeFingerprint.read(at:root)
        let destination=try ArchiveRevealTarget.resolve(.init(root:root.path,relative:"Album/photo.jpg",side:.destination,kind:.file),expectedVolume:volume)
        XCTAssertTrue(destination.exact)
        XCTAssertEqual(try Data(contentsOf:file),Data("fixture".utf8))
    }
}
