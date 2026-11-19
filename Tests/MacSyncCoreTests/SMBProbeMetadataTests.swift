import Foundation
import Darwin
import XCTest
@testable import MacSyncCore

final class SMBProbeMetadataTests:XCTestCase {
    func testFailedExclusiveRenameAndMetadataRefreshAllowSafeLinkProbe() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let dir=try AnchoredDirectory(root,expectedVolume:VolumeFingerprint.read(at:root))
        var calls:[ExclusivePublicationMethod]=[]
        let method=try dir.probeExclusivePublication(shouldContinue:{true},invoke:{ method,fd,old,new in
            calls.append(method)
            if method == .renameExclusive {
                return (-1,new.hasSuffix("-b") ? EEXIST : ENOTSUP)
            }
            if new.hasSuffix("-b") {
                // Simulate a changed timestamp after a failed SMB link.
                let url=root.appendingPathComponent(old)
                try? FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:12345678)],ofItemAtPath:url.path)
            }
            let rc=old.withCString { a in new.withCString { b in linkat(fd,a,fd,b,0) } }
            return (rc,errno)
        })
        XCTAssertEqual(method,.hardLink)
        XCTAssertEqual(calls,[.renameExclusive,.renameExclusive,.hardLink,.hardLink])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }

    func testProbeRejectsAlteredBytesAndNeverTriesPublishing() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let dir=try AnchoredDirectory(root,expectedVolume:VolumeFingerprint.read(at:root))
        var calls=0
        XCTAssertThrowsError(try dir.probeExclusivePublication(shouldContinue:{true},invoke:{ _,_,old,_ in
            calls+=1
            let handle=try? FileHandle(forWritingTo:root.appendingPathComponent(old))
            try? handle?.write(contentsOf:Data([0xff]))
            try? handle?.close()
            return (-1,EEXIST)
        }))
        XCTAssertEqual(calls,1)
    }
}
