import Foundation
import SwiftUI
import UserNotifications
import MacSyncCore

/// Strongly typed user preferences, shared by menu bar and sync workers.
/// Updating these values does not itself run a copy or delete.
@MainActor
final class SyncSettingsController: ObservableObject {
    @Published var schedule: SyncSchedule {
        didSet {
            guard schedule.isValid else {
                schedule = .standard
                return
            }
            if let data = try? JSONEncoder().encode(schedule) {
                UserDefaults.standard.set(data, forKey: "MacSync.schedule")
            }
        }
    }
    @Published var alertPolicy: ConnectionAlertPolicy {
        didSet {
            guard alertPolicy.isValid else {
                alertPolicy = ConnectionAlertPolicy()
                return
            }
            if let data = try? JSONEncoder().encode(alertPolicy) {
                UserDefaults.standard.set(data, forKey: "MacSync.connectionAlertPolicy")
            }
        }
    }
    @Published var notificationPermissionStatus = "Notifiche non configurate"

    init() {
        let defaults = UserDefaults.standard
        let savedSchedule = defaults.data(forKey: "MacSync.schedule")
            .flatMap { try? JSONDecoder().decode(SyncSchedule.self, from: $0) }
        schedule = savedSchedule?.isValid == true ? savedSchedule! : .standard
        let savedPolicy = defaults.data(forKey: "MacSync.connectionAlertPolicy")
            .flatMap { try? JSONDecoder().decode(ConnectionAlertPolicy.self, from: $0) }
        alertPolicy = savedPolicy?.isValid == true ? savedPolicy! : ConnectionAlertPolicy()
    }

    func setAlertEnabled(_ enabled: Bool) {
        alertPolicy.enabled = enabled
        guard enabled else {
            notificationPermissionStatus = "Avvisi disattivati"
            return
        }
        // Request OS permission ONLY after a user explicitly enables alerts.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge]
        ) { [weak self] granted, error in
            DispatchQueue.main.async { [weak self] in
                if granted {
                    self?.notificationPermissionStatus = "Autorizzazione notifiche concessa"
                } else if let error {
                    self?.notificationPermissionStatus = "Autorizzazione non disponibile: \(error.localizedDescription)"
                } else {
                    self?.notificationPermissionStatus = "Notifiche non autorizzate da macOS"
                }
            }
        }
    }

    func updateScheduleFrequency(_ frequency: SyncSchedule.Frequency) {
        var updated = schedule
        updated.frequency = frequency
        switch frequency {
        case .minutes:
            if !(1...45).contains(updated.interval) { updated.interval = 5 }
        case .hours:
            if !(1...12).contains(updated.interval) { updated.interval = 1 }
        case .daily, .weekly:
            break
        }
        schedule = updated
    }
}

/// Native, silent banner (no sound), once per outage episode.
/// Notification permission and system Focus settings are respected.
enum MacSyncConnectionNotifier {
    static func send(destinationID: String) {
        let notification = UNMutableNotificationContent()
        notification.title = "MacSync — Destinazione non disponibile"
        let name: String
        switch destinationID {
        case "photo-uploads": name = "Cartella_1"
        case "photo-editing": name = "Cartella_2"
        default: name = "Cartella di destinazione"
        }
        notification.body = "\(name): la condivisione non risulta accessibile. Le sincronizzazioni restano sospese fino al ritorno della destinazione."
        notification.sound = nil
        let request = UNNotificationRequest(
            identifier: "MacSync.disconnected.\(destinationID).\(UUID().uuidString)",
            content: notification, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
