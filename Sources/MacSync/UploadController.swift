import AppKit
import Foundation
import MacSyncCore

/// Copy-only TEST mode. SMB passwords are kept in the macOS Keychain.
/// This screen does NOT enable remote deletions or unattended production use.
@MainActor
final class ExperimentalUploadController: ObservableObject {
    @Published var host = UserDefaults.standard.string(forKey: "MacSync.smbHost") ?? ""
    @Published var username = UserDefaults.standard.string(forKey: "MacSync.smbUsername") ?? ""
    @Published var domain = UserDefaults.standard.string(forKey: "MacSync.smbDomain") ?? "WORKGROUP"
    @Published var share = UserDefaults.standard.string(forKey: "MacSync.smbShare") ?? ""
    @Published var password = ""
    @Published var rcloneExecutable = UserDefaults.standard.string(
        forKey: "MacSync.rcloneExecutable"
    ) ?? "/opt/homebrew/bin/rclone"
    @Published var status = "Copie disattivate. Credenziali nel Portachiavi macOS."
    @Published var active = false

    private let secretStore = SMBSecretStore()
    private let backgroundQueue = DispatchQueue(
        label: "macsync.testupload.worker", qos: .utility
    )
    private var timer: DispatchSourceTimer?

    @discardableResult
    func save() -> Bool {
        do {
            _ = try SMBSecureProfile(
                host: host, username: username, domain: domain, share: share
            )
            if !password.isEmpty {
                try secretStore.save(password: password)
                password = "" // Do not retain typed password in the UI after saving
            }
            guard try secretStore.load() != nil else {
                status = "Inserisci una password SMB e premi Salva"
                return false
            }
            UserDefaults.standard.set(host, forKey: "MacSync.smbHost")
            UserDefaults.standard.set(username, forKey: "MacSync.smbUsername")
            UserDefaults.standard.set(domain, forKey: "MacSync.smbDomain")
            UserDefaults.standard.set(share, forKey: "MacSync.smbShare")
            UserDefaults.standard.set(rcloneExecutable, forKey: "MacSync.rcloneExecutable")
            status = "Impostazioni salvate. Password custodita dal Portachiavi macOS."
            return true
        } catch {
            status = "Impostazioni non valide: " + error.localizedDescription
            return false
        }
    }

    func start(photoUploads: String, photoEditing: String) {
        stop()
        guard save() else { return }

        let alert = NSAlert()
        alert.messageText = "Attivare le copie SMB sperimentali?"
        alert.informativeText = """
        Questa versione può COPIARE e SOVRASCRIVERE file sul server, ma non
        eliminarli. Ogni file viene caricato prima in una cartella temporanea.
        Usa ESCLUSIVAMENTE condivisioni e cartelle DI PROVA.
        I tentativi interrotti possono lasciare file temporanei sul server.
        L'attivazione vale soltanto per la sessione corrente.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Attiva copie di prova")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else {
            status = "Copie disattivate"
            return
        }

        do {
            let profile = try SMBSecureProfile(
                host: host, username: username, domain: domain, share: share
            )
            let executable = URL(fileURLWithPath: rcloneExecutable)
            guard FileManager.default.isExecutableFile(atPath: rcloneExecutable) else {
                throw UploadError.noRcloneBinary
            }
            guard let secret = try secretStore.load() else {
                throw KeychainSecretError.invalidSecret
            }
            let obscured = try RclonePasswordObscurer.obscure(
                password: secret, executable: executable
            )
            let environment = try profile.environment(obscuredPassword: obscured)

            var mappings: [SMBUploadMapping] = []
            if !photoUploads.isEmpty {
                mappings.append(try SMBUploadMapping(
                    rootID: "photo-uploads",
                    localRoot: URL(fileURLWithPath: photoUploads),
                    remoteRoot: profile.remoteParent + "/Cartella_1"
                ))
            }
            if !photoEditing.isEmpty {
                mappings.append(try SMBUploadMapping(
                    rootID: "photo-editing",
                    localRoot: URL(fileURLWithPath: photoEditing),
                    remoteRoot: profile.remoteParent + "/Cartella_2"
                ))
            }
            guard !mappings.isEmpty else {
                throw UploadError.invalidMapping("Seleziona prima una cartella locale")
            }

            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("MacSync")
            let dbURL = support.appendingPathComponent("inventory.sqlite")
            guard FileManager.default.fileExists(atPath: dbURL.path) else {
                throw UploadError.invalidMapping(
                    "Inventario non disponibile: avvia il monitoraggio locale"
                )
            }
            let journal = try ChangeJournal(path: dbURL.path)
            let runner = ProcessRcloneExecutor(
                executable: executable, additionalEnvironment: environment
            )
            let worker = try SelectiveSMBCopyWorker(
                journal: journal, runner: runner, mappings: mappings
            )
            let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
            timer.schedule(
                deadline: .now() + .seconds(10),
                repeating: .seconds(300),
                leeway: .seconds(5)
            )
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
                    DispatchQueue.main.async { [weak self] in
                        self?.status = "Copia sospesa: " + error.localizedDescription
                    }
                }
            }
            self.timer = timer
            active = true
            status = "Copie sperimentali attive (ogni 5 minuti)"
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
        // A file already being transferred may finish before the worker stops.
        status = "Nuove copie arrestate (il trasferimento in corso può terminare)"
    }
}
