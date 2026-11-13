import AppKit
import Foundation
import MacSyncCore

/// Session-only opt-in for TEST COPIES. The production unattended workflow,
/// credentials-in-Keychain and non-destructive bootstrap are NOT released yet.
@MainActor
final class ExperimentalUploadController: ObservableObject {
    @Published var remoteParent = UserDefaults.standard.string(
        forKey: "MacSync.remoteParent"
    ) ?? ""
    @Published var rcloneExecutable = UserDefaults.standard.string(
        forKey: "MacSync.rcloneExecutable"
    ) ?? "/opt/homebrew/bin/rclone"
    @Published var status = "Copie SMB disattivate: nessun collegamento al server"
    @Published var active = false

    private let backgroundQueue = DispatchQueue(
        label: "macsync.testupload.worker", qos: .utility
    )
    private var timer: DispatchSourceTimer?

    func save() {
        // These are non-secret paths/aliases. Credentials belong to the
        // local rclone configuration, not GitHub or UserDefaults.
        UserDefaults.standard.set(remoteParent, forKey: "MacSync.remoteParent")
        UserDefaults.standard.set(rcloneExecutable, forKey: "MacSync.rcloneExecutable")
        status = "Impostazioni locali memorizzate; copie non ancora attive"
    }

    func start(photoUploads: String, photoEditing: String) {
        stop()
        save()

        let answer = NSAlert()
        answer.messageText = "Attivare le copie SMB sperimentali?"
        answer.informativeText = """
        Questa versione può COPIARE file sul server, ma non può eliminarli.
        Usare esclusivamente cartelle e condivisioni DI PROVA; non è ancora
        stato effettuato il collaudo sulla VPN di test.
        La sessione si disattiva quando chiudi l'app.
        """
        answer.alertStyle = .warning
        answer.addButton(withTitle: "Attiva per questa sessione")
        answer.addButton(withTitle: "Annulla")
        guard answer.runModal() == .alertFirstButtonReturn else {
            status = "Copie disattivate"
            return
        }

        do {
            guard !remoteParent.isEmpty else {
                throw UploadError.invalidMapping("Specifica remote:share di test")
            }
            guard FileManager.default.isExecutableFile(atPath: rcloneExecutable) else {
                throw UploadError.noRcloneBinary
            }

            var mappings: [SMBUploadMapping] = []
            if !photoUploads.isEmpty {
                mappings.append(try SMBUploadMapping(
                    rootID: "photo-uploads",
                    localRoot: URL(fileURLWithPath: photoUploads),
                    remoteRoot: remoteParent + "/Cartella_1"
                ))
            }
            if !photoEditing.isEmpty {
                mappings.append(try SMBUploadMapping(
                    rootID: "photo-editing",
                    localRoot: URL(fileURLWithPath: photoEditing),
                    remoteRoot: remoteParent + "/Cartella_2"
                ))
            }
            guard !mappings.isEmpty else {
                throw UploadError.invalidMapping("Prima scegli una cartella locale")
            }

            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("MacSync")
            let dbURL = support.appendingPathComponent("inventory.sqlite")
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                throw UploadError.invalidMapping(
                    "Inventario non presente: avvia prima il monitoraggio locale"
                )
            }
            let journal = try ChangeJournal(path: dbURL.path)
            let runner = ProcessRcloneExecutor(executable: URL(fileURLWithPath: rcloneExecutable))
            let worker = try SelectiveSMBCopyWorker(
                journal: journal, runner: runner, mappings: mappings
            )

            let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
            timer.schedule(deadline: .now() + .seconds(10),
                           repeating: .seconds(300),
                           leeway: .seconds(5))
            timer.setEventHandler { [weak self] in
                do {
                    let result = try worker.runOnce(enabled: true, maxJobs: 100)
                    let message = "Ultimo controllo: \(result.succeeded) copie, "
                        + "\(result.deferred) rimandate, \(result.failed) errori. "
                        + "Nessuna cancellazione remota."
                    DispatchQueue.main.async { [weak self] in
                        self?.status = message
                    }
                } catch {
                    // Avoid writing raw command arguments or SMB credentials
                    // to user-facing logs.
                    DispatchQueue.main.async { [weak self] in
                        self?.status = "Copia sospesa: " + error.localizedDescription
                    }
                }
            }
            self.timer = timer
            active = true
            status = "Copie di prova attive; prossima elaborazione automatica"
            timer.resume()
        } catch {
            active = false
            status = "Copie disattivate: " + error.localizedDescription
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        active = false
        // An already-running copy may finish. Stop prevents NEW cycles.
        status = "Nuove copie arrestate (un eventuale trasferimento in corso termina)"
    }
}
