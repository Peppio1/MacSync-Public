import AppKit
import SwiftUI
import Combine
import MacSyncCore

struct TechnicalLogSheet: View {
    @ObservedObject var copy: MountedCopyController
    var fixtureRows:[TechnicalLogRow]? = nil
    var model:MacSyncViewModel? = nil
    var previewOnly=false
    @AppStorage(TechnicalLogVerbosity.preferenceKey) private var verbosity="normal"
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
    @State private var complete = false
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
    private static let calendar:DateFormatter = {
        let f=DateFormatter(); f.dateFormat="dd/MM/yyyy HH:mm"; return f
    }()
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
                Text(complete ? "Log Completo" : "Registro tecnico").font(.title2.bold())
                Spacer()
                Button(complete ? "Torna al registro" : "Chiudi") {
                    if complete { switchView(complete: false) } else { dismiss() }
                }
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
            }
            if !complete {
                HStack {
                Picker("Dettaglio",selection:$verbosity) {
                    Text("Normale").tag("normal")
                    Text("Dettagliato").tag("detailed")
                    Text("Debug").tag("debug")
                }.frame(width:260)
                Spacer()
                Text("Si applica alle prossime operazioni Rclone").font(.caption).foregroundStyle(.secondary)
                }
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
                    if complete {
                        ForEach(rows) { row in eventRow(row) }
                    } else {
                    ForEach(groups) { group in
                        DisclosureGroup(isExpanded:Binding(
                            get:{expanded.contains(group.id)},
                            set:{ value in if value { expanded.insert(group.id) } else { expanded.remove(group.id) } })) {
                            LazyVStack(alignment:.leading,spacing:6) {
                                ForEach(group.rows) { row in eventRow(row) }
                            }.padding(.top,8)
                        } label: {
                            VStack(alignment:.leading,spacing:3) {
                                Text(group.id=="legacy" ? "Eventi senza ciclo (storico / manutenzione)" : "Ciclo "+(group.rows.last.map { Self.calendar.string(from:$0.entry.timestamp) } ?? String(group.id.prefix(8)))).font(.headline)
                                if let conclusion=group.rows.first(where:{$0.entry.action=="cycle"}) {
                                    Text(conclusion.entry.message).font(.caption).lineLimit(2)
                                }
                                Text("\(group.rows.count) eventi caricati • \(group.rows.filter{$0.entry.level=="error"}.count) errori • \(group.rows.filter{$0.entry.level=="warning"}.count) avvisi").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                    }
                    }
                    if more && (complete || rows.count<displayLimit) {
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
            if !complete {
                HStack {
                    Spacer()
                    Button("Log Completo") { switchView(complete: true) }
                }
            }
        }.padding(20).frame(minWidth:850,minHeight:580)
        .onAppear {
            if let fixtureRows {
                rows=fixtureRows; status="Dati dimostrativi"
                if let first=rows.first { expanded.insert(first.cycleID ?? "legacy") }
            } else { reset() }
        }
        .onChange(of:level) { _ in if fixtureRows==nil { reset() } }
        .onReceive(ticker) { _ in if fixtureRows==nil && !loading && !complete { refresh() } }
    }
    private func eventRow(_ row:TechnicalLogRow) -> some View {
        let e=row.entry
        return DisclosureGroup {
            VStack(alignment:.leading,spacing:4) {
                Text("Azione: "+e.action+" · radice: "+e.rootID)
                if let cycle=row.cycleID { Text("Ciclo: "+cycle) }
                if let job=row.jobID { Text("Operazione: #"+String(job)) }
                if !e.relativePath.isEmpty { LogArchivePathDetail(entry:e,model:model,disabled:previewOnly || fixtureRows != nil) }
                if e.bytes>0 { Text(ByteCountFormatter.string(fromByteCount:e.bytes,countStyle:.file)) }
                if e.durationSeconds>0 { Text(String(format:"Durata: %.3f s",e.durationSeconds)) }
                Text(e.message)
            }.font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(.leading,12)
        } label: {
            HStack(alignment:.top,spacing:8) {
                Image(systemName:symbol(e.level)).foregroundStyle(color(e.level)).frame(width:18)
                Text(complete ? e.timestamp.formatted(date: .numeric, time: .standard) : Self.clock.string(from:e.timestamp)).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                Text(row.component).font(.caption.bold()).frame(width:75,alignment:.leading)
                VStack(alignment:.leading,spacing:2) {
                    Text(e.message).font(.callout).lineLimit(complete ? nil : 2)
                    if !e.relativePath.isEmpty { Text(e.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength:0)
            }
        }.padding(.vertical,3)
    }
    private enum LoadMode: Equatable { case first, older, newer }
    private func switchView(complete: Bool) {
        self.complete = complete
        filter = ""
        if level != "all" { level = "all" }
        reset()
    }
    private func reset() {
        guard fixtureRows == nil else { return }
        appliedFilter=filter
        rows=[]; more=false; expanded=[]
        load(.first)
    }
    private func refresh() { load(rows.isEmpty ? .first : .newer) }
    private func load(_ mode:LoadMode) {
        guard fixtureRows==nil else { return }
        do {
            let path=try copy.historyPath(), selected=SyncLogLevel(rawValue:level), query=appliedFilter
            let token=UUID()
            request=token; loading=true
            let before=mode == .older ? rows.last?.id : nil
            let after=mode == .newer ? rows.first?.id : nil
            let count=pageSize
            let complete = self.complete
            let started = ProcessInfo.processInfo.systemUptime
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
                        case .older:
                            if complete { rows.append(contentsOf: batch) }
                            else { rows=Array((rows+batch).prefix(displayLimit)) }
                            more=page.count>count
                        case .newer:
                            if page.count>count { rows=batch; more=true }
                            else { rows=Array((batch+rows).prefix(displayLimit)) }
                        }
                        if mode == .first, let first=rows.first { expanded.insert(first.cycleID ?? "legacy") }
                        status="Registro aggiornato"; loading=false
                        if mode == .first && complete {
                            MountedCopyController.recordDiagnosticDuration("metric_full_log_open",
                                seconds: ProcessInfo.processInfo.systemUptime - started)
                        }
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
}
