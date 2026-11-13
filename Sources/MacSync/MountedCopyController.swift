import AppKit
import SwiftUI
import MacSyncCore

/// Deliberately TEST-only: foreground opt-in for the current app session.
/// macOS Finder must mount SMB shares and supply its saved credentials.
@MainActor
final class MountedCopyController: ObservableObject {
    @Published var status = "Copie ferme: puoi selezionare cartelle locali o SMB già montate."
    @Published var active = false
    @Published var recentEntries: [SyncLogEntry] = []

    private let queue = DispatchQueue(label: "macsync.mounted.copy.serial", qos: .utility)
    private var timer: DispatchSourceTimer?

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
        stop()

        let warning = NSAlert()
        warning.alertStyle = .warning
        warning.messageText = "Abilitare le copie di prova?"
        warning.informativeText = """
        MacSync può creare e SOVRASCRIVERE file nella cartella di destinazione
        che hai scelto. Seleziona ESCLUSIVAMENTE cartelle di prova vuote o
        contenenti dati sintetici. Nessuna cancellazione speculare è attiva.

        L'attivazione è valida solo per questa sessione. Le credenziali SMB
        sono gestite da macOS: la condivisione deve essere già montata.
        """
        warning.addButton(withTitle: "Attiva copie di prova")
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
            try log.record(
                level: .info, rootID: "app", action: "session",
                message: "Sessione di copie di prova abilitata"
            )
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(3),
                           repeating: .seconds(300), leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                do {
                    let summary = try worker.runOnce(enabled: true, maxJobs: 50)
                    let result = "Ultimo ciclo: \(summary.copied) copie, "
                        + "\(summary.deferred) rimandate, \(summary.failed) errori, "
                        + "\(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)) trasferiti."
                    DispatchQueue.main.async { [weak self] in
                        self?.status = result
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
            status = "Copie di prova attive; controllo ogni cinque minuti"
            refresh()
            timer.resume()
        } catch {
            active = false
            status = "Impossibile avviare: " + error.localizedDescription
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        active = false
        status = "Copie fermate. Un trasferimento già avviato può terminare."
    }

    func refresh() {
        do {
            let database = try Self.databaseURL()
            guard FileManager.default.fileExists(atPath: database.path) else {
                recentEntries = []
                return
            }
            recentEntries = try SyncActivityLog(path: database.path).recent(limit: 200)
        } catch {
            status = "Impossibile leggere il registro: " + error.localizedDescription
        }
    }

    func exportLog() {
        do {
            let text = try SyncActivityLog(path: Self.databaseURL().path)
                .exportText(limit: 5000)
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
