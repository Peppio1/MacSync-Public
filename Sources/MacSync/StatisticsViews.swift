import Foundation
import AppKit
import SwiftUI
import MacSyncCore

func elapsedText(_ seconds: Double) -> String {
    let n = Int(max(0,min(seconds,Double(Int32.max))))
    return String(format:"%02d:%02d:%02d",n/3600,(n%3600)/60,n%60)
}
private func sizeText(_ n:Int64) -> String {
    ByteCountFormatter.string(fromByteCount:n,countStyle:.file)
}
private func stateText(_ state:String)->String {
    let base = state.replacingOccurrences(of:"_history_incomplete",with:"")
    let labels = ["completed":"Completata","partial":"Con errori o rinvii","interrupted":"Interrotta",
        "suspended":"Sospesa","running":"In corso"]
    return (labels[base] ?? base) + (state.contains("_history_incomplete") ? " — storico incompleto" : "")
}

struct LiveSyncPanel: View {
    @ObservedObject var copy: MountedCopyController
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            if let p = copy.liveProgress {
                TimelineView(.periodic(from:p.started,by:1)) { ctx in
                    let elapsed = max(0,ctx.date.timeIntervalSince(p.started))
                    HStack {
                        Label(p.phase,systemImage:"arrow.triangle.2.circlepath")
                        Spacer()
                        if p.planned > 0 { Text("\(Int(p.fraction*100))%").monospacedDigit().bold() }
                    }.font(.headline)
                    if p.planned > 0 {
                        ProgressView(value:p.fraction)
                        Text("\(p.processed) / \(p.planned) operazioni elaborate (stima del lavoro iniziale)")
                    } else { ProgressView().controlSize(.small) }
                    HStack {
                        Text("Inizio: \(p.started.formatted(date:.omitted,time:.standard))")
                        Spacer()
                        Text("Tempo: \(elapsedText(elapsed))").monospacedDigit()
                    }
                    Text("Velocità media copia: " + SyncLiveProgress.formatRate(p.meanCopyRate))
                    if !p.currentFile.isEmpty {
                        Text(p.currentFile).lineLimit(1).truncationMode(.middle)
                    }
                }
            } else {
                if let cycle = copy.lastRecordedCycle {
                    HStack {
                        Label(stateText(cycle.state),systemImage:cycle.state == "completed" ? "checkmark.circle" : "clock")
                        Spacer()
                        if cycle.state == "completed" { Text("100%").bold() }
                    }.font(.headline)
                    HStack {
                        Text("Inizio: \(cycle.started.formatted(date:.omitted,time:.standard))")
                        Spacer()
                        Text("Fine: \(cycle.ended?.formatted(date:.omitted,time:.standard) ?? "—")")
                        Spacer()
                        Text("Durata: \(cycle.seconds.map(elapsedText) ?? "—")")
                    }
                } else { Text(copy.active ? "In attesa del prossimo ciclo" : "Sincronizzazione ferma") }
                if let next = copy.nextScheduledRun {
                    Text("Prossimo ciclo: \(next.formatted(date:.abbreviated,time:.shortened))")
                }
            }
            if !copy.historyWarning.isEmpty { Text(copy.historyWarning).foregroundStyle(.orange) }
        }.font(.caption).padding(10)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.secondary.opacity(0.07)).cornerRadius(8)
    }
}

struct AuditProgressView: View {
    let progress: ArchiveAuditProgress
    var body: some View {
        TimelineView(.periodic(from:progress.started,by:1)) { ctx in
            let elapsed = max(0.001,ctx.date.timeIntervalSince(progress.started))
            VStack(alignment:.leading,spacing:6) {
                Text(progress.phase).font(.headline)
                if progress.total > 0 && !progress.phase.hasPrefix("Analisi") {
                    ProgressView(value:min(0.99,Double(progress.compared)/Double(progress.total)))
                    Text("\(progress.compared) / \(progress.total) elementi confrontati")
                } else { ProgressView().controlSize(.small) }
                Text("File rilevati: \(progress.scannedFiles) · Cartelle: \(progress.scannedDirectories)")
                Text("Dimensione rilevata: \(sizeText(progress.detectedBytes)) · Tempo: \(elapsedText(elapsed))")
                if progress.phase.hasPrefix("Analisi") || progress.phase.hasPrefix("Inventario") {
                    Text("Velocità media scansione: \(Int(Double(progress.scannedFiles)/elapsed)) file/s")
                }
                if progress.bytesRead > 0 {
                    Text("Letti \(sizeText(progress.bytesRead)) · Media lettura locale + SMB: \(SyncLiveProgress.formatRate(Double(progress.bytesRead)/elapsed))")
                }
                if !progress.currentPath.isEmpty { Text(progress.currentPath).lineLimit(1).truncationMode(.middle) }
            }.font(.caption)
        }
    }
}

enum HistoryMetric: String, Identifiable, CaseIterable {
    case new, updated, removed, recovered, deferred, failed, directoryCreated, directoryRemoved, expired, backup, stage
    var id:String { rawValue }
    static let dashboard:[Self] = [.new,.updated,.removed,.recovered,.failed]
    static let main:[Self] = [.new,.updated,.removed,.recovered,.deferred,.failed]
    var title:String {
        switch self {
        case .new: return "Nuovi"
        case .updated: return "Aggiornati"
        case .removed: return "Eliminati"
        case .recovered: return "Recuperabili"
        case .deferred: return "Rimandati"
        case .failed: return "Errori"
        case .directoryCreated: return "Cartelle create"
        case .directoryRemoved: return "Cartelle rimosse"
        case .expired: return "Recuperi scaduti"
        case .backup: return "Backup di sicurezza"
        case .stage: return "Copie temporanee completate"
        }
    }
    var symbol:String {
        switch self {
        case .new: return "doc.badge.plus"
        case .updated: return "arrow.triangle.2.circlepath"
        case .removed: return "trash"
        case .recovered: return "archivebox"
        case .deferred: return "clock"
        case .failed: return "exclamationmark.triangle"
        default: return "folder"
        }
    }
    var kinds:[SyncEventKind] {
        switch self {
        case .new: return [.newFile]
        case .updated: return [.updatedFile]
        case .removed: return [.deleted,.recovered]
        case .recovered: return [.recovered]
        case .deferred: return [.deferred]
        case .failed: return [.failed]
        case .directoryCreated: return [.directoryCreated]
        case .directoryRemoved: return [.directoryRemoved]
        case .expired: return [.recoveryExpired]
        case .backup: return [.backupCopy]
        case .stage: return [.stageCopy]
        }
    }
    func count(_ s:SyncDashboardStats)->Int {
        switch self {
        case .new: return s.newFiles
        case .updated: return s.updatedFiles
        case .removed: return s.permanentlyDeleted+s.movedToRecovery
        case .recovered: return s.movedToRecovery
        case .deferred: return s.deferred
        case .failed: return s.failed
        case .directoryCreated: return s.createdDirectories
        case .directoryRemoved: return s.removedDirectories
        case .expired: return s.expiredRecovery
        default: return 0
        }
    }
}

/// Read-only historical links. Never open a substituted symlink or an
/// arbitrary path outside the stored archive. The current filesystem may
/// no longer contain the version recorded by the cycle.
@MainActor
private func openArchivePath(root:String,relative:String,showFile:Bool) -> String? {
    guard !root.isEmpty,root.hasPrefix("/"),!relative.isEmpty,
          relative.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({
              !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0")
          }) else { return "Percorso non disponibile" }
    let base=URL(fileURLWithPath:root).standardizedFileURL
    let item=base.appendingPathComponent(relative).standardizedFileURL
    let desired=showFile ? item : item.deletingLastPathComponent()
    guard desired.path == base.path || desired.path.hasPrefix(base.path+"/"),
          desired.resolvingSymlinksInPath().path == desired.path,
          FileManager.default.fileExists(atPath:desired.path) else { return "File/cartella non disponibile o percorso modificato" }
    if showFile {
        var isDir:ObjCBool=false
        guard FileManager.default.fileExists(atPath:item.path,isDirectory:&isDir), !isDir.boolValue else { return "File non disponibile" }
        return NSWorkspace.shared.open(item) ? nil : "Nessuna applicazione disponibile"
    }
    if item.resolvingSymlinksInPath().path == item.path && FileManager.default.fileExists(atPath:item.path) {
        NSWorkspace.shared.activateFileViewerSelecting([item])
    } else { NSWorkspace.shared.open(desired) }
    return nil
}

struct SyncHistorySheet: View {
    @ObservedObject var copy: MountedCopyController
    @Environment(\.dismiss) private var dismiss
    let initialMetric:HistoryMetric?
    @State private var selected = "session"
    @State private var cycles:[SyncCycleRecord] = []
    @State private var totals = SyncHistoryTotals()
    @State private var metric:HistoryMetric?
    @State private var busy=false
    @State private var message=""
    @State private var cycleOffset=0
    @State private var moreCycles=true
    private var selectedCycle:SyncCycleRecord? { cycles.first { $0.id == selected } }
    private var sessionID:String? { selected == "session" ? copy.historySessionID : nil }
    private var cycleID:String? { selected == "session" ? nil : selected }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Riepilogo sincronizzazione").font(.title2.bold())
                Spacer(); Button("Aggiorna") { loadCycles(reset:true) }
                Button("Chiudi") { dismiss() }
            }
            Picker("Periodo",selection:$selected) {
                Text("Sessione corrente").tag("session")
                ForEach(cycles) { cycle in
                    Text(cycle.started.formatted(date:.abbreviated,time:.standard) + " — " + stateText(cycle.state)).tag(cycle.id)
                }
            }
            if moreCycles { Button("Carica altri cicli") { loadCycles(reset:false) }.disabled(busy) }
            if let c=selectedCycle {
                HStack {
                    Text("Inizio: \(c.started.formatted(date:.abbreviated,time:.standard))")
                    Text("Fine: \(c.ended?.formatted(date:.abbreviated,time:.standard) ?? "—")")
                    Spacer()
                    Text(c.seconds.map(elapsedText) ?? "—").monospacedDigit()
                }.font(.caption)
            }
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:8) {
                ForEach(HistoryMetric.main) { m in
                    Button { metric=m } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Label(m.title,systemImage:m.symbol).font(.caption)
                            Text(m.count(totals.stats).formatted()).font(.title2.bold())
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                    }.buttonStyle(.bordered)
                }
            }
            Text("Eliminati comprende i recuperabili, senza contare backup, temporanei, cartelle o file già assenti.").font(.caption)
            Group {
                Text("Dati sincronizzati: \(sizeText(totals.stats.bytesTransferred))")
                Text("Backup creati: \(sizeText(totals.backupBytes)) — non equivale al traffico VPN")
                Text("Velocità media copia in staging: \(SyncLiveProgress.formatRate(totals.meanCopyRate))")
                HStack {
                    ForEach([HistoryMetric.directoryCreated,.directoryRemoved,.expired]) { m in
                        Button("\(m.title): \(m.count(totals.stats))") { metric=m }
                    }
                }
                HStack {
                    Button("Dettaglio backup") { metric = .backup }
                    Button("Dettaglio copie temporanee") { metric = .stage }
                }
            }.font(.caption)
            Divider()
            Text("Per coppia di cartelle").font(.headline)
            ScrollView {
                VStack(alignment:.leading) {
                    ForEach(totals.byRoot.keys.sorted(),id:\.self) { root in
                        if let stats=totals.byRoot[root] {
                            Text(root).bold()
                            Text("Nuovi \(stats.newFiles) · Aggiornati \(stats.updatedFiles) · Eliminati \(stats.permanentlyDeleted+stats.movedToRecovery) · Recuperabili \(stats.movedToRecovery) · Rimandati \(stats.deferred) · Errori \(stats.failed)")
                                .font(.caption)
                            Text(sizeText(stats.bytesTransferred)).font(.caption)
                        }
                    }
                }.frame(maxWidth:.infinity,alignment:.leading)
            }
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).foregroundStyle(.orange).font(.caption) }
            Text("Storico dal rilascio 0.12.4. I percorsi aprono il file attuale, non una copia storica.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width:810,height:690)
        .onAppear { loadCycles(reset:true); if let initialMetric { metric=initialMetric } }
        .onChange(of:selected) { _ in loadTotals() }
        .sheet(item:$metric) { item in
            HistoryDetailsSheet(copy:copy,metric:item,cycleID:cycleID,sessionID:sessionID,roots:totals.byRoot.keys.sorted())
        }
    }
    private func loadCycles(reset:Bool) {
        guard !busy else { return }
        do {
            let path=try copy.historyPath()
            let offset=reset ? 0 : cycleOffset
            busy=true
            DispatchQueue.global(qos:.utility).async {
                do {
                    let values=try SyncCycleHistory(path:path).cycles(limit:100,offset:offset)
                    DispatchQueue.main.async {
                        if reset { cycles=values } else { cycles += values }
                        cycleOffset=offset+values.count; moreCycles=values.count==100
                        if selected != "session" && !cycles.contains(where:{$0.id==selected}) { selected="session" }
                        busy=false; loadTotals()
                    }
                } catch { DispatchQueue.main.async { busy=false; message=error.localizedDescription } }
            }
        } catch { message=error.localizedDescription }
    }
    private func loadTotals() {
        let cycle=cycleID,session=sessionID,scope=selected
        do {
            let path=try copy.historyPath()
            DispatchQueue.global(qos:.utility).async {
                do {
                    let result=try SyncCycleHistory(path:path).totals(cycleID:cycle,sessionID:session)
                    DispatchQueue.main.async { if scope==selected { totals=result } }
                } catch { DispatchQueue.main.async { message=error.localizedDescription } }
            }
        } catch { message=error.localizedDescription }
    }
}

private struct HistoryDetailsSheet:View {
    @ObservedObject var copy:MountedCopyController
    let metric:HistoryMetric
    let cycleID:String?
    let sessionID:String?
    let roots:[String]
    @Environment(\.dismiss) private var dismiss
    @State private var rows:[SyncHistoryRow]=[]
    @State private var search=""
    @State private var root=""
    @State private var sort="time"
    @State private var message=""
    @State private var busy=false
    @State private var more=true
    @State private var cursor:Int64=0
    @State private var selectedRow:Int64?
    private var ordered:[SyncHistoryRow] {
        switch sort {
        case "name":return rows.sorted{$0.event.relativePath.localizedStandardCompare($1.event.relativePath) == .orderedAscending}
        case "size":return rows.sorted{($0.event.bytes ?? -1)>($1.event.bytes ?? -1)}
        default:return rows
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text(metric.title).font(.title2.bold()); Spacer(); Button("Chiudi"){dismiss()} }
            HStack {
                TextField("Cerca nome o percorso",text:$search).onSubmit { load(reset:true) }
                Picker("Coppia",selection:$root) {
                    Text("Tutte").tag("")
                    ForEach(roots,id:\.self) { Text($0).tag($0) }
                }.frame(width:210)
                Button("Cerca"){load(reset:true)}.disabled(busy)
                Picker("Ordina pagina",selection:$sort){
                    Text("Ora").tag("time");Text("Nome").tag("name");Text("Dimensione").tag("size")
                }.frame(width:175)
            }
            Table(ordered,selection:$selectedRow) {
                TableColumn("File / percorso") { row in Text(row.event.relativePath).lineLimit(2) }.width(min:240,ideal:360)
                TableColumn("Coppia") { row in Text(row.event.rootID) }.width(min:110,ideal:130)
                TableColumn("Dimensione") { row in Text(row.event.bytes.map(sizeText) ?? "—") }.width(85)
                TableColumn("Ora") { row in Text(row.event.at.formatted(date:.abbreviated,time:.standard)) }.width(150)
                TableColumn("Esito") { row in Text(row.event.detail.isEmpty ? row.event.kind.rawValue : row.event.detail) }
            }
            HStack {
                Text("\(rows.count) righe caricate")
                if more { Button("Carica altre"){load(reset:false)}.disabled(busy) }
                Spacer()
                Button("Visualizza"){open(show:true)}
                    .disabled(rows.first(where:{$0.id==selectedRow}).map{!canView($0.event)} ?? true)
                Button("Apri percorso"){open(show:false)}.disabled(selectedRow==nil)
            }
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.orange) }
        }.padding(18).frame(width:1000,height:540)
        .onAppear{load(reset:true)}
        .onChange(of:root){_ in load(reset:true)}
    }
    private func canView(_ e:SyncCycleEvent)->Bool {
        ![.deleted,.directoryCreated,.directoryRemoved,.recoveryExpired,.backupCopy,.stageCopy].contains(e.kind)
             && (e.kind != .recovered || e.recoveryPath != nil)
    }
    private func open(show:Bool) {
        guard let row=rows.first(where:{$0.id==selectedRow}) else{return}
        let e=row.event
        if show && !canView(e) { return }
        if e.kind == .recovered,let path=e.recoveryPath,path.hasPrefix(e.targetRoot+"/.macsync-recovery/") {
            message=openArchivePath(root:e.targetRoot,relative:String(path.dropFirst(e.targetRoot.count+1)),showFile:show) ?? ""
        } else {
            let useSource=(e.kind == .deferred || e.kind == .failed) && !e.isDeleteJob
            message=openArchivePath(root:useSource ? e.sourceRoot:e.targetRoot,relative:e.relativePath,showFile:show) ?? ""
        }
    }
    private func load(reset:Bool) {
        if busy { return }
        do {
            let path=try copy.historyPath(),filter=root.isEmpty ? nil:root,query=search
            let after=reset ? 0:cursor
            busy=true
            DispatchQueue.global(qos:.utility).async {
                do {
                    let page=try SyncCycleHistory(path:path).events(cycleID:cycleID,sessionID:sessionID,
                        kinds:metric.kinds,rootID:filter,search:query,afterID:after,limit:200)
                    DispatchQueue.main.async {
                        if reset { rows=page; selectedRow=nil } else { rows+=page }
                        cursor=page.last?.id ?? after; more=page.count==200; busy=false
                    }
                } catch { DispatchQueue.main.async { busy=false;message=error.localizedDescription } }
            }
        } catch { message=error.localizedDescription }
    }
}

struct ArchiveAuditPanel:View {
    @ObservedObject var copy:MountedCopyController
    @ObservedObject var runtime:MacSyncRuntime
    @ObservedObject var model:MacSyncViewModel
    @State private var selectedFinding:AuditFindingKind?
    @State private var showFindings=false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Verifica completa dell'archivio").font(.headline)
            Group {
                Picker("Metodo",selection:$copy.auditSettings.mode) {
                    Text("Rapida (metadati)").tag(ArchiveAuditMode.quick)
                    Text("Approfondita (SHA-256)").tag(ArchiveAuditMode.deep)
                }
                Toggle("Accoda copie e aggiornamenti per riallineare",isOn:$copy.auditSettings.repair)
                Toggle("Programma verifica automatica",isOn:$copy.auditSettings.enabled)
                if copy.auditSettings.enabled {
                    Picker("Frequenza",selection:$copy.auditSettings.frequency) {
                        Text("Ogni giorno").tag("daily");Text("Ogni settimana").tag("weekly");Text("Ogni mese").tag("monthly")
                    }
                    if copy.auditSettings.frequency=="weekly" {
                        Picker("Giorno",selection:$copy.auditSettings.weekday) {
                            ForEach(1...7,id:\.self){day in Text(Calendar.current.weekdaySymbols[day-1]).tag(day)}
                        }
                    } else if copy.auditSettings.frequency=="monthly" {
                        Picker("Giorno del mese",selection:$copy.auditSettings.monthDay) {
                            ForEach(1...28,id:\.self){Text(String($0)).tag($0)}
                        }
                    }
                    HStack {
                        Picker("Ora",selection:$copy.auditSettings.hour) { ForEach(0...23,id:\.self){Text(String(format:"%02d",$0)).tag($0)} }.frame(width:130)
                        Picker("Minuti",selection:$copy.auditSettings.minute) { ForEach(0...59,id:\.self){Text(String(format:"%02d",$0)).tag($0)} }.frame(width:150)
                        Spacer()
                    }
                    if let next=runtime.nextAuditAt { Text("Prossima: \(next.formatted(date:.abbreviated,time:.shortened))").font(.caption) }
                }
            }.disabled(copy.active || copy.maintaining || copy.seedBusy)
            Text("Non elimina elementi presenti solo sul server. SHA-256 può leggere l'intero archivio via VPN. Il riallineamento resta soggetto alla normale coda e ai controlli di sicurezza.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if copy.auditBusy { Button("Annulla verifica"){copy.cancelArchiveAudit()} }
                else { Button("Esegui verifica adesso"){copy.startArchiveAudit(sources:model.configuredPairs(),interactive:true)}
                    .disabled(copy.maintaining || copy.seedBusy || !model.monitoring) }
                Spacer()
                Button("Ultimo risultato…"){selectedFinding=nil;showFindings=true}.disabled(copy.auditReport==nil)
            }
            Text(copy.auditStatus).font(.caption)
            if let p=copy.auditProgress { AuditProgressView(progress:p) }
            if let report=copy.auditReport {
                LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:2),spacing:6) {
                    ForEach(AuditFindingKind.allCases,id:\.rawValue){kind in
                        Button("\(kind.label): \(report.count(kind))"){selectedFinding=kind;showFindings=true}
                    }
                }
                Text("Inizio \(report.started.formatted(date:.abbreviated,time:.standard)) · Fine \(report.ended.formatted(date:.abbreviated,time:.standard)) · \(elapsedText(report.seconds))")
                    .font(.caption)
                Text("Elementi accodati: \(report.queuedRepairs) · Lettura SHA-256: \(sizeText(report.bytesRead))").font(.caption)
            }
        }
        .onChange(of:copy.auditSettings){_ in runtime.scheduleArchiveAudit()}
        .sheet(isPresented:$showFindings){
            if let report=copy.auditReport { AuditResultSheet(report:report,kind:selectedFinding) }
        }
    }
}
private struct AuditResultSheet:View {
    let report:ArchiveAuditReport
    let kind:AuditFindingKind?
    @State private var search=""
    @State private var root=""
    @State private var selected:String?
    @State private var message=""
    @Environment(\.dismiss) private var dismiss
    private var rows:[AuditFinding] {
        report.findings.filter { f in
            (kind==nil || kind==f.kind) && (root.isEmpty || root==f.rootID) &&
            (search.isEmpty || f.relativePath.localizedCaseInsensitiveContains(search))
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Text(kind?.label ?? "Risultato verifica completa").font(.title2.bold());Spacer();Button("Chiudi"){dismiss()} }
            HStack {
                TextField("Cerca per percorso",text:$search)
                Picker("Coppia",selection:$root) {
                    Text("Tutte").tag("")
                    ForEach(Set(report.findings.map(\.rootID)).sorted(),id:\.self){ Text($0).tag($0) }
                }.frame(width:240)
            }
            Table(rows,selection:$selected) {
                TableColumn("Percorso",value:\.relativePath).width(min:260,ideal:400)
                TableColumn("Coppia",value:\.rootID).width(130)
                TableColumn("Esito"){Text($0.kind.label)}.width(180)
                TableColumn("Tipo",value:\.objectKind).width(70)
                TableColumn("Motivo",value:\.detail)
            }
            HStack {
                Text("\(rows.count) elementi")
                Spacer()
                Button("Visualizza"){open(true)}.disabled(rows.first(where:{$0.id==selected})?.objectKind != "file")
                Button("Apri percorso"){open(false)}.disabled(selected==nil)
            }
            Text(message).foregroundStyle(.orange).font(.caption)
        }.padding(18).frame(width:1000,height:600)
    }
    private func open(_ show:Bool) {
        guard let f=report.findings.first(where:{$0.id==selected}) else{return}
        let root=f.kind == .extra || f.kind == .matching ? f.targetRoot:f.sourceRoot
        message=openArchivePath(root:root,relative:f.relativePath,showFile:show) ?? ""
    }
}
