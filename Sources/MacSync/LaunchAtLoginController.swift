import AppKit
import ServiceManagement
import SwiftUI

/// Login registration belongs to macOS, not UserDefaults. Reading the real
/// SMAppService status keeps the checkbox truthful even when the user changes
/// the setting directly in System Settings.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var isAvailable = true
    @Published private(set) var statusMessage = "Avvio al login non configurato"

    init() {
        refresh()
    }

    func refresh() {
        // SwiftPM executable (swift run) is not a packaged app and should
        // never be registered as a login item. Test inside MacSync.app.
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app",
              Bundle.main.bundleIdentifier != nil else {
            enabled = false
            requiresApproval = false
            isAvailable = false
            statusMessage = "Disponibile soltanto avviando MacSync.app"
            return
        }
        isAvailable = true
        switch SMAppService.mainApp.status {
        case .enabled:
            enabled = true
            requiresApproval = false
            statusMessage = "MacSync si avvierà al login macOS"
        case .requiresApproval:
            enabled = false
            requiresApproval = true
            statusMessage = "Autorizzazione necessaria in Impostazioni di Sistema > Elementi login"
        case .notRegistered:
            enabled = false
            requiresApproval = false
            statusMessage = "Avvio automatico al login disattivato"
        case .notFound:
            enabled = false
            requiresApproval = false
            statusMessage = "App non registrabile da questa posizione; spostala in Applicazioni"
        @unknown default:
            enabled = false
            requiresApproval = false
            statusMessage = "Stato avvio al login sconosciuto: verifica Impostazioni di Sistema"
        }
    }

    func setEnabled(_ shouldEnable: Bool) {
        guard isAvailable else {
            refresh()
            return
        }
        let service = SMAppService.mainApp
        do {
            if shouldEnable {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refresh()
        } catch {
            // Never show a success checkmark on failure; the OS is the
            // source of truth and System Settings may override this switch.
            refresh()
            statusMessage = "Modifica non riuscita: \(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
