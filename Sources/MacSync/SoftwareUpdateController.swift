import Foundation
import AppKit
import SwiftUI
import MacSyncCore

/// Application lifetime, independent from windows and synchronization.
@MainActor
final class SoftwareUpdateController: ObservableObject {
    private let previewOnly: Bool
    private let defaults: UserDefaults
    private let installed: String
    private let checkRelease: (String) async throws -> UpdateCheckResult
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var stopped = false
    private var showingAlert = false
    var onPrepareSignedUpdate: ((StableUpdateRelease) -> Void)?
    @Published private(set) var automatic: Bool
    @Published private(set) var lastCheck: Date?
    @Published private(set) var checking = false
    @Published private(set) var status = ""
    @Published private(set) var available: StableUpdateRelease?
    private static let automaticKey = "MacSync.updates.automatic"
    private static let lastCheckKey = "MacSync.updates.lastAttempt"
    private static let skipKey = "MacSync.updates.skippedStableTag"

    init(previewOnly: Bool = false, defaults: UserDefaults = .standard,
         installed: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.16.0",
         checkRelease: @escaping (String) async throws -> UpdateCheckResult = StableUpdateDiscovery.check) {
        self.previewOnly = previewOnly
        self.defaults = defaults
        self.installed = installed
        self.checkRelease = checkRelease
        automatic = previewOnly ? true : (defaults.object(forKey: Self.automaticKey) as? Bool ?? true)
        lastCheck = previewOnly ? nil : defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    var versionLabel: String { "MacSync v" + installed }

    func start() {
        guard !previewOnly, !stopped else { return }
        schedule()
    }

    func setAutomatic(_ value: Bool) {
        guard !previewOnly, !stopped else { return }
        automatic = value
        defaults.set(value, forKey: Self.automaticKey)
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic, !stopped, !previewOnly, !checking else { return }
        let now = Date()
        let due = StableUpdateDiscovery.isDue(lastAttempt: lastCheck, now: now)
        let next = due ? now.addingTimeInterval(5) : lastCheck!.addingTimeInterval(StableUpdateDiscovery.interval)
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.automatic, !self.stopped else { return }
                self.check(manual: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        checking = false
    }

    func check(manual: Bool = true) {
        guard !previewOnly, !stopped, !checking, !showingAlert else { return }
        timer?.invalidate(); timer = nil
        checking = true
        status = "Controllo in corso…"
        available = nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var result: Result<UpdateCheckResult, Error>
            do { result = .success(try await self.checkRelease(self.installed)) }
            catch { result = .failure(error) }
            guard !Task.isCancelled, !self.stopped else { return }
            self.checking = false
            self.task = nil
            self.lastCheck = Date()
            self.defaults.set(self.lastCheck, forKey: Self.lastCheckKey)
            switch result {
            case .success(.noStableRelease):
                self.status = "Nessuna release stabile disponibile."
            case .success(.current):
                self.status = "Nessuna versione stabile più recente."
            case .success(.available(let release)):
                self.available = release
                self.status = "Disponibile: \(release.tagName)"
                if manual || (self.automatic && self.defaults.string(forKey: Self.skipKey) != release.tagName) {
                    self.present(release)
                }
            case .failure(let error):
                self.status = "Controllo non riuscito: " + error.localizedDescription
            }
            self.schedule()
        }
    }

    func showAvailable() {
        guard !stopped, let available else { return }
        present(available)
    }

    private func present(_ release: StableUpdateRelease) {
        guard !previewOnly, !stopped, !showingAlert, release.pageURL != nil else { return }
        showingAlert = true
        defer { showingAlert = false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "È disponibile un aggiornamento"
        alert.informativeText = "GitHub segnala MacSync \(release.tagName).\n\nMacSync fermerà le operazioni e creerà un backup verificato. Solo dopo verrà aperta la finestra di Sparkle per verificare la firma e confermare l’installazione. Le novità saranno mostrate dal feed firmato. Se annulli, chiudi e riapri MacSync."
        alert.addButton(withTitle: "Prepara aggiornamento")
        alert.addButton(withTitle: "Più tardi")
        alert.addButton(withTitle: "Salta versione")
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: onPrepareSignedUpdate?(release)
        case .alertThirdButtonReturn: defaults.set(release.tagName, forKey: Self.skipKey)
        default: break
        }
    }

    deinit { timer?.invalidate(); task?.cancel() }
}
