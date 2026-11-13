import AppKit
import SwiftUI
import MacSyncCore

/// Deliberately TEST-only: foreground opt-in for the current app session.
/// macOS Finder must mount SMB shares and supply its saved credentials.
@MainActor
final class MountedCopyController: ObservableObject {
    @Published var status = "Copie ferme: puoi selezionare cartelle locali o SMB già montate."
    @Published var active = false

    // Preferences describe the desired policy only. Actual destructive work
    // remains OFF until explicit activation of the current test session.
    @Published var mirrorEnabled = UserDefaults.standard.bool(forKey: "MacSync.mirrorEnabled") {
        didSet { UserDefaults.standard.set(mirrorEnabled, forKey: "MacSync.mirrorEnabled") }
    }
    @Published var mirrorRecovery = (UserDefaults.standard.object(forKey: "MacSync.mirrorRecovery") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(mirrorRecovery, forKey: "MacSync.mirrorRecovery") }
    }
    /// 0 = never delete recovery files automatically; 1...30 = days.
    @Published var mirrorRetention = UserDefaults.standard.object(forKey: "MacSync.mirrorRetention") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(mirrorRetention, forKey: "MacSync.mirrorRetention") }
    }
    @Published var mirrorStatus = "Cancellazioni speculari non attive"
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
    private var seedReport: SeedVerificationReport?
    private var seedVerifier: SeededArchiveVerifier?
    private var seedCancel: SeedVerificationCancellation?
    private var maintenanceCandidates: [(mapping: MountedFolderMapping, inspection: StagingInspection)] = []

    private let queue = DispatchQueue(label: "macsync.mounted.copy.serial", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var mirrorCancellation: MirrorDeletionCancellation?

    private static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MacSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("inventory.sqlite")
    }

    func start(
        sources: [(id: String, path: String, destination: String, expected: VolumeFingerprint?)]
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
        warning.messageText = policy.enabled
            ? "Attivare copie e cancellazioni speculari DI PROVA?"
            : "Abilitare le copie di prova?"
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

        Le cancellazioni precedenti a questa attivazione non saranno eseguite.
        La protezione blocca cancellazioni massive e sorgenti/volumi anomali.
        Questa scelta è valida soltanto per la sessione corrente.
        """
        warning.addButton(withTitle: policy.enabled
            ? "Conferma copia e cancellazione di prova"
            : "Attiva copie di prova")
        warning.addButton(withTitle: "Annulla")
        guard warning.runModal() == .alertFirstButtonReturn else {
            status = "Copie non attivate"
            return
        }

        do {
            let configured = sources.filter { !$0.path.isEmpty || !$0.destination.isEmpty }
            guard !configured.isEmpty,
                  configured.allSatisfy({ !$0.path.isEmpty && !$0.destination.isEmpty }) else {
                throw MountedCopyError.invalidMapping
            }
            let maps = try configured.map {
                try MountedFolderMapping(
                    rootID: $0.id,
                    source: URL(fileURLWithPath: $0.path),
                    target: URL(fileURLWithPath: $0.destination),
                    expectedTargetVolume: $0.expected
                )
            }
            let database = try Self.databaseURL()
            guard FileManager.default.fileExists(atPath: database.path) else {
                throw JournalError.database("Avvia prima il monitoraggio delle sorgenti")
            }
            let journal = try ChangeJournal(path: database.path)
            let log = try SyncActivityLog(path: database.path)
            let worker = try MountedFolderCopyWorker(
                journal: journal, log: log, mappings: maps
            )
            let recoveryManifest = try RecoveryManifest(path: database.path)
            // Initial source audit can be expensive on a large archive.
            // Create the armed deletion worker on the serial background queue.
            let cancellation = MirrorDeletionCancellation()
            mirrorCancellation = policy.enabled ? cancellation : nil
            var mirrorWorker: MirrorDeletionWorker?
            try log.record(
                level: .info, rootID: "app", action: "session",
                message: "Sessione di copie di prova abilitata"
            )
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(3),
                           repeating: .seconds(300), leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                do {
                    let startedAt = Date()
                    if policy.enabled && mirrorWorker == nil {
                        mirrorWorker = try MirrorDeletionWorker(
                            journal: journal, manifest: recoveryManifest,
                            log: log, mappings: maps, policy: policy,
                            cancellation: cancellation
                        )
                        try? log.record(
                            level: .info, rootID: "app", action: "mirror_armed",
                            message: policy.recoveryEnabled
                                ? "Mirror di prova attivato con recupero" : "Mirror di prova attivato senza recupero"
                        )
                    }
                    let summary = try worker.runOnce(enabled: true, maxJobs: 50)
                    var mirrorSummary = MirrorDeletionSummary()
                    var expired = 0
                    if let mirrorWorker {
                        mirrorSummary = try mirrorWorker.runOnce(maxFiles: 25)
                        expired = try mirrorWorker.pruneExpiredRecovery()
                    }
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
                    let result = "Ultimo ciclo: \(summary.copied) copie, "
                        + "\(summary.deferred) rimandate, \(summary.failed) errori, "
                        + "\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) trasferiti."
                    DispatchQueue.main.async { [weak self] in
                        self?.status = result
                        self?.mirrorStatus = policy.enabled ? mirrorDetails : "Cancellazioni speculari disattivate"
                        self?.refresh()
                    }
                } catch {
                    try? log.record(
                        level: .error, rootID: "app", action: "cycle",
                        message: "Errore generale durante il ciclo di copia"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.status = "Copia sospesa: " + error.localizedDescription
                        self?.refresh()
                    }
                }
            }
            self.timer = timer
            active = true
            mirrorStatus = policy.enabled
                ? "Configurazione armata: la verifica delle sorgenti avverrà al primo ciclo"
                : "Cancellazioni speculari disattivate"
            status = "Copie di prova attive; controllo ogni cinque minuti"
            refresh()
            timer.resume()
        } catch {
            active = false
            status = "Impossibile avviare: " + error.localizedDescription
        }
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
        Destinazione e leggerà integralmente entrambi i file. Per 100 GB
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
        guard !active else {
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
