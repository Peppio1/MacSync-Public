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
    private var filtered:[IncompatibleName] {
        copy.incompatibleNames.filter { item in
            (side=="all" || item.side.rawValue==side) && item.isDirectory==directories &&
            (search.isEmpty || item.relativePath.localizedCaseInsensitiveContains(search) ||
             item.rootPath.localizedCaseInsensitiveContains(search) || item.reason.localizedCaseInsensitiveContains(search))
        }
    }
    var body:some View {
        MacSyncPanel("Nomi incompatibili",icon:"folder.badge.questionmark",fillHeight:true) {
            HStack {
                VStack(alignment:.leading,spacing:3) {
                    Text("Cartelle: \(copy.incompatibleNames.filter{$0.isDirectory}.count)  ·  File: \(copy.incompatibleNames.filter{!$0.isDirectory}.count)")
                        .font(.headline)
                    Text(copy.namesStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Aggiorna elenco") { copy.refreshIncompatibleNames(pairs:model.configuredPairs()) }
                    .disabled(copy.namesBusy || runtime.previewOnly)
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
            if copy.namesBusy { ProgressView().controlSize(.small) }
            if filtered.isEmpty {
                Text("Nessun elemento nella selezione.").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80)
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(filtered) { item in
                            HStack(alignment:.top,spacing:10) {
                                Image(systemName:item.isDirectory ? "folder" : "doc").foregroundStyle(.orange)
                                VStack(alignment:.leading,spacing:3) {
                                    Text(item.displayName).font(.subheadline.weight(.semibold))
                                    Text(item.side.label+" · "+item.reason).font(.caption).foregroundStyle(.secondary)
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
            Label("Nessuna rinomina automatica. Correggi preferibilmente la sorgente; la lista destinazione si aggiorna dopo la prossima verifica archivio.",systemImage:"info.circle")
                .font(.caption).foregroundStyle(.secondary)
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
