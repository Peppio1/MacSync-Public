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
        refreshNotificationPermission()
    }

    func refreshNotificationPermission() {
        guard alertPolicy.enabled else {
            notificationPermissionStatus = "Avvisi disattivati"
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] value in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.alertPolicy.enabled else { return }
                switch value.authorizationStatus {
                case .authorized, .provisional:
                    self.notificationPermissionStatus = "Notifiche autorizzate da macOS"
                case .denied:
                    self.notificationPermissionStatus = "Notifiche bloccate: verifica Impostazioni di Sistema"
                default:
                    self.notificationPermissionStatus = "Notifiche non ancora autorizzate"
                }
            }
        }
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
                guard self?.alertPolicy.enabled == true else { return }
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
            if !(1...59).contains(updated.interval) { updated.interval = 5 }
        case .hours:
            if !(1...23).contains(updated.interval) { updated.interval = 1 }
        case .daily, .weekly:
            break
        }
        schedule = updated
    }
}

/// Native, silent banner. Use a stable request identifier for the same
/// outage, and report acceptance/failure instead of silently losing alerts.
enum MacSyncConnectionNotifier {
    enum DeliveryError: LocalizedError {
        case notAuthorized, cancelled
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Notifiche non autorizzate da macOS"
            case .cancelled: return "Avviso non più necessario"
            }
        }
    }

    @MainActor
    static func send(destinationID: String, firstObserved: Date,
                     shouldSend: @escaping @MainActor () -> Bool,
                     completion: @escaping (Error?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                guard shouldSend() else {
                    completion(DeliveryError.cancelled)
                    return
                }
                guard settings.authorizationStatus == .authorized ||
                      settings.authorizationStatus == .provisional else {
                    completion(DeliveryError.notAuthorized)
                    return
                }
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
                let key = "MacSync.disconnected.\(destinationID).\(firstObserved.timeIntervalSince1970)"
                center.add(UNNotificationRequest(
                    identifier: key, content: notification, trigger: nil
                ), withCompletionHandler: completion)
            }
        }
    }
}

/// macOS otherwise may suppress presentation while the app is foreground.
/// No sound, modal windows or permission requests are introduced here.
final class MacSyncNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
