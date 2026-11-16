import AppKit
import SwiftUI
import MacSyncCore

/// Deliberately TEST-only: foreground opt-in for the current app session.
/// macOS Finder must mount SMB shares and supply its saved credentials.
@MainActor
final class MountedCopyController: ObservableObject {
    @Published var status = "Copie ferme: puoi selezionare cartelle locali o SMB già montate."
    @Published var active = false
    @Published private(set) var nextScheduledRun: Date?
    var onConnectionCheck: (([String: DestinationAvailability], Date) -> Void)?
    @Published var automaticCopiesEnabled = UserDefaults.standard.bool(forKey: "MacSync.autoCopiesEnabled") {
        didSet {
            UserDefaults.standard.set(automaticCopiesEnabled, forKey: "MacSync.autoCopiesEnabled")
        }
    }
    @Published private(set) var automaticSession = false

    // A legacy Boolean is deliberately NOT a persisted deletion consent.
    private static let authorizationKey = "MacSync.mirrorAuthorization.v1"
    private static func loadAuthorization() -> MirrorAuthorization? {
        guard let data = UserDefaults.standard.data(forKey: authorizationKey) else { return nil }
        return try? JSONDecoder().decode(MirrorAuthorization.self, from: data)
    }
    private var mirrorAuthorization = MountedCopyController.loadAuthorization()
    private var mirrorConfigurationRevision = 0
    @Published private(set) var mirrorEnabled = MountedCopyController.loadAuthorization() != nil
    @Published var mirrorProtections: MirrorProtectionSettings = {
        guard let data = UserDefaults.standard.data(forKey: "MacSync.mirrorProtections.v1") else {
            return MirrorProtectionSettings()
        }
        guard let settings = try? JSONDecoder().decode(MirrorProtectionSettings.self, from: data),
              settings.isValid else {
            // A damaged settings record must not silently remove protection.
            var invalid = MirrorProtectionSettings()
            invalid.absoluteEnabled = true
            invalid.absoluteLimit = 0
            return invalid
        }
        return settings
    }() {
        didSet {
            if mirrorProtections.isValid, let data = try? JSONEncoder().encode(mirrorProtections) {
                UserDefaults.standard.set(data, forKey: "MacSync.mirrorProtections.v1")
            }
        }
    }
    @Published var mirrorRecovery = (UserDefaults.standard.object(forKey: "MacSync.mirrorRecovery") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(mirrorRecovery, forKey: "MacSync.mirrorRecovery") }
    }
    /// 0 = never delete recovery files automatically; 1...30 = days.
    @Published var mirrorRetention = UserDefaults.standard.object(forKey: "MacSync.mirrorRetention") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(mirrorRetention, forKey: "MacSync.mirrorRetention") }
    }
    @Published var mirrorStatus = "Cancellazioni speculari non attive"
    @Published var lastCycleStats = SyncDashboardStats()
    @Published private(set) var liveProgress: SyncLiveProgress?
    @Published private(set) var lastRecordedCycle: SyncCycleRecord?
    @Published private(set) var historyWarning = ""
    private(set) var historySessionID = UUID().uuidString

    func historyPath() throws -> String { try Self.databaseURL().path }
    func loadLastCycle() {
        guard !active, liveProgress == nil, lastRecordedCycle == nil else { return }
        guard let path = try? historyPath(), FileManager.default.fileExists(atPath:path) else { return }
        let session = historySessionID
        DispatchQueue.global(qos:.utility).async { [weak self] in
            do {
                let history = try SyncCycleHistory(path:path)
                try history.markInterrupted(exceptSession:session)
                let cycle = try history.cycles(limit:1).first
                let stats = try cycle.map { try history.totals(cycleID:$0.id).stats } ?? SyncDashboardStats()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.historySessionID==session, !self.active else { return }
                    self.lastRecordedCycle = cycle
                    self.lastCycleStats = stats
                    self.lastCycleAt = cycle?.ended
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.historyWarning = "Storico non disponibile: " + error.localizedDescription }
            }
        }
    }
    @Published var sessionStats = SyncDashboardStats()
    @Published var lastCycleAt: Date?
    @Published var completedCycles = 0
    @Published var previewStatus = "Anteprima iniziale non eseguita"
    @Published var recentEntries: [SyncLogEntry] = []
    @Published var logLevel = "all"
    @Published var logSearch = ""
    @Published var maintenanceStatus = "Temporanei: verifica non eseguita"
    @Published var maintaining = false
    @Published var seedStatus = "Allineamento iniziale SHA-256 non eseguito"
    @Published var seedBusy = false
    @Published var seedReady = false
    @Published var seedVerifiedCount = 0
    @Published var seedInspectedCount = 0
    @Published var seedReadBytes: Int64 = 0
    @Published var seedTotalJobs = 0
    @Published var seedStartedAt: Date?
    @Published var seedCurrentPath = ""
    @Published var auditSettings: ArchiveAuditSettings = {
        guard let data = UserDefaults.standard.data(forKey:"MacSync.archiveAuditSettings"),
              let value = try? JSONDecoder().decode(ArchiveAuditSettings.self,from:data),
              value.next(after:Date()) != nil else { return ArchiveAuditSettings() }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(auditSettings) {
                UserDefaults.standard.set(data,forKey:"MacSync.archiveAuditSettings")
            }
        }
    }
    @Published private(set) var auditBusy = false
    @Published private(set) var auditProgress: ArchiveAuditProgress?
    @Published private(set) var auditReport: ArchiveAuditReport?
    @Published private(set) var auditStatus = "Verifica completa non eseguita"
    private var auditCancel: SeedVerificationCancellation?

    func loadLastAudit() {
        guard auditReport == nil, !auditBusy else { return }
        if let url = try? Self.databaseURL().deletingLastPathComponent().appendingPathComponent("last-audit.json"),
           let bytes = try? Data(contentsOf:url),
           let report = try? JSONDecoder().decode(ArchiveAuditReport.self,from:bytes) {
            auditReport = report
            auditStatus = "Ultima verifica: " + report.ended.formatted(date:.abbreviated,time:.standard)
        }
    }

    /// Both scheduled audit and ordinary copy use the SAME serial queue.
    /// A request during an active cycle waits for that cycle to finish.
    func startArchiveAudit(sources: [(id:String,path:String,destination:String,expected:VolumeFingerprint?)],
                           interactive: Bool) {
        guard !auditBusy && !maintaining && !seedBusy else {
            if !interactive { noteAuditSkipped("altra verifica o manutenzione in corso") }
            return
        }
        let settings = auditSettings
        let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
        guard !configured.isEmpty,
              configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty && $0.expected?.isStrongIdentity == true })
        else { auditStatus = "Configura prima le coppie e i volumi"; return }
        if interactive {
            let alert = NSAlert()
            alert.messageText = "Avviare verifica completa?"
            alert.informativeText = (settings.mode == .deep
                ? "La verifica SHA-256 legge integralmente i file confrontabili, anche via VPN. "
                : "La verifica rapida enumera entrambe le cartelle e confronta i metadati. ")
                + (settings.repair ? "Le differenze sicure verranno accodate come copie/aggiornamenti." : "Modalità solo diagnostica.")
                + " Nessun file presente soltanto sul server verrà cancellato."
            alert.addButton(withTitle:"Avvia verifica"); alert.addButton(withTitle:"Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let db: URL
        do { db = try Self.databaseURL() }
        catch { auditStatus = error.localizedDescription; return }
        let cancel = SeedVerificationCancellation()
        auditCancel = cancel
        auditBusy = true
        maintaining = true
        invalidateSeedReport()
        auditStatus = "Verifica in attesa della coda di lavoro"
        queue.async { [weak self] in
            do {
                if cancel.isCancelled { throw SeedVerificationError.cancelled }
                let journal = try ChangeJournal(path:db.path)
                let maps = try configured.map {
                    try MountedFolderMapping(rootID:$0.id,source:URL(fileURLWithPath:$0.path),
                        target:URL(fileURLWithPath:$0.destination),expectedTargetVolume:$0.expected)
                }
                let report = try ArchiveAudit(journal:journal,mappings:maps).run(mode:settings.mode,repair:settings.repair,
                    cancellation:cancel,progress:{ snapshot in
                        DispatchQueue.main.async { [weak self] in
                            self?.auditProgress = snapshot
                            self?.auditStatus = snapshot.phase
                        }
                    })
                var storageWarning = ""
                do {
                    let data = try JSONEncoder().encode(report)
                    try data.write(to:db.deletingLastPathComponent().appendingPathComponent("last-audit.json"),options:.atomic)
                } catch { storageWarning = " — impossibile salvare lo storico della verifica" }
                let warning = storageWarning
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.auditReport = report
                    self.auditStatus = "Verifica conclusa: " + String(report.queuedRepairs) + " riparazioni accodate" + warning
                    self.auditProgress = nil
                    self.auditBusy = false
                    self.maintaining = false
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.auditStatus = cancel.isCancelled ? "Verifica annullata" : "Verifica non riuscita: " + error.localizedDescription
                    self?.auditProgress = nil
                    self?.auditBusy = false
                    self?.maintaining = false
                }
            }
        }
    }

    func noteAuditSkipped(_ reason:String) {
        if !auditBusy { auditStatus = "Verifica programmata rinviata: " + reason }
    }

    func cancelArchiveAudit() {
        auditCancel?.cancel()
        auditStatus = "Annullamento richiesto"
    }
    private var seedReport: SeedVerificationReport?
    private var seedVerifier: SeededArchiveVerifier?
    private var seedCancel: SeedVerificationCancellation?
    private var maintenanceCandidates: [(mapping: MountedFolderMapping, inspection: StagingInspection)] = []

    private let queue = DispatchQueue(label: "macsync.mounted.copy.serial", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mirrorCancellation: MirrorDeletionCancellation?
    private var sessionCancellation: MirrorDeletionCancellation?

    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MacSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("inventory.sqlite")
    }

    /// Explicit setting action only; verification runs on the existing serial
    /// worker queue and never opens an additional recurring SMB probe.
    func setMirrorEnabled(_ enabled: Bool, sources: [(id: String, path: String, destination: String, expected: VolumeFingerprint?)]) {
        guard !active && !maintaining && !seedBusy else { return }
        if !enabled {
            revokeMirrorAuthorization()
            return
        }
        guard !mirrorEnabled else { return }
        let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
        guard !configured.isEmpty, configured.allSatisfy({
            !$0.path.isEmpty && !$0.destination.isEmpty && $0.expected?.isStrongIdentity == true
        }) else {
            mirrorStatus = "Configura prima sorgenti e destinazioni e verifica i volumi."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Abilitare le cancellazioni speculari?"
        alert.informativeText = """
        MacSync potrà rimuovere dalla destinazione i file eliminati dalla sorgente, anche dopo un riavvio quando la sincronizzazione automatica è attiva. Se il recupero è disabilitato, la rimozione sarà definitiva.

        L'autorizzazione vale solo per le coppie verificate e per nuovi eventi dopo la verifica. Le protezioni tecniche restano sempre attive; le protezioni quantitative sono facoltative. Usa esclusivamente dati di prova.
        """
        alert.addButton(withTitle: "Abilita cancellazioni speculari")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let database: URL
        do { database = try Self.databaseURL() }
        catch { mirrorStatus = error.localizedDescription; return }
        let revision = mirrorConfigurationRevision
        maintaining = true
        mirrorStatus = "Verifica delle cartelle per l'autorizzazione persistente..."
        queue.async { [weak self] in
            do {
                let journal = try ChangeJournal(path: database.path)
                let maps = try configured.map {
                    try MountedFolderMapping(rootID: $0.id,
                        source: URL(fileURLWithPath: $0.path),
                        target: URL(fileURLWithPath: $0.destination), expectedTargetVolume: $0.expected)
                }
                let authorization = try MirrorAuthorization.capture(journal: journal, mappings: maps)
                let data = try JSONEncoder().encode(authorization)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.maintaining = false
                    guard self.mirrorConfigurationRevision == revision else { return }
                    UserDefaults.standard.set(data, forKey: Self.authorizationKey)
                    self.mirrorAuthorization = authorization
                    self.mirrorEnabled = true
                    self.mirrorStatus = "Cancellazioni autorizzate per le cartelle verificate; scelta persistente."
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.maintaining = false
                    guard self.mirrorConfigurationRevision == revision else { return }
                    self.mirrorStatus = "Autorizzazione non acquisita: " + error.localizedDescription
                }
            }
        }
    }

    func revokeMirrorAuthorization() {
        mirrorConfigurationRevision += 1
        UserDefaults.standard.removeObject(forKey: Self.authorizationKey)
        UserDefaults.standard.removeObject(forKey: "MacSync.mirrorEnabled")
        mirrorAuthorization = nil
        mirrorEnabled = false
        mirrorStatus = "Cancellazioni speculari disattivate"
    }

    func clearMirrorSafetyBlock() {
        guard !active && !maintaining && !seedBusy else { return }
        do {
            let journal = try ChangeJournal(path: Self.databaseURL().path)
            guard let reason = try journal.mirrorBlockReason() else {
                mirrorStatus = "Nessun blocco persistente da rimuovere"
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Rimuovere il blocco di sicurezza?"
            alert.informativeText = reason + "\n\nControlla le sorgenti e gli eventi pendenti. Se le soglie sono ancora superate, MacSync si bloccherà di nuovo al prossimo ciclo. Nessun file viene eliminato da questo pulsante."
            alert.addButton(withTitle: "Ho verificato — rimuovi blocco")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try journal.clearMirrorBlock()
            mirrorStatus = "Blocco rimosso; tutti i controlli saranno ripetuti prima del prossimo ciclo"
        } catch { mirrorStatus = "Impossibile rimuovere il blocco: " + error.localizedDescription }
    }

    func start(
        sources: [(id: String, path: String, destination: String, expected: VolumeFingerprint?)],
        schedule: SyncSchedule
    ) {
        guard !maintaining && !seedBusy else {
            status = "Una verifica/manutenzione è in corso. Le copie restano ferme."
            return
        }
        invalidateSeedReport()
        stop()

        let policy: MirrorDeletionPolicy
        do {
            policy = try MirrorDeletionPolicy(
                enabled: mirrorEnabled, recoveryEnabled: mirrorRecovery,
                retentionDays: mirrorRetention == 0 ? nil : mirrorRetention
            )
        } catch {
            status = "Impostazioni cancellazione non valide: " + error.localizedDescription
            return
        }

        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Avviare la sincronizzazione di prova?"
        let deleteWarning: String
        if !policy.enabled {
            deleteWarning = "La cancellazione speculare è DISABILITATA."
        } else if policy.recoveryEnabled {
            deleteWarning = "I file eliminati saranno SPOSTATI in .macsync-recovery. "
                + (policy.retentionDays.map { "Verranno rimossi automaticamente dopo \($0) giorni." }
                    ?? "Non verranno eliminati automaticamente.")
        } else {
            deleteWarning = "ATTENZIONE: le cancellazioni saranno DEFINITIVE, SENZA RECUPERO MacSync."
        }
        warning.informativeText = """
        MacSync può creare e SOVRASCRIVERE file nella cartella di destinazione.
        Seleziona ESCLUSIVAMENTE cartelle con DATI DI PROVA.

        \(deleteWarning)

        Le cancellazioni anteriori all'autorizzazione persistente non saranno eseguite.
        Le protezioni tecniche restano obbligatorie; i limiti quantitativi sono facoltativi.
        Avviare questa sessione non modifica l'autorizzazione alle cancellazioni.
        """
        warning.addButton(withTitle: "Avvia sincronizzazione di prova")
        warning.addButton(withTitle: "Annulla")
        guard warning.runModal() == .alertFirstButtonReturn else {
            status = "Copie non attivate"
            return
        }
        beginSession(sources: sources, policy: policy, automatic: false,
                     schedule: schedule)
    }

    /// Explicit persistent opt-in for scheduled automatic synchronization.
    /// Mirror work requires the independently saved settings authorization.
    func setAutomaticCopiesEnabled(_ enabled: Bool) {
        if enabled {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Abilitare le copie automatiche dopo il login?"
            alert.informativeText = """
            Se abilitate, MacSync potrà CREARE e SOVRASCRIVERE file
            automaticamente nella destinazione già configurata, senza
            nuove conferme a ogni login. Le cancellazioni speculari saranno
            eseguite soltanto se già autorizzate nelle relative impostazioni.

            FUNZIONE SPERIMENTALE: usa esclusivamente cartelle con
            dati di prova, non l'archivio di produzione originale.
            """
            alert.addButton(withTitle: "Abilita copie automatiche di prova")
            alert.addButton(withTitle: "Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        automaticCopiesEnabled = enabled
        if !enabled && automaticSession { stop() }
    }

    /// Called solely by the app-level coordinator after explicit opt-in.
    /// Mirror work is allowed only with a validated persisted authorization.
    func startAutomaticSafeCopies(
        sources: [(id: String, path: String, destination: String, expected: VolumeFingerprint?)],
        schedule: SyncSchedule,
        firstSlot: Date
    ) {
        guard automaticCopiesEnabled, !active, !maintaining, !seedBusy else { return }
        let policy: MirrorDeletionPolicy
        do {
            policy = try MirrorDeletionPolicy(
                enabled: mirrorEnabled, recoveryEnabled: mirrorRecovery,
                retentionDays: mirrorRetention == 0 ? nil : mirrorRetention
            )
        } catch {
            status = "Copie automatiche sospese: politica non valida"
            return
        }
        beginSession(sources: sources, policy: policy, automatic: true,
                     schedule: schedule, firstSlot: firstSlot)
    }

    private func beginSession(
        sources: [(id: String, path: String, destination: String, expected: VolumeFingerprint?)],
        policy: MirrorDeletionPolicy,
        automatic: Bool,
        schedule: SyncSchedule,
        firstSlot: Date? = nil
    ) {
        guard !active && !seedBusy && !maintaining, schedule.isValid else { return }
        let authorization = mirrorAuthorization
        let protections = mirrorProtections
        guard protections.isValid, !policy.enabled || authorization != nil else {
            status = "Impostazioni protezione o autorizzazione non valide"
            return
        }
        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({
                      !$0.path.isEmpty && !$0.destination.isEmpty &&
                      $0.expected != nil
                  }) else {
                throw MountedCopyError.invalidMapping
            }
            // No remote filesystem access while arming a session.
            // The original destination fingerprint is mandatory, even
            // when the share is currently offline.
            guard Set(configured.map { $0.id }).count == configured.count,
                  configured.allSatisfy({ $0.expected?.isStrongIdentity == true })
            else { throw MountedCopyError.volumeChanged }
            let database = try Self.databaseURL()
            guard FileManager.default.fileExists(atPath: database.path) else {
                throw JournalError.database("Avvia prima il monitoraggio delle sorgenti")
            }
            let journal = try ChangeJournal(path: database.path)
            let log = try SyncActivityLog(path: database.path)
            let sessionID = UUID().uuidString
            historySessionID = sessionID
            // These workers are initialized only at the first healthy
            // scheduled slot, on the serial utility queue.
            var maps: [MountedFolderMapping] = []
            var worker: MountedFolderCopyWorker?
            // Initial source audit can be expensive on a large archive.
            // Create the armed deletion worker on the serial background queue.
            let cancellation = MirrorDeletionCancellation()
            sessionCancellation = cancellation
            mirrorCancellation = policy.enabled ? cancellation : nil
            var mirrorWorker: MirrorDeletionWorker?
            try log.record(
                level: .info, rootID: "app", action: "session",
                message: "Sessione di copie di prova abilitata"
            )
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // Each synchronization has one connection check immediately
            // before its transfers. No independent 30-second SMB probes.
            // A scheduled clock time is honored even for the first run.
            guard let firstRun = firstSlot ?? schedule.next(after: Date()) else {
                throw MountedCopyError.invalidMapping
            }
            var scheduledSlot = firstRun
            timer.schedule(
                wallDeadline: .now() + max(0, firstRun.timeIntervalSinceNow),
                leeway: .milliseconds(250)
            )
            timer.setEventHandler { [weak self] in
                guard !cancellation.isCancelled else { return }
                let cycleID = UUID().uuidString
                let startedAt = Date()
                let startUptime = ProcessInfo.processInfo.systemUptime
                var progress = SyncLiveProgress(started: startedAt)
                progress.phase = "Controllo connessione"
                var totals = SyncHistoryTotals()
                var historyError = ""
                var history: SyncCycleHistory?
                var outcomeState = "suspended"
                var lastUpdate: TimeInterval = 0
                do {
                    let store = try SyncCycleHistory(path:database.path)
                    try store.markInterrupted(exceptSession:sessionID)
                    try store.begin(id:cycleID,sessionID:sessionID,at:startedAt)
                    history = store
                } catch { historyError = "Storico non disponibile: " + error.localizedDescription }
                func publish(force: Bool = false) {
                    let now = ProcessInfo.processInfo.systemUptime
                    guard force || now-lastUpdate >= 0.2 else { return }
                    lastUpdate = now
                    let snapshot = progress
                    DispatchQueue.main.async { [weak self] in
                        guard !cancellation.isCancelled else { return }
                        self?.liveProgress = snapshot
                    }
                }
                func observe(_ event: SyncCycleEvent) {
                    totals.add(event)
                    progress.observe(event)
                    do { try history?.append(cycleID:cycleID,event:event) }
                    catch { historyError = "Storico incompleto: " + error.localizedDescription }
                    publish()
                }
                func jobStarted(_ job: QueuedChange) {
                    progress.currentFile = job.rootID + " / " + job.relativePath
                    publish()
                }
                publish(force:true)
                defer {
                    worker?.onEvent = nil
                    worker?.onJobStarted = nil
                    worker?.onPhase = nil
                    mirrorWorker?.onEvent = nil
                    mirrorWorker?.onJobStarted = nil
                    if cancellation.isCancelled { outcomeState = "interrupted" }
                    if !historyError.isEmpty { outcomeState += "_history_incomplete" }
                    let endedAt = Date()
                    do {
                        try history?.finish(id:cycleID,at:endedAt,seconds:ProcessInfo.processInfo.systemUptime-startUptime,state:outcomeState)
                        try history?.prune(before:endedAt.addingTimeInterval(-365*86400))
                    } catch { historyError = "Storico incompleto: " + error.localizedDescription }
                    let saved = try? history?.cycles(limit:1).first
                    let finalStats = totals.stats
                    let warning = historyError
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.historySessionID == sessionID else { return }
                        self.liveProgress = nil
                        self.historyWarning = warning
                        self.lastRecordedCycle = saved ?? nil
                        self.lastCycleStats = finalStats
                        self.sessionStats.accumulate(finalStats)
                        self.completedCycles += 1
                        self.lastCycleAt = endedAt
                        self.refresh()
                    }
                    // Keep the cadence anchored to its scheduled slot.
                    // If a long copy crosses a slot, skip that slot.
                    if !cancellation.isCancelled,
                       let next = schedule.nextSlot(
                           after: scheduledSlot, completedAt: Date()
                       ) {
                        scheduledSlot = next
                        timer.schedule(
                            wallDeadline: .now() + max(0, next.timeIntervalSinceNow),
                            leeway: .milliseconds(250)
                        )
                        DispatchQueue.main.async { [weak self] in
                            if !cancellation.isCancelled, self?.active == true {
                                self?.nextScheduledRun = next
                            }
                        }
                    }
                }
                let states = Dictionary(uniqueKeysWithValues: configured.map {
                    ($0.id, DestinationProbe.inspect(
                        path: $0.destination, expectedVolume: $0.expected
                    ))
                })
                let checkedAt = Date()
                guard !cancellation.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard !cancellation.isCancelled else { return }
                    self?.onConnectionCheck?(states, checkedAt)
                }
                guard states.values.allSatisfy({ $0.isReady }) else {
                    try? log.record(
                        level: .warning, rootID: "app", action: "connection_wait",
                        message: "Destinazione non disponibile al controllo pianificato"
                    )
                    DispatchQueue.main.async { [weak self] in
                        if !cancellation.isCancelled, self?.active == true {
                            self?.status = "Destinazione non disponibile: sincronizzazione sospesa; file in coda mantenuti"
                        }
                    }
                    return
                }
                do {
                    guard !cancellation.isCancelled else { return }
                    progress.phase = "Analisi dei file"
                    publish(force:true)
                    // A persistent safety latch blocks the ENTIRE cycle,
                    // even when mirror has subsequently been disabled.
                    if let reason = try journal.mirrorBlockReason() {
                        throw MirrorDeletionFailure.bulkDeletion(reason)
                    }
                    if worker == nil {
                        maps = try configured.map {
                            try MountedFolderMapping(
                                rootID: $0.id,
                                source: URL(fileURLWithPath: $0.path),
                                target: URL(fileURLWithPath: $0.destination),
                                expectedTargetVolume: $0.expected
                            )
                        }
                        worker = try MountedFolderCopyWorker(
                            journal: journal, log: log, mappings: maps
                        )
                    }
                    // Do not process a queue belonging to a different source.
                    for mapping in maps {
                        guard try journal.watchedRootPath(rootID: mapping.rootID)
                            == mapping.source.path else {
                            throw MountedCopyError.invalidMapping
                        }
                    }
                    guard let worker, !cancellation.isCancelled else { return }
                    if policy.enabled && mirrorWorker == nil {
                        mirrorWorker = try MirrorDeletionWorker(
                            journal: journal,
                            manifest: RecoveryManifest(path: database.path),
                            log: log, mappings: maps, policy: policy,
                            cancellation: cancellation, authorization: authorization,
                            protections: protections
                        )
                        try? log.record(
                            level: .info, rootID: "app", action: "mirror_armed",
                            message: policy.recoveryEnabled
                                ? "Mirror di prova attivato con recupero" : "Mirror di prova attivato senza recupero"
                        )
                    }
                    try mirrorWorker?.verifyBeforeSynchronization()
                    let highWater = try journal.queueSequence()
                    progress.planned = try journal.plannedUploadCount(throughID:highWater)
                    progress.planned += try mirrorWorker?.plannedCount(throughID:highWater) ?? 0
                    worker.onEvent = observe
                    worker.onJobStarted = jobStarted
                    worker.onPhase = { phase in
                        progress.phase = phase
                        publish(force:phase == "Trasferimento" || phase == "Backup di sicurezza")
                    }
                    mirrorWorker?.onEvent = observe
                    mirrorWorker?.onJobStarted = jobStarted
                    progress.phase = "Trasferimento"
                    publish(force:true)
                    let summary = try worker.runCycle(
                        enabled: true, pageSize: 100, throughID: highWater,
                        shouldContinue: { !cancellation.isCancelled },
                        onProgress: { progress in
                            DispatchQueue.main.async { [weak self] in
                                guard !cancellation.isCancelled else { return }
                                self?.status = "Sincronizzazione in corso: "
                                    + "\(progress.copied) completati, "
                                    + "\(progress.deferred) rimandati, \(progress.failed) errori"
                            }
                        }
                    )
                    var mirrorSummary = MirrorDeletionSummary()
                    var expired = 0
                    if let mirrorWorker, !cancellation.isCancelled, !summary.interrupted {
                        // Repeat the protection check even if uploads remain.
                        try mirrorWorker.verifyBeforeSynchronization()
                        // A rename is currently represented as upload + delete.
                        // Never remove the old server file before pending
                        // uploads have been completed, including after failure.
                        if try journal.pendingUploads(limit: 1).isEmpty {
                            progress.phase = "Cancellazioni"
                            publish(force:true)
                            mirrorSummary = try mirrorWorker.runCycle(pageSize: 100, throughID:highWater)
                            progress.phase = "Finalizzazione"
                            publish(force:true)
                            expired = try mirrorWorker.pruneExpiredRecovery()
                        } else {
                            mirrorSummary.blocked = true
                            mirrorSummary.detail = "Cancellazioni sospese: copie o aggiornamenti ancora in coda"
                        }
                    }
                    progress.phase = "Finalizzazione"
                    progress.currentFile = ""
                    publish(force:true)
                    totals.stats.deletionsBlocked = mirrorSummary.blocked
                    outcomeState = summary.interrupted ? "interrupted" :
                        (mirrorSummary.blocked ? "suspended" :
                         ((summary.failed + summary.deferred + mirrorSummary.deferred > 0) ? "partial" : "completed"))
                    let mirrorDetails = !policy.enabled ? "" :
                        " Specchio: \(mirrorSummary.removed) eliminati, "
                        + "\(mirrorSummary.recovered) recuperabili, "
                        + "\(mirrorSummary.directories) cartelle vuote, "
                        + "\(mirrorSummary.deferred) rimandati, "
                        + "\(expired) recuperi scaduti."
                        + (mirrorSummary.blocked ? " BLOCCATO: \(mirrorSummary.detail)." : "")
                    try log.record(
                        level: summary.failed > 0 ? .warning : .info,
                        rootID: "app", action: "cycle",
                        bytes: summary.bytes,
                        durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
                        message: "Ciclo completato: \(summary.copied) copie, \(summary.deferred) rimandate, \(summary.failed) errori." + mirrorDetails
                    )
                    // Only the SQLite activity table is pruned, never file
                    // inventory, queue, photographs, backups or staging.
                    try? log.prune(retainNewest: 20_000, maxAgeDays: 90)
                    let result = (summary.interrupted
                        ? "Ciclo interrotto: " : "Ultimo ciclo: ") + "\(summary.copied) copie, "
                        + "\(summary.deferred) rimandate, \(summary.failed) errori, "
                        + "\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) trasferiti."
                    DispatchQueue.main.async { [weak self] in
                        guard !cancellation.isCancelled else { return }
                        self?.status = result
                        self?.mirrorStatus = policy.enabled ? mirrorDetails : "Cancellazioni speculari disattivate"
                        // History and totals are finalized even for interrupted cycles.
                    }
                } catch {
                    outcomeState = "suspended"
                    totals.stats.deletionsBlocked = policy.enabled
                    try? log.record(
                        level: .error, rootID: "app", action: "cycle",
                        message: "Errore generale durante il ciclo di copia"
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard !cancellation.isCancelled else { return }
                        self?.status = "Sincronizzazione sospesa: " + error.localizedDescription
                        self?.mirrorStatus = error.localizedDescription
                        // The durable history keeps already completed operations.
                    }
                }
            }
            self.timer = timer
            nextScheduledRun = firstRun
            lastCycleStats = SyncDashboardStats()
            lastRecordedCycle = nil
            liveProgress = nil
            sessionStats = SyncDashboardStats()
            lastCycleAt = nil
            completedCycles = 0
            active = true
            automaticSession = automatic
            mirrorStatus = policy.enabled
                ? "Configurazione armata: la verifica delle sorgenti avverrà al primo ciclo"
                : "Cancellazioni speculari disattivate"
            status = automatic
                ? (policy.enabled ? "Sincronizzazione automatica di prova pianificata con mirror autorizzato" : "Copie automatiche di prova pianificate (solo aggiunte e aggiornamenti)")
                : "Copie di prova pianificate; " + schedule.summary
            refresh()
            timer.resume()
        } catch {
            active = false
            status = "Impossibile avviare: " + error.localizedDescription
        }
    }

    /// Opens only existing MacSync-managed recovery folders. These are dot
    /// folders and are otherwise hidden in Finder. No files are moved.
    func revealRecoveryFolders(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        var opened = 0
        for pair in sources where !pair.destination.isEmpty {
            let base = URL(fileURLWithPath: pair.destination)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard let expected = pair.expected,
                  let actual = try? VolumeFingerprint.read(at: base),
                  actual == expected,
                  FileManager.default.fileExists(atPath: base.path) else { continue }
            let folder = base.appendingPathComponent(".macsync-recovery", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: folder.path, isDirectory: &isDirectory
            ), isDirectory.boolValue else { continue }
            NSWorkspace.shared.open(folder)
            opened += 1
        }
        mirrorStatus = opened > 0
            ? "Cartelle recupero aperte nel Finder: \(opened)"
            : "Nessuna cartella recupero disponibile; verifica destinazioni e volumi"
    }

    /// No transfers and no deletions. SHA-256 is streamed from both source
    /// and target, including through SMB. A size/time match alone NEVER
    /// clears the queue. Verifier and journal stay on a serial worker queue.
    func verifySeededFiles(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        guard !active && !maintaining && !seedBusy else {
            seedStatus = "Ferma le copie e la manutenzione prima dell'allineamento"
            return
        }
        let warning = NSAlert()
        warning.alertStyle = .informational
        warning.messageText = "Verificare i file già copiati con SHA-256?"
        warning.informativeText = """
        MacSync confronterà il contenuto dei file già presenti in Sorgente e
        Destinazione e leggerà integralmente entrambi i file. Per esempio, per 100 GB
        potrebbe leggere circa 200 GB complessivi, di cui fino a 100 GB
        attraverso la VPN. NON trasferirà o cancellerà alcun file.
        Soltanto una conferma successiva potrà allineare la coda SQLite.
        """
        warning.addButton(withTitle: "Avvia verifica in sola lettura")
        warning.addButton(withTitle: "Annulla")
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty }) else {
                throw MountedCopyError.invalidMapping
            }
            let mappings = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id, source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
            let database = try Self.databaseURL()
            guard FileManager.default.fileExists(atPath: database.path) else {
                throw JournalError.database("Avvia prima il monitoraggio locale")
            }
            let journal = try ChangeJournal(path: database.path)
            let verifier = try SeededArchiveVerifier(journal: journal, mappings: mappings)
            let cancellation = SeedVerificationCancellation()
            seedReport = nil
            seedVerifier = nil
            seedCancel = cancellation
            seedReady = false
            seedBusy = true
            seedVerifiedCount = 0
            seedInspectedCount = 0
            seedReadBytes = 0
            seedTotalJobs = try journal.plannedUploadCount()
            seedStartedAt = Date()
            seedCurrentPath = ""
            seedStatus = "Analisi SHA-256 in corso (lettura locale e SMB)…"

            queue.async { [weak self] in
                do {
                    let report = try verifier.verify(
                        cancellation: cancellation,
                        progress: { p in
                            DispatchQueue.main.async { [weak self] in
                                self?.seedInspectedCount = p.inspected
                                self?.seedVerifiedCount = p.verified
                                self?.seedReadBytes = p.bytesRead
                                self?.seedTotalJobs = p.planned
                                self?.seedCurrentPath = p.currentPath
                                self?.seedStatus = "Verificati \(p.inspected) job, "
                                    + "\(p.verified) file identici, "
                                    + "\(p.missingOrDifferent) diversi, \(p.deferred) da rivedere"
                            }
                        }
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.seedBusy = false
                        if cancellation.isCancelled {
                            self.seedStatus = "Verifica annullata: nessuna modifica alla coda"
                            return
                        }
                        self.seedReport = report
                        self.seedVerifier = verifier
                        self.seedReady = !report.matches.isEmpty
                        self.seedVerifiedCount = report.verifiedCount
                        self.seedInspectedCount = report.inspected
                        self.seedReadBytes = report.bytesRead
                        self.seedStatus = "Verifica terminata: "
                            + "\(report.verifiedCount) file identici via SHA-256; "
                            + "\(report.missingOrDifferent) diversi o mancanti, "
                            + "\(report.deferred) non verificabili. "
                            + "Nessun file copiato o cancellato. Conferma separata necessaria."
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.seedBusy = false
                        self?.seedReady = false
                        self?.seedReport = nil
                        self?.seedVerifier = nil
                        self?.seedStatus = cancellation.isCancelled
                            ? "Verifica annullata; la coda è invariata"
                            : "Verifica non riuscita: " + error.localizedDescription
                    }
                }
            }
        } catch {
            seedStatus = "Verifica non avviata: " + error.localizedDescription
        }
    }

    func cancelSeedVerification() {
        seedCancel?.cancel()
        seedStatus = "Annullamento richiesto…"
    }

    /// Only verified matches can be acknowledged. No copy/delete is issued.
    func approveSeededFiles() {
        guard !active && !seedBusy && !maintaining,
              let report = seedReport, let verifier = seedVerifier,
              !report.matches.isEmpty else { return }

        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Confermare \(report.matches.count) file già identici?"
        confirmation.informativeText = """
        I file verificati con SHA-256 verranno contrassegnati come completati
        SOLTANTO nella coda locale SQLite, dopo un nuovo controllo dello stato
        dei file. Nessun contenuto verrà modificato in Sorgente o Destinazione.
        I file diversi o non verificabili rimarranno da sincronizzare.
        """
        confirmation.addButton(withTitle: "Conferma allineamento SQLite")
        confirmation.addButton(withTitle: "Annulla")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let cancellation = SeedVerificationCancellation()
        seedCancel = cancellation
        seedBusy = true
        seedReady = false
        seedStartedAt = nil
        seedCurrentPath = ""
        seedStatus = "Conferma in corso (senza modificare file)…"
        queue.async { [weak self] in
            do {
                let acknowledged = try verifier.approve(
                    report: report, cancellation: cancellation
                )
                let db = try Self.databaseURL()
                try? SyncActivityLog(path: db.path).record(
                    level: .success, rootID: "app", action: "seed_confirmed",
                    bytes: 0,
                    message: "SHA-256: \(acknowledged) job riconosciuti senza copie; byte letti: \(report.bytesRead)"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.seedBusy = false
                    self?.seedReady = false
                    self?.seedReport = nil
                    self?.seedVerifier = nil
                    self?.seedStatus = "Allineamento confermato: \(acknowledged) job "
                        + "chiusi in SQLite; \(report.matches.count - acknowledged) "
                        + "rimasti in coda perché cambiati o non più validi. "
                        + "Nessun file modificato."
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.seedBusy = false
                    self?.seedReady = false
                    self?.seedReport = nil
                    self?.seedVerifier = nil
                    self?.seedStatus = cancellation.isCancelled
                        ? "Conferma annullata: nessun job SHA-256 modificato"
                        : "Conferma non riuscita: " + error.localizedDescription
                }
            }
        }
    }

    func invalidateSeedReport() {
        seedCancel?.cancel()
        seedReport = nil
        seedVerifier = nil
        seedReady = false
        if !seedBusy {
            seedStatus = "Cartelle cambiate: eseguire una nuova verifica SHA-256"
        }
    }

    /// A one-off, read-only scan of the already mounted destination.
    /// It may take time for large photo archives, and is NOT repeated on timers.
    func preview(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        guard !active && !maintaining && !seedBusy else {
            previewStatus = "Ferma le copie di prova prima dell'anteprima"
            return
        }
        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty })
            else { throw MountedCopyError.invalidMapping }
            let mappings = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id, source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
            let db = try Self.databaseURL()
            previewStatus = "Confronto in sola lettura: scansione cartelle…"
            queue.async { [weak self] in
                do {
                    var matched = 0
                    var differences = 0
                    var remoteOnly = 0
                    var collisions = 0
                    for mapping in mappings {
                        let result = try MountedBootstrapPreview.inspect(mapping: mapping)
                        matched += result.candidateMatches
                        differences += result.requiresCopyOrReview.count
                        remoteOnly += result.remoteOnlyPaths.count
                        collisions += result.macOSCaseCollisions.count
                    }
                    let summary =
                        "Anteprima (nessuna modifica): \(matched) match PRESUNTI per " +
                        "dimensione e data, \(differences) da verificare, " +
                        "\(remoteOnly) solo a destinazione, \(collisions) conflitti di nome."
                    try? SyncActivityLog(path: db.path).record(
                        level: .info, rootID: "app", action: "preview",
                        message: "Confronto in sola lettura terminato"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.previewStatus = summary
                        self?.refresh()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.previewStatus = "Anteprima non riuscita: "
                            + error.localizedDescription
                    }
                }
            }
        } catch {
            previewStatus = "Anteprima non avviata: " + error.localizedDescription
        }
    }

    /// Opt-in maintenance: display only MacSync-owned UUID partial files older
    /// than seven days. A separate explicit confirmation is required to clean.
    func inspectStaging(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        guard !active && !maintaining else {
            maintenanceStatus = "Ferma prima le copie o la manutenzione in corso"
            return
        }
        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty })
            else { throw MountedCopyError.invalidMapping }
            let mappings = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id,
                    source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
            maintaining = true
            maintenanceCandidates = []
            maintenanceStatus = "Verifica temporanei MacSync in corso…"
            queue.async { [weak self] in
                do {
                    let candidates = try mappings.map {
                        (mapping: $0, inspection: try StagingMaintenance.inspect(mapping: $0))
                    }
                    let count = candidates.reduce(0) { $0 + $1.inspection.count }
                    let bytes = candidates.reduce(Int64(0)) {
                        $0 > Int64.max - $1.inspection.totalBytes
                            ? Int64.max : $0 + $1.inspection.totalBytes
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.maintenanceCandidates = candidates
                        self?.maintaining = false
                        self?.maintenanceStatus = "Temporanei MacSync di oltre 7 giorni: "
                            + "\(count) file, "
                            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                            + ". Nessun file è stato cancellato."
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceStatus = "Verifica temporanei fallita: "
                            + error.localizedDescription
                    }
                }
            }
        } catch {
            maintenanceStatus = "Verifica temporanei non avviata: "
                + error.localizedDescription
        }
    }

    func cleanupStaging(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        guard !active && !maintaining else {
            maintenanceStatus = "Ferma prima le copie"
            return
        }
        let pending = maintenanceCandidates
        let count = pending.reduce(0) { $0 + $1.inspection.count }
        guard count > 0 else {
            maintenanceStatus = "Nessun file temporaneo idoneo da rimuovere"
            return
        }
        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            let freshMappings = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id, source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
            guard freshMappings.count == pending.count,
                  pending.allSatisfy({ saved in
                      freshMappings.contains(where: {
                          $0.rootID == saved.mapping.rootID &&
                          $0.target == saved.mapping.target &&
                          $0.source == saved.mapping.source &&
                          $0.targetVolume == saved.mapping.targetVolume
                      })
                  })
            else { throw MountedCopyError.invalidMapping }

            let approval = NSAlert()
            approval.alertStyle = .warning
            approval.messageText = "Eliminare \(count) file temporanei MacSync?"
            approval.informativeText = """
            Solo file UUID.partial vecchi di almeno 7 giorni, nella cartella
            .macsync-staging. Verranno ricontrollati prima della rimozione.
            Non verranno toccate fotografie o copie di backup.
            Le copie devono rimanere arrestate.
            """
            approval.addButton(withTitle: "Elimina temporanei verificati")
            approval.addButton(withTitle: "Annulla")
            guard approval.runModal() == .alertFirstButtonReturn else { return }

            maintaining = true
            maintenanceStatus = "Pulizia temporanei verificati in corso…"
            queue.async { [weak self] in
                do {
                    var deleted = 0
                    for item in pending {
                        deleted += try StagingMaintenance.cleanup(
                            mapping: item.mapping, inspected: item.inspection,
                            approved: true
                        )
                    }
                    let database = try Self.databaseURL()
                    try? SyncActivityLog(path: database.path).record(
                        level: .info, rootID: "app", action: "staging_cleanup",
                        message: "Temporanei verificati eliminati: \(deleted)"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceCandidates = []
                        self?.maintenanceStatus = "Pulizia completata: "
                            + "\(deleted) temporanei eliminati. Foto e backup invariati."
                        self?.refresh()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceStatus = "Pulizia temporanei interrotta: "
                            + error.localizedDescription
                    }
                }
            }
        } catch {
            maintenanceStatus = "Pulizia bloccata: " + error.localizedDescription
        }
    }

    func stop() {
        auditCancel?.cancel()
        sessionCancellation?.cancel()
        sessionCancellation = nil
        nextScheduledRun = nil
        automaticSession = false
        mirrorCancellation?.cancel()
        mirrorCancellation = nil
        timer?.cancel()
        timer = nil
        active = false
        mirrorStatus = "Cancellazioni speculari non attive; un'operazione già avviata può terminare"
        status = "Copie fermate. Un trasferimento già avviato può terminare."
    }

    func refresh() {
        do {
            let database = try Self.databaseURL()
            guard FileManager.default.fileExists(atPath: database.path) else {
                recentEntries = []
                return
            }
            recentEntries = try SyncActivityLog(path: database.path).recent(
                limit: 300, level: SyncLogLevel(rawValue: logLevel),
                search: logSearch
            )
        } catch {
            status = "Impossibile leggere il registro: " + error.localizedDescription
        }
    }

    func exportLog() {
        do {
            let text = try SyncActivityLog(path: Self.databaseURL().path)
                .exportText(
                    limit: 5000, level: SyncLogLevel(rawValue: logLevel),
                    search: logSearch
                )
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MacSync_sync_log.tsv"
            panel.title = "Esporta registro sincronizzazioni"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Registro esportato (controlla i nomi dei file prima di condividerlo)"
        } catch {
            status = "Esportazione fallita: " + error.localizedDescription
        }
    }
}
