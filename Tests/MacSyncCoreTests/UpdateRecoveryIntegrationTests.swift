import Foundation
import XCTest
@testable import MacSyncCore

/// Opt-in only. Every phase is invoked by a fresh XCTest process between
/// actual Sparkle installations. All state is confined to a runner fixture.
final class UpdateRecoveryIntegrationTests: XCTestCase {
    func testPersistentRecoveryAndStartupGate() throws {
        let env = ProcessInfo.processInfo.environment
        guard let phase = env["MACSYNC_RECOVERY_LAB_PHASE"] else { throw XCTSkip("Laboratorio integrato opt-in") }
        let root = URL(fileURLWithPath: try XCTUnwrap(env["MACSYNC_RECOVERY_LAB_ROOT"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let tmp = URL(fileURLWithPath: try XCTUnwrap(env["RUNNER_TEMP"]), isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertTrue(root.path.hasPrefix(tmp.path + "/macsync-install-lab."))
        guard root.path.hasPrefix(tmp.path + "/macsync-install-lab.") else {
            throw ApplicationRollback.Failure("Laboratorio non isolato")
        }
        let scenario = try XCTUnwrap(env["MACSYNC_RECOVERY_LAB_SCENARIO"])
        guard ["rollback", "success", "tampered"].contains(scenario) else {
            throw ApplicationRollback.Failure("Scenario sconosciuto")
        }
        let state = root.appendingPathComponent("state-" + scenario, isDirectory: true)
        let app = root.appendingPathComponent(scenario == "tampered" ? "bad/MacSync.app" : "target/MacSync.app", isDirectory: true)
        let key = try XCTUnwrap(env["MACSYNC_RECOVERY_LAB_PUBLIC"])
        let suite = "org.macsync.ci.recovery." + root.lastPathComponent + "." + scenario
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let fm = FileManager.default
        try fm.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = try ExclusiveArchiveLock(url: state.appendingPathComponent("archive.lock"))
        try withExtendedLifetime(lock) {
            let coordinator = UpdateRecoveryCoordinator(root: state,
                identifier: "org.macsync.ci.install-lab", publicKey: key,
                allowsLocation: { $0.standardizedFileURL.path == app.path })
            let source = state.appendingPathComponent("source", isDirectory: true)
            let digestURL = state.appendingPathComponent("expected-digest")
            let preferencesURL = state.appendingPathComponent("expected-preferences.plist")
            let marker = coordinator.markerURL
            func safetyOff() {
                XCTAssertFalse(defaults.bool(forKey: "MacSync.autoCopiesEnabled"))
                XCTAssertFalse(defaults.bool(forKey: "MacSync.autoCopiesEnabled.v2"))
                XCTAssertNil(defaults.object(forKey: "MacSync.mirrorAuthorization.v1"))
                XCTAssertNil(defaults.object(forKey: "MacSync.mirrorEnabled"))
                XCTAssertEqual(defaults.string(forKey: "MacSync.lab.unchanged"), "keep-me")
            }
            func digestMatches() throws {
                XCTAssertEqual(try ApplicationRollback.databaseDigest(coordinator.database, scratch: state),
                               try Data(contentsOf: digestURL))
                let journal = try ChangeJournal(path: coordinator.database.path)
                XCTAssertGreaterThan(try journal.pending().count, 0)
            }
            if phase == "prepare" {
                defaults.removePersistentDomain(forName: suite)
                defaults.set(true, forKey: "MacSync.autoCopiesEnabled")
                defaults.set(true, forKey: "MacSync.autoCopiesEnabled.v2")
                defaults.set("fixture-only", forKey: "MacSync.mirrorAuthorization.v1")
                defaults.set(true, forKey: "MacSync.mirrorEnabled")
                defaults.set("keep-me", forKey: "MacSync.lab.unchanged")
                XCTAssertTrue(defaults.synchronize())
                try fm.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("queued photo fixture".utf8).write(to: source.appendingPathComponent("photo.jpg"))
                let inventory = try LocalInventory(path: coordinator.database.path)
                let journal = try ChangeJournal(path: coordinator.database.path)
                _ = try inventory.reconcile(rootID: "lab", root: source)
                XCTAssertGreaterThan(try journal.pending().count, 0)
                try ApplicationRollback.databaseDigest(coordinator.database, scratch: state).write(to: digestURL)
                let snapshot = try coordinator.createSnapshot(application: app, preferences: defaults.dictionaryRepresentation())
                try coordinator.begin(application: app, previous: "0.18.1", requested: "0.18.2",
                                      snapshot: snapshot, defaults: defaults)
                XCTAssertTrue(fm.fileExists(atPath: marker.path))
                XCTAssertTrue(fm.isExecutableFile(atPath: snapshot.appendingPathComponent("Ripristina MacSync.command").path))
                try Data(contentsOf: snapshot.appendingPathComponent("preferences.plist")).write(to: preferencesURL)
                safetyOff()
                try digestMatches()
            } else if phase == "interrupted-start" {
                // A restart that has not completed initialization must keep
                // the marker. Exiting this test simulates that interrupted boot.
                let pending = try XCTUnwrap(coordinator.startup(application: app, defaults: defaults))
                XCTAssertEqual(Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String, "0.18.2")
                XCTAssertTrue(fm.fileExists(atPath: marker.path))
                try digestMatches()
                safetyOff()
                XCTAssertEqual(try Data(contentsOf: pending.snapshot.appendingPathComponent("preferences.plist")),
                               try Data(contentsOf: preferencesURL))
                XCTAssertThrowsError(try ExclusiveArchiveLock(url: state.appendingPathComponent("archive.lock")))
            } else if phase == "recover" {
                let pending = try coordinator.loadPending()
                XCTAssertThrowsError(try coordinator.recover(from: pending.snapshot, isStopped: { false }, confirm: { _ in true }))
                XCTAssertNil(try coordinator.recover(from: pending.snapshot, isStopped: { true }, confirm: { _ in false }))
                try ApplicationRollback.validateBundle(app, version: "0.18.2", identifier: "org.macsync.ci.install-lab", publicKey: key)
                let preserved = try XCTUnwrap(coordinator.recover(from: pending.snapshot, isStopped: { true }, confirm: { _ in true }))
                try ApplicationRollback.validateBundle(preserved.appendingPathComponent("MacSync.app"), version: "0.18.2",
                                                        identifier: "org.macsync.ci.install-lab", publicKey: key)
                try ApplicationRollback.validateBundle(app, version: "0.18.1", identifier: "org.macsync.ci.install-lab", publicKey: key)
                XCTAssertTrue(fm.fileExists(atPath: marker.path))
                try digestMatches()
            } else if phase == "finish" {
                let pending = try XCTUnwrap(coordinator.startup(application: app, defaults: defaults))
                let expected = scenario == "success" ? "0.18.2" : "0.18.1"
                try ApplicationRollback.validateBundle(app, version: expected, identifier: "org.macsync.ci.install-lab", publicKey: key)
                _ = try LocalInventory(path: coordinator.database.path)
                _ = try ChangeJournal(path: coordinator.database.path)
                try ArchiveDatabaseSafety.verify(coordinator.database)
                try digestMatches()
                try coordinator.complete(pending, defaults: defaults)
                XCTAssertFalse(fm.fileExists(atPath: marker.path))
                XCTAssertNil(try coordinator.startup(application: app, defaults: defaults))
                XCTAssertTrue(fm.fileExists(atPath: pending.snapshot.path))
                safetyOff()
            } else { XCTFail("Fase sconosciuta: \(phase)") }
        }
        print("RECOVERY LAB: \(scenario) / \(phase) passed")
    }
}
