import Foundation
import Darwin

/// Experimental local-only name history. No queue or remote authority.
/// Persist only under the verified source and target bindings, in the same
/// transaction as inventory observations. Absence of history is UNKNOWN.
enum SourceNameLineage {
    struct Identity: Codable, Hashable, Sendable {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanos: Int64
        let kind: String

        /// No extra stat is needed when the scanner already has this value.
        /// Hard-linked regular files are not uniquely identifiable by inode.
        init?(stat value: stat) {
            let mode = value.st_mode & mode_t(S_IFMT)
            guard value.st_ino != 0, value.st_birthtimespec.tv_sec > 0 else { return nil }
            if mode == mode_t(S_IFREG) {
                guard value.st_nlink == 1 else { return nil }
                kind = "file"
            } else if mode == mode_t(S_IFDIR) {
                kind = "directory"
            } else { return nil }
            device = UInt64(bitPattern: Int64(value.st_dev))
            inode = UInt64(value.st_ino)
            birthSeconds = Int64(value.st_birthtimespec.tv_sec)
            birthNanos = Int64(value.st_birthtimespec.tv_nsec)
        }
    }

    /// The caller must independently prove a successful publication/audit
    /// on the same mapping. Unknown is never inferred to mean never copied.
    enum Evidence: String, Codable, Sendable {
        case unknown, neverPublished, recognized
    }

    struct Record: Codable, Equatable, Sendable {
        let identity: Identity
        let sourceBinding: String
        let targetBinding: String
        let rootID: String
        private(set) var currentPath: String
        private(set) var evidence: Evidence
        /// Keep EVERY positively recognized compatible path until an
        /// authorized deletion or verified absence is committed.
        private(set) var recognizedPaths: [String]
        private(set) var uncertainPublication: Bool

        init(identity: Identity, rootID: String, sourceBinding: String,
             targetBinding: String, path: String, provenNew: Bool = false) {
            self.identity = identity
            self.rootID = rootID
            self.sourceBinding = sourceBinding
            self.targetBinding = targetBinding
            currentPath = path
            evidence = provenNew ? .neverPublished : .unknown
            recognizedPaths = []
            uncertainPublication = false
        }

        /// A failed, cancelled or interrupted copy can have published bytes.
        mutating func publicationStarted() {
            uncertainPublication = true
            if evidence == .neverPublished { evidence = .unknown }
        }

        /// Call only after a separately verified successful transfer or
        /// accepted archive match on the exact current path.
        mutating func recognize(path: String) {
            guard WindowsPathSafety.validRelativePath(path),
                  path.utf8.elementsEqual(currentPath.utf8) else { return }
            if !recognizedPaths.contains(where: { $0.utf8.elementsEqual(path.utf8) }) {
                recognizedPaths.append(path)
            }
            evidence = .recognized
            // Do not clear uncertainty here: an earlier publication may
            // have left a different path behind.
        }

        /// No deletion is authorized by this method. A caller may use the
        /// candidates only after copy success + normal mirror validation.
        mutating func observe(identity observed: Identity, path: String,
                              rootID: String, sourceBinding: String, targetBinding: String,
                              uniqueObservation: Bool) -> Decision {
            guard uniqueObservation, identity == observed,
                  self.rootID == rootID, self.sourceBinding == sourceBinding,
                  self.targetBinding == targetBinding else {
                return .unresolved
            }
            let previous = currentPath
            currentPath = path
            guard WindowsPathSafety.validRelativePath(path) else {
                return Decision(upload: nil, protectedPaths: recognizedPaths,
                    deletionCandidates: [], suppressPreviousDelete: false,
                    uncertain: evidence == .unknown || uncertainPublication)
            }
            let sameRecognized = recognizedPaths.contains { $0.utf8.elementsEqual(path.utf8) }
            // Fold-equivalent paths are not safe separate deletion targets.
            let folded = WindowsPathSafety.comparisonFold(path)
            let obsolete = recognizedPaths.filter {
                !$0.utf8.elementsEqual(path.utf8) &&
                WindowsPathSafety.comparisonFold($0) != folded
            }
            let alias = recognizedPaths.contains {
                !$0.utf8.elementsEqual(path.utf8) &&
                WindowsPathSafety.comparisonFold($0) == folded
            }
            let previousInvalid = !WindowsPathSafety.validRelativePath(previous)
            let canSuppress = previousInvalid && evidence == .neverPublished &&
                !uncertainPublication
            // A recognized compatible path is a candidate for revalidation,
            // not an unconditional skip of a copy if content has changed.
            return Decision(upload: sameRecognized ? .revalidate(path) : .copy(path),
                protectedPaths: recognizedPaths, deletionCandidates: obsolete,
                suppressPreviousDelete: canSuppress,
                uncertain: evidence == .unknown || uncertainPublication || alias)
        }
    }

    enum Upload: Equatable, Sendable { case copy(String), revalidate(String) }
    struct Decision: Equatable, Sendable {
        let upload: Upload?
        let protectedPaths: [String]
        let deletionCandidates: [String]
        let suppressPreviousDelete: Bool
        let uncertain: Bool
        static let unresolved = Decision(upload: nil, protectedPaths: [],
            deletionCandidates: [], suppressPreviousDelete: false, uncertain: true)
    }
}
