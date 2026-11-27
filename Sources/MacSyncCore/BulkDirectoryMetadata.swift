import Foundation
import MacSyncBulkMetadata

/// Experimental internal adapter; not connected to the operational audit.
/// The caller anchors and validates the directory. No mutation authority.
enum BulkDirectoryMetadata {
    struct Entry: Equatable, Sendable {
        let name: String
        let kind: String
        let device: UInt64
        let inode: UInt64
        let size: Int64?
        let mtimeSeconds: Int64
        let mtimeNanos: Int64
        let ctimeSeconds: Int64
        let ctimeNanos: Int64

        var fileFingerprint: SeedFileFingerprint? {
            guard kind == "file", let size else { return nil }
            return SeedFileFingerprint(device: device, inode: inode, size: size,
                mtimeSeconds: mtimeSeconds, mtimeNanos: mtimeNanos,
                ctimeSeconds: ctimeSeconds, ctimeNanos: ctimeNanos)
        }
    }
    enum Failure: Error, Equatable { case incomplete, filesystem(Int32) }
    private final class Collector {
        let active: () -> Bool
        let maximumEntries: Int
        var rows: [Entry] = []
        var names = Set<Data>()
        var invalid = false

        init(active: @escaping () -> Bool, maximumEntries: Int) {
            self.active = active
            self.maximumEntries = maximumEntries
        }
        func add(_ raw: ms_bulk_entry) -> Int32 {
            guard active() else { return 1 }
            guard rows.count < maximumEntries,
                  let pointer = raw.name, let name = String(validatingUTF8: pointer),
                  names.insert(Data(name.utf8)).inserted else {
                invalid = true; return 1
            }
            let kind: String
            switch raw.type {
            case 1: kind = "file"
            case 2: kind = "directory"
            case 5: kind = "symlink"
            default: invalid = true; return 1
            }
            rows.append(Entry(name: name, kind: kind, device: raw.device, inode: raw.inode,
                size: kind == "file" ? raw.size : nil,
                mtimeSeconds: raw.mtime_seconds, mtimeNanos: raw.mtime_nanos,
                ctimeSeconds: raw.ctime_seconds, ctimeNanos: raw.ctime_nanos))
            return 0
        }
    }
    /// No partial entries escape if a later record or kernel call fails.
    static func read(fd: Int32, maximumEntries: Int = 250_000,
                     shouldContinue: @escaping () -> Bool = { true }) throws -> BulkInventoryFallback.Attempt<[Entry]> {
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard maximumEntries > 0 else { throw Failure.incomplete }
        let collector = Collector(active: shouldContinue, maximumEntries: maximumEntries)
        let result = ms_bulk_read(fd, Unmanaged.passUnretained(collector).toOpaque()) { context, raw in
            guard let context, let raw else { return 1 }
            return Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue().add(raw.pointee)
        }
        guard shouldContinue() else { throw SeedVerificationError.cancelled }
        guard !collector.invalid else { throw Failure.incomplete }
        switch result {
        case 0: return .complete(collector.rows)
        case -1: return .unsupported
        case -2, -3: throw Failure.incomplete
        default: throw Failure.filesystem(result)
        }
    }
}
