import AppKit
import SwiftUI
import MacSyncCore

/// Non-destructive prototype. It does not watch folders or access the server.
@main
struct MacSyncApp: App {
    var body: some Scene {
        MenuBarExtra("MacSync", systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 12) {
                Text("MacSync").font(.headline)
                Label("Prototipo: sincronizzazione disattivata",
                      systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
                Text("Nessuna operazione su file o server viene eseguita.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text("Motore SQLite e test automatici in preparazione.")
                    .font(.caption)
                Button("Esci da MacSync") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}
