import Foundation
import SwiftUI
import MacSyncCore

/// Status-only monitor. It never mounts an SMB share, probes the company
/// router, uses a VPN client, or modifies the remote filesystem. A reconnection
/// made by macOS is detected when the expected volume appears again.
@MainActor
final class DestinationStatusController: ObservableObject {
    @Published private(set) var first: DestinationAvailability = .notConfigured
    @Published private(set) var second: DestinationAvailability = .notConfigured
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var checking = false

    private let worker = DispatchQueue(label: "macsync.destination.probe", qos: .utility)
    private var timer: Timer?
    private var latestRequest = 0

    init() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    deinit { timer?.invalidate() }

    func refresh() {
        let defaults = UserDefaults.standard
        func volume(forKey key: String) -> VolumeFingerprint? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(VolumeFingerprint.self, from: data)
        }
        let path1 = defaults.string(forKey: "MacSync.targetUploads") ?? ""
        let path2 = defaults.string(forKey: "MacSync.targetEditing") ?? ""
        let expected1 = volume(forKey: "MacSync.targetVolumeUploads")
        let expected2 = volume(forKey: "MacSync.targetVolumeEditing")

        latestRequest += 1
        let request = latestRequest
        checking = true
        worker.async { [weak self] in
            let first = DestinationProbe.inspect(path: path1, expectedVolume: expected1)
            let second = DestinationProbe.inspect(path: path2, expectedVolume: expected2)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.latestRequest == request else { return }
                self.first = first
                self.second = second
                self.lastCheckedAt = Date()
                self.checking = false
            }
        }
    }
}
