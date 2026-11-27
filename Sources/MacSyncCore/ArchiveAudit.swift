import Foundation
import Darwin
import CryptoKit

public enum ArchiveAuditMode: String, Codable, CaseIterable, Sendable {
    case quick, intelligent, deep
    /// Only these modes are available to operators. Keep .deep internally
    /// for historical reports and safety/regression diagnostics.
    public static let selectableModes: [ArchiveAuditMode] = [.quick, .intelligent]
    public var label: String {
        switch self {
        case .quick: return "Rapida (metadati)"
        case .intelligent: return "Intelligente (SHA-256 selettivo)"
        case .deep: return "Completa (SHA-256)"
        }
    }
}
public struct ArchiveAuditSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var mode: ArchiveAuditMode = .quick
    public var repair = false
    public var frequency = "weekly"
    public var weekday = 1
    public var monthDay = 1
    public var hour = 3
    public var minute = 0
    public init() {}

    /// Migrate only the operator selection; legacy DEEP reports and the
    /// internal SHA-256 code remain decodable and available for diagnostics.
    /// Return whether the stored selection actually changed.
    @discardableResult public mutating func migrateLegacyDeepSelection() -> Bool {
        guard mode == .deep else { return false }
        mode = .intelligent
        return true
    }

    /// Restore the existing settings object without discarding schedule,
    /// repair and enabled flags. Write back immediately only on migration.
    /// Invalid/unknown settings retain the established default fallback.
    public static func loadMigratingLegacyDeep(from defaults: UserDefaults, key: String,
                                               at date: Date = Date()) -> Self {
        guard let data = defaults.data(forKey: key),
              var restored = try? JSONDecoder().decode(Self.self, from: data),
              restored.next(after: date) != nil else { return Self() }
        if restored.migrateLegacyDeepSelection(),
           let encoded = try? JSONEncoder().encode(restored) {
            defaults.set(encoded, forKey: key)
        }
        return restored
    }

    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute),
              (1...7).contains(weekday), (1...28).contains(monthDay) else { return nil }
        var parts = DateComponents(hour:hour,minute:minute,second:0)
        switch frequency {
        case "daily": break
        case "weekly": parts.weekday = weekday
        case "monthly": parts.day = monthDay
        default: return nil
        }
        return calendar.nextDate(after:date,matching:parts,matchingPolicy:.nextTime,
                                 repeatedTimePolicy:.first,direction:.forward)
    }
}
public enum AuditFindingKind: String, Codable, CaseIterable, Sendable {
    case matching, missing, different, extra, uncertain
    public var label: String {
        switch self {
        case .matching: return "Corrispondenti"
        case .missing: return "Mancanti nella destinazione"
        case .different: return "Differenti"
        case .extra: return "Solo destinazione"
        case .uncertain: return "Non verificabili / conflitti"
        }
    }
}
public struct AuditFinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String { rootID + "\0" + relativePath }
    public let rootID: String
    public let relativePath: String
    public let sourceRoot: String
    public let targetRoot: String
    public let objectKind: String
    public let bytes: Int64
    public let kind: AuditFindingKind
    public let detail: String
    // Optional for compatibility with saved reports and UI test fixtures.
    public var sourceBytes: Int64? = nil
    public var targetBytes: Int64? = nil
    public var sourceModifiedAt: Double? = nil
    public var targetModifiedAt: Double? = nil
    public var repairEligible: Bool? = nil
    public var targetObjectKind: String? = nil
    public var directNameConflict: Bool? = nil
}
public struct AuditSideMetrics: Codable, Equatable, Sendable {
    public var files = 0
    public var directories = 0
    public var detectedBytes: Int64 = 0
    public var bytesRead: Int64 = 0
    public var readSeconds: Double = 0
    public var scanSeconds: Double = 0
    /// Actual syscall timings; not a count of SMB packets or content bytes.
    public var metadataTiming:DiagnosticTiming? = nil
    public init() {}
    public var meanReadRate: Double? { readSeconds > 0 && bytesRead > 0 ? Double(bytesRead)/readSeconds : nil }
    public var scanRate: Double? { scanSeconds > 0 ? Double(files)/scanSeconds : nil }
    public mutating func record(_ item: TrackedItem) {
        if item.kind == "file" {
            files += 1
            let sum = detectedBytes.addingReportingOverflow(max(0,item.size))
            detectedBytes = sum.overflow ? Int64.max : sum.partialValue
        } else if item.kind == "directory" { directories += 1 }
    }
    public mutating func read(_ count: Int64, seconds: Double) {
        let sum = bytesRead.addingReportingOverflow(max(0,count))
        bytesRead = sum.overflow ? Int64.max : sum.partialValue
        readSeconds += max(0,seconds)
    }
}

/// Lightweight counters computed once on the worker. No UI traversal of the archive.
public struct AuditFindingCounts: Codable, Equatable, Sendable {
    public var newFiles = 0
    public var updatedFiles = 0
    public var deletionFiles = 0
    // Optional for reports saved before full mirror support.
    public var deletionDirectories: Int? = nil
    public var extra = 0
    public var uncertain = 0
    public init() {}
    public mutating func record(_ finding: AuditFinding, deletionCandidates: Set<String>) {
        if finding.kind == .extra { extra += 1 }
        if finding.kind == .uncertain { uncertain += 1 }
        if finding.objectKind == "directory", finding.kind == .extra,
           deletionCandidates.contains(finding.id) {
            deletionDirectories=(deletionDirectories ?? 0)+1
        }
        guard finding.objectKind == "file" else { return }
        switch finding.kind {
        case .missing: newFiles += 1
        case .different: updatedFiles += 1
        case .extra: if deletionCandidates.contains(finding.id) { deletionFiles += 1 }
        default: break
        }
    }
    public var deletionItems: Int { deletionFiles+(deletionDirectories ?? 0) }
    public func files(_ kind: AuditFindingKind) -> Int {
        switch kind {
        case .missing: return newFiles
        case .different: return updatedFiles
        case .extra: return deletionFiles
        default: return 0
        }
    }
    public static func calculate(_ findings: [AuditFinding], deletionCandidates: Set<String>) -> Self {
        var counts = Self()
        for finding in findings { counts.record(finding,deletionCandidates:deletionCandidates) }
        return counts
    }
}

/// A bounded latest-value mailbox. At most one callback needs to be queued on
/// the main thread, even if it temporarily cannot consume progress.
public final class AuditProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: ArchiveAuditProgress?
    private var scheduled = false
    public init() {}
    public func offer(_ value: ArchiveAuditProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = value
        if scheduled { return false }
        scheduled = true
        return true
    }
    public func take() -> ArchiveAuditProgress? {
        lock.lock(); defer { lock.unlock() }
        let value = latest
        latest = nil; scheduled = false
        return value
    }
}

public struct AuditFindingPage: Sendable {
    public let rows: [AuditFinding]
    public let roots: [String]
    public let total: Int
    public let offset: Int

    /// Worker-only scan. Bounded table page; no full filtered array is built.
    public static func load(findings: [AuditFinding], kind: AuditFindingKind?, filesOnly: Bool,
                            deletionCandidates: Set<String>, root: String, search: String,
                            offset: Int, limit: Int = 200, shouldContinue: () -> Bool = { true }) -> Self? {
        let limit = max(1,min(200,limit)), offset = max(0,offset)
        var rows = [AuditFinding](), roots = Set<String>(), total = 0
        for (index,finding) in findings.enumerated() {
            if index % 256 == 0 && !shouldContinue() { return nil }
            guard kind == nil || finding.kind == kind else { continue }
            if filesOnly {
                guard finding.objectKind == "file" else { continue }
                if kind == .extra && !deletionCandidates.contains(finding.id) { continue }
            }
            roots.insert(finding.rootID)
            guard root.isEmpty || root == finding.rootID else { continue }
            guard search.isEmpty || finding.relativePath.localizedCaseInsensitiveContains(search) else { continue }
            if total >= offset && rows.count < limit { rows.append(finding) }
            total += 1
        }
        guard shouldContinue() else { return nil }
        return Self(rows:rows,roots:roots.sorted(),total:total,offset:offset)
    }
}

public struct ArchiveAuditProgress: Equatable, Sendable {
    public var source = AuditSideMetrics()
    public var destination = AuditSideMetrics()
    public var comparisonStarted: Date?
    public var scanningDestination = false
    public var counts = AuditFindingCounts()
    public var differences: [AuditFinding] = []
    public var deletionCandidates: Set<String> = []
    public var compareRate: Double? {
        let seconds = source.readSeconds + destination.readSeconds
        return seconds > 0 && bytesRead > 0 ? Double(bytesRead)/seconds : nil
    }
    public func remaining(at now: Date) -> Double? {
        guard let start = comparisonStarted, phase != "Finalizzazione" else { return nil }
        let elapsed = now.timeIntervalSince(start)
        // Delay extrapolation on heterogeneous archives until a meaningful
        // sample exists; the scan time is never charged to the compare phase.
        guard elapsed >= 8, compared >= min(500,max(10,total/100)) else { return nil }
        return OperationEstimate.remaining(processed:compared,total:total,elapsed:elapsed)
    }
    public let started: Date
    public var phase = "Analisi sorgente e destinazione"
    public var scannedFiles = 0
    public var scannedDirectories = 0
    public var detectedBytes: Int64 = 0
    public var compared = 0
    public var total = 0
    public var bytesRead: Int64 = 0
    public var currentPath = ""
    public init(started: Date = Date()) { self.started = started }
}
public struct ArchiveAuditReport: Codable, Equatable, Sendable {
    public let mode: ArchiveAuditMode
    public let started: Date
    public let ended: Date
    public let seconds: Double
    public let findings: [AuditFinding]
    public let bytesRead: Int64
    public let queuedRepairs: Int
    public let repairRequested: Bool
    // Optional for decoding reports saved by older versions.
    public var sourceMetrics: AuditSideMetrics? = nil
    public var destinationMetrics: AuditSideMetrics? = nil
    public var deletionCandidates: Set<String>? = nil
    public var recognizedFiles: Int? = nil
    public var recognizedDirectories: Int? = nil
    public var recognizedAbsentDeletes: Int? = nil
    public var metadataMatches: Int? = nil
    public var hashMatches: Int? = nil
    /// Number of file hash calculations started (including mismatches).
    public var hashCalculations: Int? = nil
    public var cachedHashMatches: Int? = nil
    public var directoryListingCacheHits: Int? = nil
    public var directoryListingReads: Int? = nil
    public var displayCounts: AuditFindingCounts? = nil
    public var nameScans: [NameScanSnapshot]? = nil
    public var comparisonSeconds: Double? = nil
    public func count(_ kind: AuditFindingKind) -> Int {
        findings.lazy.filter { $0.kind == kind }.count
    }
}
public final class ArchiveAudit {
    private let journal: ChangeJournal
    private let mappings: [MountedFolderMapping]
    // Internal test-only opt-in. No application preference or UI enables it.
    // Operations with reconciliation authority stay POSIX.
    var experimentalBulkInventory = false
    public init(journal: ChangeJournal, mappings: [MountedFolderMapping]) throws {
        guard !mappings.isEmpty, Set(mappings.map(\.rootID)).count == mappings.count else {
            throw MountedCopyError.invalidMapping
        }
        let paths = mappings.flatMap { [$0.source.path.lowercased(),$0.target.path.lowercased()] }
        for i in paths.indices {
            for j in paths.indices where j > i {
                guard paths[i] != paths[j], !paths[i].hasPrefix(paths[j]+"/"),
                    !paths[j].hasPrefix(paths[i]+"/") else { throw MountedCopyError.invalidMapping }
            }
        }
        self.journal = journal; self.mappings = mappings
    }

    // Deliberately read-only on both archives. Explicit repair can queue safe
    // UPSERTs and, with queueMirrorExtras, verified extra paths as DELETEs.
    public func run(mode: ArchiveAuditMode, repair: Bool = false,
                    cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
                    collectMetadataMatches: Bool = false,
                    shouldCollectMetadataMatch: (String,String) -> Bool = { _,_ in true },
                    deletionCandidates: Set<String> = [],
                    queueMirrorExtras: Bool = false,
                    onVerifiedFile: (String, String, SeedFileFingerprint, SeedFileFingerprint) -> Void = { _,_,_,_ in },
                    onVerifiedDirectory: (String, String, SeedFileFingerprint, SeedFileFingerprint) -> Void = { _,_,_,_ in },
                    diagnostic: (ArchiveAuditProgress) -> Void = { _ in },
                    progress: (ArchiveAuditProgress) -> Void = { _ in }) throws -> ArchiveAuditReport {
        var state = ArchiveAuditProgress()
        let queueExtras = repair && queueMirrorExtras
        if queueExtras { try journal.verifyDirectoryBindings(mappings) }
        // One indexed read of the already-approved SQLite rename plan.
        // Its relationships are NOT inferred from equal size or timestamps.
        let pendingRenames = try NameRectification.pendingProtection(journal: journal)
        state.deletionCandidates = deletionCandidates
        let startTick = ProcessInfo.processInfo.systemUptime
        var published: Double = 0
        var lastDiagnostic: Double = 0
        func check() throws { if cancellation.isCancelled { throw SeedVerificationError.cancelled } }
        func diagnosticSnapshot(force: Bool = false) {
            // Diagnostic snapshots previously copied even the large report
            // structure on every item/visit. Rate-limit only these optional
            // snapshots; all items still affect counts and safety checks.
            let now=ProcessInfo.processInfo.systemUptime
            guard force || now-lastDiagnostic >= 0.2 else { return }
            lastDiagnostic=now
            var lightweight = state
            lightweight.differences = []; lightweight.deletionCandidates = []
            diagnostic(lightweight)
        }
        func report(force: Bool = false) {
            diagnosticSnapshot(force:force)
            let now = ProcessInfo.processInfo.systemUptime
            if force || now-published >= 1 { published=now; progress(state) }
        }
        struct Pair {
            let mapping: MountedFolderMapping
            let source: [String:TrackedItem]
            let target: [String:TrackedItem]
            let ambiguous: Set<String>
            let sourceStamp: String
            let targetStamp: String
            let cacheBinding: String?
            let sourceBinding: String?
            let targetBinding: String?
        }
        var pairs: [Pair] = []
        var nameScans: [NameScanSnapshot] = []
        for mapping in mappings {
            state.phase = "Controllo coppia di cartelle"; state.currentPath = mapping.rootID; report(force:true)
            try check(); try mapping.verify()
            guard try journal.watchedRootPath(rootID: mapping.rootID) == mapping.source.path else {
                throw MirrorDeletionFailure.noBaseline
            }
            let sourceStamp = try Self.rootStamp(mapping.source)
            let targetStamp = try Self.rootStamp(mapping.target)
            let sourceBinding = queueExtras ? try DirectoryBinding.encoded(mapping.source) : nil
            let targetBinding = queueExtras ? try DirectoryBinding.encoded(mapping.target) : nil
            var scanStart = ProcessInfo.processInfo.systemUptime
            func scanned(_ item: TrackedItem) {
                if state.scanningDestination { state.destination.record(item) }
                else { state.source.record(item) }
                if item.kind == "file" {
                    state.scannedFiles += 1
                    let n = state.detectedBytes.addingReportingOverflow(max(0,item.size))
                    state.detectedBytes = n.overflow ? Int64.max : n.partialValue
                } else if item.kind == "directory" { state.scannedDirectories += 1 }
                state.currentPath = mapping.rootID + " / " + item.relativePath
                report()
            }
            state.scanningDestination = false
            let sourcePrior = state.source.scanSeconds
            scanStart = ProcessInfo.processInfo.systemUptime
            state.phase = "Analisi sorgente"; state.currentPath = mapping.rootID; report(force:true)
            let source = try LocalScanner.scan(root:mapping.source,excludeManaged:true,
                shouldContinue:{ !cancellation.isCancelled },onVisit:{ relative in
                    state.currentPath = mapping.rootID + " / " + relative; diagnosticSnapshot()
                },onItem:{ item in
                    state.source.scanSeconds = sourcePrior + ProcessInfo.processInfo.systemUptime-scanStart
                    scanned(item)
                })
            state.source.scanSeconds = sourcePrior + ProcessInfo.processInfo.systemUptime-scanStart
            try mapping.verify()
            state.scanningDestination = true
            let targetPrior = state.destination.scanSeconds
            scanStart = ProcessInfo.processInfo.systemUptime
            state.phase = "Analisi destinazione"; state.currentPath = mapping.rootID; report(force:true)
            let useBulk = experimentalBulkInventory && !repair && !collectMetadataMatches &&
                deletionCandidates.isEmpty && !queueMirrorExtras && mode != .deep
            enum ScanUpdate: Sendable {
                case visit(String), item(TrackedItem), metadata(DiagnosticTiming), method(String)
            }
            let target = try InventoryReadLane.archive.read(
                shouldContinue: { !cancellation.isCancelled }, onUpdate: { (updates: [ScanUpdate]) in
                    for update in updates {
                        switch update {
                        case .method(let method):
                            state.phase = "Analisi destinazione · " + method
                            report(force:true)
                        case .visit(let path):
                            state.currentPath = mapping.rootID + " / " + path
                            diagnosticSnapshot()
                        case .metadata(let timing):
                            var aggregate=state.destination.metadataTiming ?? DiagnosticTiming()
                            aggregate.merge(timing)
                            state.destination.metadataTiming=aggregate
                        case .item(let item):
                            state.destination.scanSeconds = targetPrior + ProcessInfo.processInfo.systemUptime - scanStart
                            scanned(item)
                        }
                    }
                }, work: { active, report in
                    func posix() throws -> [TrackedItem] {
                        try LocalScanner.scan(root: mapping.target, excludeManaged: true, preferPOSIXMetadata: true,
                            shouldContinue: active, onVisit: { report(.visit($0)) }, onItem: { report(.item($0)) },
                            onPOSIXMetadataTiming: { report(.metadata($0)) }, measurePOSIXMetadata: DiagnosticCollectionLevel.current != .standard)
                    }
                    guard useBulk else { return try posix() }
                    return try withoutActuallyEscaping(active) { checkActive in
                        let selection = try BulkInventoryFallback.scan(
                            shouldContinue: checkActive,
                            verifyBinding: {
                                try mapping.verify()
                                guard try Self.rootStamp(mapping.target) == targetStamp else {
                                    throw MountedCopyError.volumeChanged
                                }
                            }, bulk: {
                                report(.method("metadati raggruppati · prova"))
                                do {
                                    return try BulkArchiveScanner.scan(root: mapping.target, excludeManaged: true,
                                        shouldContinue: checkActive, onVisit: { report(.visit($0)) })
                                } catch BulkArchiveScanner.Failure.unsupportedName {
                                    // Discard the candidate; restart inside the same lane.
                                    return .unsupported
                                }
                            }, posix: {
                                report(.method("POSIX · fallback"))
                                return try posix()
                            })
                        if selection.method == .bulk {
                            // Publish item counters only for the accepted complete inventory.
                            for item in selection.value {
                                guard checkActive() else { throw SeedVerificationError.cancelled }
                                report(.item(item))
                            }
                        }
                        return selection.value
                    }
                })
            state.destination.scanSeconds = targetPrior + ProcessInfo.processInfo.systemUptime-scanStart
            try mapping.verify()
            guard try Self.rootStamp(mapping.source) == sourceStamp,
                  try Self.rootStamp(mapping.target) == targetStamp else { throw MountedCopyError.volumeChanged }
            let paths = Set(source.map(\.relativePath)).union(target.map(\.relativePath))
            let grouped = Dictionary(grouping:paths,by:Self.fold)
            let ambiguous = Set(grouped.filter { $0.value.count > 1 }.keys)
            try check()
            state.phase = "Controllo nomi incompatibili · Sorgente"
            report(force: true)
            // Keep cross-side ambiguity detection for audit and mirror safety,
            // but the maintenance list represents only incompatible local names.
            nameScans.append(NameScanSnapshot(
                rootID: mapping.rootID, side: .source, rootPath: mapping.source.path,
                volume: nil, date: Date(), rows: try IncompatibleName.collect(
                    rootID: mapping.rootID, rootPath: mapping.source.path, side: .source,
                    items: source, shouldContinue: { !cancellation.isCancelled })))
            pairs.append(Pair(mapping:mapping,source:Dictionary(uniqueKeysWithValues:source.map{($0.relativePath,$0)}),
                target:Dictionary(uniqueKeysWithValues:target.map{($0.relativePath,$0)}),ambiguous:ambiguous,
                sourceStamp:sourceStamp,targetStamp:targetStamp,
                cacheBinding: mode == .intelligent ? (try? DirectoryBinding.encoded(mapping.source) + "\0" + DirectoryBinding.encoded(mapping.target)) : nil,
                sourceBinding:sourceBinding,targetBinding:targetBinding))
            state.total += paths.count
        }
        var findings: [AuditFinding] = []
        var metadataMatches = 0, hashMatches = 0, cachedHashMatches = 0
        var hashCalculations = 0
        var candidates: [(MountedFolderMapping, TrackedItem, String, SeedFileFingerprint?)] = []
        state.comparisonStarted = Date()
        let comparisonTick = ProcessInfo.processInfo.systemUptime
        state.phase = mode == .deep ? "Verifica SHA-256" : (mode == .intelligent ? "Verifica intelligente" : "Confronto metadati")
        report(force:true)
        var listingHits = 0, listingReads = 0
        for pair in pairs {
            let mapping = pair.mapping
            let listingCache = AuditDirectoryListingCache()
            for path in Set(pair.source.keys).union(pair.target.keys).sorted() {
                try check()
                state.currentPath = mapping.rootID + " / " + path
                diagnosticSnapshot()
                let src = pair.source[path], dst = pair.target[path]
                let item = (src ?? dst)!
                var kind: AuditFindingKind = .uncertain
                var detail = ""
                var fingerprint: SeedFileFingerprint?
                do {
                    // On case-insensitive SMB a name mismatch can alias a
                    // different file. Do not generate repair for either path
                    // or descendants of an ambiguous/conflicting directory.
                    let comps = path.split(separator:"/")
                    let ancestors = (1...comps.count).map { comps.prefix($0).joined(separator:"/") }
                    let collision = ancestors.contains { name in
                        pair.ambiguous.contains(Self.fold(name)) ||
                        (pair.source[name] != nil && pair.target[name] != nil &&
                            pair.source[name]?.kind != pair.target[name]?.kind) ||
                        pair.source[name]?.kind == "symlink" || pair.target[name]?.kind == "symlink"
                    }
                    if pendingRenames.protects(rootID: mapping.rootID, path: path) {
                        // A known outstanding rename can present as a missing
                        // source-name and an extra old destination-name. Do
                        // not hash, enqueue repairs or authorize deletion.
                        kind = .uncertain
                        detail = "Rettifica nomi registrata e ancora pendente: copia e cancellazione sospese"
                    } else if collision || item.kind == "symlink" {
                        detail = "Percorso ambiguo, tipo incompatibile o collegamento simbolico"
                    } else if src == nil { kind = .extra }
                    else if dst == nil {
                        if WindowsPathSafety.validRelativePath(path) { kind = .missing }
                        else { detail = "Nome non creabile in sicurezza nella destinazione" }
                    }
                    else if item.kind == "directory" {
                        kind = .matching
                        if collectMetadataMatches && shouldCollectMetadataMatch(mapping.rootID,path) {
                            let beforeA: SeedFileFingerprint
                            let beforeB: SeedFileFingerprint
                            if (mode == .quick || mode == .intelligent),
                               let scannedSource = src!.verificationFingerprint,
                               let scannedTarget = dst!.verificationFingerprint {
                                // Directory metadata was already collected as
                                // part of the two complete inventories. Live
                                // validation is required before SQLite ACK.
                                beforeA = scannedSource
                                beforeB = scannedTarget
                            } else {
                                let a = try Self.safeURL(path,mapping:mapping,destination:false,listingCache:listingCache)
                                let b = try Self.safeURL(path,mapping:mapping,destination:true,listingCache:listingCache)
                                beforeA = try SeededArchiveVerifier.fingerprint(a,directory:true)
                                beforeB = try SeededArchiveVerifier.fingerprint(b,directory:true)
                                guard try SeededArchiveVerifier.fingerprint(a,directory:true) == beforeA,
                                      try SeededArchiveVerifier.fingerprint(b,directory:true) == beforeB else {
                                    throw SeedVerificationError.changedDuringRead
                                }
                            }
                            onVerifiedDirectory(mapping.rootID,path,beforeA,beforeB)
                        }
                    }
                    else if src!.size != dst!.size {
                        // QUICK/INTELLIGENT report this mismatch from the single
                        // destination inventory. Re-statting every remote mismatch
                        // would defeat the one-pass metadata policy. The transfer
                        // worker independently validates paths and target safety
                        // before any write; the audit itself never writes there.
                        // Retain the internal DEEP mode's exact legacy checks.
                        if mode == .deep {
                            let a = try Self.safeURL(path,mapping:mapping,destination:false,listingCache:listingCache)
                            let b = try Self.safeURL(path,mapping:mapping,destination:true,listingCache:listingCache)
                            let beforeA = try SeededArchiveVerifier.fingerprint(a)
                            let beforeB = try SeededArchiveVerifier.fingerprint(b)
                            guard beforeA.size == src!.size, beforeB.size == dst!.size,
                                  abs(beforeA.modifiedAt-src!.modifiedAt)<0.002,
                                  abs(beforeB.modifiedAt-dst!.modifiedAt)<0.002,
                                  try SeededArchiveVerifier.fingerprint(a) == beforeA,
                                  try SeededArchiveVerifier.fingerprint(b) == beforeB else {
                                throw SeedVerificationError.changedDuringRead
                            }
                            fingerprint = beforeA
                        }
                        kind = .different; detail = "Dimensione diversa"
                    }
                    else if mode == .quick || (mode == .intelligent && abs(src!.modifiedAt-dst!.modifiedAt) <= 2) {
                        // Metadata equivalence is NOT proof of byte identity.
                        kind = abs(src!.modifiedAt-dst!.modifiedAt) <= 2 ? .matching : .different
                        if kind == .different { detail = "Data di modifica diversa" }
                        else if collectMetadataMatches && shouldCollectMetadataMatch(mapping.rootID,path) {
                            let beforeA: SeedFileFingerprint
                            let beforeB: SeedFileFingerprint
                            if (mode == .quick || mode == .intelligent),
                               let scannedSource = src!.verificationFingerprint,
                               let scannedTarget = dst!.verificationFingerprint {
                                // The scanner already obtained both no-follow stat records.
                                // Keep the complete fingerprints for live pre-commit validation.
                                // This removes two redundant SMB metadata requests and exact
                                // parent listing walks for every pending quick-match candidate.
                                beforeA = scannedSource
                                beforeB = scannedTarget
                            } else {
                                let a = try Self.safeURL(path,mapping:mapping,destination:false,listingCache:listingCache)
                                let b = try Self.safeURL(path,mapping:mapping,destination:true,listingCache:listingCache)
                                beforeA = try SeededArchiveVerifier.fingerprint(a)
                                beforeB = try SeededArchiveVerifier.fingerprint(b)
                            }
                            guard beforeA.size == src!.size, beforeB.size == dst!.size,
                                  abs(beforeA.modifiedAt-src!.modifiedAt) < 0.002,
                                  abs(beforeB.modifiedAt-dst!.modifiedAt) < 0.002,
                                  abs(beforeA.modifiedAt-beforeB.modifiedAt) <= 2 else {
                                throw SeedVerificationError.changedDuringRead
                            }
                            fingerprint = beforeA
                            detail = "Corrispondenza metadati (contenuto non confrontato)"
                            onVerifiedFile(mapping.rootID,path,beforeA,beforeB)
                        }
                    } else {
                        let a = try Self.safeURL(path,mapping:mapping,destination:false,listingCache:listingCache)
                        let b = try Self.safeURL(path,mapping:mapping,destination:true,listingCache:listingCache)
                        let beforeA = try SeededArchiveVerifier.fingerprint(a)
                        let beforeB = try SeededArchiveVerifier.fingerprint(b)
                        guard beforeA.size == src!.size, beforeB.size == dst!.size,
                              abs(beforeA.modifiedAt-src!.modifiedAt) < 0.002,
                              abs(beforeB.modifiedAt-dst!.modifiedAt) < 0.002 else {
                            throw SeedVerificationError.changedDuringRead
                        }
                        var readTick = ProcessInfo.processInfo.systemUptime
                        func read(_ n: Int64, destination: Bool) {
                            let now = ProcessInfo.processInfo.systemUptime
                            let sum = state.bytesRead.addingReportingOverflow(n)
                            state.bytesRead = sum.overflow ? Int64.max : sum.partialValue
                            if destination { state.destination.read(n,seconds:now-readTick) }
                            else { state.source.read(n,seconds:now-readTick) }
                            readTick = now
                            report()
                        }
                        let cacheHit = mode == .intelligent && pair.cacheBinding.map { binding in
                            (try? journal.cachedContentMatches(rootID:mapping.rootID,path:path,binding:binding,source:beforeA,target:beforeB)) == true
                        } == true
                        let identical:Bool
                        if cacheHit { identical=true }
                        else {
                            hashCalculations += 1
                            let h1 = try Self.hash(a,expected:beforeA,cancel:cancellation,read:{ read($0,destination:false) })
                            readTick = ProcessInfo.processInfo.systemUptime
                            hashCalculations += 1
                            let h2 = try Self.hash(b,expected:beforeB,cancel:cancellation,read:{ read($0,destination:true) })
                            identical=h1==h2
                        }
                        guard try SeededArchiveVerifier.fingerprint(a) == beforeA,
                              try SeededArchiveVerifier.fingerprint(b) == beforeB else {
                            throw SeedVerificationError.changedDuringRead
                        }
                        fingerprint = beforeA
                        kind = identical ? .matching : .different
                        if kind == .different { detail = "Contenuto SHA-256 diverso" }
                        else {
                            detail = cacheHit ? "Contenuto SHA-256 corrispondente (cache verificata)" : "Contenuto SHA-256 corrispondente"
                            if !cacheHit, let binding=pair.cacheBinding {
                                try? journal.storeContentMatch(rootID:mapping.rootID,path:path,binding:binding,source:beforeA,target:beforeB)
                            }
                            onVerifiedFile(mapping.rootID,path,beforeA,beforeB)
                        }
                    }
                    if repair && (kind == .missing || kind == .different), let src {
                        // Reading a name does not grant permission to create or replace it.
                        _ = try mapping.fileURL(relativePath:path,destination:true)
                        let url = try Self.safeURL(path,mapping:mapping,destination:false,listingCache:listingCache)
                        if src.kind == "file" {
                            let fresh = try SeededArchiveVerifier.fingerprint(url)
                            guard fresh.size == src.size, abs(fresh.modifiedAt-src.modifiedAt)<0.002,
                                  fingerprint == nil || fingerprint == fresh else { throw SeedVerificationError.changedDuringRead }
                            fingerprint = fresh
                        } else { _ = try Self.rootStamp(url) }
                        candidates.append((mapping,src,pair.sourceStamp,fingerprint))
                    }
                } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
                catch { listingCache.invalidate(); kind = .uncertain; detail = SyncDiagnostic.describe(error) }
                if kind == .matching && item.kind == "file" {
                    if detail == "Contenuto SHA-256 corrispondente" { hashMatches += 1 }
                    else if detail == "Contenuto SHA-256 corrispondente (cache verificata)" { cachedHashMatches += 1 }
                    else { metadataMatches += 1; detail = "Corrispondenza metadati (contenuto non confrontato)" }
                }
                let finding = AuditFinding(rootID:mapping.rootID,relativePath:path,
                    sourceRoot:mapping.source.path,targetRoot:mapping.target.path,objectKind:item.kind,
                    bytes:item.size,kind:kind,detail:detail,sourceBytes:src?.size,targetBytes:dst?.size,
                     sourceModifiedAt:src?.modifiedAt,targetModifiedAt:dst?.modifiedAt,
                     repairEligible: (kind == .missing || kind == .different) && WindowsPathSafety.validRelativePath(path),
                     targetObjectKind:dst?.kind,
                     directNameConflict:pair.ambiguous.contains(Self.fold(path)) && !ancestorsHaveAlias(path,pair.ambiguous))
                findings.append(finding)
                state.counts.record(finding,deletionCandidates:deletionCandidates)
                if item.kind == "file" && kind != .matching { state.differences.append(finding) }
                state.compared += 1; report()
            }
            listingHits += listingCache.hits; listingReads += listingCache.enumerations
            listingCache.invalidate()
            try mapping.verify()
            guard try Self.rootStamp(mapping.source) == pair.sourceStamp,
                  try Self.rootStamp(mapping.target) == pair.targetStamp else { throw MountedCopyError.volumeChanged }
        }
        try check()
        let comparisonSeconds = ProcessInfo.processInfo.systemUptime - comparisonTick
        state.phase = "Finalizzazione"; state.currentPath = ""; report(force:true)
        // Candidate confirmation touches ONLY the local source and SQLite,
        // never the SMB destination. Re-check source metadata and a newly
        // recorded rename plan after each transient FSEvents interruption:
        // the old snapshot is not authority to upload a changed/deleted file.
        func safeLocalRepairs() throws -> [(rootID:String,sourcePath:String,item:TrackedItem)] {
            var safe: [(rootID:String,sourcePath:String,item:TrackedItem)] = []
            let latestProtection = try NameRectification.pendingProtection(journal:journal)
            for (map,item,stamp,fingerprint) in candidates {
                try check()
                guard try Self.rootStamp(map.source) == stamp else { throw MountedCopyError.sourceRootChanged }
                do {
                    let url=try Self.safeURL(item.relativePath,mapping:map,destination:false)
                    if let fingerprint {
                        guard try SeededArchiveVerifier.fingerprint(url) == fingerprint else { continue }
                    } else { _ = try Self.rootStamp(url) }
                    guard !latestProtection.protects(rootID:map.rootID,path:item.relativePath) else { continue }
                    safe.append((map.rootID,map.source.path,item))
                } catch { continue }
            }
            return safe
        }
        var repairs = repair ? try safeLocalRepairs() : []
        var queued = 0
        var retries = 0
        while !repairs.isEmpty {
            try check()
            // beginReconciliation sets ready=false transiently. The audit's
            // read-only comparison is still valid, but committing while the
            // monitor has not persisted newer FSEvents is prohibited.
            // Never wait inside an active SQLite transaction.
            guard cancellation.awaitCommitWindow(onWaiting:{
                state.phase="Attesa completamento inventario locale"; report(force:true)
            }) else { throw SeedVerificationError.cancelled }
            if retries > 0 {
                repairs = try safeLocalRepairs()
                if repairs.isEmpty { break }
            }
            state.phase = "Salvataggio operazioni nel database"; state.comparisonStarted = nil
            report(force:true)
            do {
                queued = try journal.enqueueAuditRepairs(repairs,
                    shouldContinue:{ cancellation.mayCommit },
                    onProgress:{ done,total in
                        state.phase = "Salvataggio operazioni nel database · \(done)/\(total)"
                        report(force: done == 0 || done == total)
                    })
                break
            } catch SeedVerificationError.cancelled {
                // The journal has already ROLLED BACK. Another brief source
                // reconciliation may have started within the transaction.
                // Retry at most 3 times using the same remote snapshot and
                // fresh LOCAL safety checks; never silently bypass Stop.
                guard !cancellation.isCancelled, retries < 3 else { throw SeedVerificationError.cancelled }
                retries += 1
                state.phase="Attesa sicurezza coda dopo eventi locali"
                report(force:true)
            }
        }
        var finalDeletionCandidates = deletionCandidates
        if queueExtras {
            // Only after ALL roots have been fully scanned and compared.
            // Validate live source absence, the same persisted root bindings,
            // and current SQLite state. Never re-read all remote files.
            let byRoot = Dictionary(grouping:findings.filter {
                $0.kind == .extra && ($0.objectKind == "file" || $0.objectKind == "directory") &&
                WindowsPathSafety.validDeletionPath($0.relativePath)
            },by: \.rootID)
            var deleteRetries = 0
            while true {
                guard cancellation.awaitCommitWindow(onWaiting:{
                    state.phase="Attesa completamento inventario locale"; report(force:true)
                }) else { throw SeedVerificationError.cancelled }
                var entries: [(rootID:String,path:String,sourcePath:String,sourceBinding:String,targetBinding:String)] = []
                for pair in pairs {
                    try check()
                    let map = pair.mapping
                    guard let src = pair.sourceBinding, let dst = pair.targetBinding else {
                        throw MountedCopyError.invalidMapping
                    }
                    try map.verify()
                    guard try DirectoryBinding.encoded(map.source)==src,
                          try DirectoryBinding.encoded(map.target)==dst else { throw MountedCopyError.volumeChanged }
                    for finding in byRoot[map.rootID] ?? [] {
                        try check()
                        if !WindowsPathSafety.validRelativePath(finding.relativePath) {
                            // Only a literal visible extra with no local alias
                            // is a candidate. Inaccessible/hidden names remain
                            // unconfirmed rather than guessed.
                            do {
                                try WindowsPathSafety.confirmLiteralAbsence(finding.relativePath,under:map.source)
                                _ = try map.verificationURL(relativePath:finding.relativePath,destination:true)
                                entries.append((map.rootID,finding.relativePath,map.source.path,src,dst))
                            } catch { continue }
                            continue
                        }
                        let url = map.source.appendingPathComponent(finding.relativePath)
                        var s = stat()
                        // Only absence, not permission denial/ENOTDIR/other
                        // errors, is evidence for deletion.
                        if url.path.withCString({ lstat($0,&s) }) != 0 && errno == ENOENT {
                            entries.append((map.rootID,finding.relativePath,map.source.path,src,dst))
                        }
                    }
                    guard try DirectoryBinding.encoded(map.source)==src,
                          try DirectoryBinding.encoded(map.target)==dst else { throw MountedCopyError.volumeChanged }
                }
                state.phase="Accodamento eliminazioni speculari"; report(force:true)
                do {
                    finalDeletionCandidates = try journal.enqueueAuditDeletes(entries,
                        shouldContinue:{ cancellation.mayCommit })
                    break
                } catch SeedVerificationError.cancelled {
                    guard !cancellation.isCancelled, deleteRetries < 3 else { throw SeedVerificationError.cancelled }
                    deleteRetries += 1
                }
            }
            state.deletionCandidates = finalDeletionCandidates
            state.counts = .calculate(findings,deletionCandidates:finalDeletionCandidates)
        }
        state.phase="Salvataggio operazioni nel database · completato"; report(force:true)
        return ArchiveAuditReport(mode:mode,started:state.started,ended:Date(),
            seconds:ProcessInfo.processInfo.systemUptime-startTick,findings:findings,
            bytesRead:state.bytesRead,queuedRepairs:queued,repairRequested:repair,
            sourceMetrics:state.source,destinationMetrics:state.destination,
            deletionCandidates:finalDeletionCandidates,metadataMatches:metadataMatches,hashMatches:hashMatches,hashCalculations:hashCalculations,cachedHashMatches:cachedHashMatches,directoryListingCacheHits:listingHits,directoryListingReads:listingReads,displayCounts:state.counts,nameScans:nameScans,comparisonSeconds:comparisonSeconds)
    }

    private func ancestorsHaveAlias(_ path:String,_ ambiguous:Set<String>) -> Bool {
        let parts=path.split(separator:"/")
        guard parts.count>1 else { return false }
        return (1..<parts.count).contains{ambiguous.contains(Self.fold(parts.prefix($0).joined(separator:"/")))}
    }

    private static func fold(_ path: String) -> String {
        path.split(separator:"/",omittingEmptySubsequences:false).map { WindowsPathSafety.comparisonFold(String($0)) }.joined(separator:"/")
    }
    private static func rootStamp(_ url: URL) throws -> String {
        var st = stat()
        guard url.path.withCString({ lstat($0,&st) }) == 0,
              st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              url.resolvingSymlinksInPath().path == url.path else { throw MountedCopyError.rootUnavailable }
        return "\(st.st_dev):\(st.st_ino)"
    }
    private static func safeURL(_ path:String,mapping:MountedFolderMapping,destination:Bool,listingCache:AuditDirectoryListingCache? = nil) throws -> URL {
        let url = try mapping.verificationURL(relativePath:path,destination:destination,listingCache:listingCache)
        guard url.resolvingSymlinksInPath().path == url.path else { throw SeedVerificationError.unsafeEntry }
        return url
    }
    private static func hash(_ url:URL,expected:SeedFileFingerprint,cancel:SeedVerificationCancellation,
                             read:(Int64)->Void) throws -> Data {
        let fd = url.path.withCString { Darwin.open($0,O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:nil) }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd,&st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(bitPattern:Int64(st.st_dev)) == expected.device,
              UInt64(st.st_ino) == expected.inode, Int64(st.st_size) == expected.size else {
            throw SeedVerificationError.changedDuringRead
        }
        var hash = SHA256()
        while true {
            if cancel.isCancelled { throw SeedVerificationError.cancelled }
            guard let chunk = try handle.read(upToCount:1024*1024), !chunk.isEmpty else { break }
            hash.update(data:chunk); read(Int64(chunk.count))
        }
        return Data(hash.finalize())
    }
}
