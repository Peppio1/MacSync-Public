import Foundation

public struct MonitorRoot: Equatable, Sendable {
    public let id: String
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

public struct MonitorUpdate: Sendable {
    public let message: String
    public let monitoring: Bool
    public let pendingChanges: Int
}

/// Local-only prototype. The watcher never connects to SMB and never performs
/// remote copies or deletions. Its change queue is for a later sync worker.
public final class LocalMonitorService {
    private let queue = DispatchQueue(label: "macsync.localmonitor.serial", qos: .utility)
    private let update: (MonitorUpdate) -> Void
    private var watcher: FSEventsWatcher?
    private var timer: DispatchSourceTimer?
    private var inventory: LocalInventory?
    private var roots: [MonitorRoot] = []
    private var lastFullScan: Date?
    private var recoveryRequired = false

    public init(onUpdate: @escaping (MonitorUpdate) -> Void) {
        self.update = onUpdate
    }

    public func start(roots: [MonitorRoot], databasePath: String) {
        queue.async { [self] in
            self.stopOnQueue()
            guard !roots.isEmpty else {
                self.report("Seleziona almeno una cartella locale", active: false)
                return
            }
            do {
                let checked = try self.validateRoots(roots)
                let store = try LocalInventory(path: databasePath)

                // Snapshot the event position BEFORE scanning. The stream
                // replays changes made during the startup scan.
                let since = FSEventsWatcher.currentEventID()
                self.roots = checked
                self.inventory = store
                self.report("Creazione inventario locale in corso…", active: false)

                for root in checked {
                    _ = try store.reconcile(rootID: root.id, root: root.url)
                }
                self.lastFullScan = Date()

                let watcher = FSEventsWatcher(queue: self.queue) { [weak self] events in
                    self?.process(events: events)
                }
                try watcher.start(paths: checked.map { $0.url.path }, since: since)
                self.watcher = watcher
                self.startHealthTimer()
                self.report("Monitoraggio locale attivo", active: true)
            } catch {
                self.stopOnQueue()
                self.report("Monitoraggio sospeso: " + error.localizedDescription, active: false)
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            self.stopOnQueue()
            self.report("Monitoraggio locale arrestato", active: false)
        }
    }

    private func validateRoots(_ roots: [MonitorRoot]) throws -> [MonitorRoot] {
        guard Set(roots.map(\.id)).count == roots.count else {
            throw JournalError.database("Gli ID delle cartelle devono essere distinti")
        }
        for root in roots {
            let values = try root.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  root.url.isFileURL else {
                throw JournalError.database("La cartella configurata non è una directory locale valida")
            }
        }
        // Disallow nested source folders, which would yield duplicate work.
        for a in roots {
            for b in roots where a.id != b.id {
                if b.url.path == a.url.path || b.url.path.hasPrefix(a.url.path + "/") {
                    throw JournalError.database("Le cartelle di origine non possono sovrapporsi")
                }
            }
        }
        return roots
    }

    private func process(events: [SourceEvent]) {
        guard let inventory else { return }
        var totalChanges = 0
        do {
            if events.contains(where: { $0.streamHistoryLost }) {
                // A dropped event stream may have missed modifications under
                // ANY watched root, not merely under the reported event path.
                let lastID = events.map(\.eventID).max()
                for root in roots {
                    _ = try inventory.reconcile(
                        rootID: root.id, root: root.url, eventID: lastID
                    )
                }
                lastFullScan = Date()
                recoveryRequired = false
                report("Eventi persi: inventario locale ricontrollato", active: true)
                return
            }
            for event in events {
                guard let root = roots.first(where: {
                    event.path == $0.url.path || event.path.hasPrefix($0.url.path + "/")
                }) else { continue }
                let result: ReconciliationResult
                if event.requiresFullReconciliation {
                    // If the source root disappeared, reconcile throws before
                    // any DB change. Do NOT treat missing source as deletions.
                    result = try inventory.reconcile(
                        rootID: root.id, root: root.url, eventID: event.eventID
                    )
                } else {
                    result = try inventory.reconcile(
                        rootID: root.id,
                        root: root.url,
                        subtree: URL(fileURLWithPath: event.path),
                        eventID: event.eventID
                    )
                }
                totalChanges += result.queuedUpserts + result.queuedDeletes
            }
            if totalChanges > 0 {
                report("Modifiche locali registrate: \(totalChanges)", active: true)
            }
        } catch {
            // Failed event paths remain unacknowledged. Retry by scanning
            // LOCAL folders at the next 5-minute health check.
            recoveryRequired = true
            report("Errore inventario: " + error.localizedDescription, active: false)
        }
    }

    private func startHealthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(300), repeating: .seconds(300))
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.inventory else { return }
            do {
                for root in self.roots {
                    let values = try root.url.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else {
                        throw JournalError.database("Cartella origine non disponibile")
                    }
                }
                // This is a LOCAL periodic audit, not a recurring SMB scan.
                if self.recoveryRequired || self.lastFullScan.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true {
                    for root in self.roots {
                        _ = try store.reconcile(rootID: root.id, root: root.url)
                    }
                    self.lastFullScan = Date()
                    self.recoveryRequired = false
                    self.report("Verifica completa locale conclusa", active: true)
                }
            } catch {
                self.recoveryRequired = true
                self.report("Verifica locale sospesa: " + error.localizedDescription, active: false)
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        watcher?.stop()
        watcher = nil
        inventory = nil
        roots = []
        lastFullScan = nil
        recoveryRequired = false
    }

    private func report(_ message: String, active: Bool) {
        // The queue is durable; count from the database rather than a UI cache.
        let count = (try? inventory?.pendingCount()) ?? 0
        update(MonitorUpdate(message: message, monitoring: active, pendingChanges: count))
    }
}
