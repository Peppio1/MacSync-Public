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

struct IncompatibleNamesPanel:View {
    @ObservedObject var copy:MountedCopyController
    @ObservedObject var model:MacSyncViewModel
    @ObservedObject var runtime:MacSyncRuntime
    @State private var directories=true
    @State private var side="all"
    @State private var search=""
    @State private var message=""
    @State private var revealing=false
    @State private var selected=Set<String>()
    @State private var confirmation:[IncompatibleName]=[]
    @State private var showConfirmation=false
    @State private var pageOffset=0
    @State private var namePage:IncompatibleNameListPage?
    @State private var displayedRequest:NameListingRequest?
    @State private var selectedRows:[IncompatibleName]=[]
    @State private var selectionRevision=0
    @State private var resolvedSelection:NameSelectionRequest?

    private var listingRequest:NameListingRequest {
        .init(revision:copy.namesRevision,side:side,directories:directories,
              search:search,offset:pageOffset)
    }
    private var selectionRequest:NameSelectionRequest {
        .init(revision:selectionRevision,namesRevision:copy.namesRevision)
    }
    private var chosen:[IncompatibleName] { selectedRows }
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
                    ForEach(IncompatibleName.Side.allCases, id: \.rawValue) { position in
                        let folders = position == .source ? (namePage?.sourceFolders ?? 0) : (namePage?.destinationFolders ?? 0)
                        let files = position == .source ? (namePage?.sourceFiles ?? 0) : (namePage?.destinationFiles ?? 0)
                        Text("\(position.label): \(folders) cartelle · \(files) file").font(.subheadline)
                    }
                    Text("I nomi già corrispondenti possono essere incompatibili con nuove copie. Le due posizioni sono contate separatamente.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(copy.namesStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if copy.scanningNames {
                    Button("Annulla scansione") { copy.cancelNameScan() }
                }
                Button("Scansiona nomi incompatibili") {
                    copy.refreshIncompatibleNames(pairs: model.configuredPairs(), scan: true)
                }.disabled(copy.namesBusy || copy.auditBusy || runtime.previewOnly)
            }
            HStack {
                Picker("Tipo",selection:$directories) {
                    Text("Cartelle").tag(true)
                    Text("File").tag(false)
                }.pickerStyle(.segmented)
                Picker("Posizione",selection:$side) {
                    Text("Tutte").tag("all")
                    Text("Sorgente").tag("source")
                    Text("Destinazione").tag("destination")
                }.frame(width:190)
            }
            TextField("Cerca nome, percorso o motivo…",text:$search).textFieldStyle(.roundedBorder)
            HStack {
                Button("Seleziona tutto") {
                    selected.formUnion(namePage?.selectableIDs ?? [])
                }
                    .help("Seleziona tutti i nomi rettificabili dei due lati, anche fuori dalla pagina corrente")
                    .disabled(!current || namePage?.selectableIDs.isEmpty != false || !canSelect)
                Button("Seleziona visibili") { selected.formUnion(namePage?.matchingSelectableIDs ?? []) }
                    .help("Seleziona tutti i risultati del filtro, anche nelle altre pagine")
                    .disabled(!current || !canSelect || namePage?.matchingSelectableIDs.isEmpty != false)
                Button("Deseleziona") { selected.removeAll() }.disabled(selected.isEmpty)
                Spacer()
                if runtime.rectificationPending {
                    Button("Riprendi pendenti") { runtime.resumeNameRectification() }
                        .disabled(!canRectify || copy.active)
                }
                Button(selectionCurrent ? "Rettifica (\(chosen.count))" : "Calcolo selezione…") {
                    confirmation=chosen;showConfirmation=true
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
                Text("Alcune rettifiche sono in sospeso. Puoi selezionare singole voci o riprendere le operazioni pendenti.")
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
            Label("Rettifica dopo conferma sui lati interessati. Nessuna sovrascrittura.",systemImage:"info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of:copy.namesRevision) { _ in
            selected.formIntersection(Set(copy.incompatibleNames.map(\.id)))
            pageOffset = 0
        }
        .onChange(of:selected) { _ in selectionRevision &+= 1 }
        .onChange(of:search) { _ in pageOffset = 0 }
        .onChange(of:side) { _ in pageOffset = 0 }
        .onChange(of:directories) { _ in pageOffset = 0 }
        .task(id:listingRequest) { await loadPage(listingRequest) }
        .task(id:selectionRequest) { await resolveSelection(selectionRequest) }
        .sheet(isPresented:$showConfirmation) {
            VStack(alignment:.leading,spacing:12) {
                Text("Conferma rettifica dei nomi").font(.title2.bold())
                Text("\(confirmation.count) elementi selezionati. Le copie automatiche e le cancellazioni speculari verranno disattivate. Il monitor verrà riavviato al termine. Le voci con lo stesso percorso sui due lati vengono incluse nel lotto.")
                    .fixedSize(horizontal:false,vertical:true)
                Text("Spazi e punti finali rimossi, caratteri vietati sostituiti con -. Nomi riservati e collisioni restano nell’elenco. Se un lato fallisce prima della rinomina remota, il nome locale viene ripristinato; gli esiti incerti restano protetti. Dopo la rettifica, esegui Verifica archivio prima di riavviare la sincronizzazione.")
                    .font(.callout).fixedSize(horizontal:false,vertical:true)
                List(confirmation) { item in
                    VStack(alignment:.leading,spacing:3) {
                        Text(item.displayName+" → "+(NameRectification.proposedName(item.name) ?? "Correzione manuale")).font(.headline)
                        Text(item.rootPath+"/"+item.relativePath).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Annulla") { showConfirmation=false }
                    Button("Conferma rettifica") {
                        let items=confirmation
                        showConfirmation=false
                        selected.removeAll()
                        runtime.rectifyNames(items)
                    }.buttonStyle(.borderedProminent).disabled(!canSelect)
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
