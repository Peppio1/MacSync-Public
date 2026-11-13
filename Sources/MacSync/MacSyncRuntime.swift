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
        copy.setAutomaticCopiesEnabled(enabled)
        if copy.automaticCopiesEnabled {
            suspendedUntilNextLaunch = false
            checkAutomaticCopies()
        } else {
            automaticStatus = "Copie automatiche disabilitate"
        }
    }

    func onFolderConfigurationChanged() {
        // The selected folders may no longer represent the destinations
        // approved for unattended copying. Disarm unattended copy preference.
        if copy.automaticCopiesEnabled {
            copy.setAutomaticCopiesEnabled(false)
        }
        suspendedUntilNextLaunch = true
        automaticStatus = "Cartelle modificate: riabilita esplicitamente le copie automatiche dopo averle verificate"
    }

    func checkAutomaticCopies() {
        guard !suspendedUntilNextLaunch else { return }

        let configured = model.configuredPairs()
        let decision = AutomaticCopyReadiness.evaluate(
            enabled: copy.automaticCopiesEnabled,
            monitorRunning: model.monitoring,
            copyActive: copy.active,
            pairs: configured.map {
                AutomaticCopyPair(
                    sourcePath: $0.path, destinationPath: $0.destination,
                    expectedVolume: $0.expected
                )
            }
        )

        switch decision {
        case .alreadyActive:
            automaticStatus = copy.automaticSession
                ? "Copie automatiche attive (solo nuovi file e aggiornamenti)"
                : "Sessione di copie manuale attiva"
        case .ready:
            automaticStatus = "Destinazione disponibile: attivo le copie automatiche"
            copy.startAutomaticSafeCopies(sources: configured)
            if copy.active {
                automaticStatus = "Copie automatiche attive (mai cancellazioni)"
            } else {
                automaticStatus = "Attivazione rinviata: verifica il registro e la configurazione"
            }
        default:
            automaticStatus = decision.description
        }
    }
}
