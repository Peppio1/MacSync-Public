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
    @Published private(set) var queueRebuildRequired = false
    @Published private(set) var ignoreDSStore = FileExclusionPolicy.ignoreDSStore

    init(previewOnly: Bool = false, monitorGate: MonitorSafetyGate = MonitorSafetyGate()) {
        self.previewOnly = previewOnly
        self.monitorGate = monitorGate
        if !previewOnly {
            do {
                let db = try Self.databaseURL()
                if FileManager.default.fileExists(atPath:db.path) {
                    queueRebuildRequired = try ChangeJournal(path:db.path).queueRebuildToken() != nil
                }
            } catch { queueRebuildRequired = true; status = "Impossibile leggere la coda: " + SyncDiagnostic.describe(error) }
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
        auditSettings.enabled = false; auditSettings.repair = false; auditSettings.mode = .intelligent
        if page == .names {
            incompatibleNames=[
                IncompatibleName(rootID:"demo",rootPath:"/Example/Archivio",relativePath:"Categoria/Cartella A ",objectKind:"directory",side:.source,reason:"Spazio finale",affectedDescendants:9),
                IncompatibleName(rootID:"demo",rootPath:"/Example/Archivio",relativePath:"Categoria/Cartella B.",objectKind:"directory",side:.source,reason:"Punto finale",affectedDescendants:4),
                IncompatibleName(rootID:"demo",rootPath:"/Example/Archivio",relativePath:"Categoria/Foto?.jpg",objectKind:"file",side:.source,reason:"Carattere incompatibile con Windows")
            ]
            namesStatus="Dati sintetici"
        }
        if page == .overview && lastAudit == nil {
            active = true; automaticSession = true
            var progress = SyncLiveProgress(started: Date().addingTimeInterval(-155), planned: 46)
            progress.workStarted = Date().addingTimeInterval(-140)
            progress.processed = 24; progress.phase = "Trasferimento"; progress.currentFile = "Cartella_1 / IMG_0042.dng"
            progress.copiedBytes = 124000000; progress.copySeconds = 10
            liveProgress = progress
        } else if page == .audit || page == .overview {
            if var report = lastAudit {
                if report.displayCounts == nil { report.displayCounts = .calculate(report.findings,deletionCandidates:report.deletionCandidates ?? []) }
                auditReport = report
            } else { auditReport = nil }
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
            progress.differences = lastAudit?.findings.filter { $0.objectKind == "file" && $0.kind != .matching } ?? []
            progress.deletionCandidates = lastAudit?.deletionCandidates ?? []
            progress.counts = .calculate(progress.differences,deletionCandidates:progress.deletionCandidates)
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
    func recordBlockedStart(reason:String) {
        guard !previewOnly else { return }
        DispatchQueue.global(qos:.utility).async {
            guard let path=try? Self.databaseURL().path else { return }
            TechnicalFallbackLog.record(databasePath:path,action:"session_blocked",message:reason)
        }
    }
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
                    self.sessionStats = stats
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
    @Published var auditSettings: ArchiveAuditSettings = ArchiveAuditSettings.loadMigratingLegacyDeep(
        from: .standard, key: "MacSync.archiveAuditSettings"
    ) {
        didSet {
            if !previewOnly, let data = try? JSONEncoder().encode(auditSettings) {
                UserDefaults.standard.set(data,forKey:"MacSync.archiveAuditSettings")
            }
        }
    }
    @Published private(set) var auditBusy = false
    @Published private(set) var auditProgress: ArchiveAuditProgress?
    @Published private(set) var incompatibleNames:[IncompatibleName]=[] {
        didSet {
            sourceNameCount = incompatibleNames.reduce(into: 0) { count, item in
                if item.side == .source { count += 1 }
            }
            namesRevision &+= 1
        }
    }
    private(set) var sourceNameCount = 0
    private(set) var namesRevision = 0
    @Published private(set) var namesLoaded = false
    @Published private(set) var namesStatus="Inventario non ancora consultato"
    @Published private(set) var namesBusy=false
    @Published private(set) var nameScanStarted: Date?
    @Published private(set) var rectificationStatus=""
    @Published private(set) var rectificationProgress: (checked: Int, total: Int)?
    @Published private(set) var rectifyingNames=false
    var scanningNames: Bool { namesCancellation != nil }

    func rectifyNamesAfterDrain(items:[IncompatibleName],
                                pairs:[(id:String,path:String,destination:String,expected:VolumeFingerprint?)],
                                token:SeedVerificationCancellation,
                                completion:@escaping @MainActor (Bool)->Void) {
        guard !previewOnly,!rectifyingNames else { completion(false);return }
        rectifyingNames=true; rectificationStatus="Verifica e rettifica dei nomi in corso…"
        queue.async { [weak self] in
            var status=""
            var resolved=Set<String>()
            var pending = true
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let db=try Self.databaseURL().path
                let journal = try ChangeJournal(path: db)
                let roots = Dictionary(uniqueKeysWithValues: pairs.filter { !$0.path.isEmpty }.map { ($0.id, $0.path) })
                let requested = items.isEmpty ? Set(pairs.map(\.id)) : Set(items.filter { $0.side == .destination }.map(\.rootID))
                var destinations: [String: MountedFolderMapping] = [:]
                for pair in pairs where requested.contains(pair.id) {
                    guard !pair.path.isEmpty, !pair.destination.isEmpty, let expected = pair.expected else { continue }
                    destinations[pair.id] = try? MountedFolderMapping(
                        rootID: pair.id, source: URL(fileURLWithPath: pair.path),
                        target: URL(fileURLWithPath: pair.destination), expectedTargetVolume: expected)
                }
                let log = try SyncActivityLog(path: db)
                log.cycleID = UUID().uuidString
                var lastProgress = -Double.infinity
                let result=try NameRectification.execute(items:items,roots:roots,journal:journal,log:log,
                    destinations:destinations, onProgress: { checked, total in
                        let now = ProcessInfo.processInfo.systemUptime
                        guard total > 0, checked == total || now - lastProgress >= 0.15 else { return }
                        lastProgress = now
                        DispatchQueue.main.async { [weak self] in self?.rectificationProgress = (checked, total) }
                    }, shouldContinue:{!token.isCancelled})
                let sides = try NameRectification.pendingSideSummary(journal: journal)
                pending = try journal.hasPendingNameRectification()
                let localPending = sides.sourcePending
                let remotePending = sides.destinationPending
                let localCompleted = pending ? sides.sourceCompleted : result.sourceRenamed
                let remoteCompleted = pending ? sides.destinationCompleted : result.destinationRenamed
                try? log.record(level: pending ? .warning : .info, rootID: "app",
                    action: pending ? "name_rectification_waiting" : "name_rectification_finish",
                    durationSeconds: ProcessInfo.processInfo.systemUptime - started, message: "Esito del lotto")
                resolved=result.resolvedIDs
                status="iMac: \(localCompleted) rinominati, \(localPending) pendenti · SMB: \(remoteCompleted) rinominati, \(remotePending) pendenti · \(result.skipped) conflitti · \(result.failed) non verificati"
                if result.cancelled { status+=" · interrotto" }
                if let reason = result.firstFailure { status += "\n" + reason }
            } catch { status="Rettifica interrotta: "+SyncDiagnostic.describe(error)+"; controllare il registro" }
            let finalStatus=status, completedIDs=resolved, needsRetry=pending
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(needsRetry);return }
                self.incompatibleNames.removeAll{completedIDs.contains($0.id)}
                self.rectificationStatus=finalStatus + (needsRetry ? " · Percorsi pendenti protetti; le copie indipendenti possono procedere" : " · Verificare i nomi eventualmente irrisolti")
                self.rectifyingNames=false
                self.rectificationProgress=nil
                self.refresh()
                completion(needsRetry)
            }
        }
    }
    private let namesQueue = DispatchQueue(label: "macsync.names.reader", qos: .utility)
    private var namesCancellation: SeedVerificationCancellation?
    private var namesGeneration = 0

    func cancelNameScan() {
        guard let namesCancellation else { return }
        namesCancellation.cancel()
        namesStatus = "Annullamento scansione richiesto…"
    }

    func refreshIncompatibleNames(pairs: [(id:String,path:String,destination:String,expected:VolumeFingerprint?)],
                                  scan: Bool = false) {
        guard !previewOnly, !rectifyingNames, !scanningNames, !scan || (!namesBusy && !auditBusy) else { return }
        namesCancellation?.cancel()
        namesGeneration += 1
        let generation = namesGeneration
        let cancellation = SeedVerificationCancellation()
        namesCancellation = scan ? cancellation : nil
        namesBusy = true
        if scan {
            nameScanStarted = Date()
            namesStatus = "Preparazione scansione dei nomi…"
        }
        let total = pairs.reduce(0) { $0 + ($1.path.isEmpty ? 0 : 1) + ($1.destination.isEmpty ? 0 : 1) }
        namesQueue.async { [weak self] in
            var warnings: [String] = []
            var snapshots: [NameScanSnapshot] = []
            var unavailable = 0
            var examined = 0
            do {
                let db = try Self.databaseURL().path
                // Cached name-list refresh must not run schema migration/DDL
                // while a transfer or archive audit is writing to SQLite.
                let journal = try ChangeJournal(path: db, readOnly: !scan)
                let log = scan ? try? SyncActivityLog(path: db) : nil
                log?.cycleID = UUID().uuidString
                try? log?.record(level: .info, rootID: "app", action: "name_scan_start", message: "Scansione dei nomi avviata")
                for pair in pairs {
                    for side in IncompatibleName.Side.allCases {
                        let value = side == .source ? pair.path : pair.destination
                        guard !value.isEmpty else { continue }
                        examined += 1
                        let root = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
                        let volume = side == .destination ? pair.expected : nil
                        if scan && !cancellation.isCancelled {
                            let phase = "\(side.label) · Posizione \(examined) di \(total)"
                            let started = ProcessInfo.processInfo.systemUptime
                            var lastPosted = started
                            func show(_ status: String) {
                                DispatchQueue.main.async { [weak self] in
                                    guard let self, self.namesGeneration == generation, !cancellation.isCancelled else { return }
                                    self.namesStatus = status
                                }
                            }
                            show(phase + " · Apertura cartella…")
                            do {
                                struct Update: Sendable { let count: Int; let path: String }
                                let snapshot = try InventoryReadLane.names.read(
                                    shouldContinue: { !cancellation.isCancelled },
                                    onUpdate: { (updates: [Update]) in
                                        guard let newest = updates.last else { return }
                                        let now = ProcessInfo.processInfo.systemUptime
                                        guard newest.path.isEmpty || now - lastPosted >= AdaptiveResourceProfile.sample().nameStatusInterval else { return }
                                        lastPosted = now
                                        let detail = newest.path.isEmpty ? "Analisi dei nomi…" : newest.path
                                        show(phase + " · \(newest.count) elementi letti · " + detail)
                                    }, work: { active, report in
                                        try NameScanSnapshot.scan(rootID: pair.id, side: side, root: root, volume: volume,
                                            shouldContinue: active, onProgress: { report(Update(count: $0, path: $1)) })
                                    })
                                guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                                try journal.saveNameScan(snapshot)
                                snapshots.append(snapshot)
                                try? log?.record(level: .success, rootID: pair.id, action: "name_scan_\(side.rawValue)_finish",
                                    durationSeconds: ProcessInfo.processInfo.systemUptime - started,
                                    message: "\(snapshot.rows.count) nomi incompatibili")
                                continue
                            } catch {
                                unavailable += 1
                                let detail = (error as? InventoryReadLane.Failure)?.errorDescription ?? SyncDiagnostic.describe(error)
                                if !cancellation.isCancelled { warnings.append(side.label + ": " + detail) }
                                try? log?.record(level: .warning, rootID: pair.id, action: "name_scan_\(side.rawValue)_incomplete",
                                    durationSeconds: ProcessInfo.processInfo.systemUptime - started, message: detail)
                            }
                        }
                        if let previous = try? journal.nameScan(rootID: pair.id, side: side),
                           previous.rootPath == root.path, previous.volume == volume {
                            snapshots.append(previous)
                        }
                    }
                }
            } catch { unavailable += 1 }
            let rows = snapshots.flatMap(\.rows)
            let dates = Dictionary(grouping: snapshots, by: \.side).compactMapValues { $0.map(\.date).min() }
            let dateSummary = IncompatibleName.Side.allCases.map { side in
                side.label + ": " + (dates[side]?.formatted(date: .abbreviated, time: .shortened) ?? "nessun esito")
            }.joined(separator: " · ")
            let incomplete = unavailable > 0 || snapshots.count < examined
            let lastWarning = warnings.first
            DispatchQueue.main.async { [weak self] in
                guard let self, self.namesGeneration == generation else { return }
                self.namesBusy = false
                self.namesCancellation = nil
                self.nameScanStarted = nil
                self.incompatibleNames = rows
                self.namesLoaded = true
                if cancellation.isCancelled {
                    self.namesStatus = "Scansione annullata · risultati completati o precedenti"
                } else if let lastWarning {
                    self.namesStatus = dateSummary + " · Esito parziale · " + lastWarning
                } else if !dates.isEmpty {
                    self.namesStatus = dateSummary
                        + (incomplete ? " · Esito parziale, alcune posizioni non verificate" : "")
                } else {
                    self.namesStatus = incomplete ? "Nessun esito salvato per le posizioni non verificate" : "Nessuna scansione disponibile"
                }
            }
        }
    }
    @Published private(set) var auditReport: ArchiveAuditReport?
    @Published private(set) var auditStatus = "Verifica completa non eseguita"
    private var auditCancel: SeedVerificationCancellation?
    private var auditCancelRequestedAt: Double?

    private var loadingLastAudit = false
    private var auditRevision = 0
    func loadLastAudit() {
        guard !previewOnly, !queueRebuildRequired, auditReport == nil, !auditBusy, !loadingLastAudit else { return }
        loadingLastAudit = true
        let revision = auditRevision
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var loaded: ArchiveAuditReport?
            if let url = try? Self.databaseURL().deletingLastPathComponent().appendingPathComponent("last-audit.json"),
               let bytes = try? Data(contentsOf:url),
               var report = try? JSONDecoder().decode(ArchiveAuditReport.self,from:bytes) {
                if report.displayCounts == nil { report.displayCounts = .calculate(report.findings,deletionCandidates:report.deletionCandidates ?? []) }
                loaded = report
            }
            let result = loaded
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingLastAudit = false
                guard self.auditRevision == revision, !self.auditBusy, self.auditReport == nil, let result else { return }
                self.auditReport = result
                self.auditStatus = "Ultima verifica: " + result.ended.formatted(date:.abbreviated,time:.standard)
            }
        }
    }

    /// Both scheduled audit and ordinary copy use the SAME serial queue.
    /// A request during an active cycle waits for that cycle to finish.
    func startArchiveAudit(sources: [(id:String,path:String,destination:String,expected:VolumeFingerprint?)],
                           interactive: Bool) {
        guard monitorGate.isReady, !interruptionRequested, liveProgress == nil, !scanningNames, !auditBusy && !maintaining && !seedBusy && !seedReady else {
            if !interactive { noteAuditSkipped("verifica, conferma o manutenzione in corso") }
            return
        }
        if queueRebuildRequired && !interactive { noteAuditSkipped("avvia manualmente la verifica dopo lo svuotamento"); return }
        var effectiveSettings = auditSettings
        // Defensive gate for programmatic callers or legacy in-memory values:
        // the UI/scheduler must never launch internal DEEP.
        if effectiveSettings.migrateLegacyDeepSelection() { auditSettings = effectiveSettings }
        if queueRebuildRequired && effectiveSettings.mode == .quick { effectiveSettings.mode = .intelligent }
        let settings = effectiveSettings
        guard !active && liveProgress == nil && !interruptionRequested else { auditStatus = "Sospendi le copie prima della verifica"; return }
        let authorization = mirrorEnabled ? mirrorAuthorization : nil
        let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
        guard !configured.isEmpty,
              configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty && $0.expected?.isStrongIdentity == true })
        else { auditStatus = "Configura prima le coppie e i volumi"; return }
        if interactive {
            let alert = NSAlert()
            alert.messageText = "Avviare verifica archivio?"
            alert.informativeText = (settings.mode == .intelligent
                ? "Confronta percorsi, dimensioni e date (tolleranza 2 secondi); utilizza SHA-256 selettivo sui file dubbi. "
                : "La verifica rapida confronta percorsi, dimensioni e date (tolleranza 2 secondi), senza leggere il contenuto. ")
                + "I file con metadati corrispondenti saranno segnalati come allineati nella verifica, senza completare né rimuovere operazioni FSEvents già in coda. "
                + "Le differenze sicure saranno accodate senza duplicare job pendenti, dopo un backup del database. "
                + "Nessuna scrittura sulle destinazioni e nessuna cancellazione dei file presenti soltanto sul server."
            alert.addButton(withTitle:"Avvia verifica"); alert.addButton(withTitle:"Annulla")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let db: URL
        do { db = try Self.databaseURL() }
        catch { auditStatus = error.localizedDescription; return }
        let gate = monitorGate
        guard let auditToken=gate.beginAudit() else { auditStatus="Inventario non pronto: verifica rinviata"; return }
        let cancel = SeedVerificationCancellation(shouldContinue:{ gate.auditBlockReason(auditToken) == nil },commitAllowed:{ gate.auditCommitAllowed(auditToken) })
        auditCancel = cancel
        auditCancelRequestedAt = nil
        auditRevision += 1
        let revision = auditRevision
        auditBusy = true
        maintaining = true
        invalidateSeedReport()
        seedVerifiedCount = 0
        auditStatus = "Verifica in attesa della coda di lavoro"
        queue.async { [weak self] in
            let auditLog = try? SyncActivityLog(path:db.path)
            let auditID=UUID().uuidString
            auditLog?.cycleID = auditID
            let started=Date()
            var last=ArchiveAuditProgress(started:started)
            last.phase="Preparazione verifica"
            var currentRoot="app"
            try? auditLog?.record(level:.info,rootID:"app",action:"audit_start",message:"ID \(auditID) — " + settings.mode.label + " avviata; inventario unico e accodamento conservativo senza completare job già pendenti")
            do {
                if cancel.isCancelled { throw SeedVerificationError.cancelled }
                let journal = try ChangeJournal(path:db.path)
                let rebuildToken = try journal.queueRebuildToken()
                if rebuildToken != nil && !interactive { throw SeedVerificationError.cancelled }
                let maps = try configured.map {
                    currentRoot=$0.id
                    return try MountedFolderMapping(rootID:$0.id,source:URL(fileURLWithPath:$0.path),
                        target:URL(fileURLWithPath:$0.destination),expectedTargetVolume:$0.expected)
                }
                currentRoot="app"
                last.phase="Controllo identità cartelle"
                try journal.verifyDirectoryBindings(maps,allowNewTarget:interactive)
                let diagnostic: (ArchiveAuditProgress) -> Void = { last=$0 }
                let mailbox = AuditProgressMailbox()
                let progress: (ArchiveAuditProgress) -> Void = { snapshot in
                    guard mailbox.offer(snapshot) else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let value = mailbox.take(), let self, self.auditRevision == revision, self.auditBusy else { return }
                        self.auditProgress = value
                        if !cancel.wasExplicitlyCancelled && self.auditStatus != value.phase { self.auditStatus = value.phase }
                    }
                }
                // Verify and preserve a standalone local snapshot before ANY queue updates.
                last.phase = "Backup preventivo database"; progress(last)
                let backupDir = db.deletingLastPathComponent().appendingPathComponent("audit-backups",isDirectory:true)
                try FileManager.default.createDirectory(at:backupDir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let backup = backupDir.appendingPathComponent(auditID+".sqlite")
                try ArchiveDatabaseSafety.backup(db,to:backup)
                try? auditLog?.record(level:.info,rootID:"app",action:"audit_backup",message:backup.path)
                guard cancel.mayCommit else { throw SeedVerificationError.cancelled }
                let candidates = (try? authorization?.auditDeletionCandidates(journal:journal,mappings:maps,shouldContinue:{ !cancel.isCancelled })) ?? []
                let local = try SeededArchiveSession(database:db,mappings:maps)
                // QUICK reads each destination item's metadata only in the
                // inventory. INTELLIGENT may additionally hash doubtful files.
                // No second mass-recognition pass, and no acknowledgment of
                // existing FSEvents or other pending SQLite jobs.
                var report = try local.auditPreservingQueuedChanges(
                    mode:settings.mode,repair:true,cancellation:cancel,
                    diagnostic:diagnostic,progress:progress,deletionCandidates:candidates
                )
                report.recognizedFiles = 0
                report.recognizedDirectories = 0
                var summaryProgress = last
                if let rebuildToken {
                    guard cancel.mayCommit else { throw SeedVerificationError.cancelled }
                    if let authorization {
                        // Invalid historical authorization must not bypass the hold.
                        _ = try authorization.completeQueueRebuild(journal:journal,mappings:maps,token:rebuildToken,report:report,shouldContinue:{cancel.mayCommit})
                    } else {
                        _ = try journal.completeQueueRebuild(token:rebuildToken,shouldContinue:{cancel.mayCommit})
                    }
                    let freshCandidates = (try? authorization?.auditDeletionCandidates(journal:journal,mappings:maps,shouldContinue:{!cancel.isCancelled})) ?? []
                    report.deletionCandidates = freshCandidates
                    report.displayCounts = .calculate(report.findings,deletionCandidates:freshCandidates)
                }
                summaryProgress.phase = "Salvataggio report"
                summaryProgress.comparisonStarted = nil
                progress(summaryProgress)
                let savedReport = report
                try? auditLog?.record(level:.info,rootID:"app",action:"audit_queue_preserved",message:settings.mode.label + ": nessuna operazione pendente confermata automaticamente; accodate " + String(report.queuedRepairs) + " differenze sicure; nessuna scrittura sul server")
 
                var storageWarning = ""
                do {
                    for snapshot in report.nameScans ?? [] { try journal.saveNameScan(snapshot) }
                } catch { storageWarning = " — impossibile salvare l’elenco dei nomi" }
                do {
                    let data = try JSONEncoder().encode(report)
                    try data.write(to:db.deletingLastPathComponent().appendingPathComponent("last-audit.json"),options:.atomic)
                } catch { storageWarning += " — impossibile salvare lo storico della verifica" }
                let warning = storageWarning
                try? auditLog?.record(level:.info,rootID:"app",action:"audit_finish",bytes:report.bytesRead,durationSeconds:report.seconds,message:"ID \(auditID) — Verifica conclusa: \(report.findings.count) elementi; \(report.queuedRepairs) riparazioni accodate" + warning)
                for (action, metrics) in [("metric_audit_source_scan", report.sourceMetrics),
                                           ("metric_audit_destination_scan", report.destinationMetrics)] {
                    guard let metrics else { continue }
                    try? auditLog?.record(level: .info, rootID: "app", action: action,
                        bytes: metrics.detectedBytes, durationSeconds: metrics.scanSeconds, message: "Scansione archivio")
                }
                if let seconds = report.comparisonSeconds {
                    try? auditLog?.record(level: .info, rootID: "app", action: "metric_audit_comparison",
                        bytes: report.bytesRead, durationSeconds: seconds, message: "Letture per hash e confronto")
                }
                for finding in report.findings where finding.kind == .uncertain {
                    try? auditLog?.record(level:.warning,rootID:finding.rootID,action:"audit_uncertain",relativePath:finding.relativePath,message:finding.detail.isEmpty ? "Confronto non verificabile" : finding.detail)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.finishAuditCancellationMetric(cycleID: auditID)
                    self.auditReport = savedReport
                    if rebuildToken != nil { self.queueRebuildRequired = false }
                    self.seedReady = false; self.seedVerifiedCount = 0
                    self.seedInspectedCount = 0; self.seedReadBytes = savedReport.bytesRead
                    self.seedStatus = "Verifica completata: operazioni già pendenti conservate"
                    self.auditStatus = "Verifica conclusa: " + String(savedReport.queuedRepairs) + " nuove operazioni accodate; coda preesistente conservata" + warning
                    self.auditProgress = nil
                    self.auditBusy = false
                    self.maintaining = false
                    self.onQueueChanged?()
                }
            } catch {
                let block=gate.auditBlockReason(auditToken)
                let explicit=cancel.wasExplicitlyCancelled
                let cause:String
                if explicit { cause="Verifica annullata: richiesta di arresto" }
                else if let block { cause="Verifica interrotta dal monitoraggio: " + block }
                else if let seed=error as? SeedVerificationError, case .cancelled=seed, !cancel.mayCommit {
                    cause="Verifica interrotta: inventario non pronto durante l’accodamento; transazione annullata"
                } else if let read = error as? InventoryReadLane.Failure {
                    cause = "Verifica interrotta in destinazione: " + (read.errorDescription ?? "")
                } else { cause="Verifica non riuscita: " + SyncDiagnostic.describe(error) }
                let context=SyncDiagnostic.clean("ID \(auditID) — \(cause); fase: \(last.phase); ultimo elemento: \(last.currentPath.isEmpty ? "—" : last.currentPath); confrontati: \(last.compared)/\(last.total); byte letti: \(last.bytesRead)",limit:3000)
                try? auditLog?.record(level:explicit ? .info : .error,rootID:currentRoot,action:"audit_error",bytes:max(0,last.bytesRead),durationSeconds:max(0,Date().timeIntervalSince(started)),message:context)
                DispatchQueue.main.async { [weak self] in
                    self?.finishAuditCancellationMetric(cycleID: auditID)
                    self?.auditStatus = cause
                    self?.refresh()
                    self?.auditProgress = nil
                    self?.auditBusy = false
                    self?.maintaining = false
                    self?.onQueueChanged?()
                }
            }
        }
    }

    func noteAuditSkipped(_ reason:String) {
        if !auditBusy { auditStatus = "Verifica programmata rinviata: " + reason }
    }

    func cancelArchiveAudit() {
        if auditBusy && auditCancelRequestedAt == nil {
            auditCancelRequestedAt = ProcessInfo.processInfo.systemUptime
        }
        auditCancel?.cancel()
        auditStatus = "Annullamento richiesto"
    }

    private func finishAuditCancellationMetric(cycleID: String) {
        guard let start = auditCancelRequestedAt else { return }
        auditCancelRequestedAt = nil
        Self.recordDiagnosticDuration("metric_audit_cancellation", seconds: ProcessInfo.processInfo.systemUptime - start, cycleID: cycleID)
    }

    nonisolated static func recordDiagnosticDuration(_ action: String, seconds: Double, cycleID: String? = nil) {
        DispatchQueue.global(qos: .utility).async {
            guard let path = try? databaseURL().path, let log = try? SyncActivityLog(path: path) else { return }
            log.cycleID = cycleID
            try? log.record(level: .info, rootID: "app", action: action, durationSeconds: seconds, message: "Durata diagnostica")
        }
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

    /// Reinstates an opt-in captured BEFORE a name-maintenance drain. This
    /// must never be called for a new automatic enablement: the regular
    /// setAutomaticCopiesEnabled(true) requires the operator's alert.
    /// Mirror authorization stays revoked until explicitly renewed.
    func restorePreviouslyAuthorizedAutomaticCopies() {
        guard !previewOnly, !active, !rectifyingNames else { return }
        automaticCopiesEnabled = true
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
                message: "Sessione di sincronizzazione abilitata — motore " + StageTransferEngine.applicationDefault().diagnosticName
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
                log.cycleID=cycleID
                log.currentJob=nil
                TechnicalFallbackLog.record(databasePath:database.path,cycleID:cycleID,action:"cycle_start",message:"Avvio ciclo — "+StageTransferEngine.applicationDefault().diagnosticName)
                let startedAt = Date()
                let startUptime = ProcessInfo.processInfo.systemUptime
                var progress = SyncLiveProgress(started: startedAt)
                progress.phase = "Controllo connessione"
                var totals = SyncHistoryTotals()
                var historyError = ""
                var history: SyncCycleHistory?
                var outcomeState = "suspended"
                var lastUpdate: TimeInterval = 0
                var profile = AdaptiveResourceProfile.sample()
                var lastProfileSample = ProcessInfo.processInfo.systemUptime
                let progressCadence = AdaptiveProgressCadence()
                let progressMailbox=SyncProgressMailbox()
                do {
                    let store = try SyncCycleHistory(path:database.path)
                    try store.markInterrupted(exceptSession:sessionID)
                    try store.begin(id:cycleID,sessionID:sessionID,at:startedAt,automatic:automatic)
                    history = store
                } catch { historyError = "Storico non disponibile: " + error.localizedDescription }
                func publish(force: Bool = false) {
                    let now = ProcessInfo.processInfo.systemUptime
                    // Refresh the power/thermal profile infrequently. Long
                    // transfers remain full speed; only UI traffic adapts.
                    if now - lastProfileSample >= 5 {
                        profile = AdaptiveResourceProfile.sample()
                        lastProfileSample = now
                    }
                    guard force || now-lastUpdate >= progressCadence.interval(profile: profile) else { return }
                    lastUpdate = now
                    // One pending main-actor update per cycle. New events
                    // replace the pending snapshot instead of enqueuing work.
                    guard progressMailbox.offer(progress) else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let snapshot=progressMailbox.take(),
                              let self, self.historySessionID==sessionID,
                              !cancellation.isCancelled else { return }
                        progressCadence.observeDeliveryDelay(
                            ProcessInfo.processInfo.systemUptime - now)
                        self.liveProgress=snapshot
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
                    log.currentJob=job
                    progress.inFlightCopyBytes = 0
                    progress.inFlightCopySeconds = 0
                    progress.currentFile = job.rootID + " / " + job.relativePath
                    progress.phase = job.kind == .delete ? "Verifica cancellazione" : "Preparazione operazione"
                    publish()
                }
                publish(force:true)
                defer {
                    worker?.onEvent = nil
                    worker?.onJobStarted = nil
                    worker?.onPhase = nil
                    worker?.onTransferProgress = nil
                    mirrorWorker?.onEvent = nil
                    mirrorWorker?.onJobStarted = nil
                    // Cycle-level diagnostics must not inherit the last
                    // file's job identity in the activity log.
                    log.currentJob=nil
                    if cancellation.endCycle() { outcomeState = "interrupted"
                        try? log.record(level: .info, rootID: "app", action: "cycle", message: "Ciclo interrotto su richiesta; operazioni in coda preservate")
                    }
                    if !historyError.isEmpty { outcomeState += "_history_incomplete" }
                    let endedAt = Date()
                    do {
                        try history?.finish(id:cycleID,at:endedAt,seconds:ProcessInfo.processInfo.systemUptime-startUptime,state:outcomeState)
                        try history?.prune(before:endedAt.addingTimeInterval(-365*86400))
                    } catch { historyError = "Storico incompleto: " + error.localizedDescription }
                    let saved = (try? history?.cycles(limit:1,finishedOnly:true).first) ?? nil
                    let finalStats = totals.stats
                    let maxUIDeliveryDelay = progressCadence.maximumDeliveryDelay
                    if maxUIDeliveryDelay >= 0.15 {
                        try? log.record(level:.info,rootID:"app",
                            action:"metric_progress_delivery_delay",
                            durationSeconds:maxUIDeliveryDelay,
                            message:"Massima attesa nella consegna del progresso UI")
                    }
                    let warning = historyError
                    let finalOutcome = outcomeState
                    TechnicalFallbackLog.record(databasePath:database.path,cycleID:cycleID,action:"cycle_end",message:finalOutcome)
                    log.cycleID=nil
                    if !automatic { timer.cancel() }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.historySessionID == sessionID else { return }
                        self.liveProgress = nil
                        self.interruptionRequested = false
                        if finalOutcome.hasPrefix("interrupted") { self.status = "Ciclo interrotto; operazioni rimanenti in coda." }
                        self.historyWarning = warning
                        self.lastRecordedCycle = saved?.id == cycleID ? saved : SyncCycleRecord(id:cycleID,sessionID:sessionID,started:startedAt,ended:endedAt,seconds:endedAt.timeIntervalSince(startedAt),state:finalOutcome.contains("history_incomplete") ? finalOutcome : finalOutcome + "_history_incomplete",automatic:automatic)
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
                try? log.record(level:.info,rootID:"app",action:"cycle_start",message:"Inizio ciclo; controllo destinazioni e coda")
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
                    try? journal.clearVerifiedContentCache()
                    try? journal.clearUploadRetries()
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
                    guard try journal.queueRebuildToken() == nil else { throw JournalError.database("Avvia una nuova verifica archivio prima di sincronizzare") }
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
                            journal: journal, log: log, mappings: maps,
                            stageEngine: .applicationDefault()
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
                            protections: protections,
                            transferEngine: .applicationDefault()
                        )
                        mirrorWorker?.operationAllowed = { gate.isReady && !cancellation.isCancelled }
                        try? log.record(
                            level: .info, rootID: "app", action: "mirror_armed",
                            message: policy.recoveryEnabled
                                ? "Mirror attivato con recupero" : "Mirror attivato senza recupero"
                        )
                    }
                    try mirrorWorker?.verifyBeforeSynchronization()
                    if StageTransferEngine.applicationDefault().diagnosticName == "rclone-direct" { try journal.clearLegacyPublicationRetries() }
                    let highWater = try journal.queueSequence()
                    progress.planned = try journal.plannedUploadCount(throughID:highWater)
                    progress.planned += try mirrorWorker?.plannedCount(throughID:highWater) ?? 0
                    try? log.record(level:.info,rootID:"app",action:"queue_plan",message:"Operazioni pianificate: \(progress.planned) — motore " + StageTransferEngine.applicationDefault().diagnosticName)
                    progress.workStarted = Date()
                    worker.onEvent = observe
                    worker.onJobStarted = jobStarted
                    worker.onTransferProgress = { bytes, seconds in
                        progress.inFlightCopyBytes = bytes
                        progress.inFlightCopySeconds = seconds
                        publish()
                    }
                    worker.onPhase = { phase in
                        if phase != "Trasferimento" {
                            progress.inFlightCopyBytes = 0
                            progress.inFlightCopySeconds = 0
                        }
                        progress.phase = phase
                        publish(force:phase == "Trasferimento" || phase == "Backup di sicurezza")
                    }
                    mirrorWorker?.onEvent = observe
                    mirrorWorker?.onJobStarted = jobStarted
                    progress.phase = "Trasferimento"
                    publish(force:true)
                    var lastStatusUpdate: TimeInterval = 0
                    let summary = try worker.runCycle(
                        enabled: true, pageSize: 100, throughID: highWater,
                        shouldContinue: { !cancellation.isCancelled && gate.isReady },
                        onProgress: { progress in
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now - lastStatusUpdate >= 0.25 else { return }
                            lastStatusUpdate = now
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
                    TechnicalFallbackLog.record(databasePath:database.path,cycleID:cycleID,action:"cycle_suspended",message:SyncDiagnostic.describe(error))
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
            if let path=try? Self.databaseURL().path {
                TechnicalFallbackLog.record(databasePath:path,action:"session_start_failed",message:SyncDiagnostic.describe(error))
            }
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
        maintenanceStatus = "Annullamento richiesto… attendo il punto sicuro."
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

    func setDSStoreExclusionAfterDrain(_ enabled:Bool,completion:@escaping @MainActor (Bool)->Void) {
        guard !previewOnly,!active,!auditBusy,!seedBusy else { completion(false); return }
        maintaining=true
        auditRevision += 1
        invalidateSeedReport()
        queue.async { [weak self] in
            do {
                let db=try Self.databaseURL()
                let journal=try ChangeJournal(path:db.path)
                try journal.requireQueueRebuild()
                UserDefaults.standard.set(enabled,forKey:FileExclusionPolicy.preferenceKey)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion(false); return }
                    self.ignoreDSStore=enabled
                    self.queueRebuildRequired=true
                    self.auditReport=nil
                    self.auditStatus="Esclusioni modificate: nuova verifica necessaria"
                    self.maintaining=false
                    completion(true)
                }
            } catch {
                let detail=SyncDiagnostic.describe(error)
                DispatchQueue.main.async { [weak self] in
                    self?.maintenanceStatus="Esclusioni non modificate: "+detail
                    self?.maintaining=false
                    completion(false)
                }
            }
        }
    }

    /// Called by the runtime only after the copy and monitor queues drain.
    func resetPendingQueueAfterDrain(completion: @escaping @MainActor (Bool) -> Void) {
        guard !previewOnly, !active, !auditBusy, !seedBusy else { completion(false); return }
        maintaining = true
        maintenanceStatus = "Backup e svuotamento della coda…"
        auditRevision += 1
        invalidateSeedReport()
        queue.async { [weak self] in
            do {
                let db = try Self.databaseURL()
                let id=UUID().uuidString
                let parent = db.deletingLastPathComponent().appendingPathComponent("queue-reset-backups",isDirectory:true)
                try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let old = db.deletingLastPathComponent().appendingPathComponent("last-audit.json")
                if FileManager.default.fileExists(atPath:old.path) {
                    try FileManager.default.copyItem(at:old,to:parent.appendingPathComponent(id+"-last-audit.json"))
                }
                let journal = try ChangeJournal(path:db.path)
                let count = try journal.resetPendingQueue(backup:parent.appendingPathComponent(id+".sqlite"))
                try? SyncActivityLog(path:db.path).record(level:.info,rootID:"app",action:"queue_reset",message:"\(count) operazioni ritirate; backup verificato, nuova verifica manuale obbligatoria")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion(false); return }
                    self.queueRebuildRequired=true
                    self.auditReport=nil
                    self.auditStatus="Coda svuotata: avvia una nuova verifica archivio"
                    self.maintenanceStatus="Coda svuotata (\(count) operazioni). Backup verificato."
                    self.maintaining=false
                    self.onQueueChanged?()
                    completion(true)
                }
            } catch {
                let detail=SyncDiagnostic.describe(error)
                DispatchQueue.main.async { [weak self] in
                    self?.maintenanceStatus="Svuotamento non riuscito: "+detail
                    self?.maintaining=false
                    completion(false)
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

    // An independent read-only WAL connection must not wait behind the
    // serial transfer worker. Coalesce refresh requests and keep copy state
    // separate from a transient history read error.
    private let logReadQueue=DispatchQueue(label:"macsync.activity.reader",qos:.utility)
    private var logReadBusy=false
    @Published private(set) var logReadWarning=""
    @Published private(set) var exportingLog=false
    func refresh() {
        guard !previewOnly,!logReadBusy else { return }
        logReadBusy=true
        let level=SyncLogLevel(rawValue:logLevel), search=logSearch, levelKey=logLevel
        logReadQueue.async { [weak self] in
            var entries:[SyncLogEntry]=[]
            var warning=""
            do {
                let db=try Self.databaseURL()
                if FileManager.default.fileExists(atPath:db.path) {
                    entries=try SyncActivityLog(path:db.path,readOnly:true).recent(limit:300,level:level,search:search)
                }
            } catch { warning="Registro temporaneamente non disponibile; dati precedenti conservati" }
            let snapshot=entries, errorText=warning
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.logReadBusy=false
                guard self.logLevel==levelKey,self.logSearch==search else { self.refresh();return }
                self.logReadWarning=errorText
                if errorText.isEmpty && self.recentEntries != snapshot { self.recentEntries=snapshot }
            }
        }
    }

    func exportLog() {
        guard !exportingLog else { return }
        // The save dialog is interactive, but SQLite reads and file writes
        // must never occupy the main actor, especially while a scan runs.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacSync_sync_log.tsv"
        panel.title = "Esporta registro sincronizzazioni"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportingLog = true
        let level = SyncLogLevel(rawValue:logLevel), search = logSearch
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result: String
            do {
                let path = try Self.databaseURL().path
                let text = try SyncActivityLog(path:path,readOnly:true)
                    .exportText(limit:5000,level:level,search:search)
                try text.write(to:url,atomically:true,encoding:.utf8)
                result = "Registro esportato (controlla i nomi dei file prima di condividerlo)"
            } catch {
                result = "Esportazione fallita: " + error.localizedDescription
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exportingLog = false
                self.status = result
            }
        }
    }
}
