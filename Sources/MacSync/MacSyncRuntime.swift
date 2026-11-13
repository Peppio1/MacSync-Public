import Foundation
import SwiftUI
import MacSyncCore

/// Lives at the App scene level, even when the configuration window is closed.
/// An opted-in copy session may therefore begin after Finder remounts SMB,
/// without requiring the user to open the settings window.
/// It NEVER grants permission to mirror-delete anything.
@MainActor
final class MacSyncRuntime: ObservableObject {
    let model = MacSyncViewModel()
    let copy = MountedCopyController()

    @Published private(set) var automaticStatus = "Copie automatiche disabilitate"

    private var timer: Timer?
    private var suspendedUntilNextLaunch = false
    private var configurationRevision = 0
    private var readinessCheckInProgress = false
    private let readinessWorker = DispatchQueue(
        label: "macsync.autocopy.readiness", qos: .utility
    )

    init() {
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAutomaticCopies() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // MacSyncViewModel starts the FSEvents scan asynchronously.
        // Delay the first attempt until monitor initialization is underway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkAutomaticCopies()
        }
    }

    deinit { timer?.invalidate() }

    func stopCopiesForCurrentLaunch() {
        suspendedUntilNextLaunch = true
        copy.stop()
        automaticStatus = "Copie fermate manualmente: avvio automatico sospeso fino al prossimo login o riavvio dell'app"
    }

    func onAutomaticPreferenceChanged(_ enabled: Bool) {
        configurationRevision += 1
        copy.setAutomaticCopiesEnabled(enabled)
        if copy.automaticCopiesEnabled {
            suspendedUntilNextLaunch = false
            checkAutomaticCopies()
        } else {
            automaticStatus = "Copie automatiche disabilitate"
        }
    }

    func onFolderConfigurationChanged() {
        configurationRevision += 1
        // The selected folders may no longer represent the destinations
        // approved for unattended copying. Disarm unattended copy preference.
        if copy.automaticCopiesEnabled {
            copy.setAutomaticCopiesEnabled(false)
        }
        suspendedUntilNextLaunch = true
        automaticStatus = "Cartelle modificate: riabilita esplicitamente le copie automatiche dopo averle verificate"
    }

    func checkAutomaticCopies() {
        guard !suspendedUntilNextLaunch, !readinessCheckInProgress else { return }
        if !copy.automaticCopiesEnabled {
            automaticStatus = "Copie automatiche disabilitate"
            return
        }
        if copy.active {
            automaticStatus = copy.automaticSession
                ? "Copie automatiche attive (solo nuovi file e aggiornamenti)"
                : "Sessione di copie manuale attiva"
            return
        }
        if !model.monitoring {
            automaticStatus = "Attendo il monitoraggio delle sorgenti"
            return
        }

        // Never run lstat/statfs on a potentially unresponsive SMB mount
        // from the main thread. Only the final, still-authorized activation
        // happens on the UI actor.
        let pairs = model.configuredPairs()
        let snapshot = pairs.map {
            AutomaticCopyPair(
                sourcePath: $0.path, destinationPath: $0.destination,
                expectedVolume: $0.expected
            )
        }
        let revision = configurationRevision
        readinessCheckInProgress = true
        automaticStatus = "Controllo disponibilità destinazioni…"
        readinessWorker.async { [weak self] in
            let decision = AutomaticCopyReadiness.evaluate(
                enabled: true, monitorRunning: true, copyActive: false,
                pairs: snapshot
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readinessCheckInProgress = false

                // The user may have toggled auto-copy, stopped a session, or
                // changed either folder while this probe was in progress.
                guard self.configurationRevision == revision,
                      !self.suspendedUntilNextLaunch,
                      self.copy.automaticCopiesEnabled,
                      self.model.monitoring,
                      !self.copy.active else { return }

                if decision == .ready {
                    self.automaticStatus = "Destinazione disponibile: attivo copie automatiche"
                    self.copy.startAutomaticSafeCopies(
                        sources: self.model.configuredPairs()
                    )
                    self.automaticStatus = self.copy.active
                        ? "Copie automatiche attive (mai cancellazioni)"
                        : "Attivazione rinviata: verifica il registro e le cartelle"
                } else {
                    self.automaticStatus = decision.description
                }
            }
        }
    }

}
