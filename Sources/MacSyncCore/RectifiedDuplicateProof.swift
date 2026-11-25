import Foundation
import Darwin
import CryptoKit

/// Exceptional duplicate cleanup, not general Windows path eligibility.
/// The proposed spelling is only a candidate; it never authorizes removal.
/// Require an exact old entry, distinct corrected entry and identical bytes
/// on source and both destination files. Only one repaired component per job.
struct RectifiedDuplicateProof {
    struct Candidate {
        let old:[String]
        let corrected:[String]
        let changed:Int
        var oldPath:String { old.joined(separator:"/") }
        var correctedPath:String { corrected.joined(separator:"/") }
    }
    static func candidate(_ path:String)->Candidate? {
        let old=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        var corrected=old
        var changed:Int?
        for (i,part) in old.enumerated() where !WindowsPathSafety.validComponent(part) {
            guard changed==nil, !part.isEmpty,
                  !part.unicodeScalars.contains(where:{$0.value<32 || "<>\"/\\|?*".unicodeScalars.contains($0)}),
                  let new=NameRectification.proposedName(part),
                  part.contains(":") || (part.hasSuffix(" ") && WindowsPathSafety.comparisonFold(part)==WindowsPathSafety.comparisonFold(new))
            else { return nil }
            corrected[i]=new;changed=i
        }
        guard let changed else { return nil }
        return Candidate(old:old,corrected:corrected,changed:changed)
    }
    struct Entry {
        let url:URL
        let info:stat
        var fingerprint:SeedFileFingerprint { .init(fileStat:info) }
        var directory:Bool { info.st_mode & mode_t(S_IFMT)==mode_t(S_IFDIR) }
        func sameIdentity(_ other:Entry)->Bool {
            info.st_dev==other.info.st_dev && info.st_ino==other.info.st_ino
        }
    }
    let candidate:Candidate
    let source:Entry
    let old:Entry
    let corrected:Entry

    private static func exact(_ root:URL,_ parts:[String],alternateAt:Int?=nil,alternate:String?=nil,
                              shouldContinue:()->Bool) throws -> Entry {
        var current=root
        for (index,part) in parts.enumerated() {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            let names=try FileManager.default.contentsOfDirectory(atPath:current.path)
            let aliases=names.filter{WindowsPathSafety.comparisonFold($0)==WindowsPathSafety.comparisonFold(part)}
            guard aliases.contains(where:{$0.utf8.elementsEqual(part.utf8)}),
                  aliases.allSatisfy({name in
                      name.utf8.elementsEqual(part.utf8) ||
                      (index==alternateAt && alternate.map{name.utf8.elementsEqual($0.utf8)}==true)
                  }) else { throw MirrorDeletionFailure.destinationChanged }
            current.appendPathComponent(part)
            var st=stat()
            guard current.path.withCString({lstat($0,&st)})==0 else { throw MirrorDeletionFailure.destinationChanged }
            let kind=st.st_mode & mode_t(S_IFMT)
            guard kind==mode_t(S_IFDIR) || (index==parts.count-1 && kind==mode_t(S_IFREG)) else {
                throw MirrorDeletionFailure.unsafePath
            }
            if index==parts.count-1 { return Entry(url:current,info:st) }
        }
        throw MirrorDeletionFailure.unsafePath
    }
    private static func absentOriginal(_ c:Candidate,mapping:MountedFolderMapping,
                                       shouldContinue:()->Bool) throws {
        let volume=try DirectoryBinding.read(mapping.source).volume
        guard ["apfs","hfs"].contains(volume.fileSystem.lowercased()) else { throw MirrorDeletionFailure.unsafePath }
        let prefix=Array(c.old.prefix(c.changed))
        let parent=prefix.isEmpty ? mapping.source : try exact(mapping.source,prefix,shouldContinue:shouldContinue).url
        let original=c.old[c.changed], replacement=c.corrected[c.changed]
        let names=try FileManager.default.contentsOfDirectory(atPath:parent.path)
        guard !names.contains(where:{$0.utf8.elementsEqual(original.utf8)}),
              names.contains(where:{$0.utf8.elementsEqual(replacement.utf8)}),
              names.filter({WindowsPathSafety.comparisonFold($0)==WindowsPathSafety.comparisonFold(original)})
                .allSatisfy({$0.utf8.elementsEqual(replacement.utf8)}) else { throw MirrorDeletionFailure.sourceChanged }
        var st=stat()
        let url=parent.appendingPathComponent(original)
        guard url.path.withCString({lstat($0,&st)}) != 0,errno==ENOENT else {
            throw MirrorDeletionFailure.sourceChanged
        }
    }
    private static func paths(_ c:Candidate,mapping:MountedFolderMapping,shouldContinue:()->Bool) throws -> (Entry,Entry,Entry) {
        try absentOriginal(c,mapping:mapping,shouldContinue:shouldContinue)
        let source=try exact(mapping.source,c.corrected,shouldContinue:shouldContinue)
        // Even if both names are returned by SMB, require distinct object
        // identities at the repaired component, not just at the final leaf.
        let oldPart=try exact(mapping.target,Array(c.old.prefix(c.changed+1)),
            alternateAt:c.changed,alternate:c.corrected[c.changed],shouldContinue:shouldContinue)
        let newPart=try exact(mapping.target,Array(c.corrected.prefix(c.changed+1)),
            alternateAt:c.changed,alternate:c.old[c.changed],shouldContinue:shouldContinue)
        guard !oldPart.sameIdentity(newPart),oldPart.info.st_ino != 0,newPart.info.st_ino != 0 else {
            throw MirrorDeletionFailure.destinationChanged
        }
        let old=try exact(mapping.target,c.old,alternateAt:c.changed,alternate:c.corrected[c.changed],shouldContinue:shouldContinue)
        let corrected=try exact(mapping.target,c.corrected,alternateAt:c.changed,alternate:c.old[c.changed],shouldContinue:shouldContinue)
        guard !old.sameIdentity(corrected),old.info.st_ino != 0,corrected.info.st_ino != 0,
              source.directory==old.directory,old.directory==corrected.directory else {
            throw MirrorDeletionFailure.destinationChanged
        }
        return (source,old,corrected)
    }
    private static func hash(_ entry:Entry,shouldContinue:()->Bool) throws -> Data {
        let fd=entry.url.path.withCString{Darwin.open($0,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)}
        guard fd>=0 else { throw MirrorDeletionFailure.destinationChanged }
        let reader=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? reader.close() }
        func verify() throws {
            var st=stat()
            guard fstat(fd,&st)==0,st.st_mode & mode_t(S_IFMT)==mode_t(S_IFREG),
                  SeedFileFingerprint(fileStat:st)==entry.fingerprint else { throw MirrorDeletionFailure.destinationChanged }
        }
        try verify()
        var digest=SHA256()
        while true {
            guard shouldContinue() else { throw SeedVerificationError.cancelled }
            guard let data=try reader.read(upToCount:1024*1024),!data.isEmpty else { break }
            digest.update(data:data)
        }
        try verify()
        return Data(digest.finalize())
    }
    static func prepare(_ c:Candidate,mapping:MountedFolderMapping,shouldContinue:()->Bool) throws -> Self {
        let (source,old,corrected)=try paths(c,mapping:mapping,shouldContinue:shouldContinue)
        if old.directory {
            guard try FileManager.default.contentsOfDirectory(atPath:old.url.path).isEmpty else {
                throw MirrorDeletionFailure.destinationChanged
            }
        } else {
            guard source.info.st_size==old.info.st_size,old.info.st_size==corrected.info.st_size else {
                throw MirrorDeletionFailure.duplicateNotVerified
            }
            let local=try hash(source,shouldContinue:shouldContinue)
            guard try hash(corrected,shouldContinue:shouldContinue)==local,
                  try hash(old,shouldContinue:shouldContinue)==local else { throw MirrorDeletionFailure.duplicateNotVerified }
        }
        let proof=Self(candidate:c,source:source,old:old,corrected:corrected)
        try proof.revalidate(mapping:mapping,shouldContinue:shouldContinue)
        return proof
    }
    func revalidate(mapping:MountedFolderMapping,shouldContinue:()->Bool) throws {
        let (s,o,n)=try Self.paths(candidate,mapping:mapping,shouldContinue:shouldContinue)
        guard s.fingerprint==source.fingerprint,o.fingerprint==old.fingerprint,n.fingerprint==corrected.fingerprint else {
            throw MirrorDeletionFailure.destinationChanged
        }
        if old.directory {
            guard try FileManager.default.contentsOfDirectory(atPath:o.url.path).isEmpty else {
                throw MirrorDeletionFailure.destinationChanged
            }
        }
    }
    func remove(mapping:MountedFolderMapping,shouldContinue:()->Bool) throws {
        try revalidate(mapping:mapping,shouldContinue:shouldContinue)
        let parent=try AnchoredDirectory(old.url.deletingLastPathComponent(),expectedVolume:mapping.targetVolume)
        try parent.remove(old.url.lastPathComponent,matching:old.info,directory:old.directory,shouldContinue:shouldContinue)
        // Do not infer absence from an inaccessible share. Confirm the old
        // spelling is no longer listed and the corrected object is unchanged.
        let names=try parent.listedNames()
        guard !names.contains(where:{$0.utf8.elementsEqual(old.url.lastPathComponent.utf8)}) else {
            throw MirrorDeletionFailure.destinationChanged
        }
        let n=try Self.exact(mapping.target,candidate.corrected,shouldContinue:shouldContinue)
        guard n.fingerprint==corrected.fingerprint else { throw MirrorDeletionFailure.destinationChanged }
    }
}
