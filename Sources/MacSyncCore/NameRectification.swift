import Foundation
import Darwin

/// The only automatic transformation authorized by the name maintenance UI.
/// No inferred suffixes, truncation, or conversion of reserved device names.
public enum NameRectification {
    public static func proposedName(_ name:String) -> String? {
        guard !WindowsPathSafety.validComponent(name), !name.isEmpty,
              name != ".",name != "..",!name.lowercased().hasPrefix(".macsync-") else { return nil }
        var result=""
        for scalar in name.unicodeScalars {
            if scalar.value<32 || "<>:\"/\\|?*".unicodeScalars.contains(scalar) {
                result += "-"
            } else { result.unicodeScalars.append(scalar) }
        }
        while result.hasSuffix(" ") || result.hasSuffix(".") { result.removeLast() }
        guard WindowsPathSafety.validComponent(result),result != name else { return nil }
        return result
    }

    public struct Result: Sendable {
        public var renamed=0
        public var sourceRenamed=0
        public var destinationRenamed=0
        public var skipped=0
        public var failed=0
        public var firstFailure: String?
        public var cancelled=false
        public var resolvedIDs:Set<String>=[]
    }

    private struct Move: Codable {
        let item: IncompatibleName
        let binding: DirectoryBinding
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanos: Int64
        let ctimeSeconds: Int64
        let ctimeNanos: Int64
        let mode: UInt16
        let newName: String

        init(item: IncompatibleName, binding: DirectoryBinding, snapshot: stat, newName: String) {
            self.item = item
            self.binding = binding
            self.inode = UInt64(snapshot.st_ino)
            self.birthSeconds = Int64(snapshot.st_birthtimespec.tv_sec)
            self.birthNanos = Int64(snapshot.st_birthtimespec.tv_nsec)
            self.size = Int64(snapshot.st_size)
            self.mtimeSeconds = Int64(snapshot.st_mtimespec.tv_sec)
            self.mtimeNanos = Int64(snapshot.st_mtimespec.tv_nsec)
            self.ctimeSeconds = Int64(snapshot.st_ctimespec.tv_sec)
            self.ctimeNanos = Int64(snapshot.st_ctimespec.tv_nsec)
            self.mode = UInt16(snapshot.st_mode)
            self.newName = newName
        }

        func matches(_ snapshot: stat, renamed: Bool) -> Bool {
            guard self.inode == UInt64(snapshot.st_ino), self.mode == UInt16(snapshot.st_mode),
                  self.birthSeconds == Int64(snapshot.st_birthtimespec.tv_sec),
                  self.birthNanos == Int64(snapshot.st_birthtimespec.tv_nsec) else { return false }
            return item.isDirectory || (
                self.size == Int64(snapshot.st_size) &&
                self.mtimeSeconds == Int64(snapshot.st_mtimespec.tv_sec) &&
                self.mtimeNanos == Int64(snapshot.st_mtimespec.tv_nsec) &&
                (renamed || (self.ctimeSeconds == Int64(snapshot.st_ctimespec.tv_sec) &&
                             self.ctimeNanos == Int64(snapshot.st_ctimespec.tv_nsec)))
            )
        }

        var parentPath: String {
            item.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        }

        var collisionKey: String {
            item.rootID + "\0" + item.side.rawValue + "\0" + parentPath + "\0" + WindowsPathSafety.comparisonFold(newName)
        }
    }

    /// Read-only projection of the existing durable name_rectification_batch.
    /// No second registry, no content reads and no authorization to rename.
    /// Both names and every descendant of a pending directory are protected,
    /// even if only one side of the logical rename has been completed.
    public struct PendingProtection: Sendable {
        public struct Relation: Sendable {
            public let rootID: String
            public let oldPath: String
            public let newPath: String
            public let isDirectory: Bool
            public let side: IncompatibleName.Side
        }
        public let relations: [Relation]
        private let scopesByRoot: [String: Set<String>]
        private let ancestorsByRoot: [String: Set<String>]
        private let exactRelations: [String: Relation]
        public var isEmpty: Bool { relations.isEmpty }

        private static func folded(_ path: String) -> String {
            path.split(separator: "/", omittingEmptySubsequences: false)
                .map { WindowsPathSafety.comparisonFold(String($0)) }.joined(separator: "/")
        }

        /// One-time O(plan size × depth) preparation. Audit and sync may
        /// inspect hundreds of thousands of paths: never linearly scan the
        /// persisted rename plan for each file or directory.
        init(relations: [Relation]) {
            self.relations = relations
            var scopes: [String: Set<String>] = [:]
            var ancestors: [String: Set<String>] = [:]
            var exact: [String: Relation] = [:]
            for relation in relations {
                for raw in [relation.oldPath, relation.newPath] {
                    let key = Self.folded(raw)
                    scopes[relation.rootID, default: []].insert(key)
                    exact[relation.rootID + "\0" + key] = relation
                    let parts = key.split(separator: "/")
                    if parts.count > 1 {
                        for depth in 1..<parts.count {
                            ancestors[relation.rootID, default: []].insert(
                                parts.prefix(depth).joined(separator: "/"))
                        }
                    }
                }
            }
            scopesByRoot = scopes
            ancestorsByRoot = ancestors
            exactRelations = exact
        }

        /// Protect the old/new leaf, descendants of pending directory renames
        /// and ancestors whose mutation might invalidate the pending plan.
        /// Unrelated sibling paths never pay a remote metadata or SHA read.
        public func protects(rootID: String, path: String) -> Bool {
            guard !path.isEmpty, let scopes = scopesByRoot[rootID] else { return false }
            let key = Self.folded(path)
            if scopes.contains(key) || ancestorsByRoot[rootID]?.contains(key) == true {
                return true
            }
            let parts = key.split(separator: "/")
            guard parts.count > 1 else { return false }
            for depth in 1..<parts.count where scopes.contains(parts.prefix(depth).joined(separator: "/")) {
                return true
            }
            return false
        }

        public func exactRelation(rootID: String, path: String) -> Relation? {
            exactRelations[rootID + "\0" + Self.folded(path)]
        }
    }

    /// Decoding failure is a global database-integrity fault: never downgrade
    /// a missing/invalid plan into "no protection".
    public static func pendingProtection(journal: ChangeJournal) throws -> PendingProtection {
        guard let batch = try journal.pendingNameRectification() else {
            return PendingProtection(relations: [])
        }
        let moves = try JSONDecoder().decode([Move].self, from: batch.data)
        guard !moves.isEmpty, (0..<moves.count).contains(batch.offset) else {
            throw JournalError.database("Stato rettifiche pendenti non valido")
        }
        var relations: [PendingProtection.Relation] = []
        for move in moves.dropFirst(batch.offset) {
            let item = move.item
            let parts = item.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.rootID.isEmpty, !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }),
                  item.name == parts.last.map(String.init),
                  WindowsPathSafety.validComponent(move.newName),
                  proposedName(item.name) == move.newName else {
                throw JournalError.database("Percorso rettifica pendente non valido")
            }
            let newPath = move.parentPath.isEmpty ? move.newName : move.parentPath + "/" + move.newName
            relations.append(.init(rootID: item.rootID, oldPath: item.relativePath,
                                   newPath: newPath, isDirectory: item.isDirectory, side: item.side))
        }
        return PendingProtection(relations: relations)
    }

    public struct PendingSideSummary: Sendable {
        public let sourceCompleted: Int
        public let destinationCompleted: Int
        public let sourcePending: Int
        public let destinationPending: Int
    }

    /// The progress JSON resides in the SAME SQLite batch as the approved
    /// moves. It is committed atomically with every completed rename; after
    /// interruption, do not infer a completed side from equal filenames.
    public static func pendingSideSummary(journal: ChangeJournal) throws -> PendingSideSummary {
        let pending = try pendingProtection(journal: journal)
        guard let batch = try journal.pendingNameRectification() else {
            return PendingSideSummary(sourceCompleted: 0, destinationCompleted: 0,
                                      sourcePending: 0, destinationPending: 0)
        }
        let records = try JSONDecoder().decode([NameRectificationProgressRecord].self, from: batch.progress)
        return PendingSideSummary(
            sourceCompleted: records.filter(\.sourceCompleted).count,
            destinationCompleted: records.filter(\.destinationCompleted).count,
            sourcePending: pending.relations.filter { $0.side == .source }.count,
            destinationPending: pending.relations.filter { $0.side == .destination }.count)
    }

    /// SMB metadata from a just-closed Finder write can still be cached.
    /// Capture the persistent plan only after a fresh file has had time to
    /// settle. This is read-only: no timestamp is synthesized and no
    /// mismatch is tolerated. Older files pay no additional delay.
    static func stableSMBSnapshot(parent: AnchoredDirectory, oldName: String,
                                  shouldContinue: () -> Bool) throws -> stat {
        let initial = try parent.leaf(oldName)
        guard (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return initial }
        func modifiedAt(_ value: stat) -> Double {
            Double(value.st_mtimespec.tv_sec) +
                Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
        }
        // Old, already-settled files are never delayed. For a recent file,
        // require an exact pair of snapshots once its last modification is
        // at least four seconds old. The five-second total cap also prevents
        // an actively modified file from delaying the entire batch.
        let initialAge = Date().timeIntervalSince1970 - modifiedAt(initial)
        guard initialAge >= 0 && initialAge < 4 else { return initial }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var candidate = initial
        while true {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MountedCopyError.sourceChanging
            }
            if Date().timeIntervalSince1970 - modifiedAt(candidate) >= 4 {
                let a = try parent.leaf(oldName)
                Thread.sleep(forTimeInterval: 0.125)
                guard shouldContinue() else { throw SeedVerificationError.cancelled }
                let b = try parent.leaf(oldName)
                let unchanged = a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
                    a.st_birthtimespec.tv_sec == b.st_birthtimespec.tv_sec &&
                    a.st_birthtimespec.tv_nsec == b.st_birthtimespec.tv_nsec &&
                    a.st_size == b.st_size &&
                    a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
                    a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
                    a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
                    a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
                if unchanged && Date().timeIntervalSince1970 - modifiedAt(b) >= 4 { return b }
                candidate = b
            } else {
                Thread.sleep(forTimeInterval: 0.125)
                candidate = try parent.leaf(oldName)
            }
        }
    }

    /// A shared destination outage must not trigger an SMB helper invocation
    /// for every remaining file in the same batch. Only infrastructure
    /// failures qualify: a file-specific collision, stale fingerprint or
    /// ambiguous helper response remains isolated to that file.
    static func isSharedDestinationFailure(_ error: Error) -> Bool {
        if let smb = error as? SMBNameRectificationError {
            switch smb {
            case .mountUnavailable, .credentialUnavailable, .timedOut: return true
            case .helperFailed: return false
            }
        }
        if let copy = error as? MountedCopyError {
            switch copy {
            case .invalidMapping, .rootUnavailable, .volumeChanged, .rcloneUnavailable,
                 .rcloneLaunchFailed: return true
            default: return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return [Int(ENOTCONN), Int(ETIMEDOUT), Int(ENETDOWN),
                    Int(ENETUNREACH), Int(EHOSTDOWN), Int(EHOSTUNREACH)].contains(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isSharedDestinationFailure(underlying)
        }
        return false
    }

    /// A confirmed batch persists before its first mutation. Resume checks
    /// exact paths and identities again, including after a lost SMB response.
    public static func execute(items: [IncompatibleName], roots: [String: String],
                               journal: ChangeJournal, log: SyncActivityLog,
                               destinations: [String: MountedFolderMapping] = [:],
                               onProgress: (Int, Int) -> Void = { _, _ in },
                               shouldContinue: () -> Bool = { true }) throws -> Result {
        var result = Result()
        func report(_ item: IncompatibleName, action: String, level: SyncLogLevel, message: String) {
            try? log.record(level: level, rootID: item.rootID, action: action,
                relativePath: SyncDiagnostic.clean(item.relativePath), message: message)
        }
        func verifiedRoot(_ item: IncompatibleName) throws -> (URL, DirectoryBinding) {
            if item.side == .source {
                guard let path = roots[item.rootID] else { throw MountedCopyError.invalidMapping }
                let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                return (root, try journal.verifyLocalSourceBinding(rootID: item.rootID, root: root))
            }
            guard let mapping = destinations[item.rootID], mapping.targetVolume.isStrongIdentity else {
                throw MountedCopyError.invalidMapping
            }
            try mapping.verify()
            return (mapping.target, try journal.verifiedNameBinding(rootID: item.rootID, root: mapping.target, side: .destination))
        }
        func counterpartKey(_ item: IncompatibleName) -> String { item.rootID + "\0" + item.relativePath }
        let resume = try journal.pendingNameRectification()
        // Reused only for the non-mutating preflight. Every actual rename
        // retains a fresh directory listing and the exclusive syscall.
        let preflightListingCache = AuditDirectoryListingCache()
        func slowPhase(_ item: IncompatibleName, name: String, started: Double) {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard elapsed >= 0.5 else { return }
            try? log.record(level: .info, rootID: item.rootID, action: "metric_name_rectification_phase",
                relativePath: SyncDiagnostic.clean(item.relativePath), durationSeconds: elapsed,
                message: item.side.label + " · " + name)
        }
        var moves: [Move] = []
        if let resume {
            guard items.isEmpty else { throw JournalError.database("Rettifica precedente in attesa") }
            moves = try JSONDecoder().decode([Move].self, from: resume.data)
        } else {
            var seen = Set<String>()
            var unavailablePreflightDestinations = Set<String>()
            let paired = Dictionary(grouping: items, by: counterpartKey)
            for item in items where seen.insert(item.id).inserted {
                guard shouldContinue() else { result.cancelled = true; return result }
                guard let name = proposedName(item.name) else { result.skipped += 1; continue }
                if item.side == .destination && unavailablePreflightDestinations.contains(item.rootID) {
                    // No safe fingerprint can be persisted for an unseen file.
                    // The operator can scan again once the volume is back.
                    result.failed += 1
                    report(item, action: "name_rectification_preflight_destination_deferred",
                        level: .warning, message: "Destinazione non disponibile: verifica da ripetere")
                    continue
                }
                let preflightStarted = ProcessInfo.processInfo.systemUptime
                do {
                    defer { slowPhase(item, name: "preflight", started: preflightStarted) }
                    let (root, binding) = try verifiedRoot(item)
                    let url = try item.revealURL(expectedRoot: root.path)
                    let parent = try AnchoredDirectory(url.deletingLastPathComponent(), expectedVolume: binding.volume)
                    let snapshot = item.side == .destination &&
                        binding.volume.fileSystem.lowercased() == "smbfs"
                        ? try stableSMBSnapshot(parent: parent, oldName: item.name,
                            shouldContinue: shouldContinue)
                        : try parent.leaf(item.name)
                    try parent.checkRectification(old: item.name, new: name, matching: snapshot,
                        preflightCache: preflightListingCache)
                    moves.append(Move(item: item, binding: binding, snapshot: snapshot, newName: name))
                } catch SeedVerificationError.cancelled {
                    result.cancelled = true
                    return result
                } catch {
                    let reason = SyncDiagnostic.describe(error)
                    if item.side == .destination && isSharedDestinationFailure(error) {
                        unavailablePreflightDestinations.insert(item.rootID)
                        result.failed += 1
                        if result.firstFailure == nil { result.firstFailure = item.side.label + " · " + reason }
                        report(item, action: "name_rectification_preflight_destination_unavailable",
                            level: .warning, message: reason)
                    } else {
                        result.skipped += 1
                        report(item, action: "name_rectify_skipped", level: .warning, message: reason)
                    }
                }
            }
            let collisions = Dictionary(grouping: moves, by: \.collisionKey).mapValues(\.count)
            let verified = Dictionary(grouping: moves.filter { collisions[$0.collisionKey] == 1 }, by: { counterpartKey($0.item) })
            moves = moves.filter { move in
                let key = counterpartKey(move.item)
                let bothSides = Set((paired[key] ?? []).map { $0.side.rawValue }).count == 2
                guard collisions[move.collisionKey] == 1, !bothSides || verified[key]?.count == 2 else {
                    result.skipped += 1
                    report(move.item, action: "name_rectify_skipped", level: .warning, message: "Conflitto o controparte non verificata")
                    return false
                }
                return true
            }
            moves.sort {
                let a = $0.item.relativePath.split(separator: "/").count
                let b = $1.item.relativePath.split(separator: "/").count
                return a == b ? $0.item.id < $1.item.id : a > b
            }
            if !moves.isEmpty {
                let grouped = Dictionary(grouping: moves, by: { counterpartKey($0.item) })
                let progress = grouped.values.compactMap { group -> NameRectificationProgressRecord? in
                    guard let first = group.first else { return nil }
                    return .init(rootID: first.item.rootID, relativePath: first.item.relativePath,
                        sourceRequired: group.contains { $0.item.side == .source },
                        destinationRequired: group.contains { $0.item.side == .destination },
                        sourceCompleted: false, destinationCompleted: false)
                }
                try journal.saveNameRectification(JSONEncoder().encode(moves), progress: progress)
            }
        }

        var deferred: [Move] = []
        // Index only *actual* path dependencies on the same side. A failed
        // SMB destination must not suppress the source operation at the same
        // path; the persisted unfinished batch still blocks ordinary sync.
        var blockedAncestors = Set<String>()
        // Per-execution circuit breaker. Pending moves stay in the durable
        // plan and can be retried explicitly after the destination recovers.
        // It never clears the journal or authorizes an ordinary sync.
        var unavailableDestinationRoots = Set<String>()
        func blockKey(_ item: IncompatibleName, path: String) -> String {
            item.rootID + "\0" + item.side.rawValue + "\0" + path
        }
        func deferMove(_ move: Move) {
            deferred.append(move)
            var prefix = ""
            for segment in move.item.relativePath.split(separator: "/") {
                prefix = prefix.isEmpty ? String(segment) : prefix + "/" + segment
                blockedAncestors.insert(blockKey(move.item, path: prefix))
            }
        }
        let offset = resume?.offset ?? 0
        guard (0...moves.count).contains(offset) else { throw JournalError.database("Rettifica non leggibile") }
        onProgress(offset, moves.count)
        for (index, move) in moves.enumerated().dropFirst(offset) {
            guard shouldContinue() else { result.cancelled = true; break }
            defer { onProgress(index + 1, moves.count) }
            let item = move.item
            if blockedAncestors.contains(blockKey(item, path: item.relativePath)) {
                deferMove(move)
                continue
            }
            if item.side == .destination && unavailableDestinationRoots.contains(item.rootID) {
                // The first shared failure has already been reported. Avoid
                // repeated SMB calls/timeouts while preserving each move in
                // SQLite for a later operator-approved resume.
                result.failed += 1
                report(item, action: "name_rectification_shared_destination_deferred",
                    level: .warning, message: "Destinazione non disponibile: rettifica conservata nel lotto")
                deferMove(move)
                continue
            }
            let executionStarted = ProcessInfo.processInfo.systemUptime
            do {
                defer { slowPhase(item, name: "execute-total", started: executionStarted) }
                let (root, binding) = try verifiedRoot(item)
                guard root.path == item.rootPath, binding == move.binding else { throw MountedCopyError.volumeChanged }
                let parentURL: URL
                if move.parentPath.isEmpty {
                    parentURL = root
                } else {
                    let parentItem = IncompatibleName(rootID: item.rootID, rootPath: item.rootPath,
                        relativePath: move.parentPath, objectKind: "directory", side: item.side, reason: "")
                    parentURL = try parentItem.revealURL(expectedRoot: root.path)
                }
                let parent = try AnchoredDirectory(parentURL, expectedVolume: binding.volume)
                let listingStarted = ProcessInfo.processInfo.systemUptime
                let names = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
                slowPhase(item, name: "live-directory-listing", started: listingStarted)
                let oldExists = names.contains { $0.utf8.elementsEqual(item.name.utf8) }
                let newExists = names.contains { $0.utf8.elementsEqual(move.newName.utf8) }
                if oldExists && !newExists {
                    let old = try parent.leaf(item.name)
                    guard move.matches(old, renamed: false) else { throw MountedCopyError.sourceChanging }
                    try journal.invalidateNameScan(rootID: item.rootID, side: item.side)
                    report(item, action: "name_rectify_start", level: .info,
                        message: item.side.label + " · Nuovo nome: " + move.newName)
                    let renameStarted = ProcessInfo.processInfo.systemUptime
                    defer { slowPhase(item, name: item.side == .destination &&
                        binding.volume.fileSystem.lowercased() == "smbfs" ? "smb-helper-and-verify" : "local-rename-and-verify",
                        started: renameStarted) }
                    if item.side == .destination && binding.volume.fileSystem.lowercased() == "smbfs" {
                        try parent.checkRectification(old: item.name, new: move.newName, matching: old)
                        try SMBNameRectification.rename(volume: binding.volume, parent: parentURL,
                            oldName: item.name, newName: move.newName, original: old, shouldContinue: shouldContinue)
                        // A direct SMB rename can be committed server-side
                        // before Finder's smbfs directory cache reflects it.
                        // Never issue another rename after helper success:
                        // wait read-only for the exact old/new names and
                        // original file identity to become visible locally.
                        let visibilityDeadline = ProcessInfo.processInfo.systemUptime + 3.5
                        while true {
                            guard shouldContinue() else { throw SeedVerificationError.cancelled }
                            try parent.verify()
                            let finalNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
                            let oldVisible = finalNames.contains { $0.utf8.elementsEqual(item.name.utf8) }
                            let newVisible = finalNames.contains { $0.utf8.elementsEqual(move.newName.utf8) }
                            if !oldVisible && newVisible {
                                guard move.matches(try parent.leaf(move.newName), renamed: true) else {
                                    throw MountedCopyError.destinationChanging
                                }
                                break
                            }
                            guard ProcessInfo.processInfo.systemUptime < visibilityDeadline else {
                                // The remote result was positive, but local
                                // visibility is still uncertain. Preserve the
                                // journal plan for recovery; never re-copy or
                                // delete the old path to force convergence.
                                throw MountedCopyError.destinationChanging
                            }
                            Thread.sleep(forTimeInterval: 0.125)
                        }
                    } else {
                        try parent.rectifyName(item.name, as: move.newName, matching: old, shouldContinue: shouldContinue)
                    }
                } else {
                    guard !oldExists, newExists, move.matches(try parent.leaf(move.newName), renamed: true) else {
                        throw MountedCopyError.destinationConflict
                    }
                }
                let path = move.parentPath.isEmpty ? move.newName : move.parentPath + "/" + move.newName
                // An unresolved move must keep its old path and its position
                // ahead of any dependent rename when the batch is reopened.
                let remaining = deferred.isEmpty ? nil
                    : try JSONEncoder().encode(deferred + Array(moves.dropFirst(index + 1)))
                let journalStarted = ProcessInfo.processInfo.systemUptime
                try journal.advanceNameRectification(to: index + 1, finished: index + 1 == moves.count && deferred.isEmpty,
                    rootID: item.side == .destination ? item.rootID : nil,
                    path: item.side == .destination ? path : nil, remainingPlan: remaining,
                    completed: (rootID: item.rootID, path: item.relativePath, side: item.side.rawValue))
                slowPhase(item, name: "sqlite-commit", started: journalStarted)
                result.renamed += 1
                if item.side == .source { result.sourceRenamed += 1 }
                else { result.destinationRenamed += 1 }
                result.resolvedIDs.insert(item.id)
                let action = resume == nil ? "name_rectified_" : "name_rectification_resumed_"
                report(item, action: action + item.side.rawValue, level: .success, message: item.side.label + " · Rettificato in: " + move.newName)
            } catch SeedVerificationError.cancelled {
                result.cancelled = true
                break
            } catch {
                result.failed += 1
                let reason = SyncDiagnostic.describe(error)
                if result.firstFailure == nil { result.firstFailure = item.side.label + " · " + reason }
                report(item, action: "name_rectification_pending_" + item.side.rawValue, level: .warning, message: reason)
                if item.side == .destination && isSharedDestinationFailure(error) {
                    unavailableDestinationRoots.insert(item.rootID)
                }
                deferMove(move)
            }
        }
        return result
    }
}
