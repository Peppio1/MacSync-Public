import AppKit
import SwiftUI
import MacSyncCore

struct TechnicalLogSheet: View {
    @ObservedObject var copy: MountedCopyController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var filter = ""
    @State private var level = "all"
    @State private var loading = false
    @State private var status = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Registro tecnico").font(.title2.bold())
                Spacer()
                Button("Chiudi") { dismiss() }
            }
            HStack {
                TextField("Cerca file, componente o codice errore",text:$filter)
                    .onSubmit { load() }
                Picker("Livello",selection:$level) {
                    Text("Tutti").tag("all")
                    ForEach(["info","success","warning","error"],id:\.self) { Text($0).tag($0) }
                }.frame(width:180)
                Button("Aggiorna") { load() }.disabled(loading)
            }
            if loading { ProgressView().controlSize(.small) }
            ScrollView([.vertical,.horizontal]) {
                Text(text.isEmpty ? "Nessun evento disponibile" : text)
                    .font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.topLeading).padding(8)
            }.background(Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
            Text(status).font(.caption)
            Text("Ultimi 5.000 eventi corrispondenti. Controlla i nomi dei file prima di condividere.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Copia log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text,forType:.string)
                }.disabled(text.isEmpty || loading)
                Button("Esporta TSV…") {
                    let panel=NSSavePanel()
                    panel.nameFieldStringValue="MacSync-log-tecnico.tsv"
                    if panel.runModal() == .OK, let url=panel.url {
                        do { try text.write(to:url,atomically:true,encoding:.utf8); status="Registro esportato" }
                        catch { status=error.localizedDescription }
                    }
                }.disabled(text.isEmpty || loading)
            }
        }.padding(20).frame(minWidth:800,minHeight:540)
        .onAppear { load() }
        .onChange(of:level) { _ in load() }
    }
    private func load() {
        do {
            let path=try copy.historyPath()
            let query=filter, selected=SyncLogLevel(rawValue:level)
            loading=true
            DispatchQueue.global(qos:.utility).async {
                do {
                    let result=try SyncActivityLog(path:path).exportText(limit:5000,level:selected,search:query)
                    DispatchQueue.main.async { text=result; status="Registro aggiornato"; loading=false }
                } catch {
                    let detail=error.localizedDescription
                    DispatchQueue.main.async { status=detail; loading=false }
                }
            }
        } catch { status=error.localizedDescription; loading=false }
    }
}
