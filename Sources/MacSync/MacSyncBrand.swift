import AppKit
import SwiftUI

/// Resource images live inside the signed app. Standalone SwiftPM previews
/// use the build's exact generated assets, or a system-symbol fallback.
enum MacSyncBrand {
    static func resource(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) { return image }
        if Bundle.main.bundleURL.pathExtension != "app",
           let directory = ProcessInfo.processInfo.environment["MACSYNC_BRAND_PREVIEW_DIR"],
           let image = NSImage(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")) {
            return image
        }
        return nil
    }
    static func menuImage() -> NSImage? {
        guard let image = resource("MacSyncMenuTemplate")?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

struct MacSyncBrandMark: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let image = MacSyncBrand.resource("MacSyncBrand") {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(scheme == .dark ? Color.cyan : Color.blue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct MacSyncMenuBarMark: View {
    var body: some View {
        if let image = MacSyncBrand.menuImage() {
            Image(nsImage: image).renderingMode(.template)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .renderingMode(.template)
        }
    }
}
