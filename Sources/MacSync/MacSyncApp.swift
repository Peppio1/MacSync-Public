import AppKit
import SwiftUI
import MacSyncCore

/// Configuration and monitoring are local-only in this prototype.
/// NO SMB operations, remote copies or remote deletions exist.
@MainActor
final class MacSyncViewModel: ObservableObject {
    @Published var photoUploads = UserDefaults.standard.string(forKey: "MacSync.photoUploads") ?? ""
    @Published var photoEditing = UserDefaults.standard.string(forKey: "MacSync.photoEditing") ?? ""
    @Published var message = "Monitoraggio non configurato"
    @Published var monitoring = false
    @Published var pendingCount = 0

    private lazy var service = LocalMonitorService { [weak self] update in
        DispatchQueue.main.async { [weak self] in
            self?.message = update.message
            self?.monitoring = update.monitoring
            self?.pendingCount = update.pendingChanges
        }
    }

    init() {
        // Start automatically when the app is opened, but configuring
        // launch-at-login is a later project phase.
        DispatchQueue.main.async { [weak self] in
            if self?.photoUploads.isEmpty == false || self?.photoEditing.isEmpty == false {
                self?.startMonitoring()
            }
        }
    }

    func chooseFolder(_ slot: Int) {
        let panel = NSOpenPanel()
        panel.title = slot == 1 ? "Seleziona Cartella_1" : "Seleziona Cartella_2"
        panel.message = "Scegli la cartella locale sull'iMac, non la cartella SMB del server."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if slot == 1 {
            photoUploads = url.standardizedFileURL.path
            UserDefaults.standard.set(photoUploads, forKey: "MacSync.photoUploads")
        } else {
            photoEditing = url.standardizedFileURL.path
            UserDefaults.standard.set(photoEditing, forKey: "MacSync.photoEditing")
        }
        startMonitoring()
    }

    func startMonitoring() {
        var roots: [MonitorRoot] = []
        if !photoUploads.isEmpty {
            roots.append(MonitorRoot(id: "photo-uploads", url: URL(fileURLWithPath: photoUploads)))
        }
        if !photoEditing.isEmpty {
            roots.append(MonitorRoot(id: "photo-editing", url: URL(fileURLWithPath: photoEditing)))
        }
        guard !roots.isEmpty else {
            message = "Seleziona almeno una cartella"
            return
        }
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("MacSync", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let db = directory.appendingPathComponent("inventory.sqlite").path
            monitoring = false
            message = "Avvio inventario locale…"
            service.start(roots: roots, databasePath: db)
        } catch {
            message = "Errore avvio: " + error.localizedDescription
            monitoring = false
        }
    }

    func stopMonitoring() {
        service.stop()
    }
}

@main
struct MacSyncApp: App {
    @StateObject private var model = MacSyncViewModel()
    @StateObject private var uploader = ExperimentalUploadController()

    var body: some Scene {
        MenuBarExtra("MacSync", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                Text("MacSync").font(.title3.bold())

                Label(
                    model.monitoring ? "Monitoraggio locale attivo" : "Monitoraggio non attivo",
                    systemImage: model.monitoring ? "checkmark.circle.fill" : "pause.circle"
                )
                .foregroundStyle(model.monitoring ? .green : .orange)

                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cartella_1").font(.caption.bold())
                    Text(model.photoUploads.isEmpty ? "Da configurare" : model.photoUploads)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Button("Seleziona cartella…") {
                        uploader.stop()
                        model.chooseFolder(1)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cartella_2").font(.caption.bold())
                    Text(model.photoEditing.isEmpty ? "Da configurare" : model.photoEditing)
                        .font(.caption2)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                    Button("Seleziona cartella…") {
                        uploader.stop()
                        model.chooseFolder(2)
                    }
                }

                Divider()

                HStack {
                    Text("Operazioni locali registrate")
                    Spacer()
                    Text(model.pendingCount.formatted()).monospacedDigit()
                }.font(.caption)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("SMB — SOLO TEST, credenziali nel Portachiavi").font(.caption.bold())
                    Text("Server SMB (nome host o IP VPN)")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("server-esempio", text: $uploader.host)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Text("Nome utente SMB")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("utente", text: $uploader.username)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Text("Dominio / gruppo di lavoro")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("WORKGROUP", text: $uploader.domain)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Text("Nome condivisione SMB (copie isolate in MacSync_TEST_ONLY)")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("CondivisioneDiProva", text: $uploader.share)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Text("Password SMB (salvata nel Portachiavi)")
                        .font(.caption2).foregroundStyle(.secondary)
                    SecureField("Inserisci per salvare o aggiornare", text: $uploader.password)
                        .textFieldStyle(.roundedBorder).font(.caption)

                    Text("Percorso eseguibile rclone sul Mac")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("/opt/homebrew/bin/rclone",
                              text: $uploader.rcloneExecutable)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Text(uploader.status)
                        .font(.caption2)
                        .foregroundStyle(uploader.active ? .green : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Anteprima iniziale (sola lettura)") {
                        uploader.inspectInitialBaseline(
                            photoUploads: model.photoUploads,
                            photoEditing: model.photoEditing
                        )
                    }
                    .disabled(uploader.active)

                    Text(uploader.baselineStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Salva") { uploader.save() }
                        if uploader.active {
                            Button("Ferma copie") { uploader.stop() }
                        } else {
                            Button("Attiva copie di prova") {
                                uploader.start(
                                    photoUploads: model.photoUploads,
                                    photoEditing: model.photoEditing
                                )
                            }
                        }
                    }
                }

                Text("Cancellazioni sul server NON disponibili. Usare solo dati fittizi; nessuna password viene salvata su GitHub o in rclone.conf.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Avvia / riavvia") { model.startMonitoring() }
                    Button("Arresta") {
                        uploader.stop()
                        model.stopMonitoring()
                    }
                    Spacer()
                    Button("Esci") {
                        uploader.stop()
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(16)
            .frame(width: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
