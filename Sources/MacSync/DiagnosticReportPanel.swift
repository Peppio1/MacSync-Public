import AppKit
import SwiftUI
import MacSyncCore

struct DiagnosticReportPanel: View {
    @ObservedObject var copy: MountedCopyController
    let previewOnly: Bool
    @AppStorage(DiagnosticCollectionLevel.preferenceKey) private var level=DiagnosticCollectionLevel.advanced.rawValue
    @AppStorage(DiagnosticCollectionLevel.profilingUntilKey) private var profilingUntil:Double=0
    @AppStorage(DiagnosticCollectionLevel.retentionKey) private var retention=DiagnosticCollectionLevel.defaultRetention
    @State private var days = 7
    @State private var exporting = false
    @State private var status = ""

    var body: some View {
        MacSyncPanel("Diagnostica e prestazioni", icon: "stethoscope", accent: false) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Livello",selection:$level) {
                    Text("Standard").tag(DiagnosticCollectionLevel.standard.rawValue)
                    Text("Avanzata").tag(DiagnosticCollectionLevel.advanced.rawValue)
                    Text("Profilazione (15 minuti)").tag(DiagnosticCollectionLevel.profiling.rawValue)
                }
                .disabled(previewOnly)
                .onChange(of:level) { value in
                    profilingUntil=value==DiagnosticCollectionLevel.profiling.rawValue ? Date().addingTimeInterval(900).timeIntervalSince1970 : 0
                }
                TimelineView(.periodic(from:Date(),by:1)) { context in
                    let effective=DiagnosticCollectionLevel.effective(raw:level,until:profilingUntil,now:context.date)
                    if level==DiagnosticCollectionLevel.profiling.rawValue {
                        if effective == .profiling {
                            Text("Profilazione: ancora \(max(0,Int(ceil(profilingUntil-context.date.timeIntervalSince1970)))) s")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Profilazione conclusa · Avanzata attiva")
                                .font(.caption).foregroundStyle(.secondary)
                                .onAppear { if !previewOnly { level=DiagnosticCollectionLevel.advanced.rawValue } }
                        }
                    }
                }
                Text("La profilazione torna automaticamente al livello avanzato dopo 15 minuti. I log tecnici ordinari restano attivi.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Conservazione statistiche",selection:$retention) {
                    ForEach(DiagnosticCollectionLevel.retentionOptions,id:\.self) { days in
                        Text("\(days) giorni").tag(days)
                    }
                }.disabled(previewOnly)
                Text("Massimo 100.000 campioni diagnostici, indipendenti dal registro ordinario.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Periodo", selection: $days) {
                        Text("Ultime 24 ore").tag(1)
                        Text("Ultimi 7 giorni").tag(7)
                        Text("Ultimi 30 giorni").tag(30)
                        Text("Ultimi 90 giorni").tag(90)
                    }
                    .frame(maxWidth: 240)
                    Spacer()
                    Button("Esporta report diagnostico…") { export() }
                        .disabled(exporting || previewOnly)
                }
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacSync-report-diagnostico.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path: String
        do { path = try copy.historyPath() }
        catch { status = "Registro diagnostico non disponibile"; return }
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        exporting = true
        status = "Esportazione in corso…"
        copy.uiResponsiveness.flushForExport {
        DispatchQueue.global(qos: .utility).async {
            let result: String
            do {
                try DiagnosticReport.exportZIP(databasePath:path,since:since,appVersion:version,to:url)
                result = "Report diagnostico esportato"
            } catch { result = "Esportazione non riuscita" }
            DispatchQueue.main.async {
                status = result
                exporting = false
            }
        }
        }
    }
}
