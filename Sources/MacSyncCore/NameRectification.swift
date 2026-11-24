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

    private enum CoordinatedStage: String, Codable {
        case prepared, sourceAttempt, sourceDone, destinationAttempt, destinationDone, rollbackSource
    }

    private struct CoordinatedGroup: Codable {
        var moves: [Move]
        var stage: CoordinatedStage = .prepared
        var failure: String? = nil
        var source: Move? { moves.first { $0.item.side == .source } }
        var destination: Move? { moves.first { $0.item.side == .destination } }
    }

    private static func coordinatedGroups(journal:ChangeJournal) throws -> [CoordinatedGroup] {
        try journal.coordinatedNameGroups().map { row in
            let plan = try JSONDecoder().decode(CoordinatedGroup.self,from:row.data)
            guard !plan.moves.isEmpty, plan.moves.count<=2,
                  Set(plan.moves.map { $0.item.side }).count==plan.moves.count,
                  plan.moves.allSatisfy({ $0.item.rootID==row.rootID && $0.item.relativePath==row.path }) else {
                throw JournalError.database("Gruppo rettifica pendente non valido")
            }
            return plan
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
        var pendingMoves: [Move] = []
        if let batch = try journal.pendingNameRectification() {
            let moves = try JSONDecoder().decode([Move].self, from: batch.data)
            guard !moves.isEmpty, (0..<moves.count).contains(batch.offset) else {
                throw JournalError.database("Stato rettifiche pendenti non valido")
            }
            pendingMoves.append(contentsOf:moves.dropFirst(batch.offset))
        }
        pendingMoves.append(contentsOf:try coordinatedGroups(journal:journal).flatMap(\.moves))
        var relations: [PendingProtection.Relation] = []
        for move in pendingMoves {
            let item = move.item
            let parts = item.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !item.rootID.isEmpty, !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
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
                                      sourcePending:pending.relations.filter { $0.side == .source }.count,
                                      destinationPending:pending.relations.filter { $0.side == .destination }.count)
        }
        let records = try JSONDecoder().decode([NameRectificationProgressRecord].self, from: batch.progress)
        var completed = try journal.nameRectificationCompleted()
        // Accept historical in-JSON completions from an older candidate,
        // but never rewrite the complete array for each new successful move.
        for record in records {
            if record.sourceCompleted {
                completed.insert(record.rootID + "\0" + record.relativePath + "\0source")
            }
            if record.destinationCompleted {
                completed.insert(record.rootID + "\0" + record.relativePath + "\0destination")
            }
        }
        return PendingSideSummary(
            sourceCompleted: completed.filter { $0.hasSuffix("\0source") }.count,
            destinationCompleted: completed.filter { $0.hasSuffix("\0destination") }.count,
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
            case .mountUnavailable, .credentialUnavailable, .credentialLookupFailed, .credentialAmbiguous, .credentialReadFailed, .timedOut: return true
            case .helperFailed, .notAttempted: return false
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

    /// Original rows remain visible even after a partially successful rename.
    public static func pendingCoordinatedRows(journal:ChangeJournal) throws -> [IncompatibleName] {
        _ = try pendingProtection(journal:journal)
        return try coordinatedGroups(journal:journal).flatMap { plan in
            plan.moves.map { move in
                let row=move.item
                return IncompatibleName(rootID:row.rootID,rootPath:row.rootPath,
                    relativePath:row.relativePath,objectKind:row.objectKind,side:row.side,
                    reason:"Rettifica in sospeso · "+(plan.failure ?? "esito da confermare"),
                    affectedDescendants:row.affectedDescendants)
            }
        }
    }

    /// One exact relative path is a transaction-like maintenance unit.
    /// Two filesystems cannot commit atomically: persist every intent before
    /// mutating and compensate on the local Mac only after a definite failure.
    /// A lost remote result is never treated as proof of failure.
    public static func executeCoordinated(items:[IncompatibleName],roots:[String:String],
                                          journal:ChangeJournal,log:SyncActivityLog,
                                          destinations:[String:MountedFolderMapping],
                                          onProgress:(Int,Int)->Void = {_,_ in},
                                          beforeDestination:()->Void = {},
                                          shouldContinue:()->Bool = {true}) throws -> Result {
        var result=Result()
        func key(_ item:IncompatibleName)->String { item.rootID+"\0"+item.relativePath }
        func check() throws {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
        }
        func report(_ item:IncompatibleName,action:String,level:SyncLogLevel,detail:String) {
            try? log.record(level:level,rootID:item.rootID,action:action,
                relativePath:SyncDiagnostic.clean(item.relativePath),message:item.side.label+" · "+detail)
        }
        // Legacy plans cannot retroactively recover a snapshot of a side
        // already retired by the old engine. Preserve their original evidence
        // and permit explicit recovery without blocking new disjoint groups.
        if items.isEmpty, try journal.pendingNameRectification() != nil {
            result=try execute(items:[],roots:roots,journal:journal,log:log,
                destinations:destinations,onProgress:onProgress,shouldContinue:shouldContinue)
            if result.cancelled { return result }
        }
        _ = try pendingProtection(journal:journal)
        let stored=try coordinatedGroups(journal:journal)
        let existing=Dictionary(uniqueKeysWithValues:stored.map { (key($0.moves[0].item),$0) })
        let selected=Dictionary(grouping:items.filter { proposedName($0.name) != nil },by:key)
        let keys=items.isEmpty ? Array(existing.keys) : Array(selected.keys)
        // A many-to-one normalization is a genuine conflict, even when the
        // proposed spelling is still free. Do not choose an arbitrary winner.
        let proposals=Dictionary(grouping:selected.keys.compactMap { k -> (String,String)? in
            guard existing[k]==nil,let row=selected[k]?.first,
                  let proposed=proposedName(row.name) else { return nil }
            let parent=row.relativePath.split(separator:"/").dropLast().joined(separator:"/")
            return (k,row.rootID+"\0"+parent+"\0"+WindowsPathSafety.comparisonFold(proposed))
        },by:{$0.1})
        let colliding=Set(proposals.values.filter{$0.count>1}.flatMap{$0.map{$0.0}})
        func path(_ k:String)->String {
            existing[k]?.moves[0].item.relativePath ?? selected[k]?.first?.relativePath ?? ""
        }
        let ordered=keys.sorted {
            let a=path($0).split(separator:"/").count, b=path($1).split(separator:"/").count
            return a==b ? $0<$1 : a>b
        }

        func boundRoot(_ item:IncompatibleName) throws -> (URL,DirectoryBinding) {
            guard let map=destinations[item.rootID], roots[item.rootID]==map.source.path else {
                throw MountedCopyError.invalidMapping
            }
            try map.verify()
            let root=item.side == .source ? map.source : map.target
            guard root.path==item.rootPath else { throw MountedCopyError.invalidMapping }
            let binding = item.side == .source
                ? try journal.verifyLocalSourceBinding(rootID:item.rootID,root:root)
                : try journal.verifiedNameBinding(rootID:item.rootID,root:root,side:.destination)
            return (root,binding)
        }

        // An absent counterpart must be proven by an exact live enumeration,
        // not guessed from a stale name list. Alias and symlink paths fail closed.
        func locate(_ path:String,under root:URL) throws -> (URL,stat)? {
            var url=root
            let parts=path.split(separator:"/",omittingEmptySubsequences:false)
            guard !parts.isEmpty else { throw MountedCopyError.unsafeFile }
            for (index,component) in parts.enumerated() {
                try check()
                let name=String(component)
                guard !name.isEmpty,name != ".",name != "..",!name.contains("\0") else {
                    throw MountedCopyError.unsafeFile
                }
                let names=try FileManager.default.contentsOfDirectory(atPath:url.path)
                guard names.contains(where:{ $0.utf8.elementsEqual(name.utf8) }) else {
                    if names.contains(where:{ WindowsPathSafety.comparisonFold($0)==WindowsPathSafety.comparisonFold(name) }) {
                        throw NameRectificationCheckError.nameOccupied
                    }
                    return nil
                }
                url.appendPathComponent(name)
                var value=stat()
                guard url.path.withCString({lstat($0,&value)})==0 else {
                    throw NameRectificationCheckError.originalNotListed
                }
                let kind=value.st_mode & mode_t(S_IFMT)
                guard kind==mode_t(S_IFDIR) || (index==parts.count-1 && kind==mode_t(S_IFREG)) else {
                    throw MountedCopyError.unsafeFile
                }
                if index==parts.count-1 { return (url,value) }
            }
            throw MountedCopyError.unsafeFile
        }

        func makePlan(_ rows:[IncompatibleName]) throws -> CoordinatedGroup {
            guard let first=rows.first,let newName=proposedName(first.name),
                  let map=destinations[first.rootID] else { throw MountedCopyError.invalidMapping }
            let previous=try pendingProtection(journal:journal)
            let parent=first.relativePath.split(separator:"/").dropLast().joined(separator:"/")
            let newPath=parent.isEmpty ? newName : parent+"/"+newName
            guard !previous.protects(rootID:first.rootID,path:first.relativePath),
                  !previous.protects(rootID:first.rootID,path:newPath) else {
                throw NameRectificationCheckError.unresolvedState
            }
            var moves:[Move]=[]
            let listingCache=AuditDirectoryListingCache()
            for side in IncompatibleName.Side.allCases {
                let root=side == .source ? map.source : map.target
                let row=IncompatibleName(rootID:first.rootID,rootPath:root.path,
                    relativePath:first.relativePath,objectKind:first.objectKind,side:side,reason:first.reason,
                    affectedDescendants:first.affectedDescendants)
                let (_,binding)=try boundRoot(row)
                guard let (url,observed)=try locate(row.relativePath,under:root) else {
                    guard !rows.contains(where:{$0.side==side}),
                          try locate(newPath,under:root)==nil else {
                        throw NameRectificationCheckError.unresolvedState
                    }
                    continue
                }
                let directory=(observed.st_mode & mode_t(S_IFMT))==mode_t(S_IFDIR)
                guard directory==row.isDirectory else { throw MountedCopyError.unsafeFile }
                let anchored=try AnchoredDirectory(url.deletingLastPathComponent(),expectedVolume:binding.volume)
                let snapshot=side == .destination && binding.volume.fileSystem.lowercased()=="smbfs"
                    ? try stableSMBSnapshot(parent:anchored,oldName:row.name,shouldContinue:shouldContinue)
                    : try anchored.leaf(row.name)
                try anchored.checkRectification(old:row.name,new:newName,matching:snapshot,
                    preflightCache:listingCache)
                moves.append(Move(item:row,binding:binding,snapshot:snapshot,newName:newName))
            }
            guard !moves.isEmpty else { throw NameRectificationCheckError.originalNotListed }
            return CoordinatedGroup(moves:moves)
        }

        func persist(_ group:CoordinatedGroup) throws {
            let row=group.moves[0].item
            try journal.saveCoordinatedNameGroup(rootID:row.rootID,path:row.relativePath,
                data:JSONEncoder().encode(group))
        }
        func transition(_ group:inout CoordinatedGroup,_ stage:CoordinatedStage) throws {
            var next=group;next.stage=stage
            try persist(next);group=next
        }
        func parentFor(_ move:Move) throws -> AnchoredDirectory {
            let (root,binding)=try boundRoot(move.item)
            guard binding==move.binding else { throw MountedCopyError.volumeChanged }
            let url:URL
            if move.parentPath.isEmpty { url=root }
            else {
                let parentItem=IncompatibleName(rootID:move.item.rootID,rootPath:root.path,
                    relativePath:move.parentPath,objectKind:"directory",side:move.item.side,reason:"")
                url=try parentItem.revealURL(expectedRoot:root.path)
            }
            return try AnchoredDirectory(url,expectedVolume:binding.volume)
        }
        enum Location { case original, renamed }
        func observe(_ move:Move,parent:AnchoredDirectory) throws -> (Location,stat) {
            try parent.verify()
            let names=try parent.listedNames()
            let old=names.contains{$0.utf8.elementsEqual(move.item.name.utf8)}
            let new=names.contains{$0.utf8.elementsEqual(move.newName.utf8)}
            if old {
                let value=try parent.leaf(move.item.name)
                guard move.matches(value,renamed:true) else { throw NameRectificationCheckError.unresolvedState }
                return (.original,value)
            }
            if new {
                let value=try parent.leaf(move.newName)
                guard move.matches(value,renamed:true) else { throw NameRectificationCheckError.unresolvedState }
                if move.item.side == .destination && move.binding.volume.fileSystem.lowercased()=="smbfs" {
                    // Finder's directory cache is not authoritative. Require
                    // a separate server-side exact spelling and identity read.
                    try SMBNameRectification.rename(volume:move.binding.volume,parent:parent.directoryURL,
                        oldName:move.item.name,newName:move.newName,original:value,
                        verifyOnly:true,shouldContinue:shouldContinue)
                }
                return (.renamed,value)
            }
            throw NameRectificationCheckError.unresolvedState
        }
        func checkedOriginal(_ move:Move,parent:AnchoredDirectory) throws -> stat {
            let (whereNow,value)=try observe(move,parent:parent)
            guard whereNow == .original,move.matches(value,renamed:false) else {
                throw NameRectificationCheckError.unresolvedState
            }
            try parent.checkRectification(old:move.item.name,new:move.newName,matching:value)
            return value
        }
        func forward(_ move:Move,parent:AnchoredDirectory,snapshot:stat) throws {
            try check()
            let item=move.item
            report(item,action:"name_rectify_start",level:.info,detail:"Nuovo nome: "+move.newName)
            if item.side == .destination && move.binding.volume.fileSystem.lowercased()=="smbfs" {
                try SMBNameRectification.rename(volume:move.binding.volume,parent:parent.directoryURL,
                    oldName:item.name,newName:move.newName,original:snapshot,shouldContinue:shouldContinue)
                let deadline=ProcessInfo.processInfo.systemUptime+3.5
                while true {
                    try check()
                    if let observed=try? observe(move,parent:parent),observed.0 == .renamed { return }
                    guard ProcessInfo.processInfo.systemUptime<deadline else {
                        throw MountedCopyError.destinationChanging
                    }
                    Thread.sleep(forTimeInterval:0.125)
                }
            } else {
                try parent.rectifyName(item.name,as:move.newName,matching:snapshot,shouldContinue:shouldContinue)
                guard try observe(move,parent:parent).0 == .renamed else {
                    throw NameRectificationCheckError.unresolvedState
                }
            }
        }
        func knownNotAttempted(_ error:Error)->Bool {
            if let smb=error as? SMBNameRectificationError {
                switch smb {
                case .notAttempted,.credentialUnavailable,.credentialLookupFailed,.credentialAmbiguous,.credentialReadFailed,.mountUnavailable: return true
                case .helperFailed,.timedOut: return false
                }
            }
            if let copy=error as? MountedCopyError {
                switch copy {
                case .rcloneUnavailable,.rcloneLaunchFailed: return true
                default: return false
                }
            }
            return false
        }
        func failed(_ group:inout CoordinatedGroup,error:Error) throws {
            group.failure=SyncDiagnostic.describe(error)
            try persist(group)
        }
        func finish(_ group:CoordinatedGroup,successful:Bool,restoredSource:Move? = nil) throws {
            let row=group.moves[0].item
            try journal.finishCoordinatedNameGroup(rootID:row.rootID,path:row.relativePath,
                completed:successful ? group.moves.map { ($0.item,$0.newName) } : [],
                restoredSource:restoredSource.map { ($0.item,$0.newName,$0.binding.volume) })
            if successful {
                for move in group.moves {
                    result.renamed+=1
                    if move.item.side == .source { result.sourceRenamed+=1 }
                    else { result.destinationRenamed+=1 }
                    result.resolvedIDs.insert(move.item.id)
                    report(move.item,action:"name_rectified_"+move.item.side.rawValue,level:.success,
                        detail:"Rettificato in: "+move.newName)
                }
            } else {
                result.failed+=group.moves.count
                let reason=group.failure ?? "Rettifica non completata"
                if result.firstFailure==nil { result.firstFailure=reason }
                for move in group.moves {
                    report(move.item,action:"name_rectification_group_failed",level:.warning,detail:reason)
                }
            }
        }
        func rollback(_ group:inout CoordinatedGroup) throws {
            guard let source=group.source else { try finish(group,successful:false);return }
            if group.stage != .rollbackSource { try transition(&group,.rollbackSource) }
            try check()
            let parent=try parentFor(source)
            let (whereNow,snapshot)=try observe(source,parent:parent)
            if whereNow == .renamed {
                try parent.restoreRectifiedName(source.newName,originalName:source.item.name,
                    matching:snapshot,shouldContinue:shouldContinue)
            }
            guard try observe(source,parent:parent).0 == .original else {
                throw NameRectificationCheckError.unresolvedState
            }
            report(source.item,action:"name_rectification_rollback_source",level:.info,
                detail:"Nome originale ripristinato; nessuna sovrascrittura")
            try finish(group,successful:false,restoredSource:source)
        }
        func drive(_ group:inout CoordinatedGroup) throws {
            if group.stage == .rollbackSource { try rollback(&group);return }
            if group.stage == .prepared, let source=group.source {
                do {
                    let parent=try parentFor(source)
                    _ = try checkedOriginal(source,parent:parent)
                    if let target=group.destination, target.binding.volume.fileSystem.lowercased()=="smbfs" {
                        let remoteParent=try parentFor(target)
                        try SMBNameRectification.preflight(volume:target.binding.volume,parent:remoteParent.directoryURL)
                    }
                } catch SeedVerificationError.cancelled { throw SeedVerificationError.cancelled }
                catch { try failed(&group,error:error);try finish(group,successful:false);return }
                try transition(&group,.sourceAttempt)
            }
            if group.stage == .sourceAttempt,let source=group.source {
                let parent=try parentFor(source)
                let observed=try observe(source,parent:parent)
                if observed.0 == .original {
                    do {
                        let snapshot=try checkedOriginal(source,parent:parent)
                        if let target=group.destination, target.binding.volume.fileSystem.lowercased()=="smbfs" {
                            let remoteParent=try parentFor(target)
                            try SMBNameRectification.preflight(volume:target.binding.volume,parent:remoteParent.directoryURL)
                        }
                        try forward(source,parent:parent,snapshot:snapshot)
                    } catch {
                        try failed(&group,error:error)
                        // The remote side has never been attempted in this phase.
                        if let verified=try? observe(source,parent:parent) {
                            if verified.0 == .original { try finish(group,successful:false);return }
                            try rollback(&group);return
                        }
                        throw error
                    }
                }
                try transition(&group,.sourceDone)
            }
            if group.stage == .sourceDone,group.destination==nil {
                try finish(group,successful:true);return
            }
            if group.stage == .destinationAttempt,let target=group.destination {
                // Never reissue an SMB write whose previous result is unknown.
                // A visible, exact new name with the original identity is
                // sufficient for confirmation; absence of such evidence is not.
                let parent=try parentFor(target)
                let observed=try observe(target,parent:parent)
                if observed.0 == .renamed { try transition(&group,.destinationDone) }
                else if !target.binding.volume.isNetworkVolume {
                    try failed(&group,error:NameRectificationCheckError.unresolvedState)
                    try rollback(&group);return
                } else { throw NameRectificationCheckError.unresolvedState }
            }
            if (group.stage == .sourceDone || group.stage == .prepared),let target=group.destination {
                let parent:AnchoredDirectory
                let snapshot:stat
                do {
                    try check()
                    beforeDestination()
                    try check()
                    parent=try parentFor(target)
                    snapshot=try checkedOriginal(target,parent:parent)
                } catch {
                    try failed(&group,error:error)
                    try rollback(&group);return
                }
                try transition(&group,.destinationAttempt)
                do {
                    try forward(target,parent:parent,snapshot:snapshot)
                } catch {
                    try failed(&group,error:error)
                    if let observed=try? observe(target,parent:parent),observed.0 == .renamed {
                        try transition(&group,.destinationDone)
                    } else if knownNotAttempted(error) ||
                                (!target.binding.volume.isNetworkVolume &&
                                 (try? observe(target,parent:parent).0) == .original) {
                        try rollback(&group);return
                    } else { throw error }
                }
                if group.stage != .destinationDone { try transition(&group,.destinationDone) }
            }
            if group.stage == .destinationDone {
                for move in group.moves {
                    let parent=try parentFor(move)
                    guard try observe(move,parent:parent).0 == .renamed else {
                        throw NameRectificationCheckError.unresolvedState
                    }
                }
                try finish(group,successful:true)
            }
        }
        onProgress(0,ordered.count)
        for (index,k) in ordered.enumerated() {
            if !shouldContinue() { result.cancelled=true;break }
            defer { onProgress(index+1,ordered.count) }
            var group:CoordinatedGroup
            if let saved=existing[k] { group=saved }
            else {
                let rows=selected[k] ?? []
                if colliding.contains(k) {
                    result.skipped+=rows.count
                    let reason="Conflitto: più nomi selezionati producono lo stesso nome proposto"
                    if result.firstFailure==nil { result.firstFailure=reason }
                    for row in rows {
                        report(row,action:"name_rectify_skipped",level:.warning,detail:reason)
                    }
                    continue
                }
                do {
                    group=try makePlan(rows)
                    try persist(group)
                } catch SeedVerificationError.cancelled { result.cancelled=true;break }
                catch {
                    let reason=SyncDiagnostic.describe(error)
                    result.skipped+=rows.count
                    if result.firstFailure==nil { result.firstFailure=reason }
                    for row in rows {
                        report(row,action:"name_rectify_skipped",level:.warning,detail:reason)
                    }
                    continue
                }
            }
            do { try drive(&group) }
            catch SeedVerificationError.cancelled { result.cancelled=true;break }
            catch {
                let reason=SyncDiagnostic.describe(error)
                try failed(&group,error:error)
                result.failed+=group.moves.count
                if result.firstFailure==nil { result.firstFailure=reason }
                for move in group.moves {
                    report(move.item,action:"name_rectification_pending_"+move.item.side.rawValue,
                        level:.warning,detail:reason)
                }
            }
        }
        return result
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
                relativePath: SyncDiagnostic.clean(item.relativePath), message: item.side.label + " · " + message)
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
                        throw NameRectificationCheckError.unresolvedState
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
