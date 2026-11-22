import Foundation
import Darwin

/// Read-only maintenance data. A row is never permission to rename or delete.
public struct IncompatibleName: Identifiable, Equatable, Codable, Sendable {
    public enum Side: String, CaseIterable, Codable, Sendable {
        case source, destination
        public var label: String { self == .source ? "Sorgente" : "Destinazione" }
    }
    public let rootID: String
    public let rootPath: String
    public let relativePath: String
    public let objectKind: String
    public let side: Side
    public let reason: String
    public var affectedDescendants: Int
    public var id: String { side.rawValue + "\0" + rootID + "\0" + relativePath }
    public var name: String { relativePath.split(separator:"/").last.map(String.init) ?? relativePath }
    public var isDirectory: Bool { objectKind == "directory" }
    public var displayName: String {
        let trailing=name.reversed().prefix{$0 == " "}.count
        return String(name.dropLast(trailing))+String(repeating:"␠",count:trailing)
    }
    public init(rootID:String,rootPath:String,relativePath:String,objectKind:String,side:Side,reason:String,affectedDescendants:Int=0) {
        self.rootID=rootID; self.rootPath=rootPath; self.relativePath=relativePath
        self.objectKind=objectKind; self.side=side; self.reason=reason
        self.affectedDescendants=affectedDescendants
    }
    public static func reason(forComponent name:String) -> String? {
        guard !WindowsPathSafety.validComponent(name) else { return nil }
        if name.hasSuffix(" ") { return "Spazio finale" }
        if name.hasSuffix(".") { return "Punto finale" }
        if name.utf16.count > 255 { return "Nome troppo lungo" }
        if name.lowercased().hasPrefix(".macsync-") { return "Nome tecnico riservato" }
        if name.unicodeScalars.contains(where:{$0.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains($0)}) {
            return "Carattere incompatibile con Windows"
        }
        return "Nome riservato o non valido in Windows"
    }
    /// Report each offending leaf once, not every descendant of an invalid parent.
    /// Counts include nested objects; they are informational, not queue counts.
    public static func collect(rootID:String,rootPath:String,side:Side,items:[TrackedItem],conflicts:Set<String> = []) -> [IncompatibleName] {
        (try? collect(rootID: rootID, rootPath: rootPath, side: side, items: items,
            conflicts: conflicts, shouldContinue: { true })) ?? []
    }

    static func collect(rootID: String, rootPath: String, side: Side, items: [TrackedItem],
                        conflicts: Set<String> = [], shouldContinue: () -> Bool) throws -> [IncompatibleName] {
        func check() throws {
            if !shouldContinue() { throw SeedVerificationError.cancelled }
        }
        var result:[String:IncompatibleName]=[:]
        var byFold:[String:[TrackedItem]]=[:]
        for item in items where item.kind == "file" || item.kind == "directory" {
            try check()
            let parts=item.relativePath.split(separator:"/",omittingEmptySubsequences:false)
            guard let leaf=parts.last else { continue }
            // Fold only the final component, not its ancestors: alias
            // parents do not independently invalidate every child name.
            let parent=parts.dropLast().joined(separator:"/")
            let key=parent+"\0"+WindowsPathSafety.comparisonFold(String(leaf))
            byFold[key,default:[]].append(item)
        }
        for group in byFold.values {
            for item in group {
                try check()
                guard let leaf=item.relativePath.split(separator:"/").last.map(String.init) else { continue }
                let conflict=group.count>1 || conflicts.contains(item.relativePath)
                guard let reason=reason(forComponent:leaf) ?? (conflict ? "Conflitto fra nomi equivalenti in Windows" : nil) else { continue }
                result[item.relativePath]=IncompatibleName(rootID:rootID,rootPath:rootPath,relativePath:item.relativePath,objectKind:item.kind,side:side,reason:reason)
            }
        }
        guard result.values.contains(where: \.isDirectory) else { return sortedRows(result) }
        for item in items {
            try check()
            let parts=item.relativePath.split(separator:"/")
            if parts.count>1 {
                for n in 1..<parts.count {
                    let ancestor=parts.prefix(n).joined(separator:"/")
                    if result[ancestor]?.isDirectory == true { result[ancestor]?.affectedDescendants += 1 }
                }
            }
        }
        return sortedRows(result)
    }

    private static func sortedRows(_ rows: [String: IncompatibleName]) -> [IncompatibleName] {
        rows.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }
    /// The destination inventory is historical. It is never scanned on a UI timer.
    public static func destinationRows(report:ArchiveAuditReport,rootID:String,rootPath:String) -> [IncompatibleName] {
        let items=report.findings.compactMap { finding -> TrackedItem? in
            guard finding.rootID==rootID, finding.targetRoot==rootPath,
                finding.targetBytes != nil || finding.kind == .extra || finding.kind == .matching || finding.kind == .different
            else { return nil }
            return TrackedItem(relativePath:finding.relativePath,kind:finding.targetObjectKind ?? finding.objectKind,size:finding.targetBytes ?? 0,modifiedAt:finding.targetModifiedAt ?? 0)
        }
        let conflicts=Set(report.findings.filter{$0.rootID==rootID && $0.targetRoot==rootPath && $0.directNameConflict == true}.map(\.relativePath))
        return collect(rootID:rootID,rootPath:rootPath,side:.destination,items:items,conflicts:conflicts)
    }
    /// Read-only exact-spelling traversal. Never follow symlinks or select an
    /// alias, even on a case-insensitive filesystem. No shell or rename calls.
    public func revealURL(expectedRoot:String) throws -> URL {
        guard rootPath==expectedRoot, !rootPath.isEmpty else { throw MountedCopyError.invalidMapping }
        var url=URL(fileURLWithPath:rootPath,isDirectory:true).standardizedFileURL
        guard url.resolvingSymlinksInPath().path==url.path else { throw MountedCopyError.unsafeFile }
        let parts=relativePath.split(separator:"/",omittingEmptySubsequences:false)
        guard !parts.isEmpty else { throw MountedCopyError.unsafeFile }
        for (index,part) in parts.enumerated() {
            let name=String(part)
            guard !name.isEmpty,name != ".",name != "..",!name.contains("\0") else { throw MountedCopyError.unsafeFile }
            let children=try FileManager.default.contentsOfDirectory(atPath:url.path)
            guard children.contains(where:{Array($0.utf8)==Array(name.utf8)}) else { throw MountedCopyError.sourceMissing }
            url.appendPathComponent(name)
            var s=stat()
            guard url.path.withCString({lstat($0,&s)})==0 else { throw MountedCopyError.sourceMissing }
            let kind=s.st_mode & mode_t(S_IFMT)
            guard kind == ((index < parts.count-1 || isDirectory) ? mode_t(S_IFDIR) : mode_t(S_IFREG)) else { throw MountedCopyError.unsafeFile }
        }
        return url
    }
}

public struct NameScanSnapshot: Codable, Equatable, Sendable {
    public let rootID: String
    public let side: IncompatibleName.Side
    public let rootPath: String
    public let volume: VolumeFingerprint?
    public let date: Date
    public let rows: [IncompatibleName]

    public init(rootID: String, side: IncompatibleName.Side, rootPath: String,
                volume: VolumeFingerprint?, date: Date, rows: [IncompatibleName]) {
        self.rootID = rootID
        self.side = side
        self.rootPath = rootPath
        self.volume = volume
        self.date = date
        self.rows = rows
    }

    public static func scan(rootID: String, side: IncompatibleName.Side, root: URL,
                            volume: VolumeFingerprint?, shouldContinue: () -> Bool,
                            onProgress: (Int, String) -> Void = { _, _ in }) throws -> Self {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        let path = root.standardizedFileURL
        let resolved = path.resolvingSymlinksInPath()
        guard side == .source || (path == resolved && volume?.isStrongIdentity == true) else {
            throw MountedCopyError.invalidMapping
        }
        let binding = try DirectoryBinding.read(resolved)
        if side == .destination {
            guard binding.volume == volume else { throw MountedCopyError.volumeChanged }
        } else {
            guard !binding.volume.isNetworkVolume else { throw MountedCopyError.unsafeFile }
        }
        var count = 0
        let items = try LocalScanner.scan(root: resolved, excludeManaged: true,
            preferPOSIXMetadata: side == .destination, shouldContinue: shouldContinue,
            onItem: { item in
                count += 1
                onProgress(count, item.relativePath)
            })
        onProgress(count, "")
        let rows = try IncompatibleName.collect(
            rootID: rootID, rootPath: resolved.path, side: side, items: items,
            shouldContinue: shouldContinue)
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard try DirectoryBinding.read(resolved) == binding else { throw MountedCopyError.volumeChanged }
        return Self(rootID: rootID, side: side, rootPath: resolved.path, volume: volume, date: Date(), rows: rows)
    }
}


/// Display-only paging and filtering for large incompatible-name inventories.
/// The result is never permission to rename or delete. The full scan stays
/// outside SwiftUI's main actor and is cancellable when filters change.
public struct IncompatibleNameListPage: Sendable {
    public let rows: [IncompatibleName]
    public let total: Int
    public let sourceFolders: Int
    public let sourceFiles: Int
    public let destinationFolders: Int
    public let destinationFiles: Int
    public let selectableIDs: [String]

    public init(rows: [IncompatibleName], total: Int,
                sourceFolders: Int, sourceFiles: Int,
                destinationFolders: Int, destinationFiles: Int,
                selectableIDs: [String]) {
        self.rows = rows
        self.total = total
        self.sourceFolders = sourceFolders
        self.sourceFiles = sourceFiles
        self.destinationFolders = destinationFolders
        self.destinationFiles = destinationFiles
        self.selectableIDs = selectableIDs
    }
}

public enum IncompatibleNameListing {
    /// Preserves the original case-insensitive search semantics and order.
    /// Count all matches while returning only one bounded page of rows.
    public static func page(items: [IncompatibleName], side: String,
                            directories: Bool, search: String, offset: Int,
                            limit: Int = 200,
                            shouldContinue: () -> Bool = { true }) -> IncompatibleNameListPage? {
        let start = max(0, offset)
        let size = max(1, min(500, limit))
        var rows: [IncompatibleName] = []
        rows.reserveCapacity(size)
        var matches = 0
        var selectableIDs: [String] = []
        var sourceFolders = 0, sourceFiles = 0
        var destinationFolders = 0, destinationFiles = 0
        for (index, item) in items.enumerated() {
            if index % 128 == 0 && !shouldContinue() { return nil }
            if NameRectification.proposedName(item.name) != nil { selectableIDs.append(item.id) }
            if item.side == .source {
                if item.isDirectory { sourceFolders += 1 } else { sourceFiles += 1 }
            } else {
                if item.isDirectory { destinationFolders += 1 } else { destinationFiles += 1 }
            }
            guard (side == "all" || item.side.rawValue == side),
                  item.isDirectory == directories,
                  (search.isEmpty ||
                   item.relativePath.localizedCaseInsensitiveContains(search) ||
                   item.rootPath.localizedCaseInsensitiveContains(search) ||
                   item.reason.localizedCaseInsensitiveContains(search)) else { continue }
            if matches >= start && rows.count < size { rows.append(item) }
            matches += 1
        }
        guard shouldContinue() else { return nil }
        return IncompatibleNameListPage(rows: rows, total: matches,
            sourceFolders: sourceFolders, sourceFiles: sourceFiles,
            destinationFolders: destinationFolders, destinationFiles: destinationFiles,
            selectableIDs: selectableIDs)
    }
}
