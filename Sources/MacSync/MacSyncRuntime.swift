import Foundation
import SwiftUI
import MacSyncCore

/// Application-lifetime coordinator. Connection status is queried ONLY
/// immediately before a scheduled synchronization attempt. No 30s polling,
/// VPN client, SMB reconnect, or background probing separate from the plan.
@MainActor
final class MacSyncRuntime: ObservableObject {
    let model = MacSyncViewModel()
    let copy = MountedCopyController()
    let settings = SyncSettingsController()
    let destinations = DestinationStatusController()

    @Published private(set) var automaticStatus = "Copie automatiche disabilitate"
    @Published private(set) var nextAutomaticAttempt: Date?

    private var autoTimer: Timer?
    private var suspendedUntilNextLaunch = false
    private var configurationRevision = 0
    private var readinessCheckInProgress = false
    private let readinessWorker = DispatchQueue(
        label: "macsync.autocopy.readiness", qos: .utility
    )
    private var outages = ConnectionOutageTracker()

    init() {
        if let data = UserDefaults.standard.data(forKey: "MacSync.connectionOutages"),
           let saved = try? JSONDecoder().decode(
               ConnectionOutageTracker.self, from: data
           ) {
            outages = saved
        }
        copy.onConnectionCheck = { [weak self] states, checkedAt in
            self?.receiveConnectionStates(states, at: checkedAt)
        }
        // The inventory/FSEvents scan starts asynchronously, while the next
        // automatic attempt is scheduled according to the chosen frequency.
        scheduleNextAutomaticAttempt()
    }

    deinit { autoTimer?.invalidate() }

    func stopCopiesForCurrentLaunch() {
        configurationRevision += 1
        suspendedUntilNextLaunch = true
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        copy.stop()
        automaticStatus = "Copie fermate manualmente: avvio automatico sospeso fino al prossimo avvio dell'app"
    }

    func onAutomaticPreferenceChanged(_ enabled: Bool) {
        configurationRevision += 1
        copy.setAutomaticCopiesEnabled(enabled)
        if copy.automaticCopiesEnabled {
            suspendedUntilNextLaunch = false
            automaticStatus = "Copie automatiche abilitate: attendo la prossima sincronizzazione"
        } else {
            automaticStatus = "Copie automatiche disabilitate"
        }
        scheduleNextAutomaticAttempt()
    }

    func onScheduleChanged() {
        // UI prevents changes during an active session; on a future session,
        // all intervals are always read from the persisted snapshot.
        configurationRevision += 1
        scheduleNextAutomaticAttempt()
    }

    func onAlertPolicyChanged(_ enabled: Bool) {
        settings.setAlertEnabled(enabled)
        if !enabled {
            outages = ConnectionOutageTracker()
            persistOutages()
        }
    }

    func onFolderConfigurationChanged() {
        configurationRevision += 1
        if copy.automaticCopiesEnabled {
            copy.setAutomaticCopiesEnabled(false)
        }
        suspendedUntilNextLaunch = true
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        destinations.configurationChanged()
        outages = ConnectionOutageTracker()
        persistOutages()
        automaticStatus = "Cartelle modificate: riabilita esplicitamente le copie automatiche dopo averle verificate"
    }

    private func persistOutages() {
        if let encoded = try? JSONEncoder().encode(outages) {
            UserDefaults.standard.set(encoded, forKey: "MacSync.connectionOutages")
        }
    }

    /// Share a single connection-status event pipeline across automatic and
    /// manually armed sessions. Only scheduled checks reach this method.
    private func receiveConnectionStates(
        _ results: [String: DestinationAvailability], at date: Date
    ) {
        destinations.update(results, checkedAt: date)
        let due = outages.record(results, at: date, policy: settings.alertPolicy)
        persistOutages()
        for id in due {
            MacSyncConnectionNotifier.send(destinationID: id)
        }
    }

    private func scheduleNextAutomaticAttempt() {
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        guard !suspendedUntilNextLaunch,
              copy.automaticCopiesEnabled,
              !copy.active,
              let next = settings.schedule.next(after: Date()) else { return }

        nextAutomaticAttempt = next
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoTimer = nil
                self?.nextAutomaticAttempt = nil
                self?.checkAutomaticCopies()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    private func checkAutomaticCopies() {
        guard !suspendedUntilNextLaunch,
              !readinessCheckInProgress,
              copy.automaticCopiesEnabled else {
            scheduleNextAutomaticAttempt()
            return
        }
        if copy.active {
            automaticStatus = copy.automaticSession
                ? "Copie automatiche attive (solo aggiunte e aggiornamenti)"
                : "Sessione di copie manuale attiva"
            scheduleNextAutomaticAttempt()
            return
        }
        if !model.monitoring {
            automaticStatus = "Attendo il monitoraggio delle sorgenti"
            scheduleNextAutomaticAttempt()
            return
        }
        let pairs = model.configuredPairs()
        let snapshot = pairs.map {
            AutomaticCopyPair(
                sourcePath: $0.path, destinationPath: $0.destination,
                expectedVolume: $0.expected
            )
        }
        let configured = pairs.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
        let revision = configurationRevision
        readinessCheckInProgress = true
        automaticStatus = "Verifica delle destinazioni prima della sincronizzazione…"

        // If only the SMB target is unavailable, do not run a copy session.
        // The next attempt comes from the SAME selected synchronization plan.
        readinessWorker.async { [weak self] in
            let decision = AutomaticCopyReadiness.evaluate(
                enabled: true, monitorRunning: true, copyActive: false,
                pairs: snapshot
            )
            var states: [String: DestinationAvailability] = [:]
            for item in configured {
                states[item.id] = DestinationProbe.inspect(
                    path: item.destination, expectedVolume: item.expected
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.readinessCheckInProgress = false
                guard self.configurationRevision == revision,
                      !self.suspendedUntilNextLaunch,
                      self.copy.automaticCopiesEnabled,
                      self.model.monitoring,
                      !self.copy.active else {
                    self.scheduleNextAutomaticAttempt()
                    return
                }
                self.receiveConnectionStates(states, at: Date())
                if decision == .ready {
                    self.automaticStatus = "Destinazioni pronte: avvio copie automatiche"
                    self.copy.startAutomaticSafeCopies(
                        sources: self.model.configuredPairs(),
                        schedule: self.settings.schedule
                    )
                    self.automaticStatus = self.copy.active
                        ? "Copie automatiche attive (senza cancellazioni)"
                        : "Attivazione rinviata: verifica configurazione e registro"
                } else {
                    self.automaticStatus = decision.description
                }
                self.scheduleNextAutomaticAttempt()
            }
        }
    }
}
