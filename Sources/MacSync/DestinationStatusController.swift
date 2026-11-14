import Foundation
import SwiftUI
import MacSyncCore

/// Passive UI projection of scheduled connection checks.
/// Never starts a separate timer and NEVER probes SMB between sync ticks.
@MainActor
final class DestinationStatusController: ObservableObject {
    @Published private(set) var first: DestinationAvailability = .notConfigured
    @Published private(set) var second: DestinationAvailability = .notConfigured
    @Published private(set) var lastCheckedAt: Date?

    func update(
        _ values: [String: DestinationAvailability], checkedAt: Date
    ) {
        first = values["photo-uploads"] ?? .notConfigured
        second = values["photo-editing"] ?? .notConfigured
        lastCheckedAt = checkedAt
    }

    func configurationChanged() {
        first = .notConfigured
        second = .notConfigured
        lastCheckedAt = nil
    }
}
