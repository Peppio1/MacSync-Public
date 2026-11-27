import Foundation

/// Per-cycle hints only. A matching folded prefix is NOT absence evidence.
/// The shared journal verifier must prove both literal absences afresh.
/// Restrict to native target volumes: SMB can conceal an incompatible name.
/// Root-scoped hints never connect two independent source/target pairs.
final class PostMirrorAbsenceReconciliation {
    private let nativeMappings:[String:MountedFolderMapping]
    private var candidates:[Int64:QueuedChange]=[:]
    private var deferredIDs=Set<Int64>()
    private var removed:[String:Set<String>]=[:]

    init(mappings:[MountedFolderMapping],prior:[QueuedChange]) {
        nativeMappings=Dictionary(uniqueKeysWithValues:mappings.filter {
            ["apfs","hfs"].contains($0.targetVolume.fileSystem.lowercased())
        }.map { ($0.rootID,$0) })
        for job in prior { consider(job,deferred:false) }
    }

    private func consider(_ job:QueuedChange,deferred:Bool) {
        guard nativeMappings[job.rootID] != nil,job.kind == .delete,
              !WindowsPathSafety.validRelativePath(job.relativePath),
              WindowsPathSafety.validDeletionPath(job.relativePath) else { return }
        candidates[job.id]=job
        if deferred { deferredIDs.insert(job.id) }
    }

    private func folded(_ path:String)->String {
        path.split(separator:"/").map { WindowsPathSafety.comparisonFold(String($0)) }.joined(separator:"/")
    }

    func observe(_ kind:SyncEventKind,job:QueuedChange) {
        guard nativeMappings[job.rootID] != nil,job.kind == .delete else { return }
        switch kind {
        case .deferred: consider(job,deferred:true)
        case .deleted,.recovered,.directoryRemoved:
            removed[job.rootID,default:[]].insert(folded(job.relativePath))
        default: break
        }
    }

    private func wasAffected(_ job:QueuedChange)->Bool {
        guard let paths=removed[job.rootID] else { return false }
        var prefix=""
        for component in job.relativePath.split(separator:"/") {
            let part=WindowsPathSafety.comparisonFold(String(component))
            prefix=prefix.isEmpty ? part : prefix+"/"+part
            if paths.contains(prefix) { return true }
        }
        return false
    }

    /// Read only the affected queued paths, in bounded batches. The callback
    /// reports whether a committed acknowledgment was a deferred event in
    /// this cycle (as opposed to a preflight candidate outside mirror consent).
    func reconcile(journal:ChangeJournal,throughID:Int64,
                   onAcknowledged:(QueuedChange,Bool)->Void,
                   shouldContinue:()->Bool) throws {
        let eligible=candidates.values.filter { $0.id<=throughID && wasAffected($0) }
        let groups=Dictionary(grouping:eligible,by: { $0.rootID })
        for rootID in groups.keys.sorted() {
            guard let map=nativeMappings[rootID],let jobs=groups[rootID] else { continue }
            let sorted=jobs.sorted { a,b in
                if a.relativePath.utf8.count == b.relativePath.utf8.count { return a.id<b.id }
                return a.relativePath.utf8.count<b.relativePath.utf8.count
            }
            for start in stride(from:0,to:sorted.count,by:1000) {
                guard shouldContinue(),try journal.queueRebuildToken()==nil,
                      try journal.mirrorBlockReason()==nil,
                      try journal.pendingUploads(limit:1).isEmpty else { return }
                let page=Array(sorted[start..<min(start+1000,sorted.count)])
                var committed:[QueuedChange]=[]
                _=try journal.acknowledgeAbsentAuditDeletes(page,mappings:[map],
                    onAcknowledged:{ committed.append($0) },shouldContinue:shouldContinue)
                for job in committed { onAcknowledged(job,deferredIDs.contains(job.id)) }
            }
        }
    }
}
