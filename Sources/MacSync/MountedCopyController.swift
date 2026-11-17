import AppKit
import SwiftUI
import MacSyncCore

/// Deliberately TEST-only: foreground opt-in for the current app session.
/// macOS Finder must mount SMB shares and supply its saved credentials.
@MainActor
final class MountedCopyController: ObservableObject {
    private let previewOnly: Bool
    private let monitorGate: MonitorSafetyGate
    var onQueueChanged: (() -> Void)?
    @Published private(set) var interruptionRequested = false

    init(previewOnly: Bool = false, monitorGate: MonitorSafetyGate = MonitorSafetyGate()) {
        self.previewOnly = previewOnly
        self.monitorGate = monitorGate
        if !previewOnly {
            UserDefaults.standard.set(automaticCopiesEnabled, forKey:"MacSync.autoCopiesEnabled.v2")
            UserDefaults.standard.set(false, forKey:"MacSync.autoCopiesEnabled")
        }
    }

    // Screenshot fixture: called only from the opt-in UI test. No real database access.
    func populateScreenshotFixture(page: MacSyncPage, entries: [SyncLogEntry], cycle: SyncCycleRecord?, lastAudit: ArchiveAuditReport? = nil, auditInProgress: Bool = true) {
        guard previewOnly else { return }
        automaticCopiesEnabled = true
        mirrorEnabled = false; mirrorAuthorization = nil
        mirrorProtections = MirrorProtectionSettings(); mirrorRecovery = false; mirrorRetention = 30
        auditSettings = ArchiveAuditSettings()
        status = "Destinazioni disponibili"
        sessionStats = SyncDashboardStats(newFiles: 24, updatedFiles: 12, permanentlyDeleted: 1, movedToRecovery: 2, failed: 1, deferred: 4)
        lastCycleStats = sessionStats
        lastRecordedCycle = cycle
        recentEntries = entries
        previewStatus = "Confronto iniziale non eseguito"
        auditSettings.enabled = false; auditSettings.repair = false; auditSettings.mode = .deep
        if page == .overview {
            active = true; automaticSession = true
            var progress = SyncLiveProgress(started: Date().addingTimeInterval(-155), planned: 46)
            progress.workStarted = Date().addingTimeInterval(-140)
            progress.processed = 24; progress.phase = "Trasferimento"; progress.currentFile = "Cartella_1 / IMG_0042.dng"
            progress.copiedBytes = 124000000; progress.copySeconds = 10
            liveProgress = progress
        } else if page == .audit {
            auditReport = lastAudit
            auditSettings.enabled = true; auditSettings.frequency = "weekly"; auditSettings.weekday = 2; auditSettings.hour = 8; auditSettings.minute = 0
            auditBusy = auditInProgress; maintaining = auditInProgress
            guard auditInProgress else {
                auditProgress = nil; auditStatus = "Verifica conclusa"
                return
            }
            var progress = ArchiveAuditProgress(started: Date().addingTimeInterval(-30))
            progress.phase = "Verifica SHA-256"; progress.scannedFiles = 240; progress.scannedDirectories = 12
            progress.detectedBytes = 800000000; progress.compared = 96; progress.total = 240
            progress.source.files = 120; progress.source.directories = 6; progress.source.detectedBytes = 400000000
            progress.destination = progress.source
            progress.source.bytesRead = 160000000; progress.source.readSeconds = 8
            progress.destination.bytesRead = 160000000; progress.destination.readSeconds = 12
            progress.comparisonStarted = Date().addingTimeInterval(-22)
            progress.bytesRead = 320000000; progress.currentPath = "Foto_caricate / IMG_0042.dng"
            auditProgress = progress; auditStatus = "Verifica in corso"
        }
    }
    @Published var status = "Copie ferme: puoi selezionare cartelle locali o SMB già montate."
    @Published var active = false
    @Published private(set) var nextScheduledRun: Date?
    var onConnectionCheck: (([String: DestinationAvailability], Date) -> Void)?
    @Published var automaticCopiesEnabled = (UserDefaults.standard.object(forKey:"MacSync.autoCopiesEnabled.v2") as? Bool) ?? UserDefaults.standard.bool(forKey:"MacSync.autoCopiesEnabled") {
        didSet {
            if !previewOnly { UserDefaults.standard.set(automaticCopiesEnabled, forKey: "MacSync.autoCopiesEnabled.v2"); UserDefaults.standard.set(false, forKey:"MacSync.autoCopiesEnabled") }
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
            if !previewOnly, mirrorProtections.isValid, let data = try? JSONEncoder().encode(mirrorProtections) {
                UserDefaults.standard.set(data, forKey: "MacSync.mirrorProtections.v1")
            }
        }
    }
    @Published var mirrorRecovery = (UserDefaults.standard.object(forKey: "MacSync.mirrorRecovery") as? Bool) ?? true {
        didSet { if !previewOnly { UserDefaults.standard.set(mirrorRecovery, forKey: "MacSync.mirrorRecovery") } }
    }
    /// 0 = never delete recovery files automatically; 1...30 = days.
    @Published var mirrorRetention = UserDefaults.standard.object(forKey: "MacSync.mirrorRetention") as? Int ?? 30 {
        didSet { if !previewOnly { UserDefaults.standard.set(mirrorRetention, forKey: "MacSync.mirrorRetention") } }
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
                let cycle = try history.cycles(limit:1,finishedOnly:true).first
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
            if !previewOnly, let data = try? JSONEncoder().encode(auditSettings) {
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
                           interactive: Bool, recognizeExisting: Bool = false) {
        guard monitorGate.isReady, !interruptionRequested, liveProgress == nil, !auditBusy && !maintaining && !seedBusy && !seedReady else {
            if !interactive { noteAuditSkipped("verifica, conferma o manutenzione in corso") }
            return
        }
        let settings = auditSettings
        let recognize = interactive && recognizeExisting && settings.mode == .deep
        guard !recognize || (!active && liveProgress == nil && !interruptionRequested) else { auditStatus = "Sospendi le copie prima del riconoscimento"; return }
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
                + (recognize ? " I file identici ancora in coda potranno essere riconosciuti con conferma separata." : "")
                + " Nessun file presente soltanto sul server verrà cancellato."
            alert.addButton(withTitle:"Avvia verifica"); alert.addButton(withTitle:"Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let db: URL
        do { db = try Self.databaseURL() }
        catch { auditStatus = error.localizedDescription; return }
        let gate = monitorGate
        let cancel = SeedVerificationCancellation(shouldContinue:{ gate.isReady })
        auditCancel = cancel
        auditBusy = true
        maintaining = true
        invalidateSeedReport()
        seedVerifiedCount = 0
        auditStatus = "Verifica in attesa della coda di lavoro"
        queue.async { [weak self] in
            let auditLog = try? SyncActivityLog(path:db.path)
            try? auditLog?.record(level:.info,rootID:"app",action:"audit_start",message:settings.mode == .deep ? "Verifica SHA-256 avviata" : "Verifica metadati avviata")
            do {
                if cancel.isCancelled { throw SeedVerificationError.cancelled }
                let journal = try ChangeJournal(path:db.path)
                let maps = try configured.map {
                    try MountedFolderMapping(rootID:$0.id,source:URL(fileURLWithPath:$0.path),
                        target:URL(fileURLWithPath:$0.destination),expectedTargetVolume:$0.expected)
                }
                try journal.verifyDirectoryBindings(maps,allowNewTarget:interactive)
                let report: ArchiveAuditReport
                let recognition: SeedVerificationReport?
                let session: SeededArchiveSession?
                let progress: (ArchiveAuditProgress) -> Void = { snapshot in
                    DispatchQueue.main.async { [weak self] in
                        self?.auditProgress = snapshot
                        self?.auditStatus = snapshot.phase
                    }
                }
                if recognize {
                    let local = try SeededArchiveSession(database:db,mappings:maps)
                    let result = try local.auditAndRecognize(repair:settings.repair,cancellation:cancel,progress:progress)
                    report = result.audit; recognition = result.recognition; session = local
                } else {
                    report = try ArchiveAudit(journal:journal,mappings:maps).run(mode:settings.mode,repair:settings.repair,cancellation:cancel,progress:progress)
                    recognition = nil; session = nil
                }

                var storageWarning = ""
                do {
                    let data = try JSONEncoder().encode(report)
                    try data.write(to:db.deletingLastPathComponent().appendingPathComponent("last-audit.json"),options:.atomic)
                } catch { storageWarning = " — impossibile salvare lo storico della verifica" }
                let warning = storageWarning
                try? auditLog?.record(level:.info,rootID:"app",action:"audit_finish",bytes:report.bytesRead,durationSeconds:report.seconds,message:"Verifica conclusa: \(report.findings.count) elementi; \(report.queuedRepairs) riparazioni accodate" + warning)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onQueueChanged?()
                    self.auditReport = report
                    if let recognition, let session, !cancel.isCancelled {
                        self.seedReport = recognition; self.seedSession = session; self.seedCancel = cancel
                        self.seedReady = !recognition.matches.isEmpty; self.seedVerifiedCount = recognition.verifiedCount
                        self.seedInspectedCount = recognition.inspected; self.seedReadBytes = recognition.bytesRead
                        self.seedStatus = recognition.matches.isEmpty ? "Nessun file in coda riconoscibile" : "\(recognition.verifiedCount) file identici in coda: conferma necessaria"
                    }
                    self.auditStatus = "Verifica conclusa: " + String(report.queuedRepairs) + " riparazioni accodate" + warning
                    self.auditProgress = nil
                    self.auditBusy = false
                    self.maintaining = false
                }
            } catch {
                try? auditLog?.record(level:cancel.isCancelled ? .info : .error,rootID:"app",action:"audit_error",message:cancel.isCancelled ? "Verifica annullata" : SyncDiagnostic.describe(error))
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
    private var seedSession: SeededArchiveSession?
    private var seedCancel: SeedVerificationCancellation?
    private var maintenanceCancel: SeedVerificationCancellation?
    private var maintenanceCandidates: [(mapping: MountedFolderMapping, inspection: StagingInspection)] = []

    private let queue = DispatchQueue(label: "macsync.mounted.copy.serial", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mirrorCancellation: MirrorDeletionCancellation?
    private var sessionCancellation: MirrorDeletionCancellation?

    // Uses only Foundation filesystem APIs; no main-actor state.
    nonisolated private static func databaseURL() throws -> URL {
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
        guard !active && !maintaining && !seedBusy && !interruptionRequested && liveProgress == nil else { return }
        if !enabled {
            revokeMirrorAuthorization()
            return
        }
        guard !mirrorEnabled, monitorGate.isReady else { return }
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
        let gate = monitorGate
        let cancel = SeedVerificationCancellation(shouldContinue:{ gate.isReady })
        maintenanceCancel = cancel
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
                try journal.verifyDirectoryBindings(maps,allowNewTarget:true)
                let authorization = try MirrorAuthorization.capture(journal: journal, mappings: maps,shouldContinue:{ !cancel.isCancelled })
                guard !cancel.isCancelled else { throw SeedVerificationError.cancelled }
                let data = try JSONEncoder().encode(authorization)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.maintaining = false
                    guard self.mirrorConfigurationRevision == revision, !cancel.isCancelled else { return }
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
        guard monitorGate.isReady, !interruptionRequested, liveProgress == nil, !maintaining && !seedBusy && !seedReady else {
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
        warning.messageText = "Avviare la sincronizzazione?"
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
        warning.addButton(withTitle: "Avvia sincronizzazione")
        warning.addButton(withTitle: "Annulla")
        guard warning.runModal() == .alertFirstButtonReturn else {
            status = "Copie non attivate"
            return
        }
        beginSession(sources: sources, policy: policy, automatic: false,
                     schedule: schedule, firstSlot:Date())
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
            alert.addButton(withTitle: "Abilita copie automatiche")
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
        guard monitorGate.isReady, automaticCopiesEnabled, !active, !maintaining, !seedBusy, !seedReady else { return }
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
        guard !previewOnly, !active && !seedBusy && !maintaining && !interruptionRequested && liveProgress == nil, schedule.isValid else { return }
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
            let gate = monitorGate
            sessionCancellation = cancellation
            interruptionRequested = false
            mirrorCancellation = policy.enabled ? cancellation : nil
            var mirrorWorker: MirrorDeletionWorker?
            try log.record(
                level: .info, rootID: "app", action: "session",
                message: "Sessione di sincronizzazione abilitata"
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
                guard cancellation.beginCycle() else { return }
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
                    try store.begin(id:cycleID,sessionID:sessionID,at:startedAt,automatic:automatic)
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
                    if cancellation.endCycle() { outcomeState = "interrupted"
                        try? log.record(level: .info, rootID: "app", action: "cycle", message: "Ciclo interrotto su richiesta; operazioni in coda preservate")
                    }
                    if !historyError.isEmpty { outcomeState += "_history_incomplete" }
                    let endedAt = Date()
                    do {
                        try history?.finish(id:cycleID,at:endedAt,seconds:ProcessInfo.processInfo.systemUptime-startUptime,state:outcomeState)
                        try history?.prune(before:endedAt.addingTimeInterval(-365*86400))
                    } catch { historyError = "Storico incompleto: " + error.localizedDescription }
                    let saved = try? history?.cycles(limit:1,finishedOnly:true).first
                    let finalStats = totals.stats
                    let warning = historyError
                    let finalOutcome = outcomeState
                    if !automatic { timer.cancel() }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.historySessionID == sessionID else { return }
                        self.liveProgress = nil
                        self.interruptionRequested = false
                        if finalOutcome.hasPrefix("interrupted") { self.status = "Ciclo interrotto; operazioni rimanenti in coda." }
                        self.historyWarning = warning
                        self.lastRecordedCycle = saved ?? nil
                        self.lastCycleStats = finalStats
                        self.sessionStats = finalStats
                        self.completedCycles += 1
                        self.lastCycleAt = endedAt
                        if !automatic {
                            self.active = false; self.automaticSession = false; self.nextScheduledRun = nil
                            self.timer = nil; self.sessionCancellation = nil; self.mirrorCancellation = nil
                        }
                        self.refresh(); self.onQueueChanged?()
                    }
                    // Keep the cadence anchored to its scheduled slot.
                    // If a long copy crosses a slot, skip that slot.
                    if automatic, !cancellation.isSessionCancelled,
                       let next = schedule.nextSlot(
                           after: scheduledSlot, completedAt: Date()
                       ) {
                        scheduledSlot = next
                        timer.schedule(
                            wallDeadline: .now() + max(0, next.timeIntervalSinceNow),
                            leeway: .milliseconds(250)
                        )
                        DispatchQueue.main.async { [weak self] in
                            if !cancellation.isSessionCancelled, self?.active == true {
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
                        message: "Controllo destinazioni — " + String(states.filter { !$0.value.isReady }.map { $0.key + ": " + $0.value.description }.sorted().joined(separator:"; ").prefix(3000))
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
                    guard gate.isReady else { throw JournalError.database("Inventario sorgenti non pronto; ciclo sospeso") }
                    // Reopen mappings on each healthy cycle, then compare the
                    // durable logical identity. A changed inode never rebinds.
                    worker = nil; mirrorWorker = nil
                    do {
                        maps = try configured.map {
                            try MountedFolderMapping(
                                rootID: $0.id,
                                source: URL(fileURLWithPath: $0.path),
                                target: URL(fileURLWithPath: $0.destination),
                                expectedTargetVolume: $0.expected
                            )
                        }
                        try journal.verifyDirectoryBindings(maps,allowNewTarget:true)
                        worker = try MountedFolderCopyWorker(
                            journal: journal, log: log, mappings: maps
                        )
                        worker?.operationAllowed = { gate.isReady && !cancellation.isCancelled }
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
                        mirrorWorker?.operationAllowed = { gate.isReady && !cancellation.isCancelled }
                        try? log.record(
                            level: .info, rootID: "app", action: "mirror_armed",
                            message: policy.recoveryEnabled
                                ? "Mirror attivato con recupero" : "Mirror attivato senza recupero"
                        )
                    }
                    try mirrorWorker?.verifyBeforeSynchronization()
                    let highWater = try journal.queueSequence()
                    progress.planned = try journal.plannedUploadCount(throughID:highWater)
                    progress.planned += try mirrorWorker?.plannedCount(throughID:highWater) ?? 0
                    progress.workStarted = Date()
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
                        shouldContinue: { !cancellation.isCancelled && gate.isReady },
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
                    if let mirrorWorker, gate.isReady, !cancellation.isCancelled, !summary.interrupted {
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
                    outcomeState = !gate.isReady && !cancellation.isCancelled ? "suspended" : summary.interrupted ? "interrupted" :
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
                        message: (cancellation.isCancelled || summary.interrupted ? "Ciclo interrotto: " : "Ciclo concluso: ") + "\(summary.copied) copie, \(summary.reconciled) pubblicazioni precedenti riconciliate, \(summary.deferred) rimandate, \(summary.failed) errori." + mirrorDetails
                    )
                    // Only the SQLite activity table is pruned, never file
                    // inventory, queue, photographs, backups or staging.
                    _ = try? log.prune(retainNewest: 20_000, maxAgeDays: 90)
                    let result = (summary.interrupted
                        ? "Ciclo interrotto: " : "Ultimo ciclo: ") + "\(summary.copied) copie, "
                        + "\(summary.deferred) rimandate, \(summary.failed) errori, "
                        + "\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) trasferiti."
                    DispatchQueue.main.async { [weak self] in
                        guard !cancellation.isCancelled else { return }
                        self?.status = gate.isReady ? result : "Sincronizzazione sospesa: inventario non pronto; coda conservata"
                        self?.mirrorStatus = policy.enabled ? mirrorDetails : "Cancellazioni speculari disattivate"
                        // History and totals are finalized even for interrupted cycles.
                    }
                } catch {
                    if cancellation.isCancelled { outcomeState = "interrupted"; return }
                    outcomeState = "suspended"
                    totals.stats.deletionsBlocked = policy.enabled
                    try? log.record(
                        level: .error, rootID: "app", action: "cycle",
                        message: "Ciclo sospeso — " + SyncDiagnostic.describe(error)
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
            // Keep the preceding completed cycle visible until this cycle ends.
            liveProgress = nil
            active = true
            automaticSession = automatic
            mirrorStatus = policy.enabled
                ? "Configurazione armata: la verifica delle sorgenti avverrà al primo ciclo"
                : "Cancellazioni speculari disattivate"
            status = automatic
                ? (policy.enabled ? "Sincronizzazione automatica pianificata con mirror autorizzato" : "Copie automatiche pianificate (solo aggiunte e aggiornamenti)")
                : "Sincronizzazione manuale avviata"
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
            let cancellation = SeedVerificationCancellation()
            seedReport = nil
            seedSession = nil
            seedCancel = cancellation
            seedReady = false
            seedBusy = true
            seedVerifiedCount = 0
            seedInspectedCount = 0
            seedReadBytes = 0
            seedTotalJobs = 0
            seedStartedAt = Date()
            seedCurrentPath = ""
            seedStatus = "Analisi SHA-256 in corso (lettura locale e SMB)…"

            queue.async { [weak self] in
                do {
                    let session = try SeededArchiveSession(database: database, mappings: mappings)
                    let report = try session.verify(
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
                        self.seedSession = session
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
                        self?.seedSession = nil
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
        guard monitorGate.isReady, !active && !seedBusy && !maintaining,
              let report = seedReport, let session = seedSession,
              !report.matches.isEmpty else { return }

        let previousCancellation = seedCancel
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
        guard confirmation.runModal() == .alertFirstButtonReturn,
              !active && !seedBusy && !maintaining,
              seedSession != nil, seedCancel === previousCancellation,
              previousCancellation?.isCancelled == false else { return }
        let gate = monitorGate
        let cancellation = SeedVerificationCancellation(shouldContinue:{ gate.isReady })
        seedCancel = cancellation
        seedBusy = true
        seedReady = false
        seedStartedAt = nil
        seedCurrentPath = ""
        seedStatus = "Conferma in corso (senza modificare file)…"
        queue.async { [weak self] in
            do {
                let acknowledged = try session.approve(
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
                    self?.seedSession = nil
                    self?.seedStatus = "Allineamento confermato: \(acknowledged) job "
                        + "chiusi in SQLite; \(report.matches.count - acknowledged) "
                        + "rimasti in coda perché cambiati o non più validi. "
                        + "Nessun file modificato."
                    self?.refresh(); self?.onQueueChanged?()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.seedBusy = false
                    self?.seedReady = false
                    self?.seedReport = nil
                    self?.seedSession = nil
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
        seedSession = nil
        seedReady = false
        if !seedBusy {
            seedStatus = "Nessun riconoscimento da confermare"
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
            let cancel = SeedVerificationCancellation()
            maintenanceCancel = cancel
            maintaining = true
            previewStatus = "Confronto in sola lettura: scansione cartelle…"
            queue.async { [weak self] in
                do {
                    var matched = 0
                    var differences = 0
                    var remoteOnly = 0
                    var collisions = 0
                    for mapping in mappings {
                        guard !cancel.isCancelled else { throw SeedVerificationError.cancelled }
                        let result = try MountedBootstrapPreview.inspect(mapping: mapping, shouldContinue: { !cancel.isCancelled })
                        matched += result.candidateMatches
                        differences += result.requiresCopyOrReview.count
                        remoteOnly += result.remoteOnlyPaths.count
                        collisions += result.macOSCaseCollisions.count
                    }
                    guard !cancel.isCancelled else { throw SeedVerificationError.cancelled }
                    let summary =
                        "Anteprima (nessuna modifica): \(matched) match PRESUNTI per " +
                        "dimensione e data, \(differences) da verificare, " +
                        "\(remoteOnly) solo a destinazione, \(collisions) conflitti di nome."
                    try? SyncActivityLog(path: db.path).record(
                        level: .info, rootID: "app", action: "preview",
                        message: "Confronto in sola lettura terminato"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceCancel = nil
                        self?.previewStatus = cancel.isCancelled ? "Anteprima annullata" : summary
                        self?.refresh()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceCancel = nil
                        self?.previewStatus = cancel.isCancelled ? "Anteprima annullata" : "Anteprima non riuscita: " + error.localizedDescription
                    }
                }
            }
        } catch {
            previewStatus = "Anteprima non avviata: " + error.localizedDescription
        }
    }

    /// Opt-in maintenance: display only MacSync-owned UUID partial files older
    /// than seven days. A separate explicit confirmation is required to clean.
    func cancelMaintenance() {
        guard maintaining, !auditBusy else { return }
        maintenanceCancel?.cancel()
    }

    func inspectStaging(sources: [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )]) {
        guard !active && !maintaining && !seedBusy else {
            maintenanceStatus = "Ferma prima le copie o la manutenzione in corso"
            return
        }
        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty })
            else { throw MountedCopyError.invalidMapping }
            let cancel = SeedVerificationCancellation()
            maintenanceCancel = cancel
            maintaining = true
            maintenanceCandidates = []
            maintenanceStatus = "Verifica temporanei MacSync in corso…"
            queue.async { [weak self] in
                do {
                    let mappings = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id,
                    source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
                    let journal = try ChangeJournal(path:Self.databaseURL().path)
                    try journal.verifyDirectoryBindings(mappings,allowNewTarget:true)
                    let candidates = try mappings.map {
                        (mapping: $0, inspection: try StagingMaintenance.inspect(mapping: $0, shouldContinue: { !cancel.isCancelled }))
                    }
                    let count = candidates.reduce(0) { $0 + $1.inspection.count }
                    let bytes = candidates.reduce(Int64(0)) {
                        $0 > Int64.max - $1.inspection.totalBytes
                            ? Int64.max : $0 + $1.inspection.totalBytes
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.maintenanceCandidates = cancel.isCancelled ? [] : candidates
                        self?.maintaining = false
                        self?.maintenanceCancel = nil
                        self?.maintenanceStatus = cancel.isCancelled ? "Verifica temporanei annullata" : ("Temporanei MacSync di oltre 7 giorni: "
                            + "\(count) file, "
                            + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                            + ". Nessun file è stato cancellato.")
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.maintaining = false
                        self?.maintenanceCancel = nil
                        self?.maintenanceStatus = cancel.isCancelled ? "Verifica temporanei annullata" : "Verifica temporanei fallita: " + error.localizedDescription
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
        guard !active && !maintaining && !seedBusy else {
            maintenanceStatus = "Ferma prima le copie"
            return
        }
        let pending = maintenanceCandidates
        let count = pending.reduce(0) { $0 + $1.inspection.count }
        guard count > 0 else {
            maintenanceStatus = "Nessun file temporaneo idoneo da rimuovere"
            return
        }
        let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
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
        guard approval.runModal() == .alertFirstButtonReturn,
              !active, !maintaining, !seedBusy else { return }

        let cancel = SeedVerificationCancellation()
        maintenanceCancel = cancel
        maintaining = true
        maintenanceStatus = "Pulizia temporanei verificati in corso…"
        queue.async { [weak self] in
            do {
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
                try ChangeJournal(path:Self.databaseURL().path).verifyDirectoryBindings(freshMappings)
                var deleted = 0
                for item in pending {
                    guard !cancel.isCancelled else { break }
                    deleted += try StagingMaintenance.cleanup(
                        mapping: item.mapping, inspected: item.inspection,
                        approved: true, shouldContinue: { !cancel.isCancelled }
                    )
                }
                let database = try Self.databaseURL()
                try? SyncActivityLog(path: database.path).record(
                    level: .info, rootID: "app", action: "staging_cleanup",
                    message: (cancel.isCancelled ? "Pulizia interrotta: " : "Pulizia completata: ") + "\(deleted) temporanei eliminati"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.maintaining = false
                    self?.maintenanceCandidates = []
                    self?.maintenanceCancel = nil
                    self?.maintenanceStatus = (cancel.isCancelled ? "Pulizia interrotta: " : "Pulizia completata: ") + "\(deleted) temporanei eliminati. Foto e backup invariati."
                    self?.refresh()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.maintaining = false
                    self?.maintenanceCancel = nil
                    self?.maintenanceCandidates = []
                    self?.maintenanceStatus = "Pulizia temporanei interrotta: "
                        + error.localizedDescription
                }
            }
        }
    }

    func interruptCurrentCycle() {
        guard let token = sessionCancellation, token.cancelCurrentCycle() else { return }
        interruptionRequested = true
        status = "Interruzione richiesta: attendo il prossimo punto sicuro."
    }

    /// Runs after the serial copy queue has drained, including any atomic transfer.
    func afterWorkerStopped(_ completion: @escaping @MainActor () -> Void) {
        queue.async { DispatchQueue.main.async { completion() } }
    }

    func stop() {
        if sessionCancellation?.cycleInProgress == true { interruptionRequested = true }
        seedCancel?.cancel()
        maintenanceCancel?.cancel()
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

    private var refreshRevision = 0
    func refresh() {
        guard !previewOnly else { return }
        refreshRevision += 1
        let revision = refreshRevision, level = SyncLogLevel(rawValue:logLevel), search = logSearch
        queue.async { [weak self] in
            do {
                let db = try Self.databaseURL()
                let entries = FileManager.default.fileExists(atPath:db.path)
                    ? try SyncActivityLog(path:db.path).recent(limit:300,level:level,search:search) : []
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.refreshRevision == revision else { return }
                    self.recentEntries = entries
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.refreshRevision == revision else { return }
                    self.status = "Impossibile leggere il registro: " + error.localizedDescription
                }
            }
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
