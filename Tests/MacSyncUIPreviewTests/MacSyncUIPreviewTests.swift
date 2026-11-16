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
    private static func render<V: View>(_ view: V, name: String, scheme: ColorScheme, directory: URL) throws {
        let background = scheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.14)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
        let canvas = VStack(alignment: .leading, spacing: 12) {
            Text("MacSync — Anteprima con dati sintetici").font(.headline)
            view
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 840, height: 420, alignment: .topLeading)
        .background(background)
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: canvas)
        renderer.proposedSize = ProposedViewSize(width: 840, height: 420)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "SwiftUI did not produce an image for \(name)")
        XCTAssertEqual(image.width, 1680)
        XCTAssertEqual(image.height, 840)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
