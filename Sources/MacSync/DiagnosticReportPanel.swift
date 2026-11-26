import AppKit
import SwiftUI
import MacSyncCore

struct DiagnosticReportPanel: View {
    @ObservedObject var copy: MountedCopyController
    let previewOnly: Bool
    @State private var days = 7
    @State private var exporting = false
    @State private var status = ""

    var body: some View {
        MacSyncPanel("Diagnostica per i test", icon: "stethoscope", accent: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Periodo", selection: $days) {
                        Text("Ultime 24 ore").tag(1)
                        Text("Ultimi 7 giorni").tag(7)
                        Text("Ultimi 30 giorni").tag(30)
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
