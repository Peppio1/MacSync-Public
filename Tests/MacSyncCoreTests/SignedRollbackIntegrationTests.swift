import Foundation
import XCTest
@testable import MacSyncCore

final class SignedRollbackIntegrationTests:XCTestCase {
    func testPublishedPredecessorReplacesFixtureWithoutRestoringOldDatabase() async throws {
        guard ProcessInfo.processInfo.environment["MACSYNC_V0195_ROLLBACK_LAB"]=="1" || ProcessInfo.processInfo.environment["MACSYNC_V0194_ROLLBACK_LAB"]=="1" else {
            throw XCTSkip("Published rollback laboratory opt-in")
        }
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("macsync-rollback-lab-"+UUID().uuidString).resolvingSymlinksInPath()
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(at:root)}
        let suite="org.macsync.ci.rollback."+UUID().uuidString
        let defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let state=root.appendingPathComponent("state")
        let source=state.appendingPathComponent("source")
        try fm.createDirectory(at:source,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let app=root.appendingPathComponent("MacSync.app")
        let installed = ProcessInfo.processInfo.environment["MACSYNC_V0195_ROLLBACK_LAB"]=="1" ? "0.19.5" : "0.19.4"
        let package=try XCTUnwrap(SignedRollbackPackage.previous(for:installed))
        let download=root.appendingPathComponent("download")
        try fm.createDirectory(at:download,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        // Real released archive + signature, verified by production code.
        let previous=try await package.prepare(in:download)
        try package.validateApplication(previous)
        try fm.copyItem(at:previous,to:app)
        let info=app.appendingPathComponent("Contents/Info.plist")
        var plist=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:info),format:nil) as? [String:Any])
        plist["CFBundleShortVersionString"]=installed
        plist["CFBundleVersion"]=installed=="0.19.5" ? "203" : "202"
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:info)
        let sign=Process()
        sign.executableURL=URL(fileURLWithPath:"/usr/bin/codesign")
        sign.arguments=["--force","--sign","-",app.path]
        sign.standardOutput=FileHandle.nullDevice
        sign.standardError=FileHandle.nullDevice
        try sign.run();sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus,0)
        try ApplicationRollback.validateBundle(app,version:installed)
        let coordinator=UpdateRecoveryCoordinator(root:state,allowsLocation:{$0.path==app.path})
        let db=coordinator.database
        try Data("photo".utf8).write(to:source.appendingPathComponent("photo.jpg"))
        _ = try LocalInventory(path:db.path).reconcile(rootID:"photos",root:source)
        let journal=try ChangeJournal(path:db.path)
        _ = try journal.enqueue(rootID:"photos",relativePath:"photo.jpg",kind:.upsert,origin:.sourceMonitor)
        let before=try journal.pending()
        defaults.set(true,forKey:"MacSync.autoCopiesEnabled.v2")
        defaults.set("fixture-consent",forKey:"MacSync.mirrorAuthorization.v2")
        defaults.set("preserve",forKey:"MacSync.fixture")
        let lock=try ExclusiveArchiveLock(url:state.appendingPathComponent("archive.lock"))
        try withExtendedLifetime(lock) {
            let snapshot=try coordinator.createSnapshot(application:app,preferences:defaults.dictionaryRepresentation())
            let staging=snapshot.appendingPathComponent("signed-rollback")
            try fm.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            for name in ["previous.zip","previous.edsignature"] {
                try fm.copyItem(at:download.appendingPathComponent(name),to:staging.appendingPathComponent(name))
            }
            let savedDB=snapshot.appendingPathComponent("inventory.sqlite")
            let savedDigest=try ApplicationRollback.databaseDigest(savedDB,scratch:state)
            XCTAssertEqual(try ApplicationRollback.databaseDigest(db,scratch:state),savedDigest)
            let signatureURL=staging.appendingPathComponent("previous.edsignature")
            let correct=try Data(contentsOf:signatureURL)
            try Data("invalid".utf8).write(to:signatureURL)
            XCTAssertThrowsError(try SignedRollbackTransaction.install(root:state,snapshot:snapshot,target:app,
                defaults:defaults,allowsLocation:{$0.path==app.path})) { error in
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("firma") || error.localizedDescription.localizedCaseInsensitiveContains("pacchetto"), error.localizedDescription)
            }
            try ApplicationRollback.validateBundle(app,version:installed)
            XCTAssertEqual(try journal.pending(),before)
            try correct.write(to:signatureURL)
            try SignedRollbackTransaction.install(root:state,snapshot:snapshot,target:app,
                defaults:defaults,allowsLocation:{$0.path==app.path})
            try package.validateApplication(app)
            try ApplicationRollback.validateBundle(snapshot.appendingPathComponent("MacSync.app"),version:installed)
            XCTAssertEqual(try ChangeJournal(path:db.path).pending(),before)
            XCTAssertEqual(try ApplicationRollback.databaseDigest(savedDB,scratch:state),savedDigest)
            XCTAssertFalse(defaults.bool(forKey:"MacSync.autoCopiesEnabled.v2"))
            XCTAssertNil(defaults.object(forKey:"MacSync.mirrorAuthorization.v2"))
            XCTAssertEqual(defaults.string(forKey:"MacSync.fixture"),"preserve")
            XCTAssertEqual(defaults.string(forKey:"MacSync.updates.skippedStableTag"),"v"+installed)
            XCTAssertFalse(fm.fileExists(atPath:coordinator.markerURL.path))
            try ArchiveDatabaseSafety.verify(db,readOnly:true)
        }
    }
}
