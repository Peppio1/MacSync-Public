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
            if !destination {
                let fingerprint = try VolumeFingerprint.read(at: resolved)
                guard !fingerprint.isNetworkVolume else {
                    throw MountedCopyError.invalidMapping
                }
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


private struct SyncSummaryMetric: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(count.formatted())
                .font(.title2.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A dedicated readable view; no source/target paths are displayed here.
private struct SyncSummarySheet: View {
    @ObservedObject var copy: MountedCopyController
    @Environment(\.dismiss) private var dismiss
    @State private var selectedScope = "session"

    private var data: SyncDashboardStats {
        selectedScope == "session" ? copy.sessionStats : copy.lastCycleStats
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Riepilogo sincronizzazione", systemImage: "chart.bar.xaxis")
                    .font(.title2.bold())
                Spacer()
                Button("Chiudi") { dismiss() }
            }
            Picker("Periodo", selection: $selectedScope) {
                Text("Sessione corrente").tag("session")
                Text("Ultimo ciclo").tag("last")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                SyncSummaryMetric(title: "Nuovi file", count: data.newFiles, symbol: "doc.badge.plus")
                SyncSummaryMetric(title: "File aggiornati", count: data.updatedFiles, symbol: "arrow.triangle.2.circlepath")
                SyncSummaryMetric(title: "Eliminati definitivamente", count: data.permanentlyDeleted, symbol: "trash")
                SyncSummaryMetric(title: "Spostati nel recupero", count: data.movedToRecovery, symbol: "archivebox")
                SyncSummaryMetric(title: "Errori", count: data.failed, symbol: "exclamationmark.triangle")
                SyncSummaryMetric(title: "Rimandati", count: data.deferred, symbol: "clock")
            }
            Divider()
            HStack {
                Text("Dati trasferiti")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: data.bytesTransferred, countStyle: .file))
                    .monospacedDigit()
            }
            HStack {
                Text("Cartelle create / rimosse")
                Spacer()
                Text("\(data.createdDirectories) / \(data.removedDirectories)")
                    .monospacedDigit()
            }
            HStack {
                Text("Recuperi scaduti eliminati")
                Spacer()
                Text(data.expiredRecovery.formatted()).monospacedDigit()
            }
            HStack {
                Text("Cicli completati nella sessione")
                Spacer()
                Text(copy.completedCycles.formatted()).monospacedDigit()
            }
            HStack {
                Text("Ultimo controllo")
                Spacer()
                if let when = copy.lastCycleAt {
                    Text(when.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text("Non ancora eseguito").foregroundStyle(.secondary)
                }
            }
            if data.deletionsBlocked {
                Label("Una protezione ha bloccato le cancellazioni. Consulta il registro.",
                      systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Spacer(minLength: 0)
            Text("I contatori sono relativi alla sessione di prova corrente; il registro SQLite conserva lo storico delle attività. I file in coda non sono conteggiati come completati.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(width: 690, height: 620)
    }
}

private struct MacSyncConfigurationView: View {
    @ObservedObject var model: MacSyncViewModel
    @ObservedObject var copy: MountedCopyController
    @ObservedObject var runtime: MacSyncRuntime
    @State private var showLog = false
    @State private var showSummary = false
    @StateObject private var loginAtStartup = LaunchAtLoginController()
    @StateObject private var destinations = DestinationStatusController()

    private func picker(_ slot: Int, destination: Bool) -> some View {
        FolderDropZone(
            title: destination ? "Destinazione" : "Sorgente",
            path: model.folderPath(slot: slot, destination: destination),
            choose: {
                guard !copy.seedBusy else { return }
                copy.stop()
                copy.invalidateSeedReport()
                let previous = model.folderPath(slot: slot, destination: destination)
                model.chooseFolder(slot: slot, destination: destination)
                if model.folderPath(slot: slot, destination: destination) != previous {
                    runtime.onFolderConfigurationChanged()
                }
                destinations.refresh()
            },
            onFolderDropped: { url in
                guard !copy.seedBusy else { return }
                copy.stop()
                copy.invalidateSeedReport()
                let previous = model.folderPath(slot: slot, destination: destination)
                model.setFolder(url: url, slot: slot, destination: destination)
                if model.folderPath(slot: slot, destination: destination) != previous {
                    runtime.onFolderConfigurationChanged()
                }
                destinations.refresh()
            }
        )
        .disabled(copy.seedBusy)
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

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Impostazioni di avvio").font(.headline)
                    Toggle(
                        "Avvia automaticamente MacSync al login macOS",
                        isOn: Binding(
                            get: { loginAtStartup.enabled },
                            set: { loginAtStartup.setEnabled($0) }
                        )
                    )
                    .disabled(!loginAtStartup.isAvailable)
                    Text(loginAtStartup.statusMessage)
                        .font(.caption)
                        .foregroundStyle(loginAtStartup.requiresApproval ? .orange : .secondary)
                    if loginAtStartup.requiresApproval {
                        Button("Apri Elementi login in Impostazioni di Sistema") {
                            loginAtStartup.openSystemSettings()
                        }
                    }
                    Text("L'avvio al login apre MacSync; le cancellazioni speculari non si attivano automaticamente.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle(
                        "Avvia automaticamente le copie e gli aggiornamenti",
                        isOn: Binding(
                            get: { copy.automaticCopiesEnabled },
                            set: { runtime.onAutomaticPreferenceChanged($0) }
                        )
                    )
                    .disabled(!loginAtStartup.isAvailable || copy.seedBusy || copy.maintaining)
                    Text(runtime.automaticStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Questa scelta richiede una conferma iniziale. Dopo il login, MacSync attende il monitoraggio locale e le destinazioni corrette; può copiare e aggiornare senza ulteriori conferme, ma non eliminare.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Disponibilità delle destinazioni").font(.headline)
                        Spacer()
                        Button("Verifica ora") { destinations.refresh() }
                            .disabled(destinations.checking)
                    }
                    HStack {
                        Image(systemName: destinations.first.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(destinations.first.isReady ? .green : .orange)
                        Text("Cartella_1: " + destinations.first.description).font(.caption)
                    }
                    HStack {
                        Image(systemName: destinations.second.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(destinations.second.isReady ? .green : .orange)
                        Text("Cartella_2: " + destinations.second.description).font(.caption)
                    }
                    Text("MacSync controlla le cartelle ogni 30 secondi senza montare condivisioni né gestire la VPN. Le copie in esecuzione vengono ritentate ai cicli successivi se macOS rimonta la stessa destinazione.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Riepilogo sincronizzazione").font(.headline)
                        Spacer()
                        Button("Apri riepilogo…") { showSummary = true }
                    }
                    HStack(spacing: 8) {
                        SyncSummaryMetric(title: "Nuovi", count: copy.sessionStats.newFiles,
                                          symbol: "doc.badge.plus")
                        SyncSummaryMetric(title: "Aggiornati", count: copy.sessionStats.updatedFiles,
                                          symbol: "arrow.triangle.2.circlepath")
                        SyncSummaryMetric(title: "Eliminati", count: copy.sessionStats.permanentlyDeleted,
                                          symbol: "trash")
                        SyncSummaryMetric(title: "Recuperati", count: copy.sessionStats.movedToRecovery,
                                          symbol: "archivebox")
                        SyncSummaryMetric(title: "Errori", count: copy.sessionStats.failed,
                                          symbol: "exclamationmark.triangle")
                    }
                    Text("Totali della sessione; apri il riepilogo per ultimi cicli, file rimandati e dimensioni trasferite.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cancellazioni speculari")
                        .font(.headline)
                    Toggle(
                        "Abilita cancellazione speculare (solo dopo conferma all'avvio)",
                        isOn: $copy.mirrorEnabled
                    )
                    .disabled(copy.active || copy.seedBusy || copy.maintaining)

                    if copy.mirrorEnabled {
                        Toggle(
                            "Sposta i file eliminati nella cartella di recupero",
                            isOn: $copy.mirrorRecovery
                        )
                        .disabled(copy.active || copy.seedBusy || copy.maintaining)

                        if copy.mirrorRecovery {
                            HStack {
                                Text("Conservazione dei file eliminati")
                                Spacer()
                                Picker("Conservazione", selection: $copy.mirrorRetention) {
                                    Text("Mai — conserva sempre").tag(0)
                                    ForEach(1...30, id: \.self) { days in
                                        Text("\(days) \(days == 1 ? "giorno" : "giorni")").tag(days)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 210)
                                .disabled(copy.active || copy.seedBusy || copy.maintaining)
                            }
                            Text("Recupero gestito in .macsync-recovery nella destinazione. I file scaduti verranno rimossi nei cicli successivi, solo se la protezione del volume è valida.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("ATTENZIONE: i file verranno eliminati DEFINITIVAMENTE dalla destinazione. MacSync non potrà ripristinarli.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("Disabilitata: i file cancellati dalla Sorgente rimarranno nella Destinazione.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(copy.mirrorStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Apri cartella di recupero nel Finder") {
                        copy.revealRecoveryFolders(sources: model.configuredPairs())
                    }
                    .font(.caption)
                }
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
                        Button("Ferma copie") { runtime.stopCopiesForCurrentLaunch() }
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

                Divider()
                Text("Prima sincronizzazione intelligente — SHA-256")
                    .font(.headline)
                Text("I file già presenti vengono confrontati leggendo il contenuto su entrambi i lati. La verifica può consumare traffico VPN, ma non trasferisce nuove copie né cancella file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if copy.seedBusy {
                        Button("Annulla verifica") { copy.cancelSeedVerification() }
                    } else {
                        Button("Verifica file già presenti") {
                            copy.verifySeededFiles(sources: model.configuredPairs())
                        }
                        .disabled(copy.active || copy.maintaining)
                    }
                    if copy.seedReady && !copy.seedBusy {
                        Button("Conferma \(copy.seedVerifiedCount) file identici") {
                            copy.approveSeededFiles()
                        }
                        .disabled(copy.active || copy.maintaining)
                    }
                    Spacer()
                }

                Text(copy.seedStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Esaminati: \(copy.seedInspectedCount)")
                    Text("Identici: \(copy.seedVerifiedCount)")
                    Spacer()
                    Text("Letti: " + ByteCountFormatter.string(
                        fromByteCount: copy.seedReadBytes, countStyle: .file
                    ))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Verifica file temporanei") {
                        copy.inspectStaging(sources: model.configuredPairs())
                    }
                     .disabled(copy.active || copy.maintaining || copy.seedBusy)
                    Button("Pulisci temporanei…") {
                        copy.cleanupStaging(sources: model.configuredPairs())
                    }
                     .disabled(copy.active || copy.maintaining || copy.seedBusy)
                    Spacer()
                }
                Text(copy.maintenanceStatus)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Modalità sperimentale: le cancellazioni richiedono conferma per sessione, inventario valido e controlli anti-cancellazioni massive. Usare soltanto cartelle di prova con dati sintetici.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Button("Ferma tutto") {
                        runtime.stopCopiesForCurrentLaunch()
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
        .onAppear {
            loginAtStartup.refresh()
            destinations.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginAtStartup.refresh()
            destinations.refresh()
        }
        .sheet(isPresented: $showSummary) {
            SyncSummarySheet(copy: copy)
        }
        .sheet(isPresented: $showLog) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Registro sincronizzazioni").font(.title2.bold())
                Text("Storico SQLite: ogni copia, errore, durata e byte trasferiti.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    TextField("Cerca file o errore…", text: $copy.logSearch)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: copy.logSearch) { _ in copy.refresh() }
                    Picker("Esito", selection: $copy.logLevel) {
                        Text("Tutti").tag("all")
                        Text("Completati").tag("success")
                        Text("Avvisi").tag("warning")
                        Text("Errori").tag("error")
                        Text("Informazioni").tag("info")
                    }
                    .frame(width: 205)
                    .onChange(of: copy.logLevel) { _ in copy.refresh() }
                }
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
    @ObservedObject var runtime: MacSyncRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MacSync").font(.headline)
            Text(model.monitoring ? "Sorgenti monitorate" : "Monitor non attivo")
                .font(.caption).foregroundStyle(.secondary)
            Text(copy.active ? "Copie di prova in esecuzione" : "Copie non attive")
                .font(.caption).foregroundStyle(.secondary)
            Text(runtime.automaticStatus)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    /// Created independently of the configuration window, so unattended
    /// COPY/UPDATE monitoring works when the menu-bar app is hidden.
    @StateObject private var runtime = MacSyncRuntime()

    var body: some Scene {
        Window("MacSync — Configurazione", id: "configuration") {
            MacSyncConfigurationView(
                model: runtime.model, copy: runtime.copy, runtime: runtime
            )
        }
        .defaultSize(width: 840, height: 740)

        MenuBarExtra("MacSync", systemImage: "arrow.triangle.2.circlepath") {
            MacSyncStatusMenu(
                model: runtime.model, copy: runtime.copy, runtime: runtime
            )
        }
        .menuBarExtraStyle(.window)
    }
}
