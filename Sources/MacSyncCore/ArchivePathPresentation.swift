import Foundation
import Darwin

/// Presentation only. Never feed decorated text back to filesystem operations.
public struct ArchivePathPresentation: Equatable, Sendable {
    public enum Side: Sendable { case source, destination, unknown
        public var label: String {
            switch self { case .source: return "Sorgente"; case .destination: return "Destinazione"; case .unknown: return "Radice" }
        }
    }
    public enum Kind: Sendable { case file, directory, unknown
        public init(_ value: String) {
            switch value { case "file": self = .file; case "directory": self = .directory; default: self = .unknown }
        }
    }
    public let root: String
    public let relative: String
    public let side: Side
    public let kind: Kind
    public init(root: String, relative: String, side: Side, kind: Kind) {
        self.root=root; self.relative=relative; self.side=side; self.kind=kind
    }
    public static func displayComponent(_ name: String) -> String {
        let trailing=name.reversed().prefix{$0 == " " || $0 == "."}.count
        return String(name.dropLast(trailing))+name.suffix(trailing).map{$0 == " " ? "␠" : "."}.joined()
    }
    private var parts: [String] {
        relative.isEmpty ? [] : relative.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
    }
    public var folder: String {
        let components=kind == .directory ? parts : Array(parts.dropLast())
        return components.isEmpty ? "Radice" : components.map(Self.displayComponent).joined(separator:"/")+"/"
    }
    public var leaf: String? {
        guard kind != .directory else { return nil }
        return parts.last.map(Self.displayComponent)
    }
    public var leafLabel: String { kind == .file ? "File" : "Elemento" }
    public var rootDisplay: String { root.isEmpty ? "Non registrata" : root }
    public var lines: [String] {
        [side.label+": "+rootDisplay,"Cartella: "+folder] + (leaf.map{[leafLabel+": "+$0]} ?? [])
    }
    public var originalFullPath: String {
        guard !root.isEmpty else { return relative }
        return relative.isEmpty ? root : root+(root.hasSuffix("/") ? "" : "/")+relative
    }
}

/// Read-only navigation, invoked only on explicit user action. Never
/// interpret a missing name as deletion evidence or resolve a Windows alias.
public struct ArchiveRevealTarget: Equatable, Sendable {
    public let url: URL
    public let exact: Bool
    public let rootBinding: DirectoryBinding
    public static func resolve(_ path: ArchivePathPresentation, expectedVolume: VolumeFingerprint?) throws -> ArchiveRevealTarget {
        guard path.side != .unknown, path.root.hasPrefix("/"), !path.root.isEmpty,
              !path.root.contains("\0"), !path.relative.isEmpty else { throw MountedCopyError.invalidMapping }
        let components=path.relative.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw MountedCopyError.unsafeFile
        }
        let root=URL(fileURLWithPath:path.root,isDirectory:true).standardizedFileURL
        guard root.path == path.root, root.resolvingSymlinksInPath().path == root.path else { throw MountedCopyError.unsafeFile }
        let binding=try DirectoryBinding.read(root)
        if path.side == .destination {
            guard let expectedVolume,expectedVolume.isStrongIdentity,binding.volume==expectedVolume else { throw MountedCopyError.volumeChanged }
        } else {
            guard !binding.volume.isNetworkVolume else { throw MountedCopyError.volumeChanged }
        }
        var current=root
        func result(_ url: URL, exact: Bool) throws -> ArchiveRevealTarget {
            guard try DirectoryBinding.read(root)==binding,
                  try VolumeFingerprint.read(at:url)==binding.volume,
                  url.resolvingSymlinksInPath().path==url.path else { throw MountedCopyError.volumeChanged }
            return ArchiveRevealTarget(url:url,exact:exact,rootBinding:binding)
        }
        for (index,name) in components.enumerated() {
            let entries=try FileManager.default.contentsOfDirectory(atPath:current.path)
            let exactNames=entries.filter{Data($0.utf8)==Data(name.utf8)}
            guard exactNames.count<=1 else { throw MountedCopyError.unsafeFile }
            guard !exactNames.isEmpty else { return try result(current,exact:false) }
            let next=current.appendingPathComponent(name)
            var info=stat()
            guard next.path.withCString({lstat($0,&info)})==0 else { throw MountedCopyError.sourceMissing }
            let mode=info.st_mode & mode_t(S_IFMT)
            let last=index==components.count-1
            if !last || path.kind == .directory {
                guard mode==mode_t(S_IFDIR) else { throw MountedCopyError.unsafeFile }
            } else if path.kind == .file {
                guard mode==mode_t(S_IFREG) else { throw MountedCopyError.unsafeFile }
            } else {
                guard mode==mode_t(S_IFDIR) || mode==mode_t(S_IFREG) else { throw MountedCopyError.unsafeFile }
            }
            guard next.resolvingSymlinksInPath().path==next.path,
                  try VolumeFingerprint.read(at:next)==binding.volume else { throw MountedCopyError.volumeChanged }
            current=next
        }
        return try result(current,exact:true)
    }
}
