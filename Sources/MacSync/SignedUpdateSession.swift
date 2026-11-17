import Foundation
import AppKit
import Sparkle
import MacSyncCore

/// The only place where the install-capable updater is instantiated.
/// The runtime owns this object only after snapshot and durable marker.
@MainActor
final class SignedUpdateSession: NSObject, SPUUpdaterDelegate {
    let installed: String
    let requested: String
    private var controller: SPUStandardUpdaterController?

    init(installed: String, requested: String) {
        self.installed = installed
        self.requested = requested
    }

    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        c.startUpdater()
        // Sparkle's own scheduler remains disabled; MacSync owns the advisory
        // 24h discovery. The user explicitly confirms in Sparkle's signed UI.
        c.updater.automaticallyChecksForUpdates = false
        c.updater.automaticallyDownloadsUpdates = false
        c.updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard SignedUpdatePolicy.accepts(installed: installed, requested: requested,
                                         offered: updateItem.displayVersionString,
                                         channel: updateItem.channel, asset: updateItem.fileURL) else {
            throw NSError(domain: "MacSync.SignedUpdate", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Versione o pacchetto non corrispondente all’aggiornamento autorizzato. Chiudi e riapri MacSync."])
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Do not resume operations even if the user dismisses the dialog:
        // a downloaded update may still be installed on quit. The marker
        // and disabled copy preferences persist until verified restart.
        // The standard user driver presents errors; quit remains available.
    }
}
