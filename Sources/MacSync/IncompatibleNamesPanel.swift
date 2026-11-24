import AppKit
import SwiftUI
import MacSyncCore

private struct NameListingRequest: Equatable {
    let revision: Int
    let side: String
    let directories: Bool
    let search: String
    let offset: Int
}

private struct NameSelectionRequest: Equatable {
    let revision: Int
    let namesRevision: Int
}

private struct NameConfirmation: Identifiable {
    let id = UUID()
    let items: [IncompatibleName]
}

struct IncompatibleNamesPanel:View {
    @ObservedObject var copy:MountedCopyController
    @ObservedObject var model:MacSyncViewModel
    @ObservedObject var runtime:MacSyncRuntime
    @State private var directories=true
    @State private var search=""
    @State private var message=""
    @State private var revealing=false
    @State private var selected=Set<String>()
    @State private var confirmation:NameConfirmation?
    @State private var pageOffset=0
    @State private var namePage:IncompatibleNameListPage?
    @State private var displayedRequest:NameListingRequest?
    @State private var selectedRows:[IncompatibleName]=[]
    @State private var selectionRevision=0
    @State private var resolvedSelection:NameSelectionRequest?

    private var listingRequest:NameListingRequest {
        .init(revision:copy.namesRevision,side:"source",directories:directories,
              search:search,offset:pageOffset)
    }
    private var selectionRequest:NameSelectionRequest {
        .init(revision:selectionRevision,namesRevision:copy.namesRevision)
    }
    private var chosen:[IncompatibleName] { selectedRows.filter { $0.side == .source } }
    private var canRectify:Bool {
        !runtime.previewOnly && !runtime.folderConfigurationBusy && !runtime.shuttingDown &&
        !copy.auditBusy && !copy.seedBusy && !copy.maintaining && !copy.rectifyingNames && !copy.namesBusy
    }
    private var canSelect: Bool { canRectify }
    private func selectable(_ item:IncompatibleName)->Bool {
        NameRectification.proposedName(item.name) != nil
    }
    var body:some View {
        // Rendering uses only a bounded snapshot. Filtering and counting are
        // performed in a cancellable worker, never during a SwiftUI update.
        let current = displayedRequest == listingRequest
        let selectionCurrent = resolvedSelection == selectionRequest
        let visibleRows = current ? (namePage?.rows ?? []) : []
        return MacSyncPanel("Nomi incompatibili",icon:"folder.badge.questionmark",fillHeight:true) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Sorgenti: \(namePage?.sourceFolders ?? 0) cartelle · \(namePage?.sourceFiles ?? 0) file").font(.subheadline)
                    Text("I nomi incompatibili sono rilevati soltanto nelle sorgenti.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(copy.namesStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Live inventory updates replace the separate scan command.
            }
            HStack {
                Picker("Tipo",selection:$directories) {
                    Text("Cartelle").tag(true)
                    Text("File").tag(false)
                }.pickerStyle(.segmented)
            }
            TextField("Cerca nome, percorso o motivo…",text:$search).textFieldStyle(.roundedBorder)
            HStack {
                Button("Seleziona tutti") {
                    selected.formUnion(namePage?.selectableIDs ?? [])
                }
                    .help("Seleziona tutti i nomi rettificabili delle sorgenti, anche fuori dalla pagina corrente")
                    .disabled(!current || namePage?.selectableIDs.isEmpty != false || !canSelect)
                Spacer()
                Button(selectionCurrent ? "Rettifica nomi (\(chosen.count))" : "Calcolo selezione…") {
                    guard selectionCurrent, !chosen.isEmpty else { return }
                    confirmation=NameConfirmation(items:chosen)
                }.buttonStyle(.borderedProminent)
                    .disabled(!canRectify || !selectionCurrent || chosen.isEmpty)
            }
            if runtime.preparingRectification {
                ProgressView("Arresto delle attività prima della rettifica…")
                    .progressViewStyle(.linear)
            } else if let progress = copy.rectificationProgress {
                ProgressView(value: Double(progress.checked), total: Double(progress.total)) {
                    Text("Rettifica · \(progress.checked) di \(progress.total) voci esaminate")
                }
            } else if copy.rectifyingNames {
                ProgressView(copy.rectificationStatus).progressViewStyle(.linear)
            } else if !copy.rectificationStatus.isEmpty {
                Text(copy.rectificationStatus).font(.caption).foregroundStyle(.secondary)
            } else if runtime.rectificationPending {
                Text("Alcune rettifiche sono in sospeso. Seleziona le voci interessate e conferma Rettifica nomi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let started = copy.nameScanStarted {
                HStack(spacing: 12) {
                    ProgressView().progressViewStyle(.linear)
                    Text(started, style: .timer)
                        .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Tempo trascorso")
                }
            } else if copy.namesBusy {
                ProgressView().controlSize(.small)
            }
            if !current {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Aggiornamento elenco…").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,minHeight:80)
            } else if visibleRows.isEmpty {
                Text("Nessun elemento nella selezione.").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80)
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(visibleRows) { item in
                            HStack(alignment:.top,spacing:10) {
                                Toggle("",isOn:Binding(get:{selected.contains(item.id)},set:{ value in
                                    if value { selected.insert(item.id) } else { selected.remove(item.id) }
                                })).toggleStyle(.checkbox).labelsHidden()
                                    .accessibilityLabel("Seleziona "+item.displayName)
                                    .disabled(!selectable(item) || !canSelect)
                                Image(systemName:item.isDirectory ? "folder" : "doc").foregroundStyle(.orange)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(item.displayName).font(.subheadline.weight(.semibold))
                                    Text(item.side.label+" · "+item.reason).font(.caption).foregroundStyle(.secondary)
                                    if let name=NameRectification.proposedName(item.name) {
                                        Text("Nuovo nome: "+name).foregroundStyle(.green).font(.caption)
                                    } else {
                                        Text("Correzione manuale").font(.caption).foregroundStyle(.orange)
                                    }
                                    Text(item.rootPath+"/"+item.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    if item.affectedDescendants>0 {
                                        Text("\(item.affectedDescendants) elementi contenuti interessati").font(.caption)
                                    }
                                }.frame(maxWidth:.infinity,alignment:.leading)
                                Button("Apri in Finder") { reveal(item) }.disabled(revealing || runtime.previewOnly)
                            }
                            Divider()
                        }
                    }
                }.frame(maxHeight:.infinity)
                HStack {
                    Text("\(pageOffset + 1)–\(pageOffset + visibleRows.count) di \(namePage?.total ?? 0) risultati")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Precedenti") { pageOffset = max(0,pageOffset-200) }
                        .disabled(!current || pageOffset == 0)
                    Button("Successivi") { pageOffset += 200 }
                        .disabled(!current || pageOffset + visibleRows.count >= (namePage?.total ?? 0))
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Label("Rettifica esclusivamente locale, dopo conferma. Nessuna sovrascrittura.",systemImage:"info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of:copy.namesRevision) { _ in
            selected.formIntersection(Set(copy.incompatibleNames.map(\.id)))
            pageOffset = 0
        }
        .onChange(of:selected) { _ in selectionRevision &+= 1 }
        .onChange(of:search) { _ in pageOffset = 0 }
        .onChange(of:directories) { _ in pageOffset = 0 }
        .task(id:listingRequest) { await loadPage(listingRequest) }
        .task(id:selectionRequest) { await resolveSelection(selectionRequest) }
        .sheet(item:$confirmation) { snapshot in
            VStack(alignment:.leading,spacing:12) {
                Text("Conferma rettifica dei nomi").font(.title2.bold())
                Text("\(snapshot.items.count) elementi selezionati. Verranno rinominati solo nelle sorgenti locali. Le modifiche saranno rilevate dal normale inventario: copia del nuovo percorso e cancellazione del precedente secondo le impostazioni mirror.")
                    .fixedSize(horizontal:false,vertical:true)
                Text("Spazi finali rimossi, punti finali e caratteri vietati sostituiti con -. Nomi riservati e collisioni restano nell’elenco.")
                    .font(.callout).fixedSize(horizontal:false,vertical:true)
                List(snapshot.items) { item in
                    VStack(alignment:.leading,spacing:3) {
                        Text(item.displayName+" → "+(NameRectification.proposedName(item.name) ?? "Correzione manuale")).font(.headline)
                        Text(item.rootPath+"/"+item.relativePath).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Annulla") { confirmation=nil }
                    Button("Conferma rettifica") {
                        let items=snapshot.items
                        guard !items.isEmpty else { return }
                        confirmation=nil
                        selected.removeAll()
                        runtime.rectifyNames(items)
                    }.buttonStyle(.borderedProminent).disabled(!canSelect || snapshot.items.isEmpty)
                }
            }.padding(20).frame(width:650,height:500)
        }
    }
    @MainActor private func loadPage(_ request:NameListingRequest) async {
        let items = copy.incompatibleNames
        // Coalesce rapid typing; tab switching and paging remain immediate.
        if !request.search.isEmpty {
            do { try await Task.sleep(nanoseconds:180_000_000) }
            catch { return }
        }
        let cancellation = SeedVerificationCancellation()
        let page = await withTaskCancellationHandler(operation:{
            await Task.detached(priority:.userInitiated) {
                IncompatibleNameListing.page(items:items,side:request.side,
                    directories:request.directories,search:request.search,
                    offset:request.offset,shouldContinue:{!cancellation.isCancelled})
            }.value
        },onCancel:{ cancellation.cancel() })
        guard !Task.isCancelled, listingRequest == request, let page else { return }
        namePage = page
        displayedRequest = request
    }

    @MainActor private func resolveSelection(_ request:NameSelectionRequest) async {
        let items = copy.incompatibleNames
        let selectedIDs = selected
        let cancellation = SeedVerificationCancellation()
        let resolved = await withTaskCancellationHandler(operation:{
            await Task.detached(priority:.userInitiated) {
                IncompatibleNameSelection.resolve(items:items,selectedIDs:selectedIDs,
                    shouldContinue:{!cancellation.isCancelled})
            }.value
        },onCancel:{ cancellation.cancel() })
        guard !Task.isCancelled, selectionRequest == request, let resolved else { return }
        selectedRows = resolved
        resolvedSelection = request
    }

    private func reveal(_ item:IncompatibleName) {
        guard let pair=model.configuredPairs().first(where:{$0.id==item.rootID}) else { message="Coppia non più configurata"; return }
        let expected=item.side == .source ? pair.path : pair.destination
        let volume=pair.expected
        revealing=true; message=""
        DispatchQueue.global(qos:.utility).async {
            do {
                let root=URL(fileURLWithPath:expected).standardizedFileURL
                let path=item.side == .source ? root.resolvingSymlinksInPath().path : root.path
                if item.side == .destination {
                    guard let volume,try VolumeFingerprint.read(at:root)==volume else { throw MountedCopyError.volumeChanged }
                }
                let url=try item.revealURL(expectedRoot:path)
                DispatchQueue.main.async {
                    self.revealing=false
                    guard !self.runtime.folderConfigurationBusy, let current=self.model.configuredPairs().first(where:{$0.id==item.rootID}),
                          (item.side == .source ? current.path : current.destination)==expected else {
                        self.message="Configurazione cambiata; aggiorna l'elenco"; return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                DispatchQueue.main.async {
                    self.revealing=false
                    self.message="Elemento non più presente o percorso non verificabile. Aggiorna l'elenco."
                    self.copy.refreshIncompatibleNames(pairs:self.model.configuredPairs())
                }
            }
        }
    }
}
