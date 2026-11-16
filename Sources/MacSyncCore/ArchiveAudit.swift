import Foundation
import Darwin
import CryptoKit

public enum ArchiveAuditMode: String, Codable, CaseIterable, Sendable { case quick, deep }
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
}
public struct ArchiveAuditProgress: Equatable, Sendable {
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
    public func count(_ kind: AuditFindingKind) -> Int {
        findings.lazy.filter { $0.kind == kind }.count
    }
}
public final class ArchiveAudit {
    private let journal: ChangeJournal
    private let mappings: [MountedFolderMapping]
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

    // Deliberately read-only except for explicitly requested guarded UPSERTs
    // in the local queue. No direct writes to the server; never creates DELETEs.
    public func run(mode: ArchiveAuditMode, repair: Bool = false,
                    cancellation: SeedVerificationCancellation = SeedVerificationCancellation(),
                    onVerifiedFile: (String, String, SeedFileFingerprint, SeedFileFingerprint) -> Void = { _,_,_,_ in },
                    progress: (ArchiveAuditProgress) -> Void = { _ in }) throws -> ArchiveAuditReport {
        var state = ArchiveAuditProgress()
        let startTick = ProcessInfo.processInfo.systemUptime
        var published: Double = 0
        func check() throws { if cancellation.isCancelled { throw SeedVerificationError.cancelled } }
        func report(force: Bool = false) {
            let now = ProcessInfo.processInfo.systemUptime
            if force || now-published >= 0.25 { published=now; progress(state) }
        }
        struct Pair {
            let mapping: MountedFolderMapping
            let source: [String:TrackedItem]
            let target: [String:TrackedItem]
            let ambiguous: Set<String>
            let sourceStamp: String
            let targetStamp: String
        }
        var pairs: [Pair] = []
        for mapping in mappings {
            try check(); try mapping.verify()
            guard try journal.watchedRootPath(rootID: mapping.rootID) == mapping.source.path else {
                throw MirrorDeletionFailure.noBaseline
            }
            let sourceStamp = try Self.rootStamp(mapping.source)
            let targetStamp = try Self.rootStamp(mapping.target)
            func scanned(_ item: TrackedItem) {
                if item.kind == "file" {
                    state.scannedFiles += 1
                    let n = state.detectedBytes.addingReportingOverflow(max(0,item.size))
                    state.detectedBytes = n.overflow ? Int64.max : n.partialValue
                } else if item.kind == "directory" { state.scannedDirectories += 1 }
                state.currentPath = mapping.rootID + " / " + item.relativePath
                report()
            }
            state.phase = "Analisi sorgente"; report(force:true)
            let source = try LocalScanner.scan(root:mapping.source,excludeManaged:true,
                shouldContinue:{ !cancellation.isCancelled },onItem:scanned)
            try mapping.verify()
            state.phase = "Analisi destinazione"; report(force:true)
            let target = try LocalScanner.scan(root:mapping.target,excludeManaged:true,
                shouldContinue:{ !cancellation.isCancelled },onItem:scanned)
            try mapping.verify()
            guard try Self.rootStamp(mapping.source) == sourceStamp,
                  try Self.rootStamp(mapping.target) == targetStamp else { throw MountedCopyError.volumeChanged }
            let paths = Set(source.map(\.relativePath)).union(target.map(\.relativePath))
            let grouped = Dictionary(grouping:paths,by:Self.fold)
            let ambiguous = Set(grouped.filter { $0.value.count > 1 }.keys)
            pairs.append(Pair(mapping:mapping,source:Dictionary(uniqueKeysWithValues:source.map{($0.relativePath,$0)}),
                target:Dictionary(uniqueKeysWithValues:target.map{($0.relativePath,$0)}),ambiguous:ambiguous,
                sourceStamp:sourceStamp,targetStamp:targetStamp))
            state.total += paths.count
        }
        var findings: [AuditFinding] = []
        var candidates: [(MountedFolderMapping, TrackedItem, String, SeedFileFingerprint?)] = []
        state.phase = mode == .deep ? "Verifica SHA-256" : "Confronto metadati"
        report(force:true)
        for pair in pairs {
            let mapping = pair.mapping
            for path in Set(pair.source.keys).union(pair.target.keys).sorted() {
                try check()
                state.currentPath = mapping.rootID + " / " + path
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
                    if collision || item.kind == "symlink" {
                        detail = "Percorso ambiguo, tipo incompatibile o collegamento simbolico"
                    } else if src == nil { kind = .extra }
                    else if dst == nil { kind = .missing }
                    else if item.kind == "directory" { kind = .matching }
                    else if src!.size != dst!.size { kind = .different; detail = "Dimensione diversa" }
                    else if mode == .quick {
                        // SMB timestamp precision varies. A tolerance of two
                        // seconds is deliberately metadata-only, not a hash.
                        kind = abs(src!.modifiedAt-dst!.modifiedAt) <= 2 ? .matching : .different
                        if kind == .different { detail = "Data di modifica diversa" }
                    } else {
                        let a = try Self.safeURL(path,mapping:mapping,destination:false)
                        let b = try Self.safeURL(path,mapping:mapping,destination:true)
                        let beforeA = try SeededArchiveVerifier.fingerprint(a)
                        let beforeB = try SeededArchiveVerifier.fingerprint(b)
                        guard beforeA.size == src!.size, beforeB.size == dst!.size,
                              abs(beforeA.modifiedAt-src!.modifiedAt) < 0.002,
                              abs(beforeB.modifiedAt-dst!.modifiedAt) < 0.002 else {
                            throw SeedVerificationError.changedDuringRead
                        }
                        func read(_ n: Int64) {
                            let sum = state.bytesRead.addingReportingOverflow(n)
                            state.bytesRead = sum.overflow ? Int64.max : sum.partialValue
                            report()
                        }
                        let h1 = try Self.hash(a,expected:beforeA,cancel:cancellation,read:read)
                        let h2 = try Self.hash(b,expected:beforeB,cancel:cancellation,read:read)
                        guard try SeededArchiveVerifier.fingerprint(a) == beforeA,
                              try SeededArchiveVerifier.fingerprint(b) == beforeB else {
                            throw SeedVerificationError.changedDuringRead
                        }
                        fingerprint = beforeA
                        kind = h1 == h2 ? .matching : .different
                        if kind == .different { detail = "Contenuto SHA-256 diverso" }
                        else { onVerifiedFile(mapping.rootID,path,beforeA,beforeB) }
                    }
                    if repair && (kind == .missing || kind == .different), let src {
                        let url = try Self.safeURL(path,mapping:mapping,destination:false)
                        if src.kind == "file" {
                            let fresh = try SeededArchiveVerifier.fingerprint(url)
                            guard fresh.size == src.size, abs(fresh.modifiedAt-src.modifiedAt)<0.002,
                                  fingerprint == nil || fingerprint == fresh else { throw SeedVerificationError.changedDuringRead }
                            fingerprint = fresh
                        } else { _ = try Self.rootStamp(url) }
                        candidates.append((mapping,src,pair.sourceStamp,fingerprint))
                    }
                } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
                catch { kind = .uncertain; detail = error.localizedDescription }
                findings.append(AuditFinding(rootID:mapping.rootID,relativePath:path,
                    sourceRoot:mapping.source.path,targetRoot:mapping.target.path,objectKind:item.kind,
                    bytes:item.size,kind:kind,detail:detail))
                state.compared += 1; report()
            }
            try mapping.verify()
            guard try Self.rootStamp(mapping.source) == pair.sourceStamp,
                  try Self.rootStamp(mapping.target) == pair.targetStamp else { throw MountedCopyError.volumeChanged }
        }
        try check()
        state.phase = "Finalizzazione"; report(force:true)
        var repairs: [(rootID:String, sourcePath:String, item:TrackedItem)] = []
        if repair {
            // Revalidate local candidates just before one atomic enqueuing.
            // No network copy occurs until the normal sync engine runs.
            for (map,item,stamp,fingerprint) in candidates {
                try check()
                guard try Self.rootStamp(map.source) == stamp else { throw MountedCopyError.sourceRootChanged }
                do {
                    let url = try Self.safeURL(item.relativePath,mapping:map,destination:false)
                    if let fingerprint {
                        guard try SeededArchiveVerifier.fingerprint(url) == fingerprint else { continue }
                    } else { _ = try Self.rootStamp(url) }
                    repairs.append((map.rootID,map.source.path,item))
                } catch { continue }
            }
        }
        try check()
        let queued = try journal.enqueueAuditRepairs(repairs, shouldContinue:{ !cancellation.isCancelled })
        report(force:true)
        return ArchiveAuditReport(mode:mode,started:state.started,ended:Date(),
            seconds:ProcessInfo.processInfo.systemUptime-startTick,findings:findings,
            bytesRead:state.bytesRead,queuedRepairs:queued,repairRequested:repair)
    }

    private static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    private static func rootStamp(_ url: URL) throws -> String {
        var st = stat()
        guard url.path.withCString({ lstat($0,&st) }) == 0,
              st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              url.resolvingSymlinksInPath().path == url.path else { throw MountedCopyError.rootUnavailable }
        return "\(st.st_dev):\(st.st_ino)"
    }
    private static func safeURL(_ path:String,mapping:MountedFolderMapping,destination:Bool) throws -> URL {
        let url = try mapping.fileURL(relativePath:path,destination:destination)
        guard url.resolvingSymlinksInPath().path == url.path else { throw SeedVerificationError.unsafeEntry }
        return url
    }
    private static func hash(_ url:URL,expected:SeedFileFingerprint,cancel:SeedVerificationCancellation,
                             read:(Int64)->Void) throws -> Data {
        let fd = url.path.withCString { Darwin.open($0,O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw SeedVerificationError.sourceMissing }
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
