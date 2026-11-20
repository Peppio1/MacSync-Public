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
        var moves: [Move] = []
        if let resume {
            guard items.isEmpty else { throw JournalError.database("Rettifica precedente in attesa") }
            moves = try JSONDecoder().decode([Move].self, from: resume.data)
        } else {
            var seen = Set<String>()
            let paired = Dictionary(grouping: items, by: counterpartKey)
            for item in items where seen.insert(item.id).inserted {
                guard shouldContinue() else { result.cancelled = true; return result }
                guard let name = proposedName(item.name) else { result.skipped += 1; continue }
                do {
                    let (root, binding) = try verifiedRoot(item)
                    let url = try item.revealURL(expectedRoot: root.path)
                    let parent = try AnchoredDirectory(url.deletingLastPathComponent(), expectedVolume: binding.volume)
                    let snapshot = try parent.leaf(item.name)
                    try parent.checkRectification(old: item.name, new: name, matching: snapshot)
                    moves.append(Move(item: item, binding: binding, snapshot: snapshot, newName: name))
                } catch {
                    result.skipped += 1
                    report(item, action: "name_rectify_skipped", level: .warning, message: SyncDiagnostic.describe(error))
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
            if !moves.isEmpty { try journal.saveNameRectification(JSONEncoder().encode(moves)) }
        }

        var deferred: [Move] = []
        let offset = resume?.offset ?? 0
        guard (0...moves.count).contains(offset) else { throw JournalError.database("Rettifica non leggibile") }
        onProgress(offset, moves.count)
        for (index, move) in moves.enumerated().dropFirst(offset) {
            guard shouldContinue() else { result.cancelled = true; break }
            defer { onProgress(index + 1, moves.count) }
            let item = move.item
            if deferred.contains(where: { pending in
                pending.item.rootID == item.rootID &&
                    (pending.item.relativePath == item.relativePath ||
                     pending.item.relativePath.hasPrefix(item.relativePath + "/"))
            }) {
                deferred.append(move)
                continue
            }
            do {
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
                let names = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
                let oldExists = names.contains { $0.utf8.elementsEqual(item.name.utf8) }
                let newExists = names.contains { $0.utf8.elementsEqual(move.newName.utf8) }
                if oldExists && !newExists {
                    let old = try parent.leaf(item.name)
                    guard move.matches(old, renamed: false) else { throw MountedCopyError.sourceChanging }
                    try journal.invalidateNameScan(rootID: item.rootID, side: item.side)
                    report(item, action: "name_rectify_start", level: .info,
                        message: item.side.label + " · Nuovo nome: " + move.newName)
                    if item.side == .destination && binding.volume.fileSystem.lowercased() == "smbfs" {
                        try parent.checkRectification(old: item.name, new: move.newName, matching: old)
                        try SMBNameRectification.rename(volume: binding.volume, parent: parentURL,
                            oldName: item.name, newName: move.newName, original: old, shouldContinue: shouldContinue)
                        try parent.verify()
                        let finalNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
                        guard !finalNames.contains(where: { $0.utf8.elementsEqual(item.name.utf8) }),
                              finalNames.contains(where: { $0.utf8.elementsEqual(move.newName.utf8) }),
                              move.matches(try parent.leaf(move.newName), renamed: true) else {
                            throw MountedCopyError.destinationChanging
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
                try journal.advanceNameRectification(to: index + 1, finished: index + 1 == moves.count && deferred.isEmpty,
                    rootID: item.side == .destination ? item.rootID : nil,
                    path: item.side == .destination ? path : nil, remainingPlan: remaining)
                result.renamed += 1
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
                deferred.append(move)
            }
        }
        return result
    }
}
