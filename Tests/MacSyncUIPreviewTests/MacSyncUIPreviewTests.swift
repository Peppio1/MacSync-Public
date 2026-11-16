import AppKit
import SwiftUI
import XCTest
import MacSyncCore
@testable import MacSync

/// Renders production SwiftUI components with synthetic data only. No app
/// runtime, controllers, preferences, inventory, filesystem sync or network.
final class MacSyncUIPreviewTests: XCTestCase {
    func testRenderProductionComponents() async throws {
        guard let path = ProcessInfo.processInfo.environment["MACSYNC_UI_PREVIEW_DIR"], !path.isEmpty else {
            throw XCTSkip("UI artifact rendering is opt-in via MACSYNC_UI_PREVIEW_DIR")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await MainActor.run {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .dark ? "dark" : "light"
                try Self.render(folderExample, name: "folders-\(suffix)", scheme: scheme, directory: directory)
                try Self.render(summaryExample, name: "summary-\(suffix)", scheme: scheme, directory: directory)
                try Self.render(auditExample, name: "audit-\(suffix)", scheme: scheme, directory: directory)
                try Self.render(scheduleExample, name: "schedule-\(suffix)", scheme: scheme, directory: directory)
                for page in MacSyncPage.allCases {
                    try Self.render(pageExample(page), name: "page-\(pageKey(page))-\(suffix)", scheme: scheme, directory: directory, width: 1180, height: 820)
                }
            }
        }
    }

    private func pageKey(_ page: MacSyncPage) -> String {
        switch page {
        case .overview: return "overview"
        case .folders: return "folders"
        case .schedule: return "schedule"
        case .audit: return "audit"
        case .history: return "history"
        case .settings: return "settings"
        }
    }

    // Window-size fixtures reuse the real shell, panels and reusable controls.
    // These are synthetic compositions, not the live controller-backed pages.
    private func pageExample(_ page: MacSyncPage) -> some View {
        MacSyncSectionShell(page: .constant(page), monitoring: true, next: Date().addingTimeInterval(900)) {
            VStack(alignment: .leading, spacing: 14) {
                switch page {
                case .overview:
                    MacSyncPanel("Stato della sincronizzazione", icon: "arrow.triangle.2.circlepath", accent: true) {
                        Text("Sincronizzazione automatica pianificata")
                        HStack {
                            Text("Prossimo ciclo tra 15 minuti").foregroundStyle(.secondary)
                            Spacer()
                            Button("Interrompi copie") {}
                            Button("Disattiva sincronizzazione automatica") {}
                        }
                    }
                    MacSyncPanel("Avanzamento e riepilogo", icon: "chart.bar.xaxis") {
                        summaryExample
                        ProgressView(value: 0.52)
                        Text("52% · 24 file di 46 · 12 MB/s").font(.caption)
                    }
                    MacSyncPanel("Ultimo ciclo", icon: "clock") {
                        Text("Durata: 5 min 18 s · Completato")
                        Button("Storico e dettagli…") {}
                    }
                    MacSyncPanel("Disponibilità delle destinazioni", icon: "folder") {
                        Label("Cartella_1: disponibile", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Label("Cartella_2: disponibile", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                case .folders:
                    MacSyncPanel("Coppie unidirezionali", icon: "folder") { folderExample }
                    MacSyncPanel("Connessione", icon: "network") {
                        Text("Destinazioni locali o SMB già montate. Direzione unica: iMac → destinazione.")
                    }
                case .schedule:
                    MacSyncPanel("Sincronizzazione automatica", icon: "calendar", accent: true) {
                        Toggle("Avvia automaticamente le copie e gli aggiornamenti", isOn: .constant(true))
                    }
                    MacSyncPanel("Frequenza", icon: "clock") {
                        Picker("Ripetizione", selection: Binding.constant(SyncSchedule.Frequency.minutes)) {
                            Text("Minuti").tag(SyncSchedule.Frequency.minutes)
                            Text("Ore").tag(SyncSchedule.Frequency.hours)
                            Text("Ogni giorno").tag(SyncSchedule.Frequency.daily)
                            Text("Giorno della settimana").tag(SyncSchedule.Frequency.weekly)
                        }.pickerStyle(.segmented)
                        SyncIntervalEditor(range: 1...59, unit: "minuti", value: 15, apply: { _ in })
                        Text("Ogni 15 minuti")
                    }
                    MacSyncPanel("Destinazione offline", icon: "wifi.slash") {
                        Toggle("Invia una notifica dopo una disconnessione prolungata", isOn: .constant(true))
                        Text("Avvisa dopo 2 ore")
                    }
                case .audit:
                    MacSyncPanel("Verifica completa", icon: "checkmark.shield", accent: true) {
                        Toggle("Modalità diagnostica (nessun riallineamento)", isOn: .constant(true))
                        auditExample
                        Button("Annulla verifica") {}
                    }
                    MacSyncPanel("Archivio già copiato", icon: "checkmark.seal") {
                        Button("Verifica file già presenti") {}
                        Button("Anteprima iniziale — sola lettura") {}
                    }
                    MacSyncPanel("Manutenzione temporanei", icon: "wrench.and.screwdriver") {
                        Button("Verifica file temporanei") {}
                        Button("Interrompi manutenzione") {}
                    }
                case .history:
                    MacSyncPanel("Registro e dettagli", icon: "list.bullet.rectangle") {
                        HStack {
                            TextField("Cerca file o errore…", text: .constant("")).textFieldStyle(.roundedBorder)
                            Button("Aggiorna") {}
                            Button("Storico cicli…") {}
                        }
                        ForEach(1...5, id: \.self) { n in
                            Divider()
                            Text("UPLOAD · success · Cartella_1").font(.caption.bold())
                            Text("Esempio/foto-\(n).jpg").font(.caption)
                            Text("Dati dimostrativi").font(.caption2).foregroundStyle(.secondary)
                        }
                        Button("Esporta TSV…") {}
                    }
                case .settings:
                    MacSyncPanel("Generali", icon: "gearshape") {
                        Toggle("Avvia automaticamente MacSync al login macOS", isOn: .constant(false))
                    }
                    MacSyncPanel("Aspetto", icon: "paintbrush") {
                        Picker("Tema", selection: Binding.constant("system")) {
                            Text("Automatico").tag("system")
                            Text("Chiaro").tag("light")
                            Text("Scuro").tag("dark")
                        }.pickerStyle(.segmented)
                    }
                    MacSyncPanel("Cancellazioni, recupero e protezioni", icon: "shield") {
                        Toggle("Abilita cancellazioni speculari (autorizzazione persistente)", isOn: .constant(false))
                        Toggle("Limite numerico", isOn: .constant(false))
                        Toggle("Limite percentuale", isOn: .constant(false))
                        Toggle("Protezione sorgente completamente vuota", isOn: .constant(false))
                        Text("Le protezioni tecniche non sono disattivabili.").font(.caption)
                    }
                    MacSyncPanel("Informazioni", icon: "info.circle") {
                        Text("MacSync · v0.13 — candidato")
                        Text("Usare solo archivi di prova.")
                    }
                }
            }
        }
    }

    private var scheduleExample: some View {
        MacSyncSectionShell(page: .constant(.schedule), monitoring: true, next: Date().addingTimeInterval(900)) {
            MacSyncPanel("Frequenza sincronizzazione", icon: "clock", accent: true) {
                Text("Minuti · Ore · Giornaliera · Settimanale").font(.caption)
                SyncIntervalEditor(range: 1...59, unit: "minuti", value: 15, apply: { _ in })
                Text("Ogni 15 minuti").font(.caption)
            }
        }
    }

    private var folderExample: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(1...2, id: \.self) { slot in
                Text("Cartella_\(slot)").font(.headline)
                HStack(spacing: 12) {
                    FolderDropZone(title: "Sorgente", path: "/Example/Source_\(slot)", choose: {}, onFolderDropped: { _ in })
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    FolderDropZone(title: "Destinazione", path: "/Example/Target_\(slot)", choose: {}, onFolderDropped: { _ in })
                }
            }
        }
    }

    private var summaryExample: some View {
        HStack(spacing: 8) {
            SyncSummaryMetric(title: "Nuovi", count: 24, symbol: "plus.circle")
            SyncSummaryMetric(title: "Aggiornati", count: 12, symbol: "arrow.clockwise")
            SyncSummaryMetric(title: "Eliminati", count: 3, symbol: "trash")
            SyncSummaryMetric(title: "Recuperabili", count: 2, symbol: "archivebox")
            SyncSummaryMetric(title: "Errori", count: 1, symbol: "exclamationmark.triangle")
        }
    }

    private var auditExample: some View {
        var progress = ArchiveAuditProgress(started: Date().addingTimeInterval(-30))
        progress.phase = "Verifica SHA-256"
        progress.scannedFiles = 240
        progress.scannedDirectories = 12
        progress.detectedBytes = 800_000_000
        progress.compared = 96
        progress.total = 240
        progress.bytesRead = 320_000_000
        progress.currentPath = "Example/document-001.dat"
        return AuditProgressView(progress: progress)
    }

    @MainActor
    private static func render<V: View>(_ view: V, name: String, scheme: ColorScheme, directory: URL, width: Int = 840, height: Int = 420) throws {
        let background = scheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.14)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
        let canvas = VStack(alignment: .leading, spacing: 12) {
            Text("MacSync — Anteprima con dati sintetici").font(.headline)
            view
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, scheme)
        // Synthetic fixture window; no MacSync runtime is started.
        _ = NSApplication.shared
        let rect = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let host = NSHostingView(rootView: canvas)
        host.frame = rect
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        host.appearance = appearance
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = rect.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, width * 2)
        XCTAssertEqual(bitmap.pixelsHigh, height * 2)
        var yellow = 0, red = 0, samples = 0
        var darkest: CGFloat = 1, brightest: CGFloat = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                let luminance = (r + g + b) / 3
                darkest = min(darkest, luminance)
                brightest = max(brightest, luminance)
                if r > 0.8 && g > 0.55 && b < 0.2 { yellow += 1 }
                if r > 0.75 && g < 0.4 && b < 0.4 { red += 1 }
            }
        }
        XCTAssertGreaterThan(samples, 0)
        XCTAssertGreaterThan(brightest - darkest, 0.15, "Blank capture: \(name)")
        XCTAssertFalse(yellow > samples / 100 && red > samples / 500, "Unsupported control placeholder: \(name)")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
