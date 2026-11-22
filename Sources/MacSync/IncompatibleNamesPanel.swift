import AppKit
import SwiftUI
import MacSyncCore

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
    private var eligible:[IncompatibleName] {
        copy.incompatibleNames.filter{selectable($0)}
    }
    private var chosen:[IncompatibleName] {
        let paths = Set(eligible.lazy.filter { selected.contains($0.id) }.map { $0.rootID + "\0" + $0.relativePath })
        return eligible.filter { paths.contains($0.rootID + "\0" + $0.relativePath) }
    }
    private var canRectify:Bool {
        !runtime.previewOnly && !runtime.folderConfigurationBusy && !runtime.shuttingDown &&
        !copy.auditBusy && !copy.seedBusy && !copy.maintaining && !copy.rectifyingNames && !copy.namesBusy
    }
    private var canSelect: Bool { canRectify && !runtime.rectificationPending }
    private func selectable(_ item:IncompatibleName)->Bool {
        NameRectification.proposedName(item.name) != nil
    }
    private var filtered:[IncompatibleName] {
        copy.incompatibleNames.filter { item in
            (side=="all" || item.side.rawValue==side) && item.isDirectory==directories &&
            (search.isEmpty || item.relativePath.localizedCaseInsensitiveContains(search) ||
             item.rootPath.localizedCaseInsensitiveContains(search) || item.reason.localizedCaseInsensitiveContains(search))
        }
    }
    var body:some View {
        // Evaluate the potentially large filtered collection once per render.
        // Heavy SMB scans and SQLite reads already run on background queues.
        let visibleRows = filtered
        return MacSyncPanel("Nomi incompatibili",icon:"folder.badge.questionmark",fillHeight:true) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    ForEach(IncompatibleName.Side.allCases, id: \.rawValue) { position in
                        let rows = copy.incompatibleNames.filter { $0.side == position }
                        let folders = rows.filter(\.isDirectory).count
                        Text("\(position.label): \(folders) cartelle · \(rows.count - folders) file").font(.subheadline)
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
                Button("Seleziona tutto") { selected.formUnion(eligible.map(\.id)) }
                    .help("Seleziona tutte le cartelle e tutti i file rettificabili sui due lati, anche nelle altre schede")
                    .disabled(eligible.isEmpty || !canSelect)
                Button("Seleziona visibili") { selected.formUnion(visibleRows.filter{selectable($0)}.map(\.id)) }
                    .disabled(!canSelect || !visibleRows.contains(where:{selectable($0)}))
                Button("Deseleziona") { selected.removeAll() }.disabled(chosen.isEmpty)
                Spacer()
                Button(runtime.rectificationPending ? "Riprendi rettifica" : "Rettifica (\(chosen.count))") {
                    if runtime.rectificationPending {
                        runtime.resumeNameRectification()
                    } else {
                        confirmation=chosen;showConfirmation=true
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(!canRectify || (runtime.rectificationPending ? copy.active : chosen.isEmpty))
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
                Text("Rettifica in sospeso. Riprendi il lotto quando le cartelle sono disponibili.")
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
            if visibleRows.isEmpty {
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
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Label("Rettifica dopo conferma sui lati interessati. Nessuna sovrascrittura.",systemImage:"info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of:copy.incompatibleNames.map(\.id)) { ids in selected.formIntersection(ids) }
        .sheet(isPresented:$showConfirmation) {
            VStack(alignment:.leading,spacing:12) {
                Text("Conferma rettifica dei nomi").font(.title2.bold())
                Text("\(confirmation.count) elementi selezionati. Le copie automatiche e le cancellazioni speculari verranno disattivate. Il monitor verrà riavviato al termine. Le voci con lo stesso percorso sui due lati vengono incluse nel lotto.")
                    .fixedSize(horizontal:false,vertical:true)
                Text("Spazi e punti finali rimossi, caratteri vietati sostituiti con -. Nomi riservati, conflitti e nomi già esistenti non saranno rettificati. Dopo la rettifica, esegui Verifica archivio prima di riavviare la sincronizzazione.")
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
