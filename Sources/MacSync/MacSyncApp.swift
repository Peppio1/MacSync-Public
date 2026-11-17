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
    @Published private(set) var commonPlan: CommonFolderPlan?
    @Published private(set) var configurationInvalid = false
    @Published var message = "Monitoraggio non configurato"
    @Published var monitoring = false
    @Published var pendingCount = 0
    @Published var scanProgress: ArchiveAuditProgress?

    let safetyGate = MonitorSafetyGate()
    private lazy var service = LocalMonitorService(safetyGate:safetyGate) { [weak self] update in
        DispatchQueue.main.async { [weak self] in
            self?.message = update.message
            self?.monitoring = update.monitoring
            self?.pendingCount = update.pendingChanges
            self?.scanProgress = update.scanProgress
        }
    }

    init(previewOnly: Bool = false) {
        guard !previewOnly else {
            photoUploads = "/Example/iMac/Foto_da_editare"
            photoEditing = "/Example/iMac/Foto_caricate"
            destinationUploads = "/Example/Server/Foto_da_editare"
            destinationEditing = "/Example/Server/Foto_caricate"
            commonPlan = CommonFolderPlan(sources: [.init(id: "photo-uploads", path: photoUploads), .init(id: "photo-editing", path: photoEditing), .init(id: "demo-third", path: "/Example/iMac/Progetti_PSD")], parent: "/Example/Server/Condivisione_Foto", expected: VolumeFingerprint(fileSystem: "smbfs", mountPath: "/Example/Server", mountSource: "//example/share"))
            monitoring = true; pendingCount = 46
            message = "Inventario locale disponibile — dati dimostrativi"
            return
        }
        if let bytes = UserDefaults.standard.data(forKey: "MacSync.commonFolders.v1") {
            if let saved = try? JSONDecoder().decode(CommonFolderPlan.self, from: bytes), saved.isValid { commonPlan = saved }
            else { configurationInvalid = true; message = "Configurazione non valida: copie bloccate" }
        }
        DispatchQueue.main.async { [weak self] in
            if let self, !self.configurationInvalid, !self.configuredPairs().filter({ !$0.path.isEmpty }).isEmpty {
                self.startMonitoring()
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
        if configurationInvalid { return [] }
        if let plan = commonPlan {
            return plan.sources.map { ($0.id, $0.path, plan.target(for: $0), plan.expected) }
        }
        return [
            (id: "photo-uploads", path: photoUploads,
             destination: destinationUploads, expected: expectedVolume(slot: 1)),
            (id: "photo-editing", path: photoEditing,
             destination: destinationEditing, expected: expectedVolume(slot: 2))
        ]
    }

    var editableCommonPlan: CommonFolderPlan {
        if let commonPlan { return commonPlan }
        let legacy = configuredPairs().filter { !$0.path.isEmpty }
        let sources = legacy.map { CommonFolderSource(id: $0.id, path: $0.path) }
        if let first = legacy.first, !first.destination.isEmpty, let expected = first.expected {
            let parent = URL(fileURLWithPath: first.destination).deletingLastPathComponent().path
            let proposed = CommonFolderPlan(sources: sources, parent: parent, expected: expected)
            if proposed.isValid && zip(sources,legacy).allSatisfy({ source, pair in
                proposed.target(for: source) == pair.destination && pair.expected == expected
            }) { return proposed }
        }
        return CommonFolderPlan(sources: sources)
    }
    var usesLegacyPairs: Bool {
        commonPlan == nil && configuredPairs().contains { !$0.destination.isEmpty } && editableCommonPlan.parent.isEmpty
    }

    func pickCommonFolders(destination: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = destination ? "Seleziona destinazione" : "Aggiungi sorgenti"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = !destination
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Invoked only after copy and audit workers have stopped. The only
    /// remote writes are explicitly confirmed creation of missing child dirs.
    /// Old root IDs stay stable only if both actual paths and volume match.
    func applyCommonFolders(add urls: [URL] = [], parent newParent: URL? = nil, remove id: String? = nil,
                            cancellation: SeedVerificationCancellation, completion: @escaping @MainActor () -> Void) {
        let original = editableCommonPlan
        let old = configuredPairs()
        message = "Verifica della nuova configurazione…"
        DispatchQueue.global(qos:.utility).async {
            do {
                guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                var plan = original
                if let id { plan.sources.removeAll { $0.id == id } }
                for url in urls {
                    guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                    let path = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard url.isFileURL, try path.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true,
                          !(try VolumeFingerprint.read(at:path)).isNetworkVolume else { throw MountedCopyError.invalidMapping }
                    if !plan.sources.contains(where:{$0.path == path.path}) { plan.sources.append(CommonFolderSource(path:path.path)) }
                }
                if let newParent {
                    guard newParent.isFileURL else { throw MountedCopyError.invalidMapping }
                    let resolved = newParent.standardizedFileURL.resolvingSymlinksInPath()
                    guard try resolved.resourceValues(forKeys:[.isDirectoryKey]).isDirectory == true else { throw MountedCopyError.rootUnavailable }
                    plan.parent = resolved.path; plan.expected = try VolumeFingerprint.read(at:resolved)
                }
                guard plan.isValid else { throw MountedCopyError.invalidMapping }
                plan.sources = plan.sources.map { source in
                    guard let previous = old.first(where:{$0.id == source.id}) else { return source }
                    if previous.path == source.path && previous.destination == plan.target(for:source) && previous.expected == plan.expected { return source }
                    return CommonFolderSource(path:source.path)
                }
                let validated = plan
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellation.isCancelled else { completion(); return }
                    let alert = NSAlert()
                    alert.messageText = "Salvare la configurazione delle cartelle?"
                    alert.informativeText = "Ogni sorgente verrà associata a una sottocartella omonima. Le sottocartelle mancanti verranno create; le associazioni modificate saranno indicizzate nuovamente. Nessun file sarà eliminato. Sincronizzazione automatica e cancellazioni richiederanno una nuova autorizzazione."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle:"Salva"); alert.addButton(withTitle:"Annulla")
                    guard alert.runModal() == .alertFirstButtonReturn else { self.message = "Configurazione invariata"; completion(); return }
                    DispatchQueue.global(qos:.utility).async {
                        do {
                            try validated.prepareTargetDirectories(shouldContinue:{ !cancellation.isCancelled })
                            guard !cancellation.isCancelled else { throw SeedVerificationError.cancelled }
                            let bytes = try JSONEncoder().encode(validated)
                            DispatchQueue.main.async { [weak self] in
                                guard let self, !cancellation.isCancelled else { completion(); return }
                                UserDefaults.standard.set(bytes,forKey:"MacSync.commonFolders.v1")
                                self.configurationInvalid = false; self.commonPlan = validated
                                if validated.sources.isEmpty {
                                    self.monitoring = false; self.pendingCount = 0; self.message = "Aggiungi almeno una sorgente"
                                }
                                completion()
                            }
                        } catch {
                            let reason = error.localizedDescription
                            DispatchQueue.main.async { [weak self] in self?.message = "Configurazione non salvata: " + reason; completion() }
                        }
                    }
                }
            } catch {
                let reason = error.localizedDescription
                DispatchQueue.main.async { [weak self] in self?.message = "Configurazione non salvata: " + reason; completion() }
            }
        }
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
        guard !configurationInvalid else { return }
        var roots: [MonitorRoot] = []
        if let plan = commonPlan {
            roots = plan.sources.map { MonitorRoot(id:$0.id,url:URL(fileURLWithPath:$0.path)) }
        } else {
        if !photoUploads.isEmpty {
            roots.append(MonitorRoot(id: "photo-uploads", url: URL(fileURLWithPath: photoUploads)))
        }
        if !photoEditing.isEmpty {
            roots.append(MonitorRoot(id: "photo-editing", url: URL(fileURLWithPath: photoEditing)))
        }
        }
        guard !roots.isEmpty else { message = "Seleziona una Sorgente"; return }
        do {
            let db = try Self.supportDatabase().path
            monitoring = false
            message = "Controllo delle Sorgenti locali…"
            service.start(
                roots: roots, databasePath: db, allowSourceRebinding: allowSourceRebinding, retireInactiveRoots: commonPlan != nil
            )
        } catch {
            message = "Errore monitoraggio: " + error.localizedDescription
            monitoring = false
        }
    }

    func stopMonitoring() {
        service.stop(); monitoring = false
    }
    func afterMonitorStopped(_ completion: @escaping @MainActor () -> Void) {
        service.afterStopped { DispatchQueue.main.async { completion() } }
    }
    func refreshPendingCount() { service.refreshCount() }
}

private final class FolderDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; urls.append(url) }
    func values() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

struct FolderDropZone: View {
    let title: String
    let path: String
    let choose: () -> Void
    let onFolderDropped: (URL) -> Void
    @State private var isTargeted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
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
    @Environment(\.macSyncLayout) private var layout

    private var tone: Color {
        switch title {
        case "Nuovi": return MacSyncColors.green(scheme)
        case "Aggiornati": return MacSyncColors.blue(scheme)
        case "Eliminati", "Rimandati": return MacSyncColors.orange(scheme)
        case "Recuperabili": return MacSyncColors.blue(scheme)
        case "Errori": return count > 0 ? MacSyncColors.red(scheme) : Color.secondary
        default: return Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.compact ? 3 : 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tone)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(count.formatted()).font(.system(size: layout.compact ? 23 : 26, weight: .semibold, design: .rounded))
                .monospacedDigit().foregroundStyle(tone).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(layout.compact ? 7 : 9)
        .frame(maxWidth: .infinity, minHeight: layout.compact ? 63 : 74, alignment: .leading)
        .background(MacSyncColors.inset(scheme), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MacSyncColors.line(scheme), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}


struct MacSyncConfigurationView: View {
    @ObservedObject var model: MacSyncViewModel
    @ObservedObject var copy: MountedCopyController
    @ObservedObject var runtime: MacSyncRuntime
    @ObservedObject var settings: SyncSettingsController
    @ObservedObject var destinations: DestinationStatusController
    @State private var showSummary = false
    @State private var initialMetric: HistoryMetric?
    @StateObject private var loginAtStartup: LaunchAtLoginController
    private let previewScheme: ColorScheme?
    @State private var selectedLog: Int64?
    @State private var logOperation = "all"
    @State private var logFolder = "all"
    @State private var logPeriod = "all"
    @State private var draftSchedule: SyncSchedule
    @State private var intervalText: String
    @State private var sourcePage = 0

    init(model: MacSyncViewModel, copy: MountedCopyController, runtime: MacSyncRuntime, settings: SyncSettingsController, destinations: DestinationStatusController, initialPage: MacSyncPage = .overview, previewScheme: ColorScheme? = nil) {
        self.model = model; self.copy = copy; self.runtime = runtime
        self.settings = settings; self.destinations = destinations
        self._page = State(initialValue: initialPage)
        self._loginAtStartup = StateObject(wrappedValue: LaunchAtLoginController(previewOnly: runtime.previewOnly))
        self._selectedLog = State(initialValue: runtime.previewOnly && initialPage == .history ? copy.recentEntries.first?.id : nil)
        self.previewScheme = previewScheme
        self._draftSchedule = State(initialValue: settings.schedule)
        self._intervalText = State(initialValue: String(settings.schedule.interval))
    }

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
            HStack {
                Text(title).font(.headline)
                Spacer()
                let configured = !model.folderPath(slot: slot, destination: false).isEmpty && !model.folderPath(slot: slot, destination: true).isEmpty
                Label(configured ? "Configurata" : "Incompleta", systemImage: configured ? "checkmark.circle" : "exclamationmark.circle").font(.caption.weight(.medium)).foregroundStyle(configured ? Color.green : Color.orange)
            }
            HStack(spacing: 12) {
                picker(slot, destination: false)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Sincronizzazione unidirezionale")
                picker(slot, destination: true)
            }
        }
    }


    @State private var page: MacSyncPage
    @AppStorage("MacSync.appearance") private var appearance = "system"

    var body: some View {
        MacSyncSectionShell(page: $page, monitoring: model.monitoring, next: copy.nextScheduledRun ?? runtime.nextAutomaticAttempt, showHeader: page == .folders, activity: nil, controls: AnyView(automaticSwitch)) {
            VStack(alignment: .leading, spacing: 10) {
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
        .disabled(runtime.folderConfigurationBusy || runtime.shuttingDown)
        .preferredColorScheme(previewScheme ?? (appearance == "light" ? .light : appearance == "dark" ? .dark : nil))
        .environment(\.locale, Locale(identifier: "it_IT"))
        .frame(minWidth: 980, minHeight: 660)
        .onAppear {
            guard !runtime.previewOnly else { return }
            copy.loadLastAudit()
            copy.loadLastCycle()
            loginAtStartup.refresh()
            settings.refreshNotificationPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !runtime.previewOnly else { return }
            loginAtStartup.refresh()
            settings.refreshNotificationPermission()
        }
        .sheet(isPresented: $showSummary) {
            SyncHistorySheet(copy:copy,model:model,initialMetric:initialMetric)
        }
    }
    private var globalActivity: String {
        if copy.interruptionRequested { return "Interruzione richiesta" }
        if copy.auditBusy { return "Verifica archivio in corso" }
        if copy.seedBusy { return "Verifica archivio già copiato" }
        if copy.maintaining { return "Manutenzione in corso" }
        if model.scanProgress != nil { return "Inventario locale in corso" }
        if let progress = copy.liveProgress { return progress.phase }
        if copy.active || runtime.nextAutomaticAttempt != nil { return "In attesa del prossimo ciclo" }
        return model.monitoring ? "Monitoraggio attivo · copie ferme" : "Monitoraggio fermo"
    }

    @ViewBuilder private var globalControls: some View {
        if copy.seedBusy { Button("Annulla SHA-256") { copy.cancelSeedVerification() }.buttonStyle(MacSyncStopStyle()) }
        if copy.auditBusy { Button("Annulla verifica") { copy.cancelArchiveAudit() }.buttonStyle(MacSyncStopStyle()) }
        if copy.maintaining && !copy.auditBusy { Button("Interrompi manutenzione") { copy.cancelMaintenance() }.buttonStyle(MacSyncStopStyle()) }
        if model.scanProgress != nil { Button("Annulla scansione") { runtime.stopCopiesForCurrentLaunch(); model.stopMonitoring() }.buttonStyle(MacSyncStopStyle()) }
        if copy.liveProgress != nil && copy.active {
            Button(copy.interruptionRequested ? "Interruzione richiesta…" : "Interrompi ciclo") { copy.interruptCurrentCycle() }
                .buttonStyle(MacSyncStopStyle()).disabled(copy.interruptionRequested)
        }
    }

    @Environment(\.colorScheme) private var scheme

    private var automaticSwitch: some View {
        HStack(spacing: 10) {
            Text("Sincronizzazione automatica").font(.subheadline.weight(.semibold))
            Toggle("Sincronizzazione automatica",isOn: Binding(get:{ copy.automaticCopiesEnabled },set:{ runtime.onAutomaticPreferenceChanged($0) }))
                .labelsHidden().toggleStyle(MacSyncVisibleSwitchStyle(green: true))
                .help(runtime.automaticStatus)
                .disabled(runtime.savingSchedule || copy.seedBusy || copy.maintaining || copy.interruptionRequested)
            Text(copy.automaticCopiesEnabled ? "Attiva" : "Disattivata").font(.subheadline.weight(.semibold))
                .foregroundStyle(copy.automaticCopiesEnabled ? MacSyncColors.green(scheme) : Color.secondary)
        }
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacSyncPanel("Operazione corrente", icon: "arrow.left.arrow.right") {
                HStack {
                    if copy.liveProgress == nil || copy.interruptionRequested { Text(globalActivity).font(.subheadline.weight(.semibold)) }
                    Spacer()
                    globalControls
                    if !copy.active && copy.liveProgress == nil && !copy.maintaining && !copy.seedBusy && model.scanProgress == nil {
                        Button("Avvia sincronizzazione") { runtime.startManualSynchronization() }.buttonStyle(.borderedProminent).disabled(!model.monitoring || runtime.savingSchedule)
                    }
                    Menu("Comandi") {
                        Button("Ferma tutto") { runtime.stopAllOperations() }
                        Button("Rileggi sorgenti") { model.startMonitoring() }.disabled(copy.active || copy.maintaining || copy.seedBusy || copy.interruptionRequested)
                        if copy.automaticCopiesEnabled && !copy.active && runtime.nextAutomaticAttempt == nil { Button("Riattiva automatismo") { runtime.resumeAutomaticCopies() } }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                HStack {
                    Label("\(model.pendingCount.formatted()) operazioni in coda", systemImage: "list.bullet.rectangle").font(.subheadline.weight(.medium))
                    Spacer()
                    if let next = copy.nextScheduledRun ?? runtime.nextAutomaticAttempt { Text("Prossimo: " + macSyncDateTime(next)).font(.caption).foregroundStyle(Color.accentColor) }
                }
                if copy.interruptionRequested { Text("Interruzione richiesta: attendo il punto sicuro. La coda viene conservata.").font(.caption) }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.message) }
                if let scan = model.scanProgress { AuditProgressView(progress: scan) }
                if copy.liveProgress != nil {
                    LiveSyncPanel(copy: copy)
                } else if model.scanProgress == nil {
                    Text(copy.active || runtime.nextAutomaticAttempt != nil ? "In attesa del prossimo ciclo" : "Nessun trasferimento in corso").font(.callout).foregroundStyle(.secondary)
                    if !copy.historyWarning.isEmpty { Text(copy.historyWarning).foregroundStyle(.orange) }
                }
            }
            MacSyncPanel("Riepilogo sessione", icon: "chart.bar.xaxis") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(HistoryMetric.main) { metric in
                        Button {
                            initialMetric = metric; showSummary = true
                        } label: {
                            SyncSummaryMetric(title: metric.title, count: metric.count(copy.sessionStats), symbol: metric.symbol)
                        }.buttonStyle(.plain).help("Apri dettaglio: " + metric.title)
                    }
                }
                HStack {
                    Text("Cicli conclusi · I recuperabili sono inclusi negli eliminati.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apri riepilogo…") { initialMetric = nil; showSummary = true }
                }
            }
            HStack(alignment: .top, spacing: 8) {
                MacSyncPanel("Ultimo ciclo", icon: "clock", fillHeight: true) {
                    if let cycle = copy.lastRecordedCycle {
                        HStack {
                            Label(macSyncCycleState(cycle.state), systemImage: cycle.state == "completed" ? "checkmark.circle.fill" : "clock")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(cycle.state == "completed" ? MacSyncColors.green(scheme) : Color.primary)
                            Spacer(minLength: 3)
                            Text(cycle.seconds.map(elapsedText) ?? "—").monospacedDigit()
                        }
                        Text("Inizio: " + macSyncDateTime(cycle.started) + "\nFine: " + (cycle.ended.map(macSyncDateTime) ?? "—")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text("Errori: \(copy.lastCycleStats.failed) · Rimandati: \(copy.lastCycleStats.deferred)").font(.caption)
                            Spacer(minLength: 4)
                            Button("Storico…") { page = .history }
                        }
                    } else {
                        Text("Nessun ciclo registrato").foregroundStyle(.secondary)
                        Button("Storico…") { page = .history }
                    }
                }
                MacSyncPanel("Destinazioni", icon: "folder", fillHeight: true) {
                    let pairs = model.configuredPairs().filter { !$0.path.isEmpty }
                    Text("\(pairs.filter { destinations.state(for:$0.id).isReady }.count) / \(pairs.count) destinazioni pronte").font(.subheadline.weight(.semibold))
                    ForEach(Array(pairs.prefix(3).enumerated()),id: \.offset) { item in destinationLine(item.element.destination, state:destinations.state(for:item.element.id)) }
                    if pairs.count > 3 { Button("Mostra tutte le cartelle…") { page = .folders } }
                    Text("Ultimo controllo: " + (destinations.lastCheckedAt.map { macSyncClock($0) } ?? "non eseguito"))
                        .font(.caption).foregroundStyle(.secondary)
                    // Cadence explained on Cartelle.
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func destinationLine(_ path: String, state: DestinationAvailability) -> some View {
        let name = path.isEmpty ? "Non configurata" : URL(fileURLWithPath:path).lastPathComponent
        return HStack(spacing: 6) {
            Text(name).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength:4)
            Text(state.description).font(.caption).foregroundStyle(state.isReady ? MacSyncColors.green(scheme) : Color.secondary).lineLimit(2)
        }.help(path + ": " + state.description)
    }

    private var folderEditAllowed: Bool {
        !copy.active && copy.liveProgress == nil && !copy.interruptionRequested && !copy.seedBusy && !copy.maintaining && !copy.auditBusy && !runtime.savingSchedule && !runtime.folderConfigurationBusy
    }
    private func changeFolders(add: [URL] = [], parent: URL? = nil, remove: String? = nil) {
        guard folderEditAllowed, !runtime.previewOnly else { return }
        runtime.editFolderConfiguration(add:add,parent:parent,remove:remove)
    }
    private func folderDrop(_ providers: [NSItemProvider], target: Bool) -> Bool {
        guard folderEditAllowed else { return false }
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty, !target || candidates.count == 1 else { return false }
        let group = DispatchGroup()
        let collector = FolderDropCollector()
        for provider in candidates {
            group.enter()
            provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil) { item,_ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL { url = value }
                else if let value = item as? Data { url = URL(dataRepresentation:value,relativeTo:nil) }
                else if let value = item as? String { url = URL(string:value) }
                else { url = nil }
                if let url { collector.append(url) }
            }
        }
        group.notify(queue:.main) {
            let urls = collector.values().sorted { $0.path < $1.path }
            guard urls.count == candidates.count else { return }
            if target { changeFolders(parent:urls.first) } else { changeFolders(add:urls) }
        }
        return true
    }

    private var foldersPage: some View {
        let plan = model.editableCommonPlan
        let lastPage = max(0,(plan.sources.count-1)/4)
        let current = min(sourcePage,lastPage)
        return VStack(alignment:.leading,spacing:12) {
            if model.usesLegacyPairs { Text("Configurazione precedente conservata. Seleziona una destinazione comune per passare al nuovo sistema.").font(.caption).foregroundStyle(.orange) }
            MacSyncPanel("Cartelle di sincronizzazione",icon:"folder") {
                HStack(alignment:.top,spacing:12) {
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("Sorgenti").font(.headline)
                            Spacer()
                            Button("Aggiungi sorgente") {
                                let selected = model.pickCommonFolders(destination:false)
                                if !selected.isEmpty { changeFolders(add:selected) }
                            }.disabled(!folderEditAllowed).help("Aggiungi sorgente")
                        }
                        if plan.sources.isEmpty {
                            VStack(spacing:6) {
                                Image(systemName:"folder.badge.plus").font(.system(size:32)).foregroundStyle(Color.accentColor)
                                Text("Trascina qui le cartelle sorgenti").font(.callout)
                            }.frame(maxWidth:.infinity,minHeight:142)
                                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.secondary.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[5,4])))
                        } else {
                            ForEach(Array(plan.sources.dropFirst(current*4).prefix(4))) { source in
                                HStack {
                                    VStack(alignment:.leading,spacing:3) {
                                        Text(source.name).font(.subheadline.weight(.semibold))
                                        Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength:4)
                                    Menu {
                                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:source.path)]) }
                                        Button("Rimuovi sorgente") { changeFolders(remove:source.id) }.disabled(!folderEditAllowed)
                                    } label: { Image(systemName:"ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                                }.padding(8).background(MacSyncColors.inset(scheme),in:RoundedRectangle(cornerRadius:8)).help(source.path)
                            }
                            if lastPage > 0 {
                                HStack {
                                    Button("Precedente") { sourcePage = max(0,current-1) }.disabled(current == 0)
                                    Spacer(); Text("\(current+1) di \(lastPage+1)").font(.caption); Spacer()
                                    Button("Successiva") { sourcePage = min(lastPage,current+1) }.disabled(current == lastPage)
                                }
                            }
                        }
                    }.padding(10).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    .background(MacSyncColors.canvas(scheme),in:RoundedRectangle(cornerRadius:10))
                    .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { folderDrop($0,target:false) }
                    Image(systemName:"arrow.right.circle").font(.system(size:26)).foregroundStyle(Color.accentColor).padding(.top,42)
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("Destinazione").font(.headline); Spacer()
                            Button(plan.parent.isEmpty ? "Aggiungi destinazione" : "Modifica") {
                                if let url = model.pickCommonFolders(destination:true).first { changeFolders(parent:url) }
                            }.disabled(!folderEditAllowed).help("Seleziona destinazione")
                        }
                        if plan.parent.isEmpty {
                            VStack(spacing:6) {
                                Image(systemName:"folder.badge.plus").font(.system(size:32)).foregroundStyle(Color.accentColor)
                                Text("Trascina qui la destinazione").font(.callout)
                            }.frame(maxWidth:.infinity,minHeight:142)
                                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.secondary.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[5,4])))
                        } else {
                            VStack(alignment:.leading,spacing:4) {
                                Text(URL(fileURLWithPath:plan.parent).lastPathComponent).font(.subheadline.weight(.semibold))
                                Text(plan.parent).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(10).background(MacSyncColors.inset(scheme),in:RoundedRectangle(cornerRadius:8)).help(plan.parent)
                            Text("Ogni sorgente viene sincronizzata nella sottocartella omonima.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
                    .background(MacSyncColors.canvas(scheme),in:RoundedRectangle(cornerRadius:10))
                    .onDrop(of:[UTType.fileURL.identifier],isTargeted:nil) { folderDrop($0,target:true) }
                }.fixedSize(horizontal:false,vertical:true)
                if !folderEditAllowed { Text("Ferma le copie e attendi il termine delle operazioni per modificare le cartelle.").font(.caption).foregroundStyle(.secondary) }
            }
            MacSyncPanel("Connessione",icon:"network") {
                let pairs = model.configuredPairs().filter{!$0.path.isEmpty}
                Text("\(pairs.filter{destinations.state(for:$0.id).isReady}.count) / \(pairs.count) destinazioni pronte").font(.subheadline.weight(.semibold))
                ForEach(Array(pairs.dropFirst(current*4).prefix(4).enumerated()),id:\.offset) { item in
                    destinationLine(item.element.destination,state:destinations.state(for:item.element.id))
                }
                Text("Ultimo controllo: " + (destinations.lastCheckedAt.map {macSyncClock($0)} ?? "non eseguito")).font(.caption).foregroundStyle(.secondary)
                Text("Direzione unica: sorgenti → destinazione. Controllo prima di ogni ciclo.").font(.caption).foregroundStyle(.secondary)
            }
            Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.message)
        }
    }

    private var editedSchedule: SyncSchedule? {
        var plan = draftSchedule
        if plan.frequency == .minutes || plan.frequency == .hours {
            guard let n = Int(intervalText.trimmingCharacters(in:.whitespacesAndNewlines)) else { return nil }
            plan.interval = n
        }
        return plan.isValid ? plan : nil
    }
    private var schedulePage: some View {
        VStack(alignment:.leading,spacing:12) {
            MacSyncPanel("Frequenza",icon:"clock") {
                Picker("Ripetizione",selection:$draftSchedule.frequency) {
                    Text("Minuti").tag(SyncSchedule.Frequency.minutes)
                    Text("Ore").tag(SyncSchedule.Frequency.hours)
                    Text("Giornaliera").tag(SyncSchedule.Frequency.daily)
                    Text("Settimanale").tag(SyncSchedule.Frequency.weekly)
                }.pickerStyle(.segmented)
                if draftSchedule.frequency == .minutes || draftSchedule.frequency == .hours {
                    let range = draftSchedule.frequency == .minutes ? 1...59 : 1...23
                    HStack {
                        Text("Ogni")
                        Button("−") { intervalText = String(max(range.lowerBound,max(range.lowerBound,min(range.upperBound,Int(intervalText) ?? range.lowerBound))-1)) }
                        TextField("Intervallo",text:$intervalText).frame(width:94).textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                        Button("+") { intervalText = String(min(range.upperBound,max(range.lowerBound,min(range.upperBound,Int(intervalText) ?? range.lowerBound))+1)) }
                        Text(draftSchedule.frequency == .minutes ? "minuti" : "ore")
                        Spacer()
                    }
                    HStack {
                        ForEach(draftSchedule.frequency == .minutes ? [5,10,15,20,30,45] : [1,2,4,8,12],id:\.self) { n in
                            Button { intervalText = String(n) } label: {
                                Text(String(n)).font(.subheadline.weight(Int(intervalText) == n ? .semibold : .regular))
                                    .frame(minWidth: 30).padding(.vertical, 3)
                            }.buttonStyle(.plain)
                                .foregroundStyle(Int(intervalText) == n ? Color.accentColor : Color.primary)
                                .background(Int(intervalText) == n ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityAddTraits(Int(intervalText) == n ? .isSelected : [])
                        }
                    }
                    if editedSchedule == nil { Text("Inserisci un intervallo da \(range.lowerBound) a \(range.upperBound).").font(.caption).foregroundStyle(.orange) }
                } else {
                    if draftSchedule.frequency == .weekly {
                        Picker("Giorno",selection:$draftSchedule.weekday) {
                            ForEach([2,3,4,5,6,7,1],id:\.self) { day in Text(macSyncWeekdayName(day)).tag(day) }
                        }
                    }
                    HStack {
                        Picker("Ora",selection:$draftSchedule.hour) { ForEach(0...23,id:\.self) { Text(String(format:"%02d",$0)).tag($0) } }.frame(width:160)
                        Picker("Minuti",selection:$draftSchedule.minute) { ForEach(0...59,id:\.self) { Text(String(format:"%02d",$0)).tag($0) } }.frame(width:160)
                    }
                }
                HStack {
                    Text(editedSchedule?.summary ?? "Intervallo non valido").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Salva") { if let plan = editedSchedule { runtime.saveSchedule(plan) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(editedSchedule == nil || editedSchedule == settings.schedule || runtime.savingSchedule || copy.seedBusy || copy.maintaining || copy.auditBusy)
                }
                if runtime.savingSchedule { Text("Attendo l'arresto sicuro del ciclo prima di applicare la frequenza…").font(.caption) }
                else if editedSchedule != settings.schedule { Text("Modifiche non salvate").font(.caption).foregroundStyle(.orange) }
                Text("Frequenza attuale: " + settings.schedule.summary).font(.caption).foregroundStyle(.secondary)
            }
            MacSyncPanel("Destinazione offline",icon:"wifi.slash") {
                MacSyncSwitchRow("Notifiche disconnessione",isOn:Binding(get:{settings.alertPolicy.enabled},set:{runtime.onAlertPolicyChanged($0)}))
                if settings.alertPolicy.enabled {
                    Stepper("Avvisa dopo \(settings.alertPolicy.afterHours) ore",value:$settings.alertPolicy.afterHours,in:1...168)
                    Text(settings.notificationPermissionStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("Avviso una sola volta per disconnessione, al controllo pianificato successivo alla soglia.").font(.caption).foregroundStyle(.secondary)
            }
        }.onChange(of:draftSchedule.frequency) { frequency in
            if frequency == .minutes && !(1...59).contains(Int(intervalText) ?? 0) {intervalText = "5"}
            if frequency == .hours && !(1...23).contains(Int(intervalText) ?? 0) {intervalText = "1"}
        }.onChange(of:settings.schedule) { plan in draftSchedule = plan; intervalText = String(plan.interval) }
    }

    private var auditPage: some View {
        ArchiveAuditPanel(copy:copy,runtime:runtime,model:model)
    }
    private struct LogRow: Identifiable {
        let entry: SyncLogEntry
        var id: Int64 { entry.id }
    }
    private var visibleLog: [SyncLogEntry] {
        copy.recentEntries.filter { entry in
            (logOperation == "all" || entry.action == logOperation) &&
            (logFolder == "all" || entry.rootID == logFolder) &&
            (logPeriod == "all" || entry.timestamp >= Date().addingTimeInterval(logPeriod == "day" ? -86400 : -604800))
        }
    }
    private var historyPage: some View {
        MacSyncPanel("Registro e dettagli", icon: "list.bullet.rectangle", fillHeight: true) {
            HStack(spacing: 8) {
                TextField("Cerca file o errore…", text: $copy.logSearch)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: copy.logSearch) { _ in copy.refresh() }
                Picker("Esito", selection: $copy.logLevel) {
                    Text("Tutti").tag("all")
                    Text("Completati").tag("success")
                    Text("Avvisi").tag("warning")
                    Text("Errori").tag("error")
                    Text("Informazioni").tag("info")
                }.frame(width: 170).onChange(of: copy.logLevel) { _ in copy.refresh() }
            }
            HStack {
                Picker("Operazione", selection: $logOperation) {
                    Text("Tutte").tag("all")
                    ForEach(Array(Set(copy.recentEntries.map(\.action))).sorted(), id: \.self) { key in Text(macSyncAction(key)).tag(key) }
                }
                Picker("Cartella", selection: $logFolder) {
                    Text("Tutte").tag("all")
                    ForEach(Array(Set(copy.recentEntries.map(\.rootID))).sorted(), id: \.self) { key in Text(macSyncRootName(key)).tag(key) }
                }
                Picker("Periodo", selection: $logPeriod) {
                    Text("Tutto").tag("all"); Text("24 ore").tag("day"); Text("7 giorni").tag("week")
                }
            }
            HStack {
                Text("Filtri e comandi").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Aggiorna") { copy.refresh() }
                Button("Esporta TSV…") { copy.exportLog() }
                Button("Storico cicli…") { initialMetric = nil; showSummary = true }.buttonStyle(.borderedProminent)
            }
            Text("Ultimi 300 eventi. TSV: ricerca ed esito (max 5.000 eventi); gli altri filtri valgono solo per la tabella.").font(.caption).foregroundStyle(.secondary)
            Table(visibleLog.map { LogRow(entry: $0) }, selection: $selectedLog) {
                TableColumn("Data e ora") { row in Text(macSyncDateTime(row.entry.timestamp)).monospacedDigit().font(.caption) }.width(min: 124, ideal: 145)
                TableColumn("Esito") { row in let entry = row.entry; MacSyncLogBadge(level: entry.level, interrupted: macSyncWasInterrupted(entry)) }.width(min: 76, ideal: 105)
                TableColumn("Operazione") { row in let entry = row.entry; Text(macSyncAction(entry.action)).lineLimit(1) }.width(min: 78, ideal: 108)
                TableColumn("File / dettaglio") { row in let entry = row.entry; Text(entry.relativePath.isEmpty ? entry.message : entry.relativePath).lineLimit(1).truncationMode(.middle).help(entry.relativePath.isEmpty ? entry.message : entry.relativePath) }
                TableColumn("Dim.") { row in let entry = row.entry; Text(entry.bytes == 0 ? "—" : ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).monospacedDigit() }.width(min: 60, ideal: 80)
            }.frame(minHeight: 105, maxHeight: .infinity)
                .layoutPriority(1)
            if let entry = visibleLog.first(where: { $0.id == selectedLog }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Dettaglio evento").font(.headline)
                        Spacer()
                        Button("Copia dettaglio") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.relativePath + "\n" + entry.message, forType: .string)
                        }
                    }
                    Text(macSyncDateTime(entry.timestamp) + " · " + macSyncRootName(entry.rootID) + " · " + String(format: "%.2f s", entry.durationSeconds)).font(.caption).foregroundStyle(.secondary)
                    if !entry.relativePath.isEmpty { Text(entry.relativePath).lineLimit(2).help(entry.relativePath).textSelection(.enabled) }
                    Text(entry.message).lineLimit(3).help(entry.message).textSelection(.enabled)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(visibleLog.isEmpty ? "Nessun evento corrispondente ai filtri." : "Seleziona una riga per consultare il dettaglio completo.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Eventi visualizzati: \(visibleLog.count)").font(.caption.weight(.medium))
                Spacer()
                Text("Completati: \(visibleLog.filter { $0.level == "success" }.count)").font(.caption).foregroundStyle(MacSyncColors.green(scheme))
                Spacer()
                Text("Avvisi: \(visibleLog.filter { $0.level == "warning" }.count)").font(.caption)
                Spacer()
                Text("Errori: \(visibleLog.filter { $0.level == "error" }.count)").font(.caption).foregroundStyle(MacSyncColors.red(scheme))
            }
        }.onAppear { copy.refresh() }
    }
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
            VStack(alignment:.leading,spacing:10) {
            MacSyncPanel("Generali", icon: "gearshape", accent: false) {
                VStack(alignment: .leading, spacing: 10) {
                    MacSyncSwitchRow(
                        "Avvia al login macOS",
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
                    MacSyncSwitchRow("Notifiche disconnessione", isOn: Binding(get:{settings.alertPolicy.enabled},set:{runtime.onAlertPolicyChanged($0)}))
                    Text("L’avvio al login non abilita le cancellazioni.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                 }
            }
            MacSyncPanel("Cancellazioni e recupero", icon: "arrow.triangle.2.circlepath", fillHeight: true) {
                VStack(alignment: .leading, spacing: 10) {
                    MacSyncSwitchRow(
                        "Abilita cancellazioni speculari",
                        isOn: Binding(get: { copy.mirrorEnabled }, set: {
                            copy.setMirrorEnabled($0, sources: model.configuredPairs())
                        })
                    )
                    .disabled(copy.active || copy.seedBusy || copy.maintaining || copy.interruptionRequested || runtime.savingSchedule)

                    if copy.mirrorEnabled {
                        MacSyncSwitchRow(
                            "Sposta i file eliminati nella cartella di recupero",
                            isOn: $copy.mirrorRecovery
                        )
                        .disabled(copy.active || copy.seedBusy || copy.maintaining || copy.interruptionRequested || runtime.savingSchedule)

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
                                .frame(maxWidth: 180)
                                .disabled(copy.active || copy.seedBusy || copy.maintaining || copy.interruptionRequested || runtime.savingSchedule)
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
                    Text(copy.mirrorStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Button("Apri cartella di recupero") { copy.revealRecoveryFolders(sources:model.configuredPairs()) }
                }
            }
            }.frame(maxWidth:.infinity,alignment:.topLeading)
            VStack(alignment:.leading,spacing:10) {
            MacSyncPanel("Aspetto", icon: "paintbrush", accent: false) {
                Picker("Tema", selection: $appearance) {
                    Text("Automatico").tag("system")
                    Text("Chiaro").tag("light")
                    Text("Scuro").tag("dark")
                }.pickerStyle(.segmented)
            }

            MacSyncPanel("Protezioni facoltative",icon:"shield",fillHeight:true) {
                    VStack(alignment: .leading, spacing: 8) {
                        MacSyncSwitchRow("Limite numerico", isOn: $copy.mirrorProtections.absoluteEnabled)
                        Text("Blocca il ciclo se il numero di cancellazioni supera la soglia nella finestra mobile.").font(.caption).foregroundStyle(.secondary)
                        if copy.mirrorProtections.absoluteEnabled {
                            HStack {
                                Text("Numero massimo di elementi")
                                Spacer()
                                TextField("Limite", value: $copy.mirrorProtections.absoluteLimit, format: .number)
                                    .frame(width: 100)
                            }
                        }
                        MacSyncSwitchRow("Limite percentuale", isOn: $copy.mirrorProtections.fractionEnabled)
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
                        MacSyncSwitchRow("Protezione sorgente completamente vuota", isOn: $copy.mirrorProtections.emptyEnabled)
                        Text("Blocca le cancellazioni quando una sorgente configurata risulta completamente vuota.").font(.caption).foregroundStyle(.secondary)
                        if !copy.mirrorProtections.isValid {
                            Text("Valori consentiti: 1–1.000.000 elementi, 1–100%.").foregroundStyle(.orange)
                        }
                        Text("Un’anomalia blocca la sincronizzazione fino alla verifica manuale.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Esamina e rimuovi blocco di sicurezza…") {
                            copy.clearMirrorSafetyBlock()
                        }
                    }
                    .disabled(copy.active || copy.seedBusy || copy.maintaining || copy.interruptionRequested || runtime.savingSchedule)
            }
            }.frame(maxWidth:.infinity,alignment:.topLeading)
            }.fixedSize(horizontal:false,vertical:true)
            SoftwareUpdatesPanel(updates: runtime.updates)
            MacSyncPanel("Informazioni", icon: "info.circle", accent: false) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacSync · v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.16.0")").font(.subheadline.weight(.semibold))
                        Text("Registro SQLite locale").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Esporta registro…") { copy.exportLog() }
                    Button("Apri cartella app…") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
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
    var interrupted = false
    @Environment(\.colorScheme) private var scheme
    private var label: String {
        if interrupted { return "Interrotto" }
        switch level {
        case "success": return "Completato"
        case "warning": return "Avviso"
        case "error": return "Errore"
        case "info": return "Info"
        default: return level
        }
    }
    private var tone: Color {
        if interrupted { return .secondary }
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
    let compact: Bool
    let fillHeight: Bool
    let content: Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.macSyncLayout) private var layout
    private var dense: Bool { compact || layout.compact }
    init(_ title: String, icon: String, accent: Bool = false, compact: Bool = false, fillHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.accent = accent; self.compact = compact; self.fillHeight = fillHeight; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 5 : 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(MacSyncColors.blue(scheme))
                    .frame(width: dense ? 23 : 27, height: dense ? 23 : 27)
                    .background(MacSyncColors.blue(scheme).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                Text(title).font(.system(size: dense ? 16 : 17, weight: .semibold))
            }
            content
        }
        .padding(dense ? 9 : 14)
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(MacSyncColors.panel(scheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(accent ? MacSyncColors.blue(scheme).opacity(0.48) : MacSyncColors.line(scheme), lineWidth: 1))
    }
}

/// Calendar weekday numbering is stable (Sunday=1, Monday=2).
/// Do not use the runner's or machine's locale for Italian UI labels.
func macSyncWeekdayName(_ day: Int) -> String {
    let names = ["Domenica", "Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato"]
    return (1...7).contains(day) ? names[day-1] : "—"
}

func macSyncClock(_ date: Date, seconds: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "it_IT")
    formatter.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
    return formatter.string(from: date)
}
func macSyncDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "it_IT")
    formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
    return formatter.string(from: date)
}
func macSyncRootName(_ root: String) -> String {
    switch root { case "photo-uploads": return "Cartella_1"; case "photo-editing": return "Cartella_2"; default: return root }
}
func macSyncAction(_ action: String) -> String {
    let names = ["upload":"Copia", "cycle":"Ciclo", "detected":"Modifiche", "audit":"Verifica", "session":"Sessione", "connection_wait":"Attesa rete", "staging_cleanup":"Pulizia", "preview":"Anteprima", "mirror_armed":"Specchio attivato"]
    return names[action] ?? action.replacingOccurrences(of: "_", with: " ").capitalized
}
func macSyncWasInterrupted(_ entry: SyncLogEntry) -> Bool {
    let message = entry.message.lowercased()
    return message.hasPrefix("ciclo interrotto") || message.hasPrefix("pulizia interrotta") || message.hasPrefix("verifica annullata")
}

/// Presentation-only sizing policy, measured from actual content bounds.
struct MacSyncWindowLayout: Equatable {
    let width: CGFloat
    let height: CGFloat
    var compact: Bool { width < 1100 || height < 760 }
    var sidebarWidth: CGFloat { compact ? 190 : 220 }
    var pageInset: CGFloat { compact ? 12 : 18 }
}
private struct MacSyncWindowLayoutKey: EnvironmentKey {
    static let defaultValue = MacSyncWindowLayout(width: 1180, height: 820)
}
extension EnvironmentValues {
    var macSyncLayout: MacSyncWindowLayout {
        get { self[MacSyncWindowLayoutKey.self] }
        set { self[MacSyncWindowLayoutKey.self] = newValue }
    }
}

/// Explicit contrast in inactive windows; accessibility remains a native toggle.
struct MacSyncVisibleSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    var green = false
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? (green ? MacSyncColors.green(scheme) : MacSyncColors.blue(scheme)) : Color.secondary.opacity(0.3))
                .frame(width: 38, height: 21)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 17, height: 17).padding(2)
                }
                .opacity(enabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct MacSyncSwitchRow: View {
    let title: String
    @Binding var isOn: Bool
    init(_ title: String, isOn: Binding<Bool>) { self.title = title; self._isOn = isOn }
    var body: some View {
        HStack(spacing: 8) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(isOn ? "Attivo" : "Disattivo").font(.caption.weight(.semibold)).foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Toggle(title, isOn: $isOn).toggleStyle(MacSyncVisibleSwitchStyle()).labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

struct MacSyncSectionShell<Content: View>: View {
    @Binding var page: MacSyncPage
    let monitoring: Bool
    let next: Date?
    let activity: String?
    let showHeader: Bool
    let controls: AnyView
    let content: Content
    @Environment(\.colorScheme) private var scheme
    init(page: Binding<MacSyncPage>, monitoring: Bool, next: Date?, showHeader: Bool = false, activity: String? = nil, controls: AnyView = AnyView(EmptyView()), @ViewBuilder content: () -> Content) {
        self._page = page; self.monitoring = monitoring; self.next = next; self.showHeader = showHeader; self.activity = activity; self.controls = controls; self.content = content()
    }
    var body: some View {
        GeometryReader { geometry in
        let layout = MacSyncWindowLayout(width: geometry.size.width, height: geometry.size.height)
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
            }.padding(layout.compact ? 12 : 16).frame(width: layout.sidebarWidth).frame(maxHeight: .infinity)
                .background(MacSyncColors.sidebar(scheme))
            Divider()
            VStack(spacing: 0) {
                if showHeader {
                HStack {
                    controls
                    Spacer()
                    if let next {
                        Label("Prossimo: " + macSyncClock(next), systemImage: "clock")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(MacSyncColors.blue(scheme))
                    } else { Text("Nessun ciclo pianificato").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.vertical, 9)
                    .background(MacSyncColors.panel(scheme))
                Divider()
                }
                if page == .history {
                    pageContent(layout).frame(maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView { pageContent(layout) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacSyncColors.canvas(scheme))
        }
        .font(.system(size: layout.compact ? 13 : 14))
        .tint(MacSyncColors.blue(scheme))
        .toggleStyle(.switch)
        .controlSize(.regular)
        .environment(\.macSyncLayout, layout)
        }
    }
    private func pageContent(_ layout: MacSyncWindowLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.compact ? 8 : 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.rawValue).font(.system(size: layout.compact ? 25 : 28, weight: .bold))
                Text(page.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            content
        }.padding(layout.pageInset).frame(maxWidth: .infinity, alignment: .topLeading)
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
            Text(copy.active ? "Copie in esecuzione" : "Copie non attive")
                .font(.caption).foregroundStyle(.secondary)
            Text(runtime.automaticStatus)
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if copy.active { Button("Sospendi copie programmate") { runtime.stopCopiesForCurrentLaunch() }.buttonStyle(MacSyncStopStyle()) }
            Button("Apri configurazione…") {
                openWindow(id: "configuration")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Controlla aggiornamenti…") { runtime.updates.check() }
                .disabled(runtime.shuttingDown)
            Divider()
            Button("Esci") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 255)
    }
}

@main
struct MacSyncApp: App {
    @NSApplicationDelegateAdaptor(MacSyncTerminationDelegate.self) private var terminationDelegate
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

 
struct SoftwareUpdatesPanel: View {
    @ObservedObject var updates: SoftwareUpdateController
    var body: some View {
        MacSyncPanel("Aggiornamenti software", icon: "arrow.triangle.2.circlepath", accent: false) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(updates.versionLabel).font(.subheadline.weight(.semibold))
                    Text("Ultimo controllo: " + (updates.lastCheck.map(macSyncDateTime) ?? "mai"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if updates.checking { ProgressView().controlSize(.small) }
                Button("Controlla") { updates.check() }.disabled(updates.checking)
            }
            MacSyncSwitchRow("Controllo automatico", isOn: Binding(
                get: { updates.automatic }, set: { updates.setAutomatic($0) }))
            if !updates.status.isEmpty {
                HStack {
                    Text(updates.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if updates.available != nil {
                        Button("Dettagli…") { updates.showAvailable() }
                    }
                }
            }
            Label("Installazione con conferma e backup preventivo.", systemImage: "shield")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
