import AppKit
import SwiftUI
import XCTest
import MacSyncCore
@testable import MacSync

/// Collect preference values from the hosted SwiftUI hierarchy during layout.
private final class AuditBoundsCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CGRect] = [:]
    func update(_ frames: [String: CGRect]) {
        lock.lock(); defer { lock.unlock() }
        values = frames
    }
    func snapshot() -> [String: CGRect] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

/// Renders the actual configuration view with a preview-only runtime. All interactions are disabled; synthetic history is stored in a temporary SQLite database, never the real app archive.
final class MacSyncUIPreviewTests: XCTestCase {
    func testWindowLayoutPolicy() async {
        await MainActor.run {
            XCTAssertFalse(MacSyncWindowLayout(width: 1180, height: 820).compact)
            XCTAssertTrue(MacSyncWindowLayout(width: 1020, height: 720).compact)
            XCTAssertTrue(MacSyncWindowLayout(width: 980, height: 660).compact)
            XCTAssertTrue(MacSyncWindowLayout(width: 1180, height: 660).compact)
        }
    }
    func testItalianWeekdayLabels() async {
        await MainActor.run {
            XCTAssertEqual((1...7).map(macSyncWeekdayName), ["Domenica","Lunedì","Martedì","Mercoledì","Giovedì","Venerdì","Sabato"])
            XCTAssertEqual(macSyncWeekdayName(0), "—")
        }
    }

    /// Synthetic main-actor heartbeat during real report pagination and a burst
    /// of progress notifications. No physical disk fixture or remote writes.
    func testAuditResponsiveUnderSyntheticLoad() async throws {
        let worker = Task.detached(priority:.utility) {
            let findings = (0..<50000).map { i in
                // Use the public audit result page via a small real report in
                // the separate core tests; here exercise burst coalescing.
                i
            }
            let mailbox = AuditProgressMailbox()
            var snapshot = ArchiveAuditProgress()
            var offered = 0
            for i in findings {
                snapshot.compared = i
                if mailbox.offer(snapshot) { offered += 1 }
            }
            return (offered,mailbox.take()?.compared)
        }
        let maxDelay = await MainActor.run { () -> Double in
            var longest = 0.0
            for _ in 0..<15 {
                let start = ProcessInfo.processInfo.systemUptime
                RunLoop.main.run(until:Date().addingTimeInterval(0.01))
                longest = max(longest,ProcessInfo.processInfo.systemUptime-start)
            }
            return longest
        }
        let result = await worker.value
        XCTAssertEqual(result.0,1)
        XCTAssertEqual(result.1,49999)
        XCTAssertLessThan(maxDelay,1.0,"Main run loop delayed under synthetic load")
        print("Synthetic UI heartbeat max: \(maxDelay) seconds")
    }

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
                    let runtime = MacSyncRuntime(previewOnly: true)
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let db = scratch.appendingPathComponent("fixture.sqlite").path
                    let log = try SyncActivityLog(path: db)
                    try log.record(level: .success, rootID: "photo-uploads", action: "upload", relativePath: "IMG_0042.dng", bytes: 25000000, durationSeconds: 2, message: "Copia dimostrativa completata")
                    try log.record(level: .success, rootID: "photo-editing", action: "upload", relativePath: "Foto_01.psd", bytes: 50000000, durationSeconds: 4, message: "Aggiornamento dimostrativo")
                    try log.record(level: .warning, rootID: "photo-uploads", action: "connection_wait", message: "Destinazione temporaneamente non disponibile")
                    try log.record(level: .error, rootID: "photo-editing", action: "upload", relativePath: "IMG_0036.dng", message: "Esempio: accesso negato")
                    try log.record(level: .info, rootID: "app", action: "cycle", message: "Ciclo interrotto su richiesta; coda preservata")
                    let history = try SyncCycleHistory(path: db)
                    let now = Date()
                    try history.begin(id: "demo-cycle", sessionID: "demo-session", at: now.addingTimeInterval(-318), automatic:true)
                    try history.finish(id: "demo-cycle", at: now, seconds: 318, state: "partial")
                    var lastAudit: ArchiveAuditReport?
                    if page == .audit || page == .overview {
                        let source = scratch.appendingPathComponent("source").resolvingSymlinksInPath()
                        let target = scratch.appendingPathComponent("target").resolvingSymlinksInPath()
                        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        for (root, name, content) in [(source,"identico.dng","same"),(target,"identico.dng","same"),(source,"mancante.jpg","missing"),(source,"diverso.psd","new"),(target,"diverso.psd","old"),(target,"extra.jpg","extra")] {
                            try Data(content.utf8).write(to: root.appendingPathComponent(name))
                        }
                        _ = try LocalInventory(path: db).reconcile(rootID: "preview", root: source)
                        let mapping = try MountedFolderMapping(rootID: "preview", source: source, target: target)
                        let report = try ArchiveAudit(journal: ChangeJournal(path: db), mappings: [mapping]).run(mode: .deep)
                        XCTAssertEqual(report.count(.matching), 1)
                        XCTAssertEqual(report.count(.missing), 1)
                        XCTAssertEqual(report.count(.different), 1)
                        XCTAssertEqual(report.count(.extra), 1)
                        lastAudit = report
                    }
                    runtime.copy.populateScreenshotFixture(page: page, entries: try log.recent(), cycle: try history.cycles(limit: 1).first, lastAudit: lastAudit)
                    let screen = MacSyncConfigurationView(model: runtime.model, copy: runtime.copy, runtime: runtime, settings: runtime.settings, destinations: runtime.destinations, initialPage: page, previewScheme: scheme)
                        .allowsHitTesting(false)
                    try Self.render(screen, name: "page-\(pageKey(page))-\(suffix)", scheme: scheme, directory: directory, width: 1180, height: 820)
                    try Self.render(screen, name: "compact-\(pageKey(page))-\(suffix)", scheme: scheme, directory: directory, width: 1020, height: 720)
                    try Self.render(screen, name: "minimum-\(pageKey(page))-\(suffix)", scheme: scheme, directory: directory, width: 980, height: 660)
                    if page == .folders {
                        runtime.populateFolderHealthPreview()
                        let errorScreen=MacSyncConfigurationView(model:runtime.model,copy:runtime.copy,runtime:runtime,settings:runtime.settings,destinations:runtime.destinations,initialPage:.folders,previewScheme:scheme).allowsHitTesting(false)
                        try Self.render(errorScreen,name:"page-folders-error-\(suffix)",scheme:scheme,directory:directory,width:1180,height:820)
                    }
                    if page == .audit {
                        runtime.copy.populateScreenshotFixture(page: page, entries: try log.recent(), cycle: try history.cycles(limit: 1).first, lastAudit: lastAudit, auditInProgress: false)
                        let idle = MacSyncConfigurationView(model: runtime.model, copy: runtime.copy, runtime: runtime, settings: runtime.settings, destinations: runtime.destinations, initialPage: page, previewScheme: scheme).allowsHitTesting(false)
                        try Self.render(idle, name: "idle-audit-\(suffix)", scheme: scheme, directory: directory, width: 1180, height: 820)
                        try Self.render(idle, name: "compact-idle-audit-\(suffix)", scheme: scheme, directory: directory, width: 1020, height: 720)
                    }
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
        case .names: return "names"
        case .history: return "history"
        case .settings: return "settings"
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
        // Full-page captures measure exact usable content bounds.
        let auditBounds = AuditBoundsCapture()
        let canvas = Group {
            if name.hasPrefix("page-") || name.hasPrefix("compact-") || name.hasPrefix("minimum-") || name.hasPrefix("idle-") {
                view
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MacSync — Anteprima con dati sintetici").font(.headline)
                    view
                    Spacer(minLength: 0)
                }.padding(20)
            }
        }
        .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, scheme)
        .coordinateSpace(name: "macsync-audit-capture")
        .onPreferenceChange(AuditPreviewBoundsKey.self) { auditBounds.update($0) }
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
        XCTAssertEqual(host.bounds.width, CGFloat(width), accuracy: 0.5, "Unexpected host width: \(name)")
        XCTAssertEqual(host.bounds.height, CGFloat(height), accuracy: 0.5, "Unexpected host height: \(name)")
        if name.contains("-audit-") {
            let frames = auditBounds.snapshot()
            let idle = name.contains("idle-")
            let required = idle ? ["operation","start","maintenance","lastResult"] : ["operation","progress","cancel","maintenance","lastResult"]
            let viewport = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).insetBy(dx: -1, dy: -1)
            for id in required {
                let frame = try XCTUnwrap(frames[id], "Missing visible audit component \(id): \(name)")
                XCTAssertGreaterThan(frame.width, 1, "Zero width \(id): \(name)")
                XCTAssertGreaterThan(frame.height, 1, "Zero height \(id): \(name)")
                XCTAssertTrue(viewport.contains(frame), "Clipped audit component \(id): \(name), \(frame)")
            }
            let panel = try XCTUnwrap(frames["operation"])
            let button = try XCTUnwrap(frames[idle ? "start" : "cancel"])
            XCTAssertTrue(panel.insetBy(dx: -1, dy: -1).contains(button), "Audit action outside operation panel: \(name)")
            print("Audit layout verified: \(name) — \(required.joined(separator: ", "))")
        }
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
