import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacSyncCore

/// Two independently configurable source/target folder pairs. Either target
/// may be a LOCAL macOS folder or an already mounted Finder SMB share.
/// No passwords, domains or server addresses are collected by this UI.
@MainActor
final class MacSyncViewModel: ObservableObject {
    @Published var photoUploads = UserDefaults.standard.string(forKey: "MacSync.photoUploads") ?? ""
    @Published var photoEditing = UserDefaults.standard.string(forKey: "MacSync.photoEditing") ?? ""
    @Published var destinationUploads = UserDefaults.standard.string(forKey: "MacSync.targetUploads") ?? ""
    @Published var destinationEditing = UserDefaults.standard.string(forKey: "MacSync.targetEditing") ?? ""
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
        DispatchQueue.main.async { [weak self] in
            if self?.photoUploads.isEmpty == false || self?.photoEditing.isEmpty == false {
                self?.startMonitoring()
            }
        }
    }

    private static func supportDatabase() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("MacSync", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("inventory.sqlite")
    }

    func folderPath(slot: Int, destination: Bool) -> String {
        switch (slot, destination) {
        case (1, false): return photoUploads
        case (1, true): return destinationUploads
        case (2, false): return photoEditing
        case (2, true): return destinationEditing
        default: return ""
        }
    }

    private func key(slot: Int, destination: Bool) -> String {
        if destination { return slot == 1 ? "MacSync.targetUploads" : "MacSync.targetEditing" }
        return slot == 1 ? "MacSync.photoUploads" : "MacSync.photoEditing"
    }

    private func volumeKey(slot: Int) -> String {
        slot == 1 ? "MacSync.targetVolumeUploads" : "MacSync.targetVolumeEditing"
    }

    private func expectedVolume(slot: Int) -> VolumeFingerprint? {
        guard let bytes = UserDefaults.standard.data(forKey: volumeKey(slot: slot)) else {
            return nil
        }
        return try? JSONDecoder().decode(VolumeFingerprint.self, from: bytes)
    }

    func configuredPairs() -> [(
        id: String, path: String, destination: String, expected: VolumeFingerprint?
    )] {
        [
            (id: "photo-uploads", path: photoUploads,
             destination: destinationUploads, expected: expectedVolume(slot: 1)),
            (id: "photo-editing", path: photoEditing,
             destination: destinationEditing, expected: expectedVolume(slot: 2))
        ]
    }

    func chooseFolder(slot: Int, destination: Bool) {
        let panel = NSOpenPanel()
        panel.title = destination ? "Seleziona Destinazione" : "Seleziona Sorgente"
        panel.message = destination
            ? "Seleziona una cartella locale oppure una condivisione SMB già montata dal Finder."
            : "Seleziona la cartella dei file originali da monitorare."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url: url, slot: slot, destination: destination)
    }

    func setFolder(url: URL, slot: Int, destination: Bool) {
        do {
            guard slot == 1 || slot == 2, url.isFileURL else {
                throw MountedCopyError.invalidMapping
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw MountedCopyError.rootUnavailable
            }
            // FSEvents is intended for sources on the Mac itself; monitoring
            // an SMB source would not provide the same reliable event stream.
            if !destination && (try VolumeFingerprint.read(at: resolved)).isNetworkVolume {
                throw MountedCopyError.invalidMapping
            }
            let old = folderPath(slot: slot, destination: destination)
            if old == resolved.path { return }

            let newSources = [
                !destination && slot == 1 ? resolved.path : photoUploads,
                !destination && slot == 2 ? resolved.path : photoEditing
            ].filter { !$0.isEmpty }
            let newTargets = [
                destination && slot == 1 ? resolved.path : destinationUploads,
                destination && slot == 2 ? resolved.path : destinationEditing
            ].filter { !$0.isEmpty }

            // Detect loops even between DIFFERENT folder pairs.
            for src in newSources {
                for dst in newTargets {
                    if src == dst || src.hasPrefix(dst + "/") ||
                       dst.hasPrefix(src + "/") {
                        throw MountedCopyError.invalidMapping
                    }
                }
            }
            // Two destinations must not overlap; two sources must not overlap.
            for group in [newSources, newTargets] where group.count > 1 {
                for i in 0..<group.count {
                    for j in (i + 1)..<group.count {
                        let a = group[i]
                        let b = group[j]
                        if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
                            throw MountedCopyError.invalidMapping
                        }
                    }
                }
            }
            if old.isEmpty == false && !destination {
                let confirm = NSAlert()
                confirm.messageText = "Cambiare la cartella sorgente?"
                confirm.informativeText = """
                MacSync azzererà soltanto l'inventario locale e i job in attesa
                della precedente sorgente. Nessun file sarà cancellato né
                sull'iMac né sulla destinazione. La nuova cartella verrà indicizzata.
                """
                confirm.alertStyle = .warning
                confirm.addButton(withTitle: "Modifica sorgente")
                confirm.addButton(withTitle: "Annulla")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }

            if destination {
                let fingerprint = try VolumeFingerprint.read(at: resolved)
                UserDefaults.standard.set(
                    try JSONEncoder().encode(fingerprint),
                    forKey: volumeKey(slot: slot)
                )
                if slot == 1 { destinationUploads = resolved.path }
                else { destinationEditing = resolved.path }
            } else {
                if slot == 1 { photoUploads = resolved.path }
                else { photoEditing = resolved.path }
            }
            UserDefaults.standard.set(resolved.path, forKey: key(slot: slot, destination: destination))

            if destination && !old.isEmpty {
                // New target: requeue all known source files. This is LOCAL
                // SQLite work and makes no deletion requests to either folder.
                let root = slot == 1 ? "photo-uploads" : "photo-editing"
                do {
                    let database = try Self.supportDatabase()
                    if FileManager.default.fileExists(atPath: database.path) {
                        let inventory = try LocalInventory(path: database.path)
                        try inventory.requeueAllForNewDestination(rootID: root)
                    }
                } catch {
                    message = "Nuova destinazione salvata, ma reindicizzazione necessaria: "
                        + error.localizedDescription
                }
            }
            if !destination {
                startMonitoring(allowSourceRebinding: true)
            }
        } catch {
            message = "Cartella non accettata: " + error.localizedDescription
        }
    }

    func startMonitoring(allowSourceRebinding: Bool = false) {
        var roots: [MonitorRoot] = []
        if !photoUploads.isEmpty {
            roots.append(MonitorRoot(id: "photo-uploads", url: URL(fileURLWithPath: photoUploads)))
        }
        if !photoEditing.isEmpty {
            roots.append(MonitorRoot(id: "photo-editing", url: URL(fileURLWithPath: photoEditing)))
        }
        guard !roots.isEmpty else { message = "Seleziona una Sorgente"; return }
        do {
            let db = try Self.supportDatabase().path
            monitoring = false
            message = "Controllo delle Sorgenti locali…"
            service.start(
                roots: roots, databasePath: db, allowSourceRebinding: allowSourceRebinding
            )
        } catch {
            message = "Errore monitoraggio: " + error.localizedDescription
            monitoring = false
        }
    }

    func stopMonitoring() {
        service.stop()
    }
}

private struct FolderDropZone: View {
    let title: String
    let path: String
    let choose: () -> Void
    let onFolderDropped: (URL) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: "folder")
                    .font(.caption.bold())
                Spacer()
                Button("Sfoglia…", action: choose)
                    .font(.caption)
            }
            Text(path.isEmpty
                 ? "Trascina qui una cartella oppure premi Sfoglia…"
                 : path)
                .font(.caption2)
                .foregroundStyle(path.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 75)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                          style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }) else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                              options: nil) { item, _ in
                let dropped: URL?
                if let url = item as? URL {
                    dropped = url
                } else if let data = item as? Data {
                    dropped = URL(dataRepresentation: data, relativeTo: nil)
                } else if let text = item as? String {
                    dropped = URL(string: text)
                } else {
                    dropped = nil
                }
                guard let dropped else { return }
                DispatchQueue.main.async { onFolderDropped(dropped) }
            }
            return true
        }
    }
}


private struct MacSyncConfigurationView: View {
    @ObservedObject var model: MacSyncViewModel
    @ObservedObject var copy: MountedCopyController
    @State private var showLog = false

    private func picker(_ slot: Int, destination: Bool) -> some View {
        FolderDropZone(
            title: destination ? "Destinazione" : "Sorgente",
            path: model.folderPath(slot: slot, destination: destination),
            choose: {
                copy.stop()
                model.chooseFolder(slot: slot, destination: destination)
            },
            onFolderDropped: { url in
                copy.stop()
                model.setFolder(url: url, slot: slot, destination: destination)
            }
        )
    }

    private func pair(_ slot: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            HStack(spacing: 12) {
                picker(slot, destination: false)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                picker(slot, destination: true)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2)
                    Text("MacSync").font(.title2.bold())
                    Spacer()
                    Label(
                        model.monitoring ? "Monitor attivo" : "Monitor fermo",
                        systemImage: model.monitoring ? "checkmark.circle.fill" : "pause.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(model.monitoring ? .green : .orange)
                }
                Text("Scegli le cartelle con Sfoglia oppure trascinale direttamente dal Finder.")
                    .font(.callout).foregroundStyle(.secondary)

                pair(1, title: "1. Cartella_1")
                Divider()
                pair(2, title: "2. Cartella_2")
                Divider()

                Text("Le destinazioni possono essere locali o condivisioni SMB già montate. MacSync utilizza le credenziali conservate da macOS.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Label("Operazioni in coda: \(model.pendingCount.formatted())",
                          systemImage: "list.bullet.rectangle")
                    Spacer()
                    Button("Rileggi Sorgenti") { model.startMonitoring() }
                }
                .font(.callout)

                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Sincronizzazione di prova")
                            .font(.headline)
                        Text(copy.status)
                            .font(.caption)
                            .foregroundStyle(copy.active ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if copy.active {
                        Button("Ferma copie") { copy.stop() }
                    } else {
                        Button("Attiva copie di prova") {
                            copy.start(sources: model.configuredPairs())
                        }
                    }
                }

                HStack {
                    Button("Anteprima iniziale — sola lettura") {
                        copy.preview(sources: model.configuredPairs())
                    }
                    .disabled(copy.active)
                    Button("Registro sincronizzazioni…") {
                        copy.refresh()
                        showLog = true
                    }
                    Spacer()
                }
                Text(copy.previewStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Questa versione di test non propaga le cancellazioni. Le copie possono sovrascrivere file nella destinazione selezionata: utilizzare soltanto dati sintetici.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Button("Ferma tutto") {
                        copy.stop()
                        model.stopMonitoring()
                    }
                    Spacer()
                    Button("Esci da MacSync") {
                        copy.stop()
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 700, minHeight: 580)
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Registro sincronizzazioni").font(.title2.bold())
                Text("Storico SQLite: ogni copia, errore, durata e byte trasferiti.")
                    .font(.caption).foregroundStyle(.secondary)
                List(copy.recentEntries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(entry.action.uppercased()) · \(entry.level) · \(entry.rootID)")
                            .font(.caption.bold())
                        Text(entry.relativePath.isEmpty ? entry.message :
                            entry.relativePath + " — " + entry.message)
                            .font(.caption)
                            .lineLimit(3)
                        Text("\(entry.timestamp.formatted()) · \(entry.bytes) byte · \(String(format: "%.2f", entry.durationSeconds)) s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Aggiorna") { copy.refresh() }
                    Button("Esporta TSV…") { copy.exportLog() }
                    Spacer()
                    Button("Chiudi") { showLog = false }
                }
            }
            .padding(16)
            .frame(width: 700, height: 560)
        }
    }
}

private struct MacSyncStatusMenu: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: MacSyncViewModel
    @ObservedObject var copy: MountedCopyController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MacSync").font(.headline)
            Text(model.monitoring ? "Sorgenti monitorate" : "Monitor non attivo")
                .font(.caption).foregroundStyle(.secondary)
            Text(copy.active ? "Copie di prova in esecuzione" : "Copie non attive")
                .font(.caption).foregroundStyle(.secondary)
            Button("Apri configurazione…") {
                openWindow(id: "configuration")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Esci") {
                copy.stop()
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 255)
    }
}

@main
struct MacSyncApp: App {
    @StateObject private var model = MacSyncViewModel()
    @StateObject private var copy = MountedCopyController()

    var body: some Scene {
        Window("MacSync — Configurazione", id: "configuration") {
            MacSyncConfigurationView(model: model, copy: copy)
        }
        .defaultSize(width: 840, height: 740)

        MenuBarExtra("MacSync", systemImage: "arrow.triangle.2.circlepath") {
            MacSyncStatusMenu(model: model, copy: copy)
        }
        .menuBarExtraStyle(.window)
    }
}
