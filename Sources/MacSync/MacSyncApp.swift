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
    @Published var scanProgress: ArchiveAuditProgress?

    private lazy var service = LocalMonitorService { [weak self] update in
        DispatchQueue.main.async { [weak self] in
            self?.message = update.message
            self?.monitoring = update.monitoring
            self?.pendingCount = update.pendingChanges
            self?.scanProgress = update.scanProgress
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

struct FolderDropZone: View {
    let title: String
    let path: String
    let choose: () -> Void
    let onFolderDropped: (URL) -> Void
    @State private var isTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: title == "Destinazione" ? "externaldrive.connected.to.line.below" : "folder")
                    .foregroundStyle(MacSyncColors.blue(scheme))
                    .font(.system(size: 17, weight: .medium))
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button("Sfoglia…", action: choose)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
            if !path.isEmpty {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Text(path.isEmpty ? "Trascina qui una cartella" : path)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .help(path.isEmpty ? "Scegli o trascina una cartella" : path)
        .background(isTargeted ? MacSyncColors.blue(scheme).opacity(0.14) : MacSyncColors.inset(scheme))
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


struct SyncSummaryMetric: View {
    let title: String
    let count: Int
    let symbol: String
    @Environment(\.colorScheme) private var scheme

    private var tone: Color {
        switch title {
        case "Nuovi": return MacSyncColors.green(scheme)
        case "Aggiornati": return MacSyncColors.blue(scheme)
        case "Eliminati": return MacSyncColors.orange(scheme)
        case "Recuperabili": return MacSyncColors.blue(scheme)
        case "Errori": return count > 0 ? MacSyncColors.red(scheme) : Color.secondary
        default: return Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone)
                .frame(width: 28, height: 28)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(count.formatted())
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tone)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .background(MacSyncColors.inset(scheme), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MacSyncColors.line(scheme), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

private struct MacSyncConfigurationView: View {
    @ObservedObject var model: MacSyncViewModel
    @ObservedObject var copy: MountedCopyController
    @ObservedObject var runtime: MacSyncRuntime
    @ObservedObject var settings: SyncSettingsController
    @ObservedObject var destinations: DestinationStatusController
    @State private var showSummary = false
    @State private var initialMetric: HistoryMetric?
    @StateObject private var loginAtStartup = LaunchAtLoginController()

    private func picker(_ slot: Int, destination: Bool) -> some View {
        FolderDropZone(
            title: destination ? "Destinazione" : "Sorgente",
            path: model.folderPath(slot: slot, destination: destination),
            choose: {
                guard !copy.seedBusy && !copy.maintaining else { return }
                runtime.stopCopiesForCurrentLaunch()
                copy.invalidateSeedReport()
                let previous = model.folderPath(slot: slot, destination: destination)
                model.chooseFolder(slot: slot, destination: destination)
                if model.folderPath(slot: slot, destination: destination) != previous {
                    runtime.onFolderConfigurationChanged()
                }
            },
            onFolderDropped: { url in
                guard !copy.seedBusy && !copy.maintaining else { return }
                runtime.stopCopiesForCurrentLaunch()
                copy.invalidateSeedReport()
                let previous = model.folderPath(slot: slot, destination: destination)
                model.setFolder(url: url, slot: slot, destination: destination)
                if model.folderPath(slot: slot, destination: destination) != previous {
                    runtime.onFolderConfigurationChanged()
                }
            }
        )
        .disabled(copy.seedBusy || copy.maintaining)
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


    @State private var page: MacSyncPage = .overview
    @AppStorage("MacSync.appearance") private var appearance = "system"

    var body: some View {
        MacSyncSectionShell(page: $page, monitoring: model.monitoring, next: copy.nextScheduledRun ?? runtime.nextAutomaticAttempt) {
            VStack(alignment: .leading, spacing: 16) {
                if copy.seedBusy || copy.auditBusy || copy.maintaining || copy.active || model.scanProgress != nil {
                    HStack {
                        Label("Operazioni in corso o pianificate", systemImage: "clock").font(.caption)
                        Spacer()
                        if copy.seedBusy { Button("Annulla SHA-256") { copy.cancelSeedVerification() }.buttonStyle(MacSyncStopStyle()) }
                        if copy.auditBusy { Button("Annulla verifica") { copy.cancelArchiveAudit() }.buttonStyle(MacSyncStopStyle()) }
                        if copy.maintaining && !copy.auditBusy { Button("Interrompi manutenzione") { copy.cancelMaintenance() }.buttonStyle(MacSyncStopStyle()) }
                        if model.scanProgress != nil { Button("Annulla scansione") { runtime.stopCopiesForCurrentLaunch(); model.stopMonitoring() }.buttonStyle(MacSyncStopStyle()) }
                        if copy.active { Button("Interrompi copie") { runtime.stopCopiesForCurrentLaunch() }.buttonStyle(MacSyncStopStyle()) }
                    }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                switch page {
                case .overview: overviewPage
                case .folders: foldersPage
                case .schedule: schedulePage
                case .audit: auditPage
                case .history: historyPage
                case .settings: settingsPage
                }
            }
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
            copy.loadLastAudit()
            copy.loadLastCycle()
            loginAtStartup.refresh()
            settings.refreshNotificationPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginAtStartup.refresh()
            settings.refreshNotificationPermission()
        }
        .sheet(isPresented: $showSummary) {
            SyncHistorySheet(copy:copy,model:model,initialMetric:initialMetric)
        }
    }
    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Stato della sincronizzazione", icon: "arrow.triangle.2.circlepath", accent: true) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(copy.active ? "Sincronizzazione pianificata" : "Sincronizzazione di prova")
                            .font(.system(size: 19, weight: .semibold))
                        Text(copy.status)
                            .font(.caption)
                            .foregroundStyle(copy.active ? .green : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if copy.active {
                        Button("Interrompi copie") { runtime.stopCopiesForCurrentLaunch() }.buttonStyle(MacSyncStopStyle())
                    } else {
                        Button("Avvia copie di prova") {
                            // A manual session may explicitly permit mirror
                            // deletion. Keep the unattended coordinator idle
                            // throughout its confirmation dialogue.
                            runtime.stopCopiesForCurrentLaunch()
                            copy.start(sources: model.configuredPairs(),
                                       schedule: settings.schedule)
                        }.buttonStyle(.borderedProminent).disabled(copy.seedBusy || copy.maintaining || model.scanProgress != nil || !model.monitoring)
                    }
                }
                Text(runtime.automaticStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    if copy.automaticCopiesEnabled && !copy.active && runtime.nextAutomaticAttempt == nil {
                        Button("Riattiva copie automatiche") { runtime.resumeAutomaticCopies() }
                            .disabled(copy.seedBusy || copy.maintaining)
                    }
                    if copy.automaticCopiesEnabled {
                        Button("Disattiva sincronizzazione automatica") { runtime.onAutomaticPreferenceChanged(false) }
                            .disabled(copy.seedBusy || copy.maintaining)
                    }
                    Spacer()
                    Button("Ferma tutto") {
                        runtime.stopCopiesForCurrentLaunch()
                        if copy.seedBusy { copy.cancelSeedVerification() }
                        if copy.auditBusy { copy.cancelArchiveAudit() }
                        model.stopMonitoring()
                    }
                }
            }
            MacSyncPanel("Avanzamento e riepilogo", icon: "chart.bar.xaxis", accent: false) {
                HStack {
                    Label("Operazioni in coda: \(model.pendingCount.formatted())",
                          systemImage: "list.bullet.rectangle")
                    Spacer()
                    if model.scanProgress != nil {
                        Button("Annulla scansione") { runtime.stopCopiesForCurrentLaunch(); model.stopMonitoring() }.buttonStyle(MacSyncStopStyle())
                    } else {
                        Button("Rileggi Sorgenti") { model.startMonitoring() }.disabled(copy.active || copy.maintaining || copy.seedBusy)
                    }
                }
                .font(.callout)

                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    if let scan = model.scanProgress {
                        AuditProgressView(progress:scan)
                    }
                    LiveSyncPanel(copy:copy)
                    HStack {
                        Text("Riepilogo sincronizzazione").font(.headline)
                        Spacer()
                        Button("Apri riepilogo…") { initialMetric = nil; showSummary = true }
                    }
                    HStack(spacing: 8) {
                        ForEach(HistoryMetric.dashboard) { metric in
                            Button {
                                initialMetric = metric; showSummary = true
                            } label: {
                                SyncSummaryMetric(title:metric.title,count:metric.count(copy.sessionStats),symbol:metric.symbol)
                            }.buttonStyle(.plain)
                        }
                    }
                    Text("Totali della sessione; apri il riepilogo per ultimi cicli, file rimandati e dimensioni trasferite.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
            MacSyncPanel("Ultimo ciclo", icon: "clock", accent: false) {

                if let cycle = copy.lastRecordedCycle {
                    Label(macSyncCycleState(cycle.state), systemImage: cycle.state == "completed" ? "checkmark.circle.fill" : "clock").font(.subheadline.weight(.semibold))
                        .foregroundStyle(cycle.state == "completed" ? Color.green : Color.primary)
                    Text("Inizio: " + cycle.started.formatted(date: .abbreviated, time: .standard))
                    Text("Fine: " + (cycle.ended?.formatted(date: .abbreviated, time: .standard) ?? "—"))
                    Text("Durata: " + (cycle.seconds.map(elapsedText) ?? "—"))
                } else { Text("Nessun ciclo registrato").foregroundStyle(.secondary) }
                Button("Storico e dettagli…") { page = .history }
            }
            MacSyncPanel("Disponibilità delle destinazioni", icon: "folder", accent: false) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ultimo controllo").font(.subheadline.weight(.medium))
                        Spacer()
                        if let checked = destinations.lastCheckedAt {
                            Text(checked.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Text("Non ancora eseguito")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
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
                    Text("La disponibilità viene controllata immediatamente prima di ciascuna sincronizzazione pianificata, senza verifiche extra. Se macOS rende nuovamente disponibile lo stesso volume, i file in coda vengono ripresi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            }
        }
    }
    private var foldersPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Cartella_1", icon: "folder", accent: false) {
                pair(1, title: model.folderPath(slot: 1, destination: false).isEmpty || model.folderPath(slot: 1, destination: true).isEmpty ? "Configurazione incompleta" : "Sorgente → Destinazione")
            }
            MacSyncPanel("Cartella_2", icon: "folder", accent: false) {
                pair(2, title: model.folderPath(slot: 2, destination: false).isEmpty || model.folderPath(slot: 2, destination: true).isEmpty ? "Configurazione incompleta" : "Sorgente → Destinazione")
            }
            MacSyncPanel("Connessione", icon: "network", accent: false) {
                Text("Le destinazioni possono essere locali o condivisioni SMB già montate. MacSync utilizza le credenziali conservate da macOS.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Direzione unica: iMac → destinazione.").font(.caption)
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
            }
        }
    }
    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Sincronizzazione automatica", icon: "calendar", accent: true) {
                    Toggle(
                        "Avvia automaticamente le copie e gli aggiornamenti",
                        isOn: Binding(
                            get: { copy.automaticCopiesEnabled },
                            set: { runtime.onAutomaticPreferenceChanged($0) }
                        )
                    )
                    .disabled(copy.seedBusy || copy.maintaining)
                    Text(runtime.automaticStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Questa scelta richiede una conferma iniziale. Dopo il login, MacSync attende il monitoraggio locale e le destinazioni corrette; può copiare e aggiornare senza ulteriori conferme, e può eliminare solo con autorizzazione speculare separata.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
            }
            MacSyncPanel("Frequenza", icon: "clock", accent: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Frequenza sincronizzazione").font(.headline)
                    Picker("Ripetizione", selection: Binding(
                        get: { settings.schedule.frequency },
                        set: { value in
                            settings.updateScheduleFrequency(value)
                            runtime.onScheduleChanged()
                        }
                    )) {
                        Text("Minuti").tag(SyncSchedule.Frequency.minutes)
                        Text("Ore").tag(SyncSchedule.Frequency.hours)
                        Text("Ogni giorno").tag(SyncSchedule.Frequency.daily)
                        Text("Giorno della settimana").tag(SyncSchedule.Frequency.weekly)
                    }
                    .pickerStyle(.segmented)
                    .disabled(copy.active || copy.seedBusy || copy.maintaining)
                    if settings.schedule.frequency == .minutes ||
                       settings.schedule.frequency == .hours {
                         SyncIntervalEditor(
                             range: settings.schedule.frequency == .minutes ? 1...59 : 1...23,
                             unit: settings.schedule.frequency == .minutes ? "minuti" : "ore",
                             value: settings.schedule.interval,
                             apply: { value in
                                 guard !copy.active, !copy.seedBusy, !copy.maintaining else { return }
                                 var plan = settings.schedule
                                 plan.interval = value
                                 guard plan.isValid else { return }
                                 settings.schedule = plan
                                 runtime.onScheduleChanged()
                             }
                         )
                         .disabled(copy.active || copy.seedBusy || copy.maintaining)
                    } else {
                        if settings.schedule.frequency == .weekly {
                            Picker("Giorno", selection: Binding(
                                get: { settings.schedule.weekday },
                                set: { value in
                                    var plan = settings.schedule
                                    plan.weekday = value
                                    settings.schedule = plan
                                    runtime.onScheduleChanged()
                                }
                            )) {
                                Text("Lunedì").tag(2)
                                Text("Martedì").tag(3)
                                Text("Mercoledì").tag(4)
                                Text("Giovedì").tag(5)
                                Text("Venerdì").tag(6)
                                Text("Sabato").tag(7)
                                Text("Domenica").tag(1)
                            }
                            .disabled(copy.active || copy.seedBusy || copy.maintaining)
                        }
                        DatePicker("Orario", selection: Binding(
                            get: {
                                var parts = Calendar.current.dateComponents(
                                    [.year, .month, .day], from: Date()
                                )
                                parts.hour = settings.schedule.hour
                                parts.minute = settings.schedule.minute
                                return Calendar.current.date(from: parts) ?? Date()
                            },
                            set: { value in
                                let time = Calendar.current.dateComponents(
                                    [.hour, .minute], from: value
                                )
                                var plan = settings.schedule
                                plan.hour = time.hour ?? 9
                                plan.minute = time.minute ?? 0
                                settings.schedule = plan
                                runtime.onScheduleChanged()
                            }
                        ), displayedComponents: .hourAndMinute)
                        .disabled(copy.active || copy.seedBusy || copy.maintaining)
                    }
                    Label(settings.schedule.summary, systemImage: "calendar.badge.clock")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    if let next = copy.nextScheduledRun ?? runtime.nextAutomaticAttempt {
                        Text("Prossimo controllo e sincronizzazione: "
                             + next.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Quando le copie sono attive, prima di ogni ciclo MacSync controlla che la destinazione SMB sia ancora quella configurata. Nessun controllo aggiuntivo fra due cicli. Per cambiare la frequenza, ferma prima le copie.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            MacSyncPanel("Destinazione offline", icon: "wifi.slash", accent: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Avviso per destinazione non disponibile").font(.headline)
                    Toggle("Invia una notifica dopo una disconnessione prolungata",
                           isOn: Binding(
                                get: { settings.alertPolicy.enabled },
                                set: { runtime.onAlertPolicyChanged($0) }
                           ))
                    if settings.alertPolicy.enabled {
                        Stepper(
                            "Avvisa dopo \(settings.alertPolicy.afterHours) "
                                + (settings.alertPolicy.afterHours == 1 ? "ora" : "ore"),
                            value: Binding(
                                get: { settings.alertPolicy.afterHours },
                                set: { newValue in
                                    settings.alertPolicy.afterHours = newValue
                                }
                            ), in: 1...168
                        )
                        Text(settings.notificationPermissionStatus)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Disattivato per impostazione predefinita. Il tempo decorre dalla prima indisponibilità rilevata. La notifica viene valutata soltanto al successivo controllo previsto dalla frequenza di sincronizzazione, una sola volta per disconnessione.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var auditPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Verifica completa", icon: "checkmark.shield", accent: true) {
                ArchiveAuditPanel(copy:copy,runtime:runtime,model:model)
            }
            MacSyncPanel("Archivio già copiato", icon: "checkmark.seal", accent: false) {
                Text("Prima sincronizzazione intelligente — SHA-256")
                    .font(.headline)
                Text("I file già presenti vengono confrontati leggendo il contenuto su entrambi i lati. La verifica può consumare traffico VPN, ma non trasferisce nuove copie né cancella file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if copy.seedBusy {
                        Button("Annulla verifica") { copy.cancelSeedVerification() }.buttonStyle(MacSyncStopStyle())
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

                if copy.seedBusy, let start = copy.seedStartedAt {
                    TimelineView(.periodic(from:start,by:1)) { ctx in
                        let elapsed = max(0.001,ctx.date.timeIntervalSince(start))
                        VStack(alignment:.leading,spacing:6) {
                            if copy.seedTotalJobs > 0 {
                                ProgressView(value:min(0.99,Double(copy.seedInspectedCount)/Double(copy.seedTotalJobs)))
                                Text("Job analizzati: \(copy.seedInspectedCount) / \(copy.seedTotalJobs)")
                            }
                            Text("Tempo: " + elapsedText(elapsed) + " · Lettura media locale + SMB: " +
                                SyncLiveProgress.formatRate(Double(copy.seedReadBytes)/elapsed))
                            if !copy.seedCurrentPath.isEmpty {
                                Text(copy.seedCurrentPath).lineLimit(1).truncationMode(.middle)
                            }
                            if copy.seedInspectedCount > 0 && copy.seedTotalJobs > copy.seedInspectedCount {
                                let remaining = elapsed * Double(copy.seedTotalJobs-copy.seedInspectedCount) / Double(copy.seedInspectedCount)
                                Text("Tempo rimanente indicativo: " + elapsedText(remaining))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
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
                Button("Anteprima iniziale — sola lettura") { copy.preview(sources: model.configuredPairs()) }
                    .disabled(copy.active || copy.seedBusy || copy.maintaining)
                Text(copy.previewStatus).font(.caption).foregroundStyle(.secondary)
            }
            MacSyncPanel("Manutenzione temporanei", icon: "wrench.and.screwdriver", accent: false) {
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
            }
        }
    }
    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Registro e dettagli", icon: "list.bullet.rectangle", accent: false) {
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
                        HStack(spacing: 8) {
                            MacSyncLogBadge(level: entry.level)
                            Text(entry.action.uppercased()).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(entry.rootID).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.relativePath.isEmpty ? entry.message :
                            entry.relativePath + " — " + entry.message)
                            .font(.system(size: 13))
                            .lineLimit(3)
                        Text("\(entry.timestamp.formatted()) · \(entry.bytes) byte · \(String(format: "%.2f", entry.durationSeconds)) s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.frame(minHeight: 360)
                HStack {
                    Button("Aggiorna") { copy.refresh() }
                    Button("Esporta TSV…") { copy.exportLog() }
                    Spacer()
                    Button("Storico cicli…") { initialMetric = nil; showSummary = true }
                }
            }.onAppear { copy.refresh() }
            }
        }
    }
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacSyncPanel("Generali", icon: "gearshape", accent: false) {
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
                 }
            }
            MacSyncPanel("Aspetto", icon: "paintbrush", accent: false) {
                Picker("Tema", selection: $appearance) {
                    Text("Automatico").tag("system")
                    Text("Chiaro").tag("light")
                    Text("Scuro").tag("dark")
                }.pickerStyle(.segmented)
            }
            MacSyncPanel("Cancellazioni, recupero e protezioni", icon: "shield", accent: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Cancellazioni speculari")
                        .font(.headline)
                    Toggle(
                        "Abilita cancellazioni speculari (autorizzazione persistente)",
                        isOn: Binding(get: { copy.mirrorEnabled }, set: {
                            copy.setMirrorEnabled($0, sources: model.configuredPairs())
                        })
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Protezioni facoltative — disattivate di default").font(.headline)
                        Toggle("Limite numerico", isOn: $copy.mirrorProtections.absoluteEnabled)
                        if copy.mirrorProtections.absoluteEnabled {
                            HStack {
                                Text("Numero massimo di elementi")
                                Spacer()
                                TextField("Limite", value: $copy.mirrorProtections.absoluteLimit, format: .number)
                                    .frame(width: 100)
                            }
                        }
                        Toggle("Limite percentuale", isOn: $copy.mirrorProtections.fractionEnabled)
                        if copy.mirrorProtections.fractionEnabled {
                            HStack {
                                Text("Percentuale massima")
                                Spacer()
                                TextField("Percentuale", value: $copy.mirrorProtections.percentLimit, format: .number)
                                    .frame(width: 70)
                                Text("%")
                            }
                        }
                        if copy.mirrorProtections.absoluteEnabled || copy.mirrorProtections.fractionEnabled {
                            Picker("Finestra mobile", selection: $copy.mirrorProtections.windowHours) {
                                ForEach([1, 6, 12, 24, 48], id: \.self) { hours in
                                    Text("\(hours) h").tag(hours)
                                }
                            }
                        }
                        Toggle("Protezione sorgente completamente vuota", isOn: $copy.mirrorProtections.emptyEnabled)
                        if !copy.mirrorProtections.isValid {
                            Text("Valori consentiti: 1–1.000.000 elementi, 1–100%.").foregroundStyle(.orange)
                        }
                        Text("Le soglie sono valutate per ciascuna coppia. Un'anomalia blocca tutta la sincronizzazione fino alla verifica manuale. Le protezioni tecniche non sono disattivabili.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Esamina e rimuovi blocco di sicurezza…") {
                            copy.clearMirrorSafetyBlock()
                        }
                    }
                    .disabled(copy.active || copy.seedBusy || copy.maintaining)
                    Text(copy.mirrorStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Apri cartella di recupero nel Finder") {
                        copy.revealRecoveryFolders(sources: model.configuredPairs())
                    }
                    .font(.caption)
                }
            }
            MacSyncPanel("Informazioni", icon: "info.circle", accent: false) {
                Text("MacSync · v0.13.1 — candidato").font(.headline)
                Text("Usare solo archivi di prova finché il collaudo SMB non è completato.").foregroundStyle(.orange)
                Button("Esporta registro…") { copy.exportLog() }
            }
        }
    }
}

enum MacSyncPage: String, CaseIterable, Identifiable {
    case overview = "Panoramica", folders = "Cartelle", schedule = "Pianificazione"
    case audit = "Verifica archivio", history = "Registro attività", settings = "Impostazioni"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "house"
        case .folders: return "folder"
        case .schedule: return "calendar"
        case .audit: return "checkmark.shield"
        case .history: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "Stato generale della sincronizzazione e attività recenti."
        case .folders: return "Configura le coppie sorgente e destinazione."
        case .schedule: return "Personalizza frequenza e orari della sincronizzazione."
        case .audit: return "Scansioni rapide, SHA-256 e manutenzione controllata."
        case .history: return "Consulta operazioni, avvisi ed errori."
        case .settings: return "Configura avvio, aspetto, recupero e sicurezza."
        }
    }
}

// Shared UI tokens for both themes. Use explicit surfaces so inactive AppKit
// preview windows do not inherit the darker system under-page background.
enum MacSyncColors {
    static func canvas(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.10, green: 0.12, blue: 0.15) : Color(red: 0.95, green: 0.96, blue: 0.98)
    }
    static func sidebar(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.12, green: 0.14, blue: 0.18) : Color(red: 0.91, green: 0.94, blue: 0.97)
    }
    static func panel(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.15, green: 0.18, blue: 0.22) : .white
    }
    static func inset(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.18, green: 0.21, blue: 0.26) : Color(red: 0.96, green: 0.97, blue: 0.99)
    }
    static func line(_ s: ColorScheme) -> Color {
        s == .dark ? .white.opacity(0.11) : Color(red: 0.82, green: 0.86, blue: 0.91)
    }
    static func blue(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.47, green: 0.72, blue: 1) : Color(red: 0.10, green: 0.34, blue: 0.72)
    }
    static func green(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 0.36, green: 0.86, blue: 0.59) : Color(red: 0.07, green: 0.45, blue: 0.28)
    }
    static func orange(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 1, green: 0.72, blue: 0.38) : Color(red: 0.64, green: 0.32, blue: 0.05)
    }
    static func red(_ s: ColorScheme) -> Color {
        s == .dark ? Color(red: 1, green: 0.52, blue: 0.52) : Color(red: 0.70, green: 0.16, blue: 0.19)
    }
}

struct MacSyncStopStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(MacSyncColors.red(scheme))
            .background(MacSyncColors.red(scheme).opacity(configuration.isPressed ? 0.20 : 0.08), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(MacSyncColors.red(scheme).opacity(0.32), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct MacSyncLogBadge: View {
    let level: String
    @Environment(\.colorScheme) private var scheme
    private var label: String {
        switch level {
        case "success": return "Completato"
        case "warning": return "Avviso"
        case "error": return "Errore"
        case "info": return "Info"
        default: return level
        }
    }
    private var tone: Color {
        switch level {
        case "success": return MacSyncColors.green(scheme)
        case "warning": return MacSyncColors.orange(scheme)
        case "error": return MacSyncColors.red(scheme)
        default: return MacSyncColors.blue(scheme)
        }
    }
    var body: some View {
        Text(label).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tone)
            .background(tone.opacity(0.12), in: Capsule())
    }
}

struct MacSyncPanel<Content: View>: View {
    let title: String
    let icon: String
    let accent: Bool
    let content: Content
    @Environment(\.colorScheme) private var scheme
    init(_ title: String, icon: String, accent: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.accent = accent; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MacSyncColors.blue(scheme))
                    .frame(width: 32, height: 32)
                    .background(MacSyncColors.blue(scheme).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSyncColors.panel(scheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(accent ? MacSyncColors.blue(scheme).opacity(0.48) : MacSyncColors.line(scheme), lineWidth: 1))
    }
}

struct MacSyncSectionShell<Content: View>: View {
    @Binding var page: MacSyncPage
    let monitoring: Bool
    let next: Date?
    let content: Content
    @Environment(\.colorScheme) private var scheme
    init(page: Binding<MacSyncPage>, monitoring: Bool, next: Date?, @ViewBuilder content: () -> Content) {
        self._page = page; self.monitoring = monitoring; self.next = next; self.content = content()
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(MacSyncColors.blue(scheme))
                        .frame(width: 36, height: 36)
                        .background(MacSyncColors.blue(scheme).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacSync").font(.system(size: 21, weight: .bold))
                        Text("Sincronizzazione").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 20)
                ForEach(MacSyncPage.allCases) { item in
                    Button { page = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.icon).frame(width: 20)
                            Text(item.rawValue)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 14, weight: page == item ? .semibold : .regular))
                        .padding(.horizontal, 11).padding(.vertical, 11)
                        .foregroundStyle(page == item ? MacSyncColors.blue(scheme) : Color.primary)
                        .background(page == item ? MacSyncColors.blue(scheme).opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
                Divider()
                Label(monitoring ? "Monitor attivo" : "Monitor fermo", systemImage: monitoring ? "checkmark.circle.fill" : "pause.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(monitoring ? MacSyncColors.green(scheme) : MacSyncColors.orange(scheme))
                    .padding(.vertical, 6)
            }.padding(16).frame(width: 220).frame(maxHeight: .infinity)
                .background(MacSyncColors.sidebar(scheme))
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Label(page.rawValue, systemImage: page.icon).font(.subheadline.weight(.medium))
                    Spacer()
                    if let next {
                        Label("Prossimo ciclo: " + next.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacSyncColors.blue(scheme))
                    }
                }.padding(.horizontal, 24).padding(.vertical, 15)
                    .background(MacSyncColors.panel(scheme))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(page.rawValue).font(.system(size: 30, weight: .bold))
                            Text(page.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 4)
                        content
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacSyncColors.canvas(scheme))
        }
        .font(.system(size: 13))
        .tint(MacSyncColors.blue(scheme))
        .toggleStyle(.switch)
        .controlSize(.regular)
    }
}

struct SyncIntervalEditor: View {
    let range: ClosedRange<Int>
    let unit: String
    let value: Int
    let apply: (Int) -> Void
    @State private var draft = ""
    @Environment(\.colorScheme) private var scheme
    private var parsed: Int? {
        guard let n = Int(draft.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(n) else { return nil }
        return n
    }
    private func commit(_ n: Int) {
        guard range.contains(n) else { return }
        draft = String(n); apply(n)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ogni")
                Button { commit(max(range.lowerBound, (parsed ?? value) - 1)) } label: { Image(systemName: "minus") }
                    .disabled((parsed ?? value) <= range.lowerBound)
                TextField("Intervallo", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(width: 76)
                    .accessibilityLabel("Intervallo in " + unit)
                    .onSubmit { if let parsed { commit(parsed) } }
                Button { commit(min(range.upperBound, (parsed ?? value) + 1)) } label: { Image(systemName: "plus") }
                    .disabled((parsed ?? value) >= range.upperBound)
                Text(unit)
                Button("Applica") { if let parsed { commit(parsed) } }
                    .buttonStyle(.borderedProminent).disabled(parsed == nil || parsed == value)
                Spacer()
            }
            HStack {
                ForEach(unit == "minuti" ? [5, 10, 15, 20, 30, 45] : [1, 2, 4, 8, 12], id: \.self) { n in
                    Button { commit(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 13, weight: n == value ? .semibold : .regular))
                            .frame(minWidth: 26)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .foregroundStyle(n == value ? MacSyncColors.blue(scheme) : Color.primary)
                            .background(n == value ? MacSyncColors.blue(scheme).opacity(0.15) : MacSyncColors.inset(scheme), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(MacSyncColors.line(scheme), lineWidth: 1))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(n == value ? .isSelected : [])
                        .disabled(!range.contains(n))
                }
            }
            Text(parsed == nil ? "Inserisci un numero intero da \(range.lowerBound) a \(range.upperBound)." : "Intervallo consentito: \(range.lowerBound)–\(range.upperBound) \(unit).")
                .font(.caption).foregroundStyle(parsed == nil ? Color.orange : Color.secondary)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { new in draft = String(new) }
        .onChange(of: unit) { _ in draft = String(value) }
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
            if copy.active { Button("Interrompi copie") { runtime.stopCopiesForCurrentLaunch() }.buttonStyle(MacSyncStopStyle()) }
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
        Window("MacSync", id: "configuration") {
            MacSyncConfigurationView(
                model: runtime.model, copy: runtime.copy, runtime: runtime,
                settings: runtime.settings, destinations: runtime.destinations
            )
        }
        .defaultSize(width: 1180, height: 820)

        MenuBarExtra("MacSync", systemImage: "arrow.triangle.2.circlepath") {
            MacSyncStatusMenu(
                model: runtime.model, copy: runtime.copy, runtime: runtime
            )
        }
        .menuBarExtraStyle(.window)
    }
}
