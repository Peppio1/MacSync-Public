import SwiftUI
import MacSyncCore

/// Inspection only. The preview follows the live worker cursor; new events,
/// retry windows and remote preflight can change the next actionable job.
struct QueuePreviewSheet: View {
    @ObservedObject var copy:MountedCopyController
    @ObservedObject var model:MacSyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var search=""
    @State private var kind="all"
    @State private var status="all"
    @State private var offset=0
    @State private var snapshot:QueuePreviewPage?
    @State private var warning=""
    @State private var updated:Date?
    private struct Request:Equatable {
        let search:String;let kind:String;let status:String;let offset:Int
    }
    private var request:Request { .init(search:search,kind:kind,status:status,offset:offset) }
    private func origin(_ raw:String)->String {
        switch raw {
        case "initial_inventory":return "Inventario iniziale"
        case "source_monitor":return "Monitoraggio locale"
        case "archive_audit":return "Verifica archivio"
        case "destination_rebind":return "Cambio destinazione"
        default:return "Origine non determinata"
        }
    }
    private func path(_ row:QueuePreviewRow)->ArchivePathPresentation {
        let pair=model.configuredPairs().first{$0.id==row.job.rootID}
        let deleting=row.job.kind == .delete
        return .init(root:(deleting ? pair?.destination : pair?.path) ?? "",
                     relative:row.job.relativePath,side:deleting ? .destination : .source,
                     kind:.init(row.objectKind))
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text("Coda di sincronizzazione").font(.title2.weight(.semibold))
                    Text("\(model.pendingCount.formatted()) operazioni pendenti · Sola consultazione").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Ordine previsto dal motore: copie e aggiornamenti per ID, poi eliminazioni dai percorsi più lunghi. Le voci non eseguibili sono in fondo. Il controllo del server e nuovi eventi possono cambiare la pianificazione.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            TextField("Cerca nome, percorso o radice…",text:$search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Operazioni",selection:$kind) {
                    Text("Tutte").tag("all");Text("Copie / aggiornamenti").tag("upsert");Text("Eliminazioni").tag("delete")
                }.pickerStyle(.segmented)
                Picker("Stato",selection:$status) {
                    Text("Tutti").tag("all");Text("Pianificate").tag("planned");Text("Sospese / rimandate").tag("blocked")
                }.pickerStyle(.menu)
            }
            if !warning.isEmpty { Text(warning).font(.caption).foregroundStyle(.orange) }
            if let updated { Text("Aggiornata: "+macSyncDateTime(updated)).font(.caption).foregroundStyle(.secondary) }
            Divider()
            if let snapshot {
                if snapshot.rows.isEmpty {
                    Text("Nessuna operazione nella selezione.").foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment:.leading,spacing:10) {
                            ForEach(Array(snapshot.rows.enumerated()),id:\.element.id) { index,row in
                                HStack(alignment:.top,spacing:10) {
                                    Text("\(offset+index+1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width:42,alignment:.trailing)
                                    Image(systemName:row.job.kind == .delete ? "trash" : (row.objectKind=="directory" ? "folder.badge.plus" : "doc.badge.plus"))
                                        .foregroundStyle(row.job.kind == .delete ? Color.orange : Color.accentColor)
                                    VStack(alignment:.leading,spacing:4) {
                                        HStack {
                                            Text(row.job.kind == .delete ? "Eliminazione" : (row.objectKind=="directory" ? "Creazione / verifica cartella" : "Copia / aggiornamento")).font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text("#\(row.id)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                        ArchivePathBlock(path:path(row))
                                        ArchiveFinderButton(path:path(row),rootID:row.job.rootID,model:model)
                                        Text("Accodata: "+macSyncDateTime(row.job.recordedAt)+" · "+origin(row.origin))
                                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                        if row.relatedToRectification {
                                            Text("Associata a una rettifica automatica").font(.caption).foregroundStyle(.secondary)
                                        }
                                        if row.requiresLiteralVerification {
                                            Text("Vecchio nome incompatibile: l’assenza va verificata sul filesystem. La sola mancata visibilità su SMB non è sufficiente.")
                                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                                        }
                                        Text(row.status.label).font(.caption.weight(.medium))
                                            .foregroundStyle(row.status == .current ? Color.accentColor : (row.status.isPlanned ? Color.secondary : Color.orange))
                                            .fixedSize(horizontal:false,vertical:true)
                                    }.frame(maxWidth:.infinity,alignment:.leading)
                                }
                                Divider()
                            }
                        }
                    }
                }
                HStack {
                    Text("Pagina \(offset/200+1) · \(snapshot.rows.count) voci").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Precedenti") { offset=max(0,offset-200) }.disabled(offset==0)
                    Button("Successive") { offset+=200 }.disabled(!snapshot.hasMore)
                }
            } else { ProgressView("Lettura coda locale…").frame(maxWidth:.infinity,maxHeight:.infinity) }
        }
        .padding(20).frame(minWidth:780,idealWidth:920,minHeight:500,idealHeight:680)
        .onChange(of:search) { _ in offset=0 }
        .onChange(of:kind) { _ in offset=0 }
        .onChange(of:status) { _ in offset=0 }
        .task(id:request) {
            let wanted=request
            let requestedAt=ProcessInfo.processInfo.systemUptime
            var firstResult=true
            do { try await Task.sleep(nanoseconds:200_000_000) } catch { return }
            while !Task.isCancelled {
                do {
                    let queryStarted=ProcessInfo.processInfo.systemUptime
                    let next=try await copy.queuePreview(search:wanted.search,kind:wanted.kind,status:wanted.status,offset:wanted.offset)
                    guard !Task.isCancelled,request==wanted else { return }
                    let returned=ProcessInfo.processInfo.systemUptime
                    copy.uiResponsiveness.record("metric_ui_queue_query",seconds:returned-queryStarted)
                    snapshot=next;warning="";updated=Date()
                    if firstResult {
                        copy.uiResponsiveness.record("metric_ui_queue_first_result",seconds:returned-requestedAt)
                        firstResult=false
                    }
                } catch {
                    guard !Task.isCancelled,request==wanted else { return }
                    warning="Coda temporaneamente non disponibile; ultimo elenco conservato."
                }
                do { try await Task.sleep(nanoseconds:3_000_000_000) } catch { return }
            }
        }
    }
}
