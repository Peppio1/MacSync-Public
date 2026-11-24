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
        // Remove spaces from the trailing Windows-incompatible suffix and
        // preserve every trailing dot as a hyphen. Keep the previous refusal
        // of empty, reserved-device and managed names after trimming.
        var trailingDots = 0
        while result.hasSuffix(" ") || result.hasSuffix(".") {
            if result.hasSuffix(".") { trailingDots += 1 }
            result.removeLast()
        }
        guard WindowsPathSafety.validComponent(result) else { return nil }
        result += String(repeating: "-", count: trailingDots)
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
        // Optional for compatibility with already persisted v0.19.0 plans.
        let unilateral: Bool?

        init(item: IncompatibleName, binding: DirectoryBinding, snapshot: stat, newName: String, unilateral: Bool = false) {
            self.unilateral = unilateral
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

    /// Combine current local inventory with unresolved local durable plans.
    /// The latter may already have changed their on-disk spelling before a
    /// crash; do not hide them merely because the incompatible leaf vanished.
    public static func localMaintenanceRows(_ rows:[IncompatibleName],journal:ChangeJournal) throws -> [IncompatibleName] {
        var byID=Dictionary(uniqueKeysWithValues:rows.filter{$0.side == .source}.map{($0.id,$0)})
        for row in try pendingCoordinatedRows(journal:journal) where row.side == .source {
            byID[row.id]=row
        }
        return byID.values.sorted{$0.id<$1.id}
    }

    /// Rectify only local source names. Persist each local intent before
    /// the exclusive rename; retain uncertain states for explicit recovery.
    /// No destination mapping, credentials or remote execution is accepted.
    public static func executeLocal(items:[IncompatibleName],roots:[String:String],
                                    journal:ChangeJournal,log:SyncActivityLog,
                                    onProgress:(Int,Int)->Void = {_,_ in},
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
        guard !items.isEmpty,items.allSatisfy({$0.side == .source}) else {
            throw MountedCopyError.invalidMapping
        }
        // Legacy remote plans are read-only protection. Do not resume them
        // using this engine, even if the original local side is selected.
        _ = try pendingProtection(journal:journal)
        let stored=try coordinatedGroups(journal:journal)
        let existing=Dictionary(uniqueKeysWithValues:stored.map { (key($0.moves[0].item),$0) })
        result.skipped=items.filter { proposedName($0.name) == nil }.count
        let selected=Dictionary(grouping:items.filter { proposedName($0.name) != nil },by:key)
        let keys=Array(selected.keys)
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
            guard item.side == .source,let configured=roots[item.rootID],configured==item.rootPath else {
                throw MountedCopyError.invalidMapping
            }
            let root=URL(fileURLWithPath:configured,isDirectory:true)
            let binding=try journal.verifyLocalSourceBinding(rootID:item.rootID,root:root)
            guard !binding.volume.isNetworkVolume else { throw MountedCopyError.invalidMapping }
            return (root,binding)
        }

        // Exact live path enumeration: aliases and symlinks fail closed.
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
            guard let first=rows.first,let newName=proposedName(first.name) else { throw MountedCopyError.invalidMapping }
            let previous=try pendingProtection(journal:journal)
            let parent=first.relativePath.split(separator:"/").dropLast().joined(separator:"/")
            let newPath=parent.isEmpty ? newName : parent+"/"+newName
            guard !previous.protects(rootID:first.rootID,path:first.relativePath),
                  !previous.protects(rootID:first.rootID,path:newPath) else {
                throw NameRectificationCheckError.unresolvedState
            }
            let (root,binding)=try boundRoot(first)
            guard let (url,observed)=try locate(first.relativePath,under:root) else {
                throw NameRectificationCheckError.originalNotListed
            }
            guard (observed.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR))==first.isDirectory else {
                throw MountedCopyError.unsafeFile
            }
            let anchored=try AnchoredDirectory(url.deletingLastPathComponent(),expectedVolume:binding.volume)
            let snapshot=try anchored.leaf(first.name)
            try anchored.checkRectification(old:first.name,new:newName,matching:snapshot)
            return CoordinatedGroup(moves:[Move(item:first,binding:binding,snapshot:snapshot,newName:newName,unilateral:true)])
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
            guard !(old && new) else { throw NameRectificationCheckError.unresolvedState }
            if old {
                let value=try parent.leaf(move.item.name)
                guard move.matches(value,renamed:true) else { throw NameRectificationCheckError.unresolvedState }
                return (.original,value)
            }
            if new {
                let value=try parent.leaf(move.newName)
                guard move.matches(value,renamed:true) else { throw NameRectificationCheckError.unresolvedState }
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
            try parent.rectifyName(item.name,as:move.newName,matching:snapshot,shouldContinue:shouldContinue)
            guard try observe(move,parent:parent).0 == .renamed else {
                throw NameRectificationCheckError.unresolvedState
            }
        }
        func failed(_ group:inout CoordinatedGroup,error:Error) throws {
            group.failure=SyncDiagnostic.describe(error)
            try persist(group)
        }
        func finish(_ group:CoordinatedGroup,successful:Bool,restoredSource:Move? = nil) throws {
            let row=group.moves[0].item
            try journal.finishCoordinatedNameGroup(rootID:row.rootID,path:row.relativePath,
                completed:successful ? group.moves.map { ($0.item,$0.newName) } : [],
                restoredSource:restoredSource.map { ($0.item,$0.newName,$0.binding.volume) },
                recordReconciliationScope:false)
            if successful {
                for move in group.moves {
                    result.renamed+=1
                    result.sourceRenamed+=1
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
            try check()
            guard group.moves.count==1,group.source != nil,group.destination==nil,
                  group.moves[0].unilateral == true else { throw MountedCopyError.invalidMapping }
            if group.stage == .rollbackSource { try rollback(&group);return }
            if group.stage == .prepared, let source=group.source {
                do {
                    let parent=try parentFor(source)
                    _ = try checkedOriginal(source,parent:parent)
                    
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
                        
                        try forward(source,parent:parent,snapshot:snapshot)
                    } catch {
                        try failed(&group,error:error)
                        // Only the exact original local identity may be restored.
                        if let verified=try? observe(source,parent:parent) {
                            if verified.0 == .original { try finish(group,successful:false);return }
                            try rollback(&group);return
                        }
                        throw error
                    }
                }
                try transition(&group,.sourceDone)
            }
            if group.stage == .sourceDone,group.destination==nil, let source=group.source {
                guard try observe(source,parent:parentFor(source)).0 == .renamed else {
                    throw NameRectificationCheckError.unresolvedState
                }
                try finish(group,successful:true);return
            }
            throw NameRectificationCheckError.unresolvedState
        }
        onProgress(0,ordered.count)
        for (index,k) in ordered.enumerated() {
            if !shouldContinue() { result.cancelled=true;break }
            defer { onProgress(index+1,ordered.count) }
            var group:CoordinatedGroup
            if let saved=existing[k] {
                if !(saved.moves.count == 1 && saved.moves[0].item.side == .source && saved.moves[0].unilateral == true) ||
                    saved.stage == .destinationAttempt || saved.stage == .destinationDone {
                    result.skipped += selected[k]?.count ?? 1
                    let reason="Piano precedente non compatibile: percorso protetto; verificare prima del reset volontario"
                    if result.firstFailure == nil { result.firstFailure=reason }
                    for row in selected[k] ?? [] { report(row,action:"name_rectify_skipped",level:.warning,detail:reason) }
                    continue
                }
                group=saved
            }
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

}
