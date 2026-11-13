import Foundation
import XCTest
@testable import MacSyncCore

final class FSEventsWatcherTests: XCTestCase {
    func testNativeWatcherReceivesFileCreationOnMacOSRunner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSync-fsevents-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let detected = expectation(description: "FSEvents noticed file creation")
        detected.assertForOverFulfill = false
        let queue = DispatchQueue(label: "macsync.tests.fsevents")
        let watcher = FSEventsWatcher(queue: queue) { events in
            if events.contains(where: { $0.path.hasSuffix("/fresh-photo.jpg") }) {
                detected.fulfill()
            }
        }
        let startID = FSEventsWatcher.currentEventID()
        try watcher.start(paths: [root.path], since: startID)
        defer { watcher.stop() }

        // Give FSEvents a moment to register the temporary folder on CI.
        Thread.sleep(forTimeInterval: 0.3)
        try Data("camera photo".utf8).write(to: root.appendingPathComponent("fresh-photo.jpg"))
        wait(for: [detected], timeout: 12)
    }
}
