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
        public var skipped=0
        public var failed=0
        public var cancelled=false
        public var resolvedIDs:Set<String>=[]
    }

    /// A batch belongs only to configured, previously bound roots.
    /// Preflight captures each object identity, rejects competing proposed
    /// names, and processes descendants before parents. A collision never
    /// results in an alternative spelling or a replacement.
    public static func execute(items:[IncompatibleName], roots:[String:String],
                               journal:ChangeJournal,log:SyncActivityLog,
                               destinations: [String: MountedFolderMapping] = [:],
                               shouldContinue:()->Bool = {true}) throws -> Result {
        struct Move {
            let item:IncompatibleName
            let root:URL
            let binding:DirectoryBinding
            let url:URL
            let snapshot:stat
            let new:String
            var collisionKey:String { item.rootID+"\0"+url.deletingLastPathComponent().path+"\0"+WindowsPathSafety.comparisonFold(new) }
        }
        var result=Result(), moves:[Move]=[]
        var seen=Set<String>()
        func report(_ item:IncompatibleName,_ detail:String) throws {
            try log.record(level:.warning,rootID:item.rootID,action:"name_rectify_skipped",relativePath:SyncDiagnostic.clean(item.relativePath),message:detail)
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
        for item in items {
            guard shouldContinue() else { result.cancelled=true;return result }
            guard seen.insert(item.id).inserted else { continue }
            guard let name=proposedName(item.name) else {
                result.skipped+=1;try report(item,"Rettifica manuale necessaria o posizione non autorizzata");continue
            }
            do {
                let (root, binding) = try verifiedRoot(item)
                let url=try item.revealURL(expectedRoot:root.path)
                var value=stat()
                guard url.path.withCString({lstat($0,&value)})==0 else { throw MountedCopyError.sourceMissing }
                let expectedKind=mode_t(item.isDirectory ? S_IFDIR : S_IFREG)
                guard value.st_mode & mode_t(S_IFMT)==expectedKind else { throw MountedCopyError.unsafeFile }
                moves.append(Move(item:item,root:root,binding:binding,url:url,snapshot:value,new:name))
            } catch {
                result.skipped+=1
                try report(item,SyncDiagnostic.describe(error))
            }
        }
        // If a confirmed path occurs on two sides but one could not be
        // verified, leave its counterpart untouched as well.
        func pairedKey(_ row: IncompatibleName) -> String {
            row.rootID + "\0" + row.relativePath
        }
        let paired = Dictionary(grouping: items, by: pairedKey)
        let verified = Dictionary(grouping: moves, by: { pairedKey($0.item) })
        let counts=Dictionary(grouping:moves,by:\.collisionKey).mapValues{$0.count}
        moves.sort {
            let a=$0.item.relativePath.split(separator:"/").count,b=$1.item.relativePath.split(separator:"/").count
            if a != b { return a>b }
            return $0.item.id<$1.item.id
        }
        for move in moves {
            guard shouldContinue() else { result.cancelled=true;break }
            let key = pairedKey(move.item)
            if Set((paired[key] ?? []).map { $0.side.rawValue }).count > 1,
               verified[key]?.count != 2 {
                result.skipped += 1
                try report(move.item, "Controparte non verificata; rettifica coordinata rinviata")
                continue
            }
            if counts[move.collisionKey,default:0]>1 {
                result.skipped+=1;try report(move.item,"Conflitto fra nomi proposti; nessun elemento del gruppo modificato");continue
            }
            do {
                let (root, binding) = try verifiedRoot(move.item)
                guard root == move.root, binding == move.binding,
                      try move.item.revealURL(expectedRoot:move.root.path)==move.url else {
                    throw MountedCopyError.sourceRootChanged
                }
                let parent=try AnchoredDirectory(move.url.deletingLastPathComponent(),expectedVolume:move.binding.volume)
                let current=try parent.leaf(move.item.name)
                // Child renames may legitimately change the timestamps of a
                // parent directory. Pin its identity, but do not mistake
                // those changes for replacement. Files still require the
                // complete original metadata snapshot.
                guard current.st_dev==move.snapshot.st_dev,current.st_ino==move.snapshot.st_ino,
                      current.st_birthtimespec.tv_sec==move.snapshot.st_birthtimespec.tv_sec,
                      current.st_birthtimespec.tv_nsec==move.snapshot.st_birthtimespec.tv_nsec,
                      current.st_mode==move.snapshot.st_mode else { throw MountedCopyError.sourceChanging }
                if !move.item.isDirectory {
                    guard current.st_size==move.snapshot.st_size,
                          current.st_mtimespec.tv_sec==move.snapshot.st_mtimespec.tv_sec,
                          current.st_mtimespec.tv_nsec==move.snapshot.st_mtimespec.tv_nsec,
                          current.st_ctimespec.tv_sec==move.snapshot.st_ctimespec.tv_sec,
                          current.st_ctimespec.tv_nsec==move.snapshot.st_ctimespec.tv_nsec else { throw MountedCopyError.sourceChanging }
                }
                // Journal the intended name before the mutation; the normal
                // inventory restart reconciles even after an unexpected exit.
                try journal.invalidateNameScan(rootID: move.item.rootID, side: move.item.side)
                try log.record(level:.info,rootID:move.item.rootID,action:"name_rectify_start",relativePath:SyncDiagnostic.clean(move.item.relativePath),message:move.item.side.label + " · Nuovo nome: " + move.new)
                try parent.rectifyName(move.item.name,as:move.new,matching:current,shouldContinue:shouldContinue)
                result.renamed+=1;result.resolvedIDs.insert(move.item.id)
                try? log.record(level:.success,rootID:move.item.rootID,action:"name_rectified",relativePath:SyncDiagnostic.clean(move.item.relativePath),message:move.item.side.label + " · Rettificato in: " + move.new)
            } catch SeedVerificationError.cancelled {
                result.cancelled=true;break
            } catch MountedCopyError.destinationConflict {
                result.skipped+=1;try report(move.item,"Nome risultante già presente o equivalente; nessuna sovrascrittura")
            } catch {
                // Failure after the syscall can leave the outcome uncertain.
                // Do not retry, rollback or rename another path automatically.
                result.failed+=1;try report(move.item,SyncDiagnostic.describe(error))
                break
            }
        }
        return result
    }
}
