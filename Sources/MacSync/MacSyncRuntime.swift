import Foundation
import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import MacSyncCore

/// Application-lifetime coordinator. Operational checks still run before copies.
/// Visible folder-health probes are separate and read-only; no VPN client or
/// forced reconnect.
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
    @Published private(set) var sourceHealth: [String:FolderHealth] = [:]
    @Published private(set) var targetHealth: [String:FolderHealth] = [:]
    @Published private(set) var parentHealth: FolderHealth = .checking
    @Published private(set) var healthCheckedAt: Date?
    private var probingHealth = false
    private var healthRevision = 0
    private var remountProbeInFlight = false
    private var lastRemountProbeAt: Date?
    @Published private(set) var remountRecoveryStatus = ""

    @Published private(set) var savingSchedule = false
    @Published private(set) var folderConfigurationBusy = false
    @Published private(set) var automaticStatus = "Copie automatiche disabilitate"
    @Published private(set) var nextAutomaticAttempt: Date?

    @Published private(set) var nextFinalShutdownAt: Date?
    @Published private(set) var finalShutdownStatus = ""
    @Published private(set) var finalShutdownDeadline: Date?
    private var finalShutdownTimer: Timer?
    private var finalShutdownSlot: Date?
    private var finalShutdownHolding = false
    private var finalShutdownChecking = false
    private var finalShutdownForcedCycle = false
    private var finalShutdownGeneration = 0
    private var finalShutdownRequestSent = false
    var canCancelFinalShutdown: Bool { finalShutdownSlot != nil && !finalShutdownRequestSent }
    private var autoTimer: Timer?
    private var auditTimer: Timer?
    @Published private(set) var nextAuditAt: Date?
    private var auditRevision = 0
    @Published private(set) var rectificationPending = false
    private var rectificationRevision = 0
    @Published private(set) var preparingRectification = false
    @Published private(set) var rectificationCancellationRequested = false
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
            if !self.copy.queueRebuildRequired && self.nextAuditAt == nil { self.scheduleArchiveAudit() }
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
        rescheduleFinalShutdown()
        updates.onPrepareSignedUpdate = { [weak self] release in
            self?.prepareSignedUpdate(release)
        }
        updates.start()
        DispatchQueue.main.async { [weak self] in self?.recoverExistingFinderSMBMountIfNeeded() }
        if let path = try? copy.historyPath() {
            let revision = rectificationRevision
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pending = (try? ChangeJournal(path: path).hasPendingNameRectification()) == true
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.shuttingDown, self.rectificationRevision==revision else { return }
                    self.rectificationPending = pending
                    if pending {
                        self.automaticStatus = "Rettifica pendente: i percorsi interessati restano protetti; riprendi da Nomi incompatibili"
                    }
                }
            }
        }
    }

    deinit { autoTimer?.invalidate(); auditTimer?.invalidate(); finalShutdownTimer?.invalidate() }

    // A single read-only probe in flight. No extra SMB enumeration, writes,
    // reconnect attempts or automatic authorization. Stale results discarded.
    func refreshFolderHealth() {
        guard !previewOnly, !shuttingDown, !folderConfigurationBusy, !probingHealth else { return }
        recoverExistingFinderSMBMountIfNeeded()
        let plan=model.editableCommonPlan
        let pairs=model.configuredPairs().filter{ !$0.path.isEmpty }
        let rev=healthRevision
        let previousSources=sourceHealth, previousTargets=targetHealth, previousParent=parentHealth
        probingHealth=true
        let db=try? copy.historyPath()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var sources:[String:FolderHealth]=[:], targets:[String:FolderHealth]=[:]
            for pair in pairs {
                sources[pair.id]=FolderHealth.inspect(path:pair.path)
                targets[pair.id]=FolderHealth.inspect(path:pair.destination,expected:pair.expected,destination:true)
            }
            let parent=FolderHealth.inspect(path:plan.parent,expected:plan.expected,destination:true)
            let sourceResult=sources,targetResult=targets
            let date=Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probingHealth=false
                guard !self.shuttingDown, self.healthRevision==rev else {
                    self.refreshFolderHealth(); return
                }
                self.sourceHealth=sourceResult; self.targetHealth=targetResult
                self.parentHealth=parent; self.healthCheckedAt=date
                if let db {
                    let sourceEvents=sourceResult.filter{previousSources[$0.key] != $0.value}.map{($0.key,"source_health",$0.value)}
                    let targetEvents=targetResult.filter{previousTargets[$0.key] != $0.value}.map{($0.key,"target_health",$0.value)}
                    let parentEvents:[(String,String,FolderHealth)] = previousParent == parent ? [] : [("app","target_parent_health",parent)]
                    let events=sourceEvents+targetEvents+parentEvents
                    DispatchQueue.global(qos:.utility).async {
                        if let log=try? SyncActivityLog(path:db) {
                            for (id,action,state) in events where state != .checking {
                                try? log.record(level:state.isError ? .warning : .info,rootID:id,action:action,message:state.description)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Recover only an already mounted, uniquely matched SMB share. No
    /// credential lookup, Finder mount request or silent trust reset occurs.
    /// The expensive probe and SQLite checks stay off the main actor.
    private func recoverExistingFinderSMBMountIfNeeded() {
        guard !previewOnly, !shuttingDown, !folderConfigurationBusy, !remountProbeInFlight,
              !copy.active, !copy.maintaining, !copy.auditBusy, !copy.seedBusy,
              !copy.rectifyingNames, !copy.namesBusy, !rectificationPending,
              !finalShutdownHolding, let plan = model.remountRecoveryPlan,
              let expected = plan.expected,
              expected.fileSystem.lowercased() == "smbfs", expected.isStrongIdentity,
              !plan.parent.isEmpty, !plan.sources.isEmpty else { return }
        let now = Date()
        if let previous = lastRemountProbeAt, now.timeIntervalSince(previous) < 20 { return }
        lastRemountProbeAt = now
        remountProbeInFlight = true
        let revision = configurationRevision
        DispatchQueue.global(qos:.utility).async { [weak self] in
            // A live but different SMB share at the old path is not a safe
            // remount candidate. A stale local /Volumes directory is allowed.
            let old = try? VolumeFingerprint.read(at:URL(fileURLWithPath:plan.parent))
            let oldIsOtherSMB = old?.fileSystem.lowercased() == "smbfs" && old != expected
            let candidate: (path:String,volume:VolumeFingerprint)? =
                DestinationProbe.inspect(path:plan.parent,expectedVolume:expected) != .ready && !oldIsOtherSMB
                ? SMBRemountLocator.verifiedCandidate(savedPath:plan.parent,expected:expected) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !self.shuttingDown, self.configurationRevision == revision,
                      self.model.remountRecoveryPlan == plan,
                      !self.folderConfigurationBusy, !self.copy.active,
                      !self.copy.maintaining, !self.copy.auditBusy,
                      !self.copy.rectifyingNames else {
                    self.remountProbeInFlight = false
                    return
                }
                guard let candidate, let db = try? self.copy.historyPath() else {
                    self.remountProbeInFlight = false
                    return
                }
                self.folderConfigurationBusy = true
                let newParent = candidate.path, volume = candidate.volume
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    let verified: Bool
                    do {
                        let maps = try plan.sources.map { source in
                            try MountedFolderMapping(rootID:source.id,
                                source:URL(fileURLWithPath:source.path),
                                target:URL(fileURLWithPath:newParent).appendingPathComponent(source.name),
                                expectedTargetVolume:volume)
                        }
                        let journal = try ChangeJournal(path:db)
                        try journal.rebindVerifiedSMBMount(maps,oldVolume:expected)
                        verified = true
                    } catch { verified = false }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if verified && self.configurationRevision == revision && !self.shuttingDown &&
                           self.model.acceptVerifiedSMBRemount(oldParent:plan.parent,
                                 newParent:newParent,newVolume:volume) {
                            // A new mount path requires renewed consent to
                            // mirror/delete; previously allowed copies stay enabled.
                            self.copy.revokeMirrorAuthorization()
                            self.destinations.configurationChanged()
                            self.healthRevision += 1
                            self.remountRecoveryStatus = "Condivisione Finder ritrovata e verificata. Copie disponibili; eventuali cancellazioni richiedono nuova autorizzazione."
                        } else if !self.shuttingDown {
                            self.remountRecoveryStatus = "Condivisione SMB rilevata con un percorso diverso; identità delle cartelle non confermata. Nessuna scrittura autorizzata."
                        }
                        self.folderConfigurationBusy = false
                        self.remountProbeInFlight = false
                        if !self.shuttingDown {
                            self.refreshFolderHealth()
                            self.scheduleNextAutomaticAttempt()
                        }
                    }
                }
            }
        }
    }

    func populateFolderHealthPreview() {
        guard previewOnly else { return }
        sourceHealth=["photo-uploads":.ready,"photo-editing":.missing,"demo-third":.ready]
        targetHealth=["photo-uploads":.missing,"photo-editing":.missing,"demo-third":.missing]
        parentHealth = .missing
        healthCheckedAt=Date()
    }

    func scheduleArchiveAudit() {
        guard !previewOnly, !shuttingDown, !folderConfigurationBusy, !savingSchedule, !finalShutdownHolding else { return }
        auditRevision += 1
        auditTimer?.invalidate()
        auditTimer = nil
        nextAuditAt = nil
        let policy = copy.auditSettings
        guard !copy.queueRebuildRequired, policy.enabled, let next = policy.next(after:Date()) else { return }
        nextAuditAt = next
        let revision = auditRevision
        let timer = Timer(fire:next,interval:0,repeats:false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.auditRevision == revision, self.copy.auditSettings.enabled else { return }
                if self.model.monitoring && self.model.safetyGate.isReady && !self.folderConfigurationBusy && !self.savingSchedule && !self.shuttingDown && self.copy.liveProgress == nil && !self.copy.interruptionRequested {
                    self.startScheduledArchiveAudit()
                } else {
                    self.copy.noteAuditSkipped("monitoraggio locale non pronto; prossimo slot programmato")
                }
                self.scheduleArchiveAudit()
            }
        }
        RunLoop.main.add(timer,forMode:.common)
        auditTimer = timer
    }

    private func startScheduledArchiveAudit() {
        guard !shuttingDown, !finalShutdownHolding, !copy.maintaining, !copy.seedBusy, !copy.seedReady, !copy.auditBusy, copy.liveProgress == nil else {
            copy.noteAuditSkipped("sincronizzazione o manutenzione in corso"); return
        }
        configurationRevision += 1
        let revision = configurationRevision
        autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
        if copy.active { copy.stop() }
        copy.afterWorkerStopped { [weak self] in
            guard let self, self.configurationRevision == revision, !self.shuttingDown, !self.finalShutdownHolding, self.copy.auditSettings.enabled else { return }
            self.autoTimer?.invalidate(); self.autoTimer = nil; self.nextAutomaticAttempt = nil
            self.copy.startArchiveAudit(sources:self.model.configuredPairs(),interactive:false)
            if !self.copy.auditBusy { self.scheduleNextAutomaticAttempt() }
        }
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

    func resetApplicationData() {
        guard !previewOnly, !shuttingDown, !preparingSignedUpdate, let storageGuard else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Azzerare tutti i dati di MacSync?"
        confirmation.informativeText = "Verranno eliminati configurazione, database, coda, registri e backup interni. I file nelle cartelle sincronizzate e le voci del Portachiavi restano intatti. MacSync si chiuderà e completerà il ripristino alla prossima apertura."
        confirmation.addButton(withTitle: "Annulla")
        confirmation.addButton(withTitle: "Azzera dati e chiudi")
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }
        let paths = model.configuredPairs().flatMap { [$0.path, $0.destination] } +
            [model.photoUploads, model.photoEditing, model.destinationUploads, model.destinationEditing]
        requestShutdown { [weak self] in
            guard let self else { return }
            do {
                let service = SMAppService.mainApp
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
                try storageGuard.scheduleFactoryReset(configuredPaths: paths)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Ripristino non avviato"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Chiudi MacSync")
                alert.runModal()
            }
            self.automaticStatus = "MacSync in chiusura"
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
        automaticStatus = "Chiusura delle attività per il ripristino…"
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
        finalShutdownTimer?.invalidate(); finalShutdownTimer = nil
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

    func setDSStoreExclusion(_ enabled:Bool) {
        guard enabled != copy.ignoreDSStore,!previewOnly,!shuttingDown,!folderConfigurationBusy,!savingSchedule,
              !copy.active,!copy.maintaining,!copy.auditBusy,!copy.seedBusy else { return }
        let confirm=NSAlert()
        confirm.messageText=enabled ? "Ignorare i file .DS_Store?" : "Includere i file .DS_Store?"
        confirm.informativeText="Nessun file verrà eliminato. È necessaria una nuova verifica archivio prima di riprendere la sincronizzazione."
        confirm.addButton(withTitle:"Conferma"); confirm.addButton(withTitle:"Annulla")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        folderConfigurationBusy=true
        stopAllOperations()
        copy.maintaining=true
        copy.afterWorkerStopped { [weak self] in
            guard let self else { return }
            self.model.afterMonitorStopped { [weak self] in
                guard let self else { return }
                guard !self.shuttingDown else {
                    self.copy.maintaining=false; self.folderConfigurationBusy=false; self.finishShutdownIfReady(); return
                }
                self.copy.setDSStoreExclusionAfterDrain(enabled) { [weak self] success in
                    guard let self else { return }
                    self.folderConfigurationBusy=false
                    if !self.shuttingDown {
                        self.model.startMonitoring()
                        if success { self.suspendedUntilNextLaunch=false; self.automaticStatus="Attendo una nuova verifica archivio manuale" }
                        self.scheduleArchiveAudit()
                    }
                    self.finishShutdownIfReady()
                }
            }
        }
    }

    func resetPendingQueue() {
        guard !previewOnly,!shuttingDown,!folderConfigurationBusy,!savingSchedule,
              !copy.maintaining,!copy.auditBusy,!copy.seedBusy else { return }
        let confirm=NSAlert()
        confirm.messageText="Svuotare la coda di sincronizzazione?"
        confirm.informativeText="Verrà creato un backup verificato del database. Nessun file sul Mac o sul server verrà eliminato. Le copie e le cancellazioni rimarranno sospese fino a una nuova verifica archivio avviata manualmente."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle:"Svuota coda")
        confirm.addButton(withTitle:"Annulla")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        folderConfigurationBusy=true
        stopAllOperations()
        copy.maintaining=true
        copy.afterWorkerStopped { [weak self] in
            guard let self else { return }
            self.model.afterMonitorStopped { [weak self] in
                guard let self else { return }
                guard !self.shuttingDown else {
                    self.copy.maintaining=false
                    self.folderConfigurationBusy=false
                    self.finishShutdownIfReady()
                    return
                }
                self.copy.resetPendingQueueAfterDrain { [weak self] success in
                    guard let self else { return }
                    self.folderConfigurationBusy=false
                    if !self.shuttingDown {
                        self.model.startMonitoring()
                        if success {
                            self.suspendedUntilNextLaunch=false
                            self.automaticStatus="Attendo una nuova verifica archivio manuale"
                        }
                        self.scheduleArchiveAudit()
                    }
                    self.finishShutdownIfReady()
                }
            }
        }
    }

    /// Explicitly confirmed name maintenance. Stop workers and drain before
    /// any rename. Restore previously authorized automatic copies; no
    /// destination mutation or new mirror consent is performed here.
    func rectifyNames(_ items:[IncompatibleName]) {
        guard !previewOnly,!items.isEmpty,!shuttingDown,!folderConfigurationBusy,!savingSchedule,
              !copy.auditBusy,!copy.seedBusy,!copy.maintaining,!copy.rectifyingNames,!copy.namesBusy,
              !preparingSignedUpdate,!finalShutdownHolding else { return }
        let permitted=Set(copy.incompatibleNames.filter{ NameRectification.proposedName($0.name) != nil }.map(\.id))
        let approved=items.filter{permitted.contains($0.id) && $0.side == .source}
        guard !approved.isEmpty else { return }
        performNameRectification(approved)
    }

    func resumeNameRectification() {
        guard rectificationPending, !previewOnly, !shuttingDown, !folderConfigurationBusy,
              !savingSchedule, !copy.active, !copy.maintaining, !copy.auditBusy,
              !copy.namesBusy, !copy.seedBusy, !copy.rectifyingNames,
              !preparingSignedUpdate, !finalShutdownHolding else { return }
        let pending = copy.incompatibleNames.filter { $0.side == .source && $0.reason.hasPrefix("Rettifica in sospeso") }
        guard !pending.isEmpty else { return }
        performNameRectification(pending)
    }

    func cancelNameRectification() {
        guard preparingRectification || copy.rectifyingNames else { return }
        rectificationCancellationRequested = true
        folderEditCancellation?.cancel()
    }

    private func performNameRectification(_ approved: [IncompatibleName]) {
        rectificationRevision += 1
        let pairs = model.configuredPairs()
        // This does NOT authorize automatic copies for the first time.
        // Preserve only the earlier explicit choice through maintenance.
        let restoreAutomaticCopies = copy.automaticCopiesEnabled && !suspendedUntilNextLaunch
        folderConfigurationBusy=true
        preparingRectification=true
        rectificationCancellationRequested=false
        let token=SeedVerificationCancellation()
        folderEditCancellation=token
        stopAllOperations()
        copy.setAutomaticCopiesEnabled(false)
        copy.invalidateSeedReport()
        copy.afterWorkerStopped { [weak self] in
            guard let self else { return }
            self.model.afterMonitorStopped { [weak self] in
                guard let self else { return }
                self.preparingRectification=false
                if self.shuttingDown || token.isCancelled {
                    self.folderConfigurationBusy=false;self.folderEditCancellation=nil
                    self.rectificationCancellationRequested=false
                    self.finishShutdownIfReady();return
                }
                self.copy.rectifyNamesAfterDrain(items:approved,pairs:pairs,token:token) { [weak self] pending in
                    guard let self else { return }
                    self.folderConfigurationBusy=false;self.folderEditCancellation=nil
                    self.rectificationCancellationRequested=false
                    self.rectificationPending = pending
                    if !self.shuttingDown {
                        if self.copy.queueRebuildRequired {
                            self.automaticStatus = "Sincronizzazione sospesa: prepara una nuova verifica archivio manuale"
                            self.finishShutdownIfReady()
                            return
                        }
                        self.model.startMonitoring()
                        if restoreAutomaticCopies && !token.isCancelled {
                            self.suspendedUntilNextLaunch = false
                            self.copy.restorePreviouslyAuthorizedAutomaticCopies()
                            self.automaticStatus = pending ? "Rettifica pendente: copie indipendenti ripristinate, nomi incerti protetti" : "Rettifica conclusa: copie automatiche precedentemente autorizzate ripristinate"
                            self.scheduleNextAutomaticAttempt()
                        } else {
                            self.automaticStatus = pending ? "Rettifica pendente: percorsi protetti, copie indipendenti avviabili manualmente" : "Rettifica terminata: attendi l'inventario prima di riavviare le copie"
                        }
                        self.scheduleArchiveAudit()
                    }
                    self.finishShutdownIfReady()
                }
            }
        }
    }

    func startManualSynchronization() {
        guard !previewOnly, !shuttingDown, !savingSchedule, !folderConfigurationBusy, !finalShutdownHolding, !copy.queueRebuildRequired,
              model.monitoring, model.safetyGate.isReady, !copy.active, !copy.maintaining,
              !copy.seedBusy, !copy.seedReady, !copy.interruptionRequested else {
            guard !previewOnly else { return }
            copy.status = copy.queueRebuildRequired ? "Sincronizzazione non avviata: verifica archivio richiesta o coda non leggibile" : !model.monitoring || !model.safetyGate.isReady ? "Sincronizzazione non avviata: monitoraggio o inventario non pronto" : "Sincronizzazione non avviata: operazione già in corso o blocco di sicurezza"
            copy.recordBlockedStart(reason:copy.status)
            return
        }
        configurationRevision += 1
        autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
        copy.start(sources:model.configuredPairs(),schedule:settings.schedule)
        if !copy.active { scheduleNextAutomaticAttempt() }
    }

    func stopCopiesForCurrentLaunch() {
        if finalShutdownSlot != nil { resetFinalShutdown(message:"Spegnimento annullato: copie sospese",resume:false) }
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
        copy.cancelSeedVerification(); copy.cancelArchiveAudit(); copy.cancelMaintenance(); copy.cancelNameScan()
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
        if !enabled && finalShutdownSlot != nil { resetFinalShutdown(message:"Spegnimento annullato: automatismo disabilitato",resume:false) }
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
                    self.refreshFolderHealth()
                    self.finishShutdownIfReady()
                }
            }
        }
    }

    func onFolderConfigurationChanged() {
        if finalShutdownSlot != nil { resetFinalShutdown(message:"Spegnimento annullato: cartelle modificate",resume:false) }
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
        healthRevision += 1; sourceHealth=[:]; targetHealth=[:]; parentHealth = .checking; healthCheckedAt=nil
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

    // All power-off requests are ordinary macOS requests; never sudo or force quit.
    // The timer lives independently of the configuration window.
    func rescheduleFinalShutdown() {
        guard !previewOnly, !shuttingDown else { return }
        resetFinalShutdown(message:"",resume:true)
        finalShutdownTimer?.invalidate(); finalShutdownTimer = nil
        guard settings.finalShutdown.enabled else { return }
        if !copy.automaticCopiesEnabled { finalShutdownStatus = "Richiede la sincronizzazione automatica attiva" }
        let timer = Timer(timeInterval:5,repeats:true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFinalShutdown() }
        }
        RunLoop.main.add(timer,forMode:.common)
        finalShutdownTimer = timer
    }

    func cancelFinalShutdownToday() {
        guard canCancelFinalShutdown else { return }
        resetFinalShutdown(message:"Spegnimento annullato per oggi",resume:true)
    }

    private func resetFinalShutdown(message: String, resume: Bool) {
        let wasHolding = finalShutdownHolding || (finalShutdownForcedCycle && finalShutdownChecking)
        finalShutdownGeneration += 1
        finalShutdownSlot = nil; finalShutdownDeadline = nil
        finalShutdownHolding = false; finalShutdownChecking = false; finalShutdownForcedCycle = false; finalShutdownRequestSent = false
        nextFinalShutdownAt = settings.finalShutdown.next(after:Date())
        finalShutdownStatus = message
        if resume && wasHolding && !shuttingDown {
            scheduleNextAutomaticAttempt()
            scheduleArchiveAudit()
        }
    }

    private func tickFinalShutdown() {
        guard !previewOnly, !shuttingDown, !preparingSignedUpdate, !copy.queueRebuildRequired, settings.finalShutdown.enabled else { return }
        let now = Date()
        if finalShutdownSlot == nil {
            guard let next = nextFinalShutdownAt, next <= now else { return }
            // No catch-up request from a previous day after sleep or clock change.
            guard Calendar.current.isDate(next,inSameDayAs:now),
                  copy.automaticCopiesEnabled, !suspendedUntilNextLaunch else {
                resetFinalShutdown(message:"Spegnimento rinviato: automatismo non attivo o fascia trascorsa",resume:true)
                return
            }
            finalShutdownSlot = next; nextFinalShutdownAt = nil
            finalShutdownStatus = "Attendo la sincronizzazione finale"
        }
        guard let slot = finalShutdownSlot else { return }
        guard Calendar.current.isDate(slot,inSameDayAs:now),
              copy.automaticCopiesEnabled, !suspendedUntilNextLaunch else {
            resetFinalShutdown(message:"Spegnimento rinviato",resume:true); return
        }
        guard !finalShutdownChecking, !folderConfigurationBusy, !savingSchedule,
              model.monitoring, model.safetyGate.isReady, !copy.maintaining, !copy.auditBusy,
              !copy.seedBusy, !copy.seedReady, !copy.interruptionRequested, copy.liveProgress == nil else { return }
        if finalShutdownHolding {
            guard let deadline = finalShutdownDeadline, now >= deadline else { return }
            checkFinalShutdownQueue(slot:slot,finalCheck:true)
            return
        }
        if let cycle = copy.lastRecordedCycle,
           FinalShutdownPolicy.mayRequestShutdown(slot:slot,cycleStarted:cycle.started,
               cycleState:cycle.state,errors:copy.lastCycleStats.failed,
               deferred:copy.lastCycleStats.deferred,queueEmpty:true,monitorReady:true),
           copy.historyWarning.isEmpty {
            checkFinalShutdownQueue(slot:slot,finalCheck:false)
        } else if !finalShutdownForcedCycle {
            // Reuse the already authorized automatic path. Wait for a running
            // cycle; drain an idle session before arming the final one.
            finalShutdownForcedCycle = true; finalShutdownChecking = true
            let generation = finalShutdownGeneration
            configurationRevision += 1
            autoTimer?.invalidate(); autoTimer = nil; nextAutomaticAttempt = nil
            copy.stop()
            copy.afterWorkerStopped { [weak self] in
                guard let self, self.finalShutdownGeneration == generation, !self.shuttingDown else { return }
                self.finalShutdownChecking = false
                self.activateAutomaticSession(at:Date())
            }
        } else {
            finalShutdownStatus = "Attendo un ciclo completato senza errori"
        }
    }

    private func checkFinalShutdownQueue(slot: Date, finalCheck: Bool) {
        guard !finalShutdownChecking, let db = try? copy.historyPath() else { return }
        finalShutdownChecking = true
        let generation = finalShutdownGeneration
        let pairs = model.configuredPairs()
        let gate = model.safetyGate
        let token = gate.shutdownValidationToken()
        if finalCheck { finalShutdownStatus = "Controllo finale sorgenti, destinazioni e coda prima dello spegnimento" }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let empty: Bool = (try? { () throws -> Bool in
                guard let token, gate.shutdownValidationStillValid(token) else { return false }
                let journal = try ChangeJournal(path:db)
                if finalCheck {
                    guard !pairs.isEmpty else { return false }
                    let maps = try pairs.map { try MountedFolderMapping(rootID:$0.id,source:URL(fileURLWithPath:$0.path),target:URL(fileURLWithPath:$0.destination),expectedTargetVolume:$0.expected) }
                    try journal.verifyDirectoryBindings(maps)
                    for map in maps {
                        guard gate.shutdownValidationStillValid(token) else { return false }
                        let scan = try LocalScanner.scan(root:map.source,shouldContinue:{ gate.shutdownValidationStillValid(token) })
                        guard try journal.inventoryMatchesForShutdown(rootID:map.rootID,scanned:scan) else { return false }
                    }
                    try journal.verifyDirectoryBindings(maps)
                }
                return try journal.pending(limit:1).isEmpty && gate.shutdownValidationStillValid(token)
            }()) == true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.finalShutdownGeneration == generation, !self.shuttingDown else { return }
                self.finalShutdownChecking = false
                guard self.finalShutdownSlot == slot, self.copy.automaticCopiesEnabled,
                      !self.suspendedUntilNextLaunch, !self.folderConfigurationBusy, !self.savingSchedule,
                      self.model.monitoring, token.map({ gate.shutdownValidationStillValid($0) }) == true, !self.copy.maintaining,
                      !self.copy.interruptionRequested, self.copy.liveProgress == nil,
                      let cycle = self.copy.lastRecordedCycle,
                      self.copy.historyWarning.isEmpty,
                      FinalShutdownPolicy.mayRequestShutdown(slot:slot,cycleStarted:cycle.started,
                          cycleState:cycle.state,errors:self.copy.lastCycleStats.failed,
                          deferred:self.copy.lastCycleStats.deferred,queueEmpty:empty,monitorReady:true) else {
                    if finalCheck {
                        self.resetFinalShutdown(message:"Spegnimento annullato: sorgenti, destinazioni o coda non confermate",resume:true)
                        return
                    }
                    if self.finalShutdownHolding {
                        self.finalShutdownHolding = false; self.finalShutdownDeadline = nil
                        self.finalShutdownForcedCycle = false
                        self.scheduleNextAutomaticAttempt(); self.scheduleArchiveAudit()
                    }
                    self.finalShutdownStatus = "Spegnimento sospeso: coda o inventario non pronti"
                    return
                }
                if finalCheck {
                    self.sendFinalShutdownRequest()
                } else {
                    self.finalShutdownHolding = true; self.finalShutdownChecking = true
                    self.configurationRevision += 1
                    self.autoTimer?.invalidate(); self.autoTimer = nil; self.nextAutomaticAttempt = nil
                    self.auditRevision += 1
                    self.auditTimer?.invalidate(); self.auditTimer = nil; self.nextAuditAt = nil
                    self.copy.stop()
                    self.copy.afterWorkerStopped { [weak self] in
                        guard let self, self.finalShutdownGeneration == generation, !self.shuttingDown else { return }
                        self.finalShutdownChecking = false
                        self.finalShutdownDeadline = Date().addingTimeInterval(60)
                        self.finalShutdownStatus = "Spegnimento tra 60 secondi: annullabile in Panoramica, Pianificazione e menu"
                        let note = UNMutableNotificationContent()
                        note.title = "MacSync — Spegnimento programmato"
                        note.body = "Il ciclo finale è completato. Apri MacSync per annullare lo spegnimento entro 60 secondi."
                        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"MacSync.finalShutdown",content:note,trigger:nil),withCompletionHandler:nil)
                    }
                }
            }
        }
    }

    private func sendFinalShutdownRequest() {
        // The last source/target and queue checks and cooldown have completed. osascript asks
        // System Events to shut down normally, respecting other applications.
        // macOS may request Automation permission or reject the request.
        finalShutdownChecking = true
        finalShutdownRequestSent = true
        finalShutdownDeadline = nil
        finalShutdownStatus = "Invio richiesta di spegnimento a macOS"
        let generation = finalShutdownGeneration
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
            process.arguments = ["-e","with timeout of 20 seconds","-e","tell application \"System Events\" to shut down","-e","end timeout"]
            let errorPipe = Pipe(); process.standardError = errorPipe
            let message: String
            do {
                try process.run()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let detail = String(data:errorData,encoding:.utf8) ?? ""
                message = process.terminationStatus == 0 ? "Richiesta di spegnimento accettata da macOS" :
                    "Spegnimento non riuscito: " + String(detail.prefix(300))
            } catch { message = "Spegnimento non riuscito: " + error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.finalShutdownGeneration == generation, !self.shuttingDown else { return }
                self.resetFinalShutdown(message:message,resume:true)
            }
        }
    }

    private func scheduleNextAutomaticAttempt(afterSlot: Date? = nil) {
        autoTimer?.invalidate()
        autoTimer = nil
        nextAutomaticAttempt = nil
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy, !suspendedUntilNextLaunch, !finalShutdownHolding,
              copy.automaticCopiesEnabled, !copy.queueRebuildRequired,
              !copy.active, !copy.maintaining, !copy.auditBusy, !copy.interruptionRequested, copy.liveProgress == nil else { return }
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
        guard !shuttingDown, !savingSchedule, !folderConfigurationBusy, !suspendedUntilNextLaunch, !finalShutdownHolding,
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
