import Foundation
import AppKit
import SwiftUI
import UserNotifications
import MacSyncCore

/// Application-lifetime coordinator. Connection status is queried ONLY
/// immediately before a scheduled synchronization attempt. No 30s polling,
/// VPN client, SMB reconnect, or background probing separate from the plan.
@MainActor
final class MacSyncRuntime: ObservableObject {
    static weak var operationalRuntime: MacSyncRuntime?
    private let storageGuard: RuntimeStorageGuard?
    @Published private(set) var shuttingDown = false
    private var shutdownCompletion: (@MainActor () -> Void)?
    private var shutdownWorkersDrained = false
    private(set) var preparingSignedUpdate = false
    private var signedUpdateSession: SignedUpdateSession?
    var readyForTermination: Bool { shuttingDown && shutdownWorkersDrained && !folderConfigurationBusy && !savingSchedule && shutdownCompletion == nil }
    private var folderEditCancellation: SeedVerificationCancellation?
    let previewOnly: Bool
    let model: MacSyncViewModel
    let copy: MountedCopyController
    let updates: SoftwareUpdateController
    let settings: SyncSettingsController
    let destinations = DestinationStatusController()

    @Published private(set) var savingSchedule = false
    @Published private(set) var folderConfigurationBusy = false
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

    init(previewOnly: Bool = false) {
        self.previewOnly = previewOnly
        storageGuard = previewOnly ? nil : RuntimeStorageGuard.acquireOrExit()
        model = MacSyncViewModel(previewOnly: previewOnly)
        copy = MountedCopyController(previewOnly: previewOnly,monitorGate:model.safetyGate)
        settings = SyncSettingsController(previewOnly: previewOnly)
        updates = SoftwareUpdateController(previewOnly: previewOnly)
        guard !previewOnly else {
            automaticStatus = "Copie automatiche abilitate"
            nextAutomaticAttempt = Date().addingTimeInterval(900)
            destinations.update(["photo-uploads": .ready, "photo-editing": .ready, "demo-third": .ready], checkedAt: Date())
            return
        }
        Self.operationalRuntime = self
        copy.onQueueChanged = { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.model.refreshPendingCount()
            if !self.copy.active && self.nextAutomaticAttempt == nil { self.scheduleNextAutomaticAttempt() }
        }
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
        updates.onPrepareSignedUpdate = { [weak self] release in
            self?.prepareSignedUpdate(release)
        }
        updates.start()
    }

    deinit { autoTimer?.invalidate(); auditTimer?.invalidate() }

    func scheduleArchiveAudit() {
        guard !previewOnly, !shuttingDown, !folderConfigurationBusy, !savingSchedule else { return }
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
                if self.model.monitoring && self.model.safetyGate.isReady && !self.folderConfigurationBusy && !self.savingSchedule && !self.shuttingDown && self.copy.liveProgress == nil && !self.copy.interruptionRequested {
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

    /// No install-capable Sparkle object exists before this gate succeeds.
    func prepareSignedUpdate(_ release: StableUpdateRelease) {
        guard !previewOnly, !shuttingDown, let storageGuard,
              let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              release.isNewer(than: installed), release.tagName.hasPrefix("v"),
              SignedUpdatePolicy.assetURL(version: String(release.tagName.dropFirst())) != nil,
              ApplicationRollback.allowedInstallLocation(Bundle.main.bundleURL),
              !Bundle.main.bundleURL.path.contains("/AppTranslocation/"),
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String == SignedUpdatePolicy.publicKey,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == SignedUpdatePolicy.feedURL else {
            let alert = NSAlert()
            alert.messageText = "Aggiornamento non autorizzato"
            alert.informativeText = "Installa MacSync nella cartella Applicazioni e verifica la configurazione dell’aggiornamento."
            alert.runModal()
            return
        }
        let requested = String(release.tagName.dropFirst())
        preparingSignedUpdate = true
        requestShutdown { [weak self] in
            guard let self else { return }
            defer { self.preparingSignedUpdate = false }
            do {
                let snapshot = try storageGuard.createUpdateSnapshot()
                try storageGuard.beginSignedUpdate(previous: installed, requested: requested, snapshot: snapshot)
                self.automaticStatus = "Backup completato; sincronizzazione sospesa fino al riavvio"
                let session = SignedUpdateSession(installed: installed, requested: requested)
                self.signedUpdateSession = session
                // Defer until the current shutdown completion and modal UI
                // have returned. Sparkle cannot install before this point.
                DispatchQueue.main.async { session.start() }
            } catch {
                self.automaticStatus = "Aggiornamento bloccato; riavvia MacSync"
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Aggiornamento bloccato"
                alert.informativeText = error.localizedDescription +
                    "\n\nNessun installatore avviato. Esci e riapri MacSync."
                alert.runModal()
            }
        }
    }

    func requestShutdown(_ completion: @escaping @MainActor () -> Void) {
        if shuttingDown {
            // A refused update termination leaves workers stopped; allow
            // a later ordinary quit without permitting a second snapshot.
            if shutdownWorkersDrained && !folderConfigurationBusy && shutdownCompletion == nil {
                completion()
            }
            return
        }
        shuttingDown = true
        updates.stop()
        shutdownCompletion = completion
        folderEditCancellation?.cancel()
        stopAllOperations()
        copy.invalidateSeedReport()
        // A blocked SMB call may take time; do not terminate during a write.
        copy.afterWorkerStopped { [weak self] in
            self?.model.afterMonitorStopped { [weak self] in
                self?.shutdownWorkersDrained = true
                self?.finishShutdownIfReady()
            }
        }
    }

    private func finishShutdownIfReady() {
        guard shuttingDown, shutdownWorkersDrained, !folderConfigurationBusy, !savingSchedule else { return }
        let complete = shutdownCompletion; shutdownCompletion = nil; complete?()
    }

    func startManualSynchronization() {
        guard !previewOnly, !shuttingDown, !savingSchedule, !folderConfigurationBusy,
              model.monitoring, model.safetyGate.isReady, !copy.active, !copy.maintaining,
              !copy.seedBusy, !copy.seedReady, !copy.interruptionRequested else { return }
        configurationRevision += 1
        autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
        copy.start(sources:model.configuredPairs(),schedule:settings.schedule)
        if !copy.active { scheduleNextAutomaticAttempt() }
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

    func stopAllOperations() {
        stopCopiesForCurrentLaunch()
        auditRevision += 1
        auditTimer?.invalidate(); auditTimer = nil; nextAuditAt = nil
        copy.cancelSeedVerification(); copy.cancelArchiveAudit(); copy.cancelMaintenance()
        model.stopMonitoring()
    }

    func resumeAutomaticCopies() {
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy, copy.automaticCopiesEnabled, !copy.active, !copy.seedBusy, !copy.maintaining, !copy.interruptionRequested, copy.liveProgress == nil else { return }
        configurationRevision += 1
        suspendedUntilNextLaunch = false
        automaticStatus = "Copie automatiche abilitate: attendo il prossimo ciclo"
        scheduleNextAutomaticAttempt()
        scheduleArchiveAudit()
    }

    func onAutomaticPreferenceChanged(_ enabled: Bool) {
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy else { return }
        configurationRevision += 1
        copy.setAutomaticCopiesEnabled(enabled)
        if copy.automaticCopiesEnabled {
            suspendedUntilNextLaunch = false
            automaticStatus = "Copie automatiche abilitate: attendo la prossima sincronizzazione"
        } else {
            automaticStatus = "Copie automatiche disabilitate"
        }
        autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
        if copy.automaticCopiesEnabled { copy.afterWorkerStopped { [weak self] in self?.scheduleNextAutomaticAttempt() } }
    }

    func saveSchedule(_ schedule: SyncSchedule) {
        guard !previewOnly, !shuttingDown, schedule.isValid, !folderConfigurationBusy, !savingSchedule, !copy.seedBusy, !copy.maintaining, !copy.auditBusy else { return }
        let resume = copy.automaticCopiesEnabled && !suspendedUntilNextLaunch
        savingSchedule = true
        configurationRevision += 1
        autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
        copy.stop()
        let revision = configurationRevision
        copy.afterWorkerStopped { [weak self] in
            guard let self else { return }
            guard self.configurationRevision == revision else { self.savingSchedule = false; self.finishShutdownIfReady(); return }
            self.settings.schedule = schedule
            self.suspendedUntilNextLaunch = !resume
            self.savingSchedule = false
            self.automaticStatus = resume ? "Frequenza aggiornata: pianificazione riavviata" : "Frequenza aggiornata"
            self.scheduleNextAutomaticAttempt()
            self.scheduleArchiveAudit()
        }
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

    func editFolderConfiguration(add:[URL],parent:URL?,remove:String?) {
        guard !previewOnly, !shuttingDown, !folderConfigurationBusy, !savingSchedule, !copy.active, copy.liveProgress == nil, !copy.interruptionRequested, !copy.maintaining, !copy.seedBusy else { return }
        folderConfigurationBusy = true
        let token = SeedVerificationCancellation()
        folderEditCancellation = token
        stopAllOperations()
        copy.invalidateSeedReport()
        onFolderConfigurationChanged()
        copy.afterWorkerStopped { [weak self] in
            guard let self else { return }
            self.model.afterMonitorStopped { [weak self] in
                guard let self else { return }
                if self.shuttingDown || token.isCancelled {
                    self.folderConfigurationBusy = false
                    self.folderEditCancellation = nil
                    self.finishShutdownIfReady()
                    return
                }
                self.model.applyCommonFolders(add:add,parent:parent,remove:remove,cancellation:token) { [weak self] in
                    guard let self else { return }
                    self.folderConfigurationBusy = false
                    self.folderEditCancellation = nil
                    if !self.shuttingDown && self.model.configuredPairs().contains(where:{ !$0.path.isEmpty }) { self.model.startMonitoring() }
                    self.finishShutdownIfReady()
                }
            }
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
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy, !suspendedUntilNextLaunch,
              copy.automaticCopiesEnabled,
              !copy.active, !copy.interruptionRequested, copy.liveProgress == nil else { return }
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
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy, !suspendedUntilNextLaunch,
              copy.automaticCopiesEnabled, !copy.active else { return }
        guard model.monitoring, model.safetyGate.isReady, !copy.maintaining, !copy.seedBusy, !copy.seedReady else {
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
