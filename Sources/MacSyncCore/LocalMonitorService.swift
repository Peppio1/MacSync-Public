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
    public var scanProgress: ArchiveAuditProgress? = nil
    public var pendingBreakdown: PendingQueueBreakdown? = nil
    public var sourceNames: [IncompatibleName]? = nil
}

/// Local-only prototype. The watcher never connects to SMB and never performs
/// remote copies or deletions. Its change queue is for a later sync worker.
// All mutable watcher/inventory state is confined to queue. The only
// state touched by callers, scanRequest, is protected by requestLock;
// safetyGate has its own synchronization. Callbacks are delivered on queue.
// This is the explicit cross-queue boundary for the drained copy worker.
public final class LocalMonitorService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macsync.localmonitor.serial", qos: .utility)
    private let update: (MonitorUpdate) -> Void
    private var watcher: FSEventsWatcher?
    private var timer: DispatchSourceTimer?
    private var inventory: LocalInventory?
    private var activityLog: SyncActivityLog?
    private var roots: [MonitorRoot] = []
    private var lastFullScan: Date?
    private var recoveryRequired = false
    private var activeGeneration: UUID?
    private var activeRequest: SeedVerificationCancellation?
    private var activeDatabasePath: String?
    private let requestLock = NSLock()
    private var scanRequest: SeedVerificationCancellation?
    public let safetyGate: MonitorSafetyGate

    public init(safetyGate: MonitorSafetyGate = MonitorSafetyGate(), onUpdate: @escaping (MonitorUpdate) -> Void) {
        self.safetyGate = safetyGate
        self.update = onUpdate
    }

    public func start(roots: [MonitorRoot], databasePath: String, allowSourceRebinding: Bool = false, retireInactiveRoots: Bool = false, allowUnilateralAuditPreparation: Bool = false) {
        let request = SeedVerificationCancellation()
        requestLock.lock()
        scanRequest?.cancel()
        scanRequest = request
        let generation = safetyGate.invalidate()
        queue.async { [self] in
            self.stopOnQueue()
            guard !request.isCancelled else { self.report("Scansione annullata", active: false); return }
            guard !roots.isEmpty else {
                self.report("Seleziona almeno una cartella locale", active: false)
                return
            }
            do {
                if !allowUnilateralAuditPreparation, FileManager.default.fileExists(atPath:databasePath),
                   try ChangeJournal(path:databasePath,readOnly:true).unilateralNameAuditRequired() {
                    self.report("Rinomina unilaterale: monitoraggio sospeso; prepara la verifica archivio",active:false)
                    return
                }
                let checked = try self.validateRoots(roots)
                let store = try SQLiteConnectionSetup.openWithBoundedRetry(shouldContinue:{ !request.isCancelled }) {
                    try LocalInventory(path:databasePath)
                }
                if retireInactiveRoots {
                    guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                    try store.retireInactiveRoots(keeping:Set(checked.map(\.id)))
                }
                for root in checked {
                    guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                    if let existing = try store.rootPath(rootID: root.id),
                       existing != root.url.path {
                        guard allowSourceRebinding else {
                            throw JournalError.database("Source folder mapping changed; confirmation required")
                        }
                        try store.resetRootForNewSource(rootID: root.id, newRoot: root.url)
                    }
                }

                // Snapshot the event position BEFORE scanning. The stream
                // replays changes made during the startup scan.
                let since = FSEventsWatcher.currentEventID()
                self.roots = checked
                self.inventory = store
                self.activityLog = try SQLiteConnectionSetup.openWithBoundedRetry(shouldContinue:{ !request.isCancelled }) {
                    try SyncActivityLog(path:databasePath)
                }
                self.report("Creazione inventario locale in corso…", active: false)

                var scan = ArchiveAuditProgress()
                scan.phase = "Inventario locale iniziale"
                var lastUpdate = 0.0
                let scanTick = ProcessInfo.processInfo.systemUptime
                self.update(MonitorUpdate(message:scan.phase,monitoring:false,pendingChanges:0,scanProgress:scan))
                for root in checked {
                    // The inventory itself checks under its SQLite transaction that
                    // this is a truly pristine root before tagging bootstrap
                    // jobs. Existing roots/restarts become source_monitor.
                    _ = try store.reconcile(rootID:root.id,root:root.url,
                        origin:.initialInventory,shouldContinue:{ !request.isCancelled },onItem:{ item in
                        if item.kind == "file" {
                            scan.scannedFiles += 1
                            let sum = scan.detectedBytes.addingReportingOverflow(max(0,item.size))
                            scan.detectedBytes = sum.overflow ? Int64.max : sum.partialValue
                        } else if item.kind == "directory" { scan.scannedDirectories += 1 }
                        scan.source.record(item)
                        scan.source.scanSeconds = ProcessInfo.processInfo.systemUptime-scanTick
                        scan.currentPath = root.id + " / " + item.relativePath
                        let now = ProcessInfo.processInfo.systemUptime
                        if now-lastUpdate >= 0.25 {
                            lastUpdate = now
                            self.update(MonitorUpdate(message:scan.phase,monitoring:false,pendingChanges:0,scanProgress:scan))
                        }
                    })
                }
                guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                self.update(MonitorUpdate(message:"Inventario locale completato",monitoring:false,pendingChanges:0,scanProgress:scan))
                self.lastFullScan = Date()

                let watcher = FSEventsWatcher(queue: self.queue) { [weak self] events in
                    self?.process(events: events, request:request, generation:generation)
                }
                try watcher.start(paths: checked.map { $0.url.path }, since: since)
                self.watcher = watcher
                self.activeGeneration = generation
                self.activeRequest = request
                self.activeDatabasePath = databasePath
                guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                self.startHealthTimer(request:request,generation:generation)
                self.safetyGate.setReady(true,generation:generation)
                self.report("Monitoraggio locale attivo", active: true)
            } catch {
                if !request.isCancelled {
                    try? SyncActivityLog(path:databasePath).record(level:.error,rootID:"monitor",action:"inventory_start",message:SyncDiagnostic.describe(error))
                }
                self.stopOnQueue()
                self.report(request.isCancelled ? "Scansione annullata" : "Monitoraggio sospeso: " + error.localizedDescription, active: false)
            }
        }
        requestLock.unlock()
    }

    public func stop() {
        requestLock.lock()
        scanRequest?.cancel()
        safetyGate.invalidate()
        queue.async { [self] in
            self.stopOnQueue()
            self.report("Monitoraggio locale arrestato", active: false)
        }
        requestLock.unlock()
    }

    public func afterStopped(_ completion: @escaping () -> Void) { queue.async { completion() } }
    public func refreshCount() { queue.async { [weak self] in guard let self, self.safetyGate.isReady else { return }; self.report("Monitoraggio locale attivo",active:true) } }

    /// Invoked only by the independent serial transfer queue, before any
    /// remote operations. FSEvents remains running; its queued events and
    /// this targeted inventory update use the same serial writer.
    @discardableResult
    public func rectifyQueuedNames(_ approved:[IncompatibleName], pendingOnly:Bool = true,
                                   onProgress:(Int,Int)->Void = {_,_ in},
                                   shouldContinue:()->Bool) throws -> NameRectification.Result {
        try queue.sync {
            guard let inventory, let generation=activeGeneration,
                  let request=activeRequest, let databasePath=activeDatabasePath,
                  !request.isCancelled, shouldContinue(), safetyGate.isReady else {
                throw SeedVerificationError.cancelled
            }
            let journal=try ChangeJournal(path:databasePath)
            let baseRows = pendingOnly ? try journal.pendingLocalNameRectifications() :
                try roots.flatMap { try inventory.incompatibleNames(rootID:$0.id,sourcePath:$0.url.path) }
            let rows=try NameRectification.localMaintenanceRows(baseRows,journal:journal)
            let current=Dictionary(uniqueKeysWithValues:rows.map{($0.id,$0)})
            let selected=approved.filter { row in
                current[row.id] == row && row.selectableProposal != nil
            }
            guard !selected.isEmpty else { return NameRectification.Result() }
            let localRoots=Dictionary(uniqueKeysWithValues:roots.map{($0.id,$0.url.path)})
            guard selected.allSatisfy({localRoots[$0.rootID] == $0.rootPath}) else {
                throw MountedCopyError.invalidMapping
            }
            safetyGate.beginReconciliation(generation:generation)
            do {
                let log=try SyncActivityLog(path:databasePath)
                log.cycleID=UUID().uuidString
                let result=try NameRectification.executeLocal(items:selected,roots:localRoots,
                    journal:journal,log:log,
                    onProgress:onProgress,shouldContinue:{!request.isCancelled && shouldContinue()})
                // Even after Stop, reconcile names already changed. A
                // canceled monitor generation instead remains fail-closed.
                for root in roots {
                    var scopes=Set<String>()
                    for row in selected where row.rootID == root.id {
                        guard let name=NameRectification.proposedName(row.name) else { continue }
                        let parent=row.relativePath.split(separator:"/").dropLast().joined(separator:"/")
                        scopes.insert(row.relativePath)
                        scopes.insert(parent.isEmpty ? name : parent+"/"+name)
                    }
                    let ordered=scopes.sorted { a,b in
                        a.count == b.count ? a < b : a.count < b.count
                    }
                    var top:[String]=[]
                    for scope in ordered {
                        if !top.contains(where:{scope.hasPrefix($0+"/")}) { top.append(scope) }
                    }
                    for scope in top {
                        _ = try inventory.reconcile(rootID:root.id,root:root.url,
                            subtree:root.url.appendingPathComponent(scope),
                            shouldContinue:{!request.isCancelled})
                    }
                }
                guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                safetyGate.setReady(true,generation:generation)
                report("Rettifica locale: \(result.sourceRenamed) rinominati · inventario aggiornato",active:true)
                return result
            } catch {
                recoveryRequired=true
                safetyGate.fail(generation:generation,reason:"Rettifica locale: inventario da riconciliare")
                report("Rettifica locale sospesa: "+SyncDiagnostic.describe(error),active:false)
                throw error
            }
        }
    }

    private func validateRoots(_ roots: [MonitorRoot]) throws -> [MonitorRoot] {
        guard Set(roots.map(\.id)).count == roots.count else {
            throw JournalError.database("Gli ID delle cartelle devono essere distinti")
        }
        for root in roots {
            let values = try root.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  root.url.isFileURL, !(try VolumeFingerprint.read(at:root.url)).isNetworkVolume else {
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

    /// FSEvents may spell a path through a system alias (e.g. /var
    /// instead of /private/var), including a renamed-away leaf.
    /// Never resolve the leaf itself: its exact spelling is significant.
    static func eventURL(_ path:String,roots:[MonitorRoot])->(MonitorRoot,URL)? {
        guard path.hasPrefix("/") else { return nil }
        let lexical=URL(fileURLWithPath:path).standardizedFileURL
        func match(_ url:URL)->(MonitorRoot,URL)? {
            for root in roots {
                if url.path==root.url.path || url.path.hasPrefix(root.url.path+"/") {
                    return (root,url)
                }
            }
            return nil
        }
        if let direct=match(lexical) { return direct }
        let parent=lexical.deletingLastPathComponent().resolvingSymlinksInPath()
        return match(parent.appendingPathComponent(lexical.lastPathComponent))
    }

    private func process(events: [SourceEvent], request: SeedVerificationCancellation, generation: UUID) {
        guard let inventory, !request.isCancelled else { return }
        safetyGate.beginReconciliation(generation:generation)
        var totalChanges = 0
        do {
            let selective=try inventory.selectiveNameExceptionsActive()
            // Unknown file-event spelling must not be silently ignored in
            // selective mode. Reconcile local roots instead; normal FSEvents
            // events remain targeted. HistoryDone is a stream marker.
            let uncertainPath=selective && events.contains {
                !$0.isHistoryMarkerOnly && Self.eventURL($0.path,roots:roots)==nil
            }
            if recoveryRequired || uncertainPath || events.contains(where: { $0.streamHistoryLost || $0.requiresFullReconciliation }) {
                // A dropped event stream may have missed modifications under
                // ANY watched root, not merely under the reported event path.
                var scan = ArchiveAuditProgress(); scan.phase = "Riconciliazione inventario locale"
                update(MonitorUpdate(message:scan.phase,monitoring:false,pendingChanges:(try? inventory.pendingCount()) ?? 0,scanProgress:scan))
                let lastID = events.map(\.eventID).max()
                for root in roots {
                    _ = try inventory.reconcile(
                        rootID: root.id, root: root.url, eventID: lastID, shouldContinue:{ !request.isCancelled }
                    )
                }
                lastFullScan = Date()
                guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                recoveryRequired = false
                safetyGate.setReady(true,generation:generation)
                report("Eventi persi: inventario locale ricontrollato", active: true)
                return
            }
            for event in events {
                guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                if event.isHistoryMarkerOnly { continue }
                guard let (root,url) = Self.eventURL(event.path,roots:roots) else { continue }
                let result: ReconciliationResult
                if event.requiresFullReconciliation {
                    // If the source root disappeared, reconcile throws before
                    // any DB change. Do NOT treat missing source as deletions.
                    result = try inventory.reconcile(
                        rootID: root.id, root: root.url, eventID: event.eventID, shouldContinue:{ !request.isCancelled }
                    )
                } else {
                    // In selective mode a directory rename is best observed
                    // at its parent: old and new spellings in the same scan,
                    // one root-most guard instead of orphan child events.
                    // Never widen beyond the pinned local root.
                    let parent=url.deletingLastPathComponent()
                    let scope=selective && event.isDirectoryRename && url.path != root.url.path &&
                        (parent.path==root.url.path || parent.path.hasPrefix(root.url.path+"/")) ? parent:url
                    result = try inventory.reconcile(
                        rootID: root.id,
                        root: root.url,
                        subtree: scope,
                        eventID: event.eventID, shouldContinue:{ !request.isCancelled }
                    )
                }
                totalChanges += result.queuedUpserts + result.queuedDeletes
            }
            guard !request.isCancelled else { throw SeedVerificationError.cancelled }
            safetyGate.setReady(true,generation:generation)
            if totalChanges > 0 {
                try? activityLog?.record(
                    level: .info, rootID: "monitor", action: "detected",
                    message: "Modifiche locali rilevate: \(totalChanges)"
                )
                report("Modifiche locali registrate: \(totalChanges)", active: true)
            }
        } catch {
            // Failed event paths remain unacknowledged. Retry by scanning
            // LOCAL folders at the next 5-minute health check.
            recoveryRequired = true
            safetyGate.fail(generation:generation,reason:"Errore riconciliazione inventario: " + SyncDiagnostic.describe(error))
            try? activityLog?.record(level:.error,rootID:"monitor",action:"inventory_event",message:SyncDiagnostic.describe(error))
            report("Errore inventario: " + error.localizedDescription, active: false)
        }
    }

    private func startHealthTimer(request: SeedVerificationCancellation,generation: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(300), repeating: .seconds(300))
        timer.setEventHandler { [weak self] in
            guard let self, let store = self.inventory, !request.isCancelled else { return }
            do {
                for root in self.roots {
                    let values = try root.url.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else {
                        throw JournalError.database("Cartella origine non disponibile")
                    }
                }
                // This is a LOCAL periodic audit, not a recurring SMB scan.
                if self.recoveryRequired || (self.lastFullScan.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true) {
                    self.safetyGate.beginReconciliation(generation:generation)
                    var scan = ArchiveAuditProgress(); scan.phase = "Verifica locale"
                    self.update(MonitorUpdate(message:scan.phase,monitoring:false,pendingChanges:(try? store.pendingCount()) ?? 0,scanProgress:scan))
                    for root in self.roots {
                        _ = try store.reconcile(rootID: root.id, root: root.url, shouldContinue:{ !request.isCancelled })
                    }
                    guard !request.isCancelled else { throw SeedVerificationError.cancelled }
                    self.safetyGate.setReady(true,generation:generation)
                    self.lastFullScan = Date()
                    self.recoveryRequired = false
                    try? self.activityLog?.record(
                        level: .info, rootID: "monitor", action: "audit",
                        message: "Verifica locale completata"
                    )
                    self.report("Verifica completa locale conclusa", active: true)
                }
            } catch {
                self.safetyGate.fail(generation:generation,reason:"Verifica locale sospesa: " + SyncDiagnostic.describe(error))
                self.recoveryRequired = true
                try? self.activityLog?.record(level:.error,rootID:"monitor",action:"inventory_health",message:SyncDiagnostic.describe(error))
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
        activityLog = nil
        activeGeneration=nil; activeRequest=nil; activeDatabasePath=nil
        roots = []
        lastFullScan = nil
        recoveryRequired = false
    }

    private func report(_ message: String, active: Bool) {
        // The queue is durable; count from the database rather than a UI cache.
        let breakdown = try? inventory?.pendingBreakdown()
        let names: [IncompatibleName]?
        if active, let inventory,let databasePath=activeDatabasePath {
            names = try? {
                let rows=try roots.flatMap { try inventory.incompatibleNames(rootID:$0.id,sourcePath:$0.url.path) }
                return try NameRectification.localMaintenanceRows(rows,journal:ChangeJournal(path:databasePath,readOnly:true))
            }()
        } else { names = nil }
        update(MonitorUpdate(message:message,monitoring:active,pendingChanges:breakdown?.total ?? 0,
                             pendingBreakdown:breakdown,sourceNames:names))
    }
}
