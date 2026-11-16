import Foundation
import SwiftUI
import UserNotifications
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
    private var auditTimer: Timer?
    @Published private(set) var nextAuditAt: Date?
    private var auditRevision = 0
    private var suspendedUntilNextLaunch = false
    private var configurationRevision = 0
    private var outages = ConnectionOutageTracker()
    private var pendingAlerts: [String: UUID] = [:]
    private let notificationDelegate = MacSyncNotificationDelegate()

    init() {
        if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
            UNUserNotificationCenter.current().delegate = notificationDelegate
        }
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
        scheduleArchiveAudit()
    }

    deinit { autoTimer?.invalidate(); auditTimer?.invalidate() }

    func scheduleArchiveAudit() {
        auditRevision += 1
        auditTimer?.invalidate()
        auditTimer = nil
        nextAuditAt = nil
        let policy = copy.auditSettings
        guard policy.enabled, let next = policy.next(after:Date()) else { return }
        nextAuditAt = next
        let revision = auditRevision
        let timer = Timer(fire:next,interval:0,repeats:false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.auditRevision == revision, self.copy.auditSettings.enabled else { return }
                if self.model.monitoring {
                    self.copy.startArchiveAudit(sources:self.model.configuredPairs(),interactive:false)
                } else {
                    self.copy.noteAuditSkipped("monitoraggio locale non pronto; prossimo slot programmato")
                }
                self.scheduleArchiveAudit()
            }
        }
        RunLoop.main.add(timer,forMode:.common)
        auditTimer = timer
    }

    func stopCopiesForCurrentLaunch() {
        configurationRevision += 1
        suspendedUntilNextLaunch = true
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        copy.stop()
        automaticStatus = "Copie fermate manualmente: avvio automatico sospeso fino al prossimo avvio dell'app"
    }

    func resumeAutomaticCopies() {
        guard copy.automaticCopiesEnabled, !copy.active, !copy.seedBusy, !copy.maintaining else { return }
        configurationRevision += 1
        suspendedUntilNextLaunch = false
        automaticStatus = "Copie automatiche abilitate: attendo il prossimo ciclo"
        scheduleNextAutomaticAttempt()
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
            pendingAlerts.removeAll()
            outages = ConnectionOutageTracker()
            persistOutages()
        }
    }

    func onFolderConfigurationChanged() {
        configurationRevision += 1
        copy.stop()
        copy.revokeMirrorAuthorization()
        // A new destination must not silently inherit opt-in repairs.
        copy.auditSettings.repair = false
        copy.auditSettings.enabled = false
        scheduleArchiveAudit()
        if copy.automaticCopiesEnabled {
            copy.setAutomaticCopiesEnabled(false)
        }
        suspendedUntilNextLaunch = true
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        destinations.configurationChanged()
        pendingAlerts.removeAll()
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
        // Recovery, configuration changes or disabling alerts invalidate
        // pending delivery callbacks from the old incident.
        for id in Array(pendingAlerts.keys) where outages.firstObserved(for: id) == nil {
            pendingAlerts.removeValue(forKey: id)
        }
        persistOutages()
        for id in due {
            guard pendingAlerts[id] == nil,
                  let episode = outages.firstObserved(for: id) else { continue }
            let token = UUID()
            pendingAlerts[id] = token
            MacSyncConnectionNotifier.send(
                destinationID: id, firstObserved: episode,
                shouldSend: { [weak self] in
                    guard let self else { return false }
                    return self.settings.alertPolicy.enabled &&
                        self.pendingAlerts[id] == token &&
                        self.outages.firstObserved(for: id) == episode
                }
            ) { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pendingAlerts[id] == token else { return }
                    self.pendingAlerts.removeValue(forKey: id)
                    guard self.settings.alertPolicy.enabled,
                          self.outages.firstObserved(for: id) == episode else { return }
                    if let error {
                        // Remains due; no immediate retry timer is created.
                        self.settings.notificationPermissionStatus =
                            "Avviso non inviato: " + error.localizedDescription
                            + ". Nuovo tentativo al prossimo ciclo."
                    } else {
                        _ = self.outages.markAccepted(for: id, firstObserved: episode)
                        self.persistOutages()
                        self.settings.notificationPermissionStatus =
                            "Avviso accettato dal sistema notifiche macOS"
                    }
                }
            }
        }
    }

    private func scheduleNextAutomaticAttempt(afterSlot: Date? = nil) {
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        guard !suspendedUntilNextLaunch,
              copy.automaticCopiesEnabled,
              !copy.active else { return }
        let schedule = settings.schedule
        let now = Date()
        let next = afterSlot.flatMap {
            schedule.nextSlot(after: $0, completedAt: now)
        } ?? schedule.next(after: now)
        guard let next else { return }

        nextAutomaticAttempt = next
        let revision = configurationRevision
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.configurationRevision == revision else { return }
                self.autoTimer = nil
                self.nextAutomaticAttempt = nil
                self.activateAutomaticSession(at: next)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    /// The app-level timer only waits for a usable local monitor. It never
    /// probes SMB. Once armed, the copy worker owns all subsequent slots,
    /// including offline checks, retries and notifications.
    private func activateAutomaticSession(at slot: Date) {
        guard !suspendedUntilNextLaunch,
              copy.automaticCopiesEnabled, !copy.active else { return }
        guard model.monitoring else {
            automaticStatus = "Attendo il monitoraggio delle sorgenti"
            scheduleNextAutomaticAttempt(afterSlot: slot)
            return
        }
        let pairs = model.configuredPairs()
        // Reuse the pure configuration gate without filesystem probes.
        let decision = AutomaticCopyReadiness.evaluate(
            enabled: true, monitorRunning: true, copyActive: false,
            pairs: pairs.map {
                AutomaticCopyPair(sourcePath: $0.path,
                                  destinationPath: $0.destination,
                                  expectedVolume: $0.expected)
            },
            probe: { _, _ in .ready }
        )
        guard decision == .ready else {
            automaticStatus = decision.description
            scheduleNextAutomaticAttempt(afterSlot: slot)
            return
        }
        copy.startAutomaticSafeCopies(
            sources: pairs, schedule: settings.schedule, firstSlot: slot
        )
        automaticStatus = copy.active
            ? (copy.mirrorEnabled ? "Sincronizzazione automatica pianificata con cancellazioni autorizzate" : "Copie automatiche pianificate (senza cancellazioni)")
            : "Attivazione rinviata: verifica configurazione e registro"
        if !copy.active { scheduleNextAutomaticAttempt(afterSlot: slot) }
    }
}
