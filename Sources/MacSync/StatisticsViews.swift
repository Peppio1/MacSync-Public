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
func macSyncCycleState(_ state:String)->String {
    let base = state.replacingOccurrences(of:"_history_incomplete",with:"")
    let labels = ["completed":"Completata","partial":"Con errori o rinvii","interrupted":"Interrotta",
        "suspended":"Sospesa","running":"In corso"]
    return (labels[base] ?? base) + (state.contains("_history_incomplete") ? " — storico incompleto" : "")
}

struct MacSyncLinearProgress: View {
    let value: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MacSyncColors.line(scheme))
                Capsule().fill(MacSyncColors.blue(scheme)).frame(width: geo.size.width * min(1, max(0, value)))
            }
        }.frame(height: 8)
            .accessibilityLabel("Avanzamento")
            .accessibilityValue("\(Int(min(1,max(0,value))*100)) percento")
    }
}

struct LiveSyncPanel: View {
    @ObservedObject var copy: MountedCopyController
    @Environment(\.macSyncLayout) private var layout
    var body: some View {
        VStack(alignment:.leading,spacing:layout.compact ? 3 : 5) {
            if let p = copy.liveProgress {
                TimelineView(.periodic(from:p.started,by:1)) { ctx in
                    let elapsed = max(0,ctx.date.timeIntervalSince(p.started))
                    HStack {
                        Label(p.phase,systemImage:"arrow.triangle.2.circlepath")
                        Spacer()
                        if p.planned > 0 { Text("\(Int(p.fraction*100))%").monospacedDigit().bold() }
                    }.font(.headline)
                    if p.planned > 0 {
                        MacSyncLinearProgress(value:p.fraction)
                        Text("\(p.processed) / \(p.planned) operazioni elaborate (non percentuale di byte copiati)")
                        Text("File confermati: \(p.confirmedFiles) · Cartelle create: \(p.confirmedDirectories) · Rimandati: \(p.deferredOperations) · Errori: \(p.failedOperations)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Inizio").font(.caption).foregroundStyle(.secondary)
                            Text(macSyncClock(p.started, seconds: true)).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tempo trascorso").font(.caption).foregroundStyle(.secondary)
                            Text(elapsedText(elapsed)).monospacedDigit().font(.system(size: 16, weight: .semibold))
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rimanente stimato").font(.caption).foregroundStyle(.secondary)
                            Text(p.remaining(at:ctx.date).map(elapsedText) ?? "Calcolo…").monospacedDigit().font(.system(size: 16, weight: .semibold))
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Velocità media staging").font(.caption).foregroundStyle(.secondary)
                            Text(SyncLiveProgress.formatRate(p.meanCopyRate)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                        }
                    }
                    if !p.currentFile.isEmpty {
                        Text("File: " + p.currentFile).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).truncationMode(.middle).help(p.currentFile)
                    }
                }
            } else {
                if let cycle = copy.lastRecordedCycle {
                    HStack {
                        Label(macSyncCycleState(cycle.state),systemImage:cycle.state == "completed" ? "checkmark.circle" : "clock")
                        Spacer()
                        if cycle.state == "completed" { Text("100%").bold() }
                    }.font(.headline)
                    HStack {
                        Text("Inizio: \(macSyncClock(cycle.started, seconds: true))")
                        Spacer()
                        Text("Fine: \(cycle.ended.map { macSyncClock($0, seconds: true) } ?? "—")")
                        Spacer()
                        Text("Durata: \(cycle.seconds.map(elapsedText) ?? "—")")
                    }
                } else { Text(copy.active ? "In attesa del prossimo ciclo" : "Sincronizzazione ferma") }
                if copy.automaticCopiesEnabled,let next = copy.nextScheduledRun,next>Date() {
                    Text("Prossimo ciclo: \(macSyncDateTime(next))")
                }
            }
            if !copy.historyWarning.isEmpty { Text(copy.historyWarning).foregroundStyle(.orange) }
        }.font(.system(size: 13)).padding(layout.compact ? 7 : 10)
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.secondary.opacity(0.07)).cornerRadius(8)
    }
}

struct AuditProgressView: View {
    let progress: ArchiveAuditProgress
    var body: some View {
        TimelineView(.periodic(from:progress.started,by:1)) { ctx in
            let elapsed = max(0.001,ctx.date.timeIntervalSince(progress.started))
            VStack(alignment:.leading,spacing:4) {
                Text(progress.phase).font(.headline)
                if progress.total > 0 && !progress.phase.hasPrefix("Analisi") {
                    HStack {
                        MacSyncLinearProgress(value:min(0.99,Double(progress.compared)/Double(progress.total)))
                        Text("\(Int(min(0.99,Double(progress.compared)/Double(progress.total))*100))%").monospacedDigit().bold()
                    }
                    Text("\(progress.compared) / \(progress.total) elementi confrontati")
                } else { ProgressView().controlSize(.small) }
                Text("File rilevati: \(progress.scannedFiles) · Cartelle: \(progress.scannedDirectories)")
                Text("Dimensione rilevata: \(sizeText(progress.detectedBytes)) · Tempo: \(elapsedText(elapsed))")
                if progress.phase.hasPrefix("Analisi") || progress.phase.hasPrefix("Inventario") {
                    Text("Velocità media scansione: \(Int(Double(progress.scannedFiles)/elapsed)) file/s")
                }
                if progress.bytesRead > 0 {
                    Text("Letti \(sizeText(progress.bytesRead)) · Velocità media: \(SyncLiveProgress.formatRate(Double(progress.bytesRead)/elapsed))")
                }
                if !progress.currentPath.isEmpty { Text(progress.currentPath).lineLimit(1).truncationMode(.middle).help(progress.currentPath) }
            }.font(.system(size: 13))
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
private func openArchivePath(root:String,relative:String,showFile:Bool,
                             rootID:String, destination:Bool, model:MacSyncViewModel) -> String? {
    guard let pair=model.configuredPairs().first(where:{$0.id==rootID}),
          (destination ? pair.destination:pair.path) == root else {
        return "La coppia di cartelle è cambiata rispetto alla registrazione"
    }
    if destination {
        guard let expected=pair.expected,expected.isStrongIdentity,
              let actual=try? VolumeFingerprint.read(at:URL(fileURLWithPath:root)),actual==expected else {
            return "Destinazione non montata o non corrispondente"
        }
    }
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
    @ObservedObject var model: MacSyncViewModel
    @Environment(\.dismiss) private var dismiss
    let initialMetric:HistoryMetric?
    @State private var selected = ""
    @State private var cycles:[SyncCycleRecord] = []
    @State private var totals = SyncHistoryTotals()
    @State private var metric:HistoryMetric?
    @State private var busy=false
    @State private var message=""
    @State private var cycleOffset=0
    @State private var moreCycles=true
    private var selectedCycle:SyncCycleRecord? { cycles.first { $0.id == selected } }
    private var cycleID:String? { selected.isEmpty ? nil : selected }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("Riepilogo sincronizzazione").font(.title2.bold())
                Spacer(); Button("Aggiorna") { loadCycles(reset:true) }
                Button("Chiudi") { dismiss() }
            }
            Picker("Periodo",selection:$selected) {
                if cycles.isEmpty { Text("Nessun ciclo concluso").tag("") }
                ForEach(cycles) { cycle in
                    Text(cycle.started.formatted(date:.abbreviated,time:.standard) + " — " + macSyncCycleState(cycle.state)).tag(cycle.id)
                }
            }
            HStack {
                Button("Precedente") {
                    if let i=cycles.firstIndex(where:{$0.id==selected}), i+1<cycles.count { selected=cycles[i+1].id }
                }.disabled(cycles.firstIndex(where:{$0.id==selected}).map{$0+1>=cycles.count} ?? true)
                Button("Successiva") {
                    if let i=cycles.firstIndex(where:{$0.id==selected}), i>0 { selected=cycles[i-1].id }
                }.disabled(cycles.firstIndex(where:{$0.id==selected}).map{$0==0} ?? true)
                Button("Torna all’ultima") { if let first=cycles.first { selected=first.id } }.disabled(cycles.first?.id==selected)
                Spacer()
                if moreCycles { Button("Carica altri cicli") { loadCycles(reset:false) }.disabled(busy) }
            }
            if let c=selectedCycle {
                HStack {
                    Text("Inizio: \(c.started.formatted(date:.abbreviated,time:.standard))")
                    Text("Fine: \(c.ended?.formatted(date:.abbreviated,time:.standard) ?? "—")")
                    Spacer()
                    Text(c.automatic.map { $0 ? "Automatica" : "Manuale" } ?? "Modalità non registrata")
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
                    }.buttonStyle(.bordered).disabled(selectedCycle == nil)
                }
            }
            Text("Eliminati comprende i recuperabili, senza contare backup, temporanei, cartelle o file già assenti.").font(.caption)
            Group {
                Text("Dati sincronizzati: \(sizeText(totals.stats.bytesTransferred))")
                Text("Backup creati: \(sizeText(totals.backupBytes)) — non equivale al traffico VPN")
                Text("Velocità media copia in staging: \(SyncLiveProgress.formatRate(totals.meanCopyRate))")
                HStack {
                    ForEach([HistoryMetric.directoryCreated,.directoryRemoved,.expired]) { m in
                        Button("\(m.title): \(m.count(totals.stats))") { metric=m }.disabled(selectedCycle == nil)
                    }
                }
                HStack {
                    Button("Dettaglio backup") { metric = .backup }.disabled(selectedCycle == nil)
                    Button("Dettaglio copie temporanee") { metric = .stage }.disabled(selectedCycle == nil)
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
        .padding(20).frame(width:850,height:730)
        .onAppear { selected=copy.lastRecordedCycle?.id ?? ""; loadCycles(reset:true) }
        .onChange(of:selected) { _ in loadTotals() }
        .onChange(of:copy.lastRecordedCycle?.id) { _ in
            if selected == cycles.first?.id { selected=copy.lastRecordedCycle?.id ?? "" }
            loadCycles(reset:true)
        }
        .sheet(item:$metric) { item in
            if let cycleID {
                HistoryDetailsSheet(copy:copy,model:model,metric:item,cycleID:cycleID,sessionID:nil,roots:Array(Set(totals.byRoot.keys).union(model.configuredPairs().map(\.id))).sorted())
            }
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
                    let values=try SyncCycleHistory(path:path,readOnly:true).cycles(limit:100,offset:offset,finishedOnly:true)
                    DispatchQueue.main.async {
                        if reset { cycles=values } else { cycles += values.filter { value in !cycles.contains(where:{$0.id==value.id}) } }
                        cycleOffset=offset+values.count; moreCycles=values.count==100
                        if !cycles.contains(where:{$0.id==selected}) { selected=cycles.first?.id ?? "" }
                        busy=false; loadTotals()
                        if reset, !selected.isEmpty, let initialMetric { metric=initialMetric }
                    }
                } catch { DispatchQueue.main.async { busy=false; message=error.localizedDescription } }
            }
        } catch { message=error.localizedDescription }
    }
    private func loadTotals() {
        guard let cycle=cycleID else { totals=SyncHistoryTotals(); return }
        let scope=selected
        totals=SyncHistoryTotals()
        do {
            let path=try copy.historyPath()
            DispatchQueue.global(qos:.utility).async {
                do {
                    let result=try SyncCycleHistory(path:path,readOnly:true).totals(cycleID:cycle)
                    DispatchQueue.main.async { if scope==selected { totals=result } }
                } catch { DispatchQueue.main.async { message=error.localizedDescription } }
            }
        } catch { message=error.localizedDescription }
    }
}

private struct HistoryDetailsSheet:View {
    @ObservedObject var copy:MountedCopyController
    @ObservedObject var model:MacSyncViewModel
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
            message=openArchivePath(root:e.targetRoot,relative:String(path.dropFirst(e.targetRoot.count+1)),showFile:show,rootID:e.rootID,destination:true,model:model) ?? ""
        } else {
            let useSource=(e.kind == .deferred || e.kind == .failed) && !e.isDeleteJob
            message=openArchivePath(root:useSource ? e.sourceRoot:e.targetRoot,relative:e.relativePath,showFile:show,rootID:e.rootID,destination:!useSource,model:model) ?? ""
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
                    let page=try SyncCycleHistory(path:path,readOnly:true).events(cycleID:cycleID,sessionID:sessionID,
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

/// Preview-only geometry markers. The screenshot test checks the actual
/// layout, not the existence of an unused view declaration.
struct AuditPreviewBoundsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    @ViewBuilder
    func auditPreviewBounds(_ id: String, enabled: Bool) -> some View {
        if enabled {
            self.background {
                GeometryReader { proxy in
                    Color.clear.preference(key: AuditPreviewBoundsKey.self,
                        value: [id: proxy.frame(in: .named("macsync-audit-capture"))])
                }
            }
        } else { self }
    }
}

struct ArchiveAuditPanel: View {
    @ObservedObject var copy: MountedCopyController
    @ObservedObject var runtime: MacSyncRuntime
    @ObservedObject var model: MacSyncViewModel
    @State private var selectedFinding: AuditFindingKind?
    @State private var showFindings = false
    @Environment(\.macSyncLayout) private var layout
    private var detailFont: Font { .system(size: layout.compact ? 11 : 12) }

    private var busy: Bool {
        copy.maintaining || copy.seedBusy || copy.interruptionRequested || runtime.savingSchedule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.compact ? 8 : 12) {
            HStack(alignment: .top, spacing: layout.compact ? 8 : 12) {
                VStack(alignment: .leading, spacing: 8) {
                    configuration
                    maintenance.auditPreviewBounds("maintenance", enabled: runtime.previewOnly)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    operation
                    lastResult.auditPreviewBounds("lastResult", enabled: runtime.previewOnly)
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: copy.auditSettings) { _ in
            runtime.scheduleArchiveAudit()
        }
        .sheet(isPresented: $showFindings) {
            if let report = copy.auditReport {
                AuditResultSheet(model: model, findings: report.findings, kind: selectedFinding)
            }
        }
    }

    private var configuration: some View {
        MacSyncPanel("Configurazione verifica", icon: "gearshape", compact: true) {
            Text("Metodo di verifica").font(.subheadline.weight(.semibold))
            Picker("Metodo", selection: $copy.auditSettings.mode) {
                ForEach(ArchiveAuditMode.selectableModes, id: \.rawValue) { mode in
                    Text(mode == .quick ? "Rapida (metadati)" : "Intelligente").tag(mode)
                }
            }.pickerStyle(.segmented).labelsHidden()
            Text(copy.auditSettings.mode == .quick
                ? "Confronta percorsi, dimensioni e date (tolleranza 2 secondi), senza leggere i contenuti."
                : "Confronta i metadati (tolleranza 2 secondi) e usa SHA-256 selettivo per le date discordanti a parità di dimensione.")
                .font(detailFont).foregroundStyle(.secondary)
            Divider()
            Text("Confronto e accodamento delle differenze con backup del database. Solo i job del primo inventario già corrispondenti possono essere considerati soddisfatti; FSEvents e job storici ambigui restano in coda. Nessuna modifica al server.")
                .font(detailFont).foregroundStyle(.secondary)
            Divider()
            MacSyncSwitchRow("Programma verifica automatica", isOn: $copy.auditSettings.enabled)
            Text("Le verifiche programmate utilizzano lo stesso metodo e preparano la coda.").font(detailFont).foregroundStyle(.secondary)
            if copy.auditSettings.enabled {
                scheduleControls
                if let next = runtime.nextAuditAt {
                    Text("Prossima: \(macSyncDateTime(next))").font(detailFont).foregroundStyle(.secondary)
                }
            }
            Text("File e cartelle solo nella destinazione vengono accodati per l’eliminazione; eseguiti solo con mirror autorizzato.")
                .font(detailFont).foregroundStyle(.secondary)
        }.disabled(busy || copy.active)
    }

    private var scheduleControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker("Frequenza", selection: $copy.auditSettings.frequency) {
                    Text("Giornaliera").tag("daily")
                    Text("Settimanale").tag("weekly")
                    Text("Mensile").tag("monthly")
                }
                if copy.auditSettings.frequency == "weekly" {
                    Picker("Giorno", selection: $copy.auditSettings.weekday) {
                        ForEach([2,3,4,5,6,7,1], id: \.self) { day in
                            Text(macSyncWeekdayName(day)).tag(day)
                        }
                    }
                } else if copy.auditSettings.frequency == "monthly" {
                    Picker("Giorno", selection: $copy.auditSettings.monthDay) {
                        ForEach(1...28, id: \.self) { Text(String($0)).tag($0) }
                    }
                }
            }
            HStack {
                Picker("Ora", selection: $copy.auditSettings.hour) {
                    ForEach(0...23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                Picker("Minuti", selection: $copy.auditSettings.minute) {
                    ForEach(0...59, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
            }
        }.font(detailFont)
    }

    private var operation: some View {
        MacSyncPanel("Stato e avanzamento", icon: "arrow.triangle.2.circlepath", accent: true, compact: true) {
            if let p = copy.auditProgress {
                CompactArchiveAuditProgress(progress: p)
                    .auditPreviewBounds("progress", enabled: runtime.previewOnly)
            } else {
                Text(copy.auditBusy ? "Verifica in corso" : copy.seedBusy ? "Conferma in corso" : "Nessuna verifica in corso")
                    .font(.subheadline.weight(.semibold))
                Text(copy.auditStatus).font(detailFont).foregroundStyle(.secondary).lineLimit(2).help(copy.auditStatus)
            }
            if copy.seedBusy {
                Text(copy.seedStatus).font(detailFont).lineLimit(3).help(copy.seedStatus)
            }
            HStack(spacing: 6) {
                if let p = copy.auditProgress, !p.currentPath.isEmpty {
                    Text("File: " + p.currentPath).font(detailFont)
                        .lineLimit(1).truncationMode(.middle).help(p.currentPath)
                        .accessibilityLabel("File corrente: " + p.currentPath)
                }
                Spacer(minLength: 0)
                if copy.auditBusy {
                    Button("Annulla verifica") { copy.cancelArchiveAudit() }.buttonStyle(MacSyncStopStyle())
                        .auditPreviewBounds("cancel", enabled: runtime.previewOnly)
                } else if copy.seedBusy {
                    Button("Annulla conferma") { copy.cancelSeedVerification() }.buttonStyle(MacSyncStopStyle())
                } else if copy.active {
                    Button("Sospendi copie") { runtime.stopCopiesForCurrentLaunch() }
                } else {
                    if copy.queueRebuildRequired && !model.monitoring {
                        Button("Prepara verifica archivio") {
                            model.startMonitoring(allowUnilateralAuditPreparation:true)
                        }.buttonStyle(.borderedProminent)
                            .disabled(busy || runtime.folderConfigurationBusy || runtime.shuttingDown || model.scanProgress != nil)
                    } else {
                        Button("Avvia verifica") {
                            copy.startArchiveAudit(sources: model.configuredPairs(), interactive: true)
                        }.buttonStyle(.borderedProminent)
                            .disabled(busy || !model.monitoring || copy.liveProgress != nil || copy.seedReady || runtime.folderConfigurationBusy)
                            .auditPreviewBounds("start", enabled: runtime.previewOnly)
                    }
                }
            }
        }.auditPreviewBounds("operation", enabled: runtime.previewOnly)
    }

    private var lastResult: some View {
        MacSyncPanel("Ultima verifica", icon: "chart.bar.xaxis", compact: true) {
            if let report = copy.auditReport {
                HStack(alignment:.firstTextBaseline,spacing:4) {
                    Text(macSyncDateTime(report.ended)).font(.caption.weight(.medium)).monospacedDigit()
                    Spacer(minLength:3)
                    Text(elapsedText(report.seconds)).font(detailFont).monospacedDigit()
                }
                Text(report.mode.label).font(.caption2).foregroundStyle(.secondary)
                Divider()
                AuditArchiveComparison(source:report.sourceMetrics,destination:report.destinationMetrics,showSpeed:false)
                AuditFindingCards(model:model,findings:report.findings,deletionCandidates:report.deletionCandidates ?? [],counts:report.displayCounts ?? AuditFindingCounts(),partial:false,dense:true)
                HStack {
                    Text("Solo destinazione: \((report.displayCounts?.extra ?? 0).formatted()) · Non verificabili: \((report.displayCounts?.uncertain ?? 0).formatted())").font(detailFont).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Button("Visualizza report…") { selectedFinding = nil; showFindings = true }
                }
                if let metadata = report.metadataMatches, let hashes = report.hashMatches {
                    Text("Corrispondenze file: metadati \(metadata.formatted()) · SHA-256 \(hashes.formatted())").font(detailFont).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
                }
            } else {
                Text("Nessuna verifica completata").font(detailFont).foregroundStyle(.secondary)
                Button("Visualizza report…") {}.disabled(true)
            }
            if copy.seedReady && !copy.seedBusy {
                Divider()
                Text("\(copy.seedVerifiedCount) file identici in coda").font(.subheadline.weight(.semibold))
                Text("Nessun file verrà modificato.").font(detailFont).foregroundStyle(.secondary)
                HStack {
                    Button("Conferma allineamento…") { copy.approveSeededFiles() }
                        .buttonStyle(.borderedProminent).disabled(copy.active || busy)
                    Button("Scarta") { copy.invalidateSeedReport() }.disabled(busy)
                }
            } else if !copy.seedBusy && (copy.seedStatus.hasPrefix("Allineamento confermato") || copy.seedStatus.hasPrefix("Allineamento automatico")) {
                Text(copy.seedStatus).font(.caption2).lineLimit(1).help(copy.seedStatus)
            }
        }
    }

    private func shortFindingLabel(_ kind: AuditFindingKind) -> String {
        switch kind {
        case .matching: return "Corrispondenti"
        case .missing: return "Mancanti"
        case .different: return "Differenti"
        case .extra: return "Solo destinazione"
        case .uncertain: return "Non verificabili"
        }
    }

    private func resultRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(detailFont).lineLimit(2)
            Spacer(minLength: 4)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private var maintenance: some View {
        MacSyncPanel("Manutenzione temporanei", icon: "wrench.and.screwdriver", compact: true) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verifica e rimuove i temporanei di copie interrotte. Usala a copie ferme.")
                        .font(detailFont).foregroundStyle(.secondary)
                    Text(copy.maintenanceStatus).font(detailFont).foregroundStyle(.secondary)
                        .lineLimit(2).help(copy.maintenanceStatus)
                }
                Spacer(minLength: 4)
                if copy.maintaining && !copy.auditBusy {
                    Button("Annulla manutenzione") { copy.cancelMaintenance() }.buttonStyle(MacSyncStopStyle())
                } else {
                    HStack {
                        Button("Verifica") { copy.inspectStaging(sources: model.configuredPairs()) }
                        Button("Pulisci…") { copy.cleanupStaging(sources: model.configuredPairs()) }
                    }.disabled(copy.active || busy)
                }
            }
        }
    }
}

/// Compact audit-only presentation. Inventory progress keeps its existing view.
struct CompactArchiveAuditProgress: View {
    let progress: ArchiveAuditProgress
    var overview = false
    @Environment(\.macSyncLayout) private var layout
    private var determinate: Bool { progress.comparisonStarted != nil && progress.total > 0 }
    var body: some View {
        TimelineView(.periodic(from:progress.started,by:1)) { context in
            let elapsed = max(0,context.date.timeIntervalSince(progress.started))
            let fraction = determinate ? min(0.99,Double(progress.compared)/Double(progress.total)) : 0
            VStack(alignment:.leading,spacing:4) {
                HStack {
                    Text(progress.phase).font(.subheadline.weight(.semibold))
                    Spacer()
                    if determinate { Text("\(Int(fraction*100))%").monospacedDigit().bold() }
                }
                if determinate {
                    MacSyncLinearProgress(value:fraction)
                    Text("\(progress.compared) / \(progress.total) " + (progress.phase == "Riconoscimento automatico" ? "candidati ricontrollati" : "elementi confrontati")).font(.caption)
                } else { ProgressView().controlSize(.small) }
                HStack {
                    metric("Trascorso",elapsedText(elapsed))
                    metric("Rimanente stimato",progress.remaining(at:context.date).map(elapsedText) ?? "Calcolo…")
                    if overview {
                        metric("Lettura media complessiva",SyncLiveProgress.formatRate(progress.compareRate),info:"Byte letti da sorgente e destinazione divisi per la somma dei tempi di lettura ed elaborazione SHA-256. Non è la velocità di copia.")
                    } else {
                        metric("Velocità lettura",SyncLiveProgress.formatRate(progress.compareRate))
                    }
                }
                if !overview {
                    Divider()
                    AuditArchiveComparison(source:progress.source,destination:progress.destination,showSpeed:true)
                }
            }
        }
    }
    private func metric(_ title: String, _ value: String, info: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if let info { OverviewMetricInfo(text:info) }
            }
            Text(value).font(.system(size: layout.compact ? 12 : 15, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OverviewMetricInfo: View {
    let text: String
    var body: some View {
        Image(systemName:"info.circle")
            .font(.system(size:10)).foregroundStyle(.secondary)
            .help(text).accessibilityLabel(text)
    }
}

/// Presentation only: use the existing audit snapshot, never start extra disk or SMB reads.
struct OverviewArchiveSides: View {
    let source: AuditSideMetrics?
    let destination: AuditSideMetrics?
    let live: Bool
    @Environment(\.macSyncLayout) private var layout
    @Environment(\.colorScheme) private var scheme
    private var reading: Bool { (source?.bytesRead ?? 0) > 0 || (destination?.bytesRead ?? 0) > 0 }
    var body: some View {
        HStack(alignment:.top,spacing:8) {
            side("Sorgente",icon:"folder",metrics:source,remote:false)
            side("Destinazione",icon:"externaldrive",metrics:destination,remote:true)
        }
    }
    private func side(_ title:String,icon:String,metrics:AuditSideMetrics?,remote:Bool) -> some View {
        let scanning = live && !reading
        let rate: String = {
            guard live, let metrics else { return "—" }
            if scanning { return metrics.scanRate.map { $0.formatted(.number.precision(.fractionLength(0))) + " file/s" } ?? "—" }
            return SyncLiveProgress.formatRate(metrics.meanReadRate)
        }()
        let explanation = scanning ? "Numero di file inventariati diviso per il tempo di scansione. Non misura la lettura dei contenuti." : "Byte letti divisi per il tempo di lettura ed elaborazione SHA-256. " + (remote ? "Può risentire delle prestazioni della rete SMB. " : "") + "Misura disponibile durante la verifica, non durante la copia."
        return VStack(alignment:.leading,spacing:5) {
            Label(title,systemImage:icon).font(.system(size:layout.compact ? 13 : 15,weight:.semibold))
                .foregroundStyle(MacSyncColors.blue(scheme))
            Divider()
            HStack(alignment:.bottom,spacing:4) {
                value("File",metrics.map { $0.files.formatted() } ?? "—")
                value("Cartelle",metrics.map { $0.directories.formatted() } ?? "—")
                value("Dimensione",metrics.map { sizeText($0.detectedBytes) } ?? "—")
                value(scanning ? "Scansione" : "Velocità media di lettura",rate,info:explanation)
            }
        }
        .padding(layout.compact ? 7 : 10).frame(maxWidth:.infinity,alignment:.leading)
        .background(MacSyncColors.panel(scheme),in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(MacSyncColors.line(scheme),lineWidth:1))
    }
    private func value(_ label:String,_ number:String,info:String? = nil) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack(spacing:2) {
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).minimumScaleFactor(0.8)
                if let info { OverviewMetricInfo(text:info) }
            }
            Text(number).font(.system(size:layout.compact ? 12 : 15,weight:.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct AuditArchiveComparison: View {
    let source: AuditSideMetrics?
    let destination: AuditSideMetrics?
    let showSpeed: Bool
    @Environment(\.macSyncLayout) private var layout
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing:3) {
            HStack(spacing:4) {
                Text("Archivio").font(.caption2).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
                Text("Sorgente").font(.caption.weight(.semibold)).frame(maxWidth:.infinity,alignment:.trailing)
                Text("Destinazione").font(.caption.weight(.semibold)).frame(maxWidth:.infinity,alignment:.trailing)
            }
            Divider()
            row("File",source.map { $0.files.formatted() },destination.map { $0.files.formatted() })
            row("Cartelle",source.map { $0.directories.formatted() },destination.map { $0.directories.formatted() })
            row("Dimensione",source.map { sizeText($0.detectedBytes) },destination.map { sizeText($0.detectedBytes) })
            if showSpeed {
                let reading = (source?.bytesRead ?? 0) > 0 || (destination?.bytesRead ?? 0) > 0
                row(reading ? "Lettura media" : "Scansione",rate(source,reading:reading),rate(destination,reading:reading))
            }
        }.padding(5).background(MacSyncColors.inset(scheme),in:RoundedRectangle(cornerRadius:6))
    }
    private func rate(_ value:AuditSideMetrics?,reading:Bool) -> String? {
        guard let value else { return nil }
        if reading { return SyncLiveProgress.formatRate(value.meanReadRate) }
        return value.scanRate.map { "\($0.formatted(.number.precision(.fractionLength(0)))) file/s" }
    }
    private func row(_ name:String,_ left:String?,_ right:String?) -> some View {
        HStack(spacing:4) {
            Text(name).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            Text(left ?? "—").monospacedDigit().fontWeight(.semibold).frame(maxWidth:.infinity,alignment:.trailing)
            Text(right ?? "—").monospacedDigit().fontWeight(.semibold).frame(maxWidth:.infinity,alignment:.trailing)
        }.font(.system(size:layout.compact ? 10 : 11)).lineLimit(1).minimumScaleFactor(0.75)
    }
}

private struct AuditDetailSnapshot: Identifiable {
    let id = UUID()
    let kind: AuditFindingKind
    let findings: [AuditFinding]
    let deletionCandidates: Set<String>
    let title: String
}

struct AuditFindingCards: View {
    @ObservedObject var model: MacSyncViewModel
    let findings: [AuditFinding]
    let deletionCandidates: Set<String>
    let counts: AuditFindingCounts
    let partial: Bool
    var dense = false
    var overview = false
    @State private var selection: AuditDetailSnapshot?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment:.leading,spacing:3) {
            if overview { differenceCaption }
            HStack(spacing:6) {
                card(.missing,"Nuovi da copiare","doc.badge.plus")
                card(.different,"Da aggiornare","arrow.triangle.2.circlepath")
                card(.extra,"Da eliminare","trash")
            }
            if !overview { differenceCaption }
        }
        .sheet(item:$selection) { snapshot in
            AuditResultSheet(model:model,findings:snapshot.findings,kind:snapshot.kind,title:snapshot.title,filesOnly:snapshot.kind != .extra,deletionCandidates:snapshot.deletionCandidates)
        }
    }
    private var differenceCaption: some View {
        Text(partial ? "Differenze rilevate finora · risultati parziali" : "Da eliminare: \(counts.deletionFiles) file · \(counts.deletionDirectories ?? 0) cartelle · solo con mirror autorizzato")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
    }
    private func card(_ kind:AuditFindingKind,_ title:String,_ symbol:String) -> some View {
        let count = kind == .extra ? counts.deletionItems : counts.files(kind)
        return Button {
            // Freeze the current report, no filtering or allocation of a new
            // full array on the main thread.
            selection = AuditDetailSnapshot(kind:kind,findings:findings,deletionCandidates:deletionCandidates,title:title)
        } label: {
            if overview {
                let color = kind == .missing ? MacSyncColors.green(scheme) : kind == .different ? MacSyncColors.blue(scheme) : MacSyncColors.red(scheme)
                HStack(spacing:5) {
                    Image(systemName:symbol).foregroundStyle(color)
                    Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength:2)
                    Text(count.formatted()).font(.system(size:16,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(color)
                    Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary)
                }.padding(7).frame(maxWidth:.infinity,alignment:.leading)
                    .background(MacSyncColors.inset(scheme),in:RoundedRectangle(cornerRadius:8))
                    .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(MacSyncColors.line(scheme),lineWidth:1))
            } else if dense {
                let color = kind == .missing ? MacSyncColors.green(scheme) : kind == .different ? MacSyncColors.blue(scheme) : MacSyncColors.red(scheme)
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:3) {
                        Image(systemName:symbol).foregroundStyle(color)
                        Text(count.formatted()).font(.system(size:16,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(color)
                        Spacer(minLength:0)
                        Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(.secondary)
                }.padding(5).frame(maxWidth:.infinity,alignment:.leading)
                    .background(MacSyncColors.inset(scheme),in:RoundedRectangle(cornerRadius:6))
                    .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(MacSyncColors.line(scheme),lineWidth:1))
            } else {
                SyncSummaryMetric(title:title,count:count,symbol:symbol)
            }
        }.buttonStyle(.plain).help("Mostra gli elementi: " + title)
    }
}

private struct AuditPageRequest: Equatable {
    let search: String
    let root: String
    let offset: Int
}

private struct AuditResultSheet:View {
    @ObservedObject var model:MacSyncViewModel
    let findings:[AuditFinding]
    let kind:AuditFindingKind?
    var title: String? = nil
    var filesOnly = false
    var deletionCandidates: Set<String> = []
    @State private var search=""
    @State private var root=""
    @State private var selected:String?
    @State private var message=""
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [AuditFinding] = []
    @State private var roots: [String] = []
    @State private var total = 0
    @State private var offset = 0
    @State private var loading = true
    private var request: AuditPageRequest { .init(search:search,root:root,offset:offset) }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {Text(title ?? kind?.label ?? "Risultato verifica completa").font(.title2.bold());Spacer();Button("Chiudi"){dismiss()} }
            HStack {
                TextField("Cerca per percorso",text:$search)
                Picker("Coppia",selection:$root) {
                    Text("Tutte").tag("")
                    ForEach(roots,id:\.self){ Text($0).tag($0) }
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
                if loading { ProgressView().controlSize(.small); Text("Caricamento…").font(.caption) }
                else { Text(total == 0 ? "0 elementi" : "\(offset+1)–\(offset+rows.count) di \(total.formatted()) elementi") }
                Button("Precedenti") { offset = max(0,offset-200) }.disabled(loading || offset == 0)
                Button("Successivi") { offset += 200 }.disabled(loading || offset+rows.count >= total)
                Spacer()
                Button("Visualizza"){open(true)}.disabled(rows.first(where:{$0.id==selected})?.objectKind != "file")
                Button("Apri percorso"){open(false)}.disabled(selected==nil)
            }
            Text(message).foregroundStyle(.orange).font(.caption)
        }.padding(18).frame(width:1000,height:600)
            .onChange(of:search) { _ in offset = 0 }
            .onChange(of:root) { _ in offset = 0 }
            .task(id:request) { await load(request) }
    }
    @MainActor private func load(_ request: AuditPageRequest) async {
        loading = true; selected = nil; rows = []
        let snapshot = findings, filter = kind, files = filesOnly, deletions = deletionCandidates
        let cancel = SeedVerificationCancellation()
        // Search and pagination operate on a frozen report; superseded searches
        // are cancelled and can never publish stale results.
        let page = await withTaskCancellationHandler(operation:{
            await Task.detached(priority:.userInitiated) {
                AuditFindingPage.load(findings:snapshot,kind:filter,filesOnly:files,deletionCandidates:deletions,root:request.root,search:request.search,offset:request.offset,shouldContinue:{ !cancel.isCancelled })
            }.value
        },onCancel:{ cancel.cancel() })
        guard !Task.isCancelled, let page, self.request == request else { return }
        rows = page.rows; roots = page.roots; total = page.total; loading = false
    }
    private func open(_ show:Bool) {
        guard let f=rows.first(where:{$0.id==selected}) else{return}
        let destination=f.kind == .extra || f.kind == .matching
        let root=destination ? f.targetRoot:f.sourceRoot
        message=openArchivePath(root:root,relative:f.relativePath,showFile:show,rootID:f.rootID,destination:destination,model:model) ?? ""
    }
}
