import AppKit
import SwiftUI
import Combine
import MacSyncCore

struct TechnicalLogSheet: View {
    @ObservedObject var copy: MountedCopyController
    @Environment(\.dismiss) private var dismiss
    @State private var rows:[TechnicalLogRow]=[]
    @State private var filter=""
    @State private var appliedFilter=""
    @State private var level="all"
    @State private var loading=false
    @State private var status=""
    @State private var fallback=""
    @State private var showFallback=false
    @State private var more=false
    @State private var expanded=Set<String>()
    @State private var request=UUID()
    private let ticker=Timer.publish(every:5,on:.main,in:.common).autoconnect()
    private let pageSize=100
    private let displayLimit=5000

    private struct CycleGroup: Identifiable {
        let id:String
        var rows:[TechnicalLogRow]
    }
    private var groups:[CycleGroup] {
        var index:[String:Int]=[:], result:[CycleGroup]=[]
        for row in rows {
            let key=row.cycleID ?? "legacy"
            if let i=index[key] { result[i].rows.append(row) }
            else { index[key]=result.count; result.append(CycleGroup(id:key,rows:[row])) }
        }
        return result
    }
    private static let clock:DateFormatter = {
        let f=DateFormatter(); f.dateFormat="HH:mm:ss.SSS"; return f
    }()
    private func color(_ level:String) -> Color {
        switch level { case "error": return .red; case "warning": return .orange; case "success": return .green; default: return .secondary }
    }
    private func symbol(_ level:String) -> String {
        switch level { case "error": return "xmark.circle"; case "warning": return "exclamationmark.triangle"; case "success": return "checkmark.circle"; default: return "info.circle" }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Registro tecnico").font(.title2.bold())
                Spacer()
                Button("Chiudi") { dismiss() }
            }
            HStack {
                TextField("Cerca file, azione, errore o ID",text:$filter).onSubmit { reset() }
                Button("Cerca") { reset() }
                Picker("Livello",selection:$level) {
                    Text("Tutti").tag("all")
                    Text("Errori").tag("error")
                    Text("Avvisi").tag("warning")
                    Text("Successi").tag("success")
                    Text("Info").tag("info")
                }.frame(width:180)
                Button("Aggiorna") { refresh() }.disabled(loading)
            }
            HStack {
                Text("\(rows.count) eventi caricati").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    if rows.isEmpty && !loading { Text("Nessun evento disponibile").foregroundStyle(.secondary).padding(10) }
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded:Binding(
                            get:{expanded.contains(group.id)},
                            set:{ value in if value { expanded.insert(group.id) } else { expanded.remove(group.id) } })) {
                            LazyVStack(alignment:.leading,spacing:6) {
                                ForEach(group.rows) { row in eventRow(row) }
                            }.padding(.top,8)
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(group.id=="legacy" ? "Eventi senza ciclo (storico / manutenzione)" : "Ciclo "+String(group.id.prefix(8))).font(.headline)
                                Text("\(group.rows.count) eventi caricati" + (group.rows.contains(where:{$0.entry.level=="error"}) ? " • contiene errori" : "")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                    }
                    if more && rows.count<displayLimit {
                        Button("Carica altri 100 eventi") { load(.older) }.disabled(loading).frame(maxWidth:.infinity)
                    }
                }.padding(8)
            }.background(Color.secondary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            DisclosureGroup("Diagnostica indipendente da SQLite",isExpanded:$showFallback) {
                ScrollView {
                    Text(fallback.isEmpty ? "Nessun evento diagnostico disponibile" : fallback)
                        .font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                        .frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:120)
                Button("Copia diagnostica") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fallback,forType:.string)
                }.disabled(fallback.isEmpty)
            }
            Text("Caricamento a pagine. Le esportazioni possono contenere nomi di file: controllali prima di condividerle.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Copia eventi caricati") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TechnicalLogRow.tsv(rows),forType:.string)
                }.disabled(rows.isEmpty)
                Button("Esporta fino a 5.000 eventi…") { export() }.disabled(loading)
            }
        }.padding(20).frame(minWidth:850,minHeight:580)
        .onAppear { reset() }
        .onChange(of:level) { _ in reset() }
        .onReceive(ticker) { _ in if !loading { refresh() } }
    }
    private func eventRow(_ row:TechnicalLogRow) -> some View {
        let e=row.entry
        return DisclosureGroup {
            VStack(alignment:.leading,spacing:4) {
                Text("Azione: "+e.action+" · radice: "+e.rootID)
                if let cycle=row.cycleID { Text("Ciclo: "+cycle) }
                if let job=row.jobID { Text("Operazione: #"+String(job)) }
                if !e.relativePath.isEmpty { Text("File: "+e.relativePath) }
                if e.bytes>0 { Text(ByteCountFormatter.string(fromByteCount:e.bytes,countStyle:.file)) }
                if e.durationSeconds>0 { Text(String(format:"Durata: %.3f s",e.durationSeconds)) }
                Text(e.message)
            }.font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(.leading,12)
        } label: {
            HStack(alignment:.top,spacing:8) {
                Image(systemName:symbol(e.level)).foregroundStyle(color(e.level)).frame(width:18)
                Text(Self.clock.string(from:e.timestamp)).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                Text(row.component).font(.caption.bold()).frame(width:75,alignment:.leading)
                VStack(alignment:.leading,spacing:2) {
                    Text(e.message).font(.callout).lineLimit(2)
                    if !e.relativePath.isEmpty { Text(e.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength:0)
            }
        }.padding(.vertical,3)
    }
    private enum LoadMode: Equatable { case first, older, newer }
    private func reset() {
        appliedFilter=filter
        rows=[]; more=false; expanded=[]
        load(.first)
    }
    private func refresh() { load(rows.isEmpty ? .first : .newer) }
    private func load(_ mode:LoadMode) {
        do {
            let path=try copy.historyPath(), selected=SyncLogLevel(rawValue:level), query=appliedFilter
            let token=UUID()
            request=token; loading=true
            let before=mode == .older ? rows.last?.id : nil
            let after=mode == .newer ? rows.first?.id : nil
            let count=pageSize
            DispatchQueue.global(qos:.utility).async {
                let diagnostics=TechnicalFallbackLog.recent(databasePath:path)
                do {
                    let reader=try SyncActivityLog(path:path,readOnly:true)
                    let page=try reader.technicalPage(limit:count+1,level:selected,search:query,beforeID:before,afterID:after)
                    DispatchQueue.main.async {
                        guard request==token else { return }
                        fallback=diagnostics
                        let batch=Array(page.prefix(count))
                        switch mode {
                        case .first: rows=batch; more=page.count>count
                        case .older: rows=Array((rows+batch).prefix(displayLimit)); more=page.count>count
                        case .newer:
                            if page.count>count { rows=batch; more=true }
                            else { rows=Array((batch+rows).prefix(displayLimit)) }
                        }
                        if mode == .first, let first=rows.first { expanded.insert(first.cycleID ?? "legacy") }
                        status="Registro aggiornato"; loading=false
                    }
                } catch {
                    let detail=SyncDiagnostic.describe(error)
                    DispatchQueue.main.async {
                        guard request==token else { return }
                        fallback=diagnostics; status="Registro SQLite non disponibile: "+detail; loading=false
                    }
                }
            }
        } catch { status=SyncDiagnostic.describe(error); loading=false }
    }
    private func export() {
        guard let path=try? copy.historyPath() else { return }
        let panel=NSSavePanel(); panel.nameFieldStringValue="MacSync-log-tecnico.tsv"
        guard panel.runModal()==.OK, let url=panel.url else { return }
        let selected=SyncLogLevel(rawValue:level), query=appliedFilter
        DispatchQueue.global(qos:.utility).async {
            do {
                let content=try SyncActivityLog(path:path,readOnly:true).technicalPage(limit:5000,level:selected,search:query)
                try TechnicalLogRow.tsv(content).write(to:url,atomically:true,encoding:.utf8)
                DispatchQueue.main.async { status="Registro esportato" }
            } catch {
                let detail=SyncDiagnostic.describe(error)
                DispatchQueue.main.async { status="Esportazione fallita: "+detail }
            }
        }
    }
}
