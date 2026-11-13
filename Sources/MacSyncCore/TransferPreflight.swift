import Foundation
import Darwin

/// A conservative preflight for file transfers to local or Finder-mounted SMB
/// destinations. This is advisory because free space may change during a copy;
/// it never reserves space, and no other files are deleted to make room.
public enum TransferPreflight {
    public static func availableBytes(onVolumeContaining destination: URL) throws -> Int64? {
        var fs = statfs()
        guard destination.path.withCString({ statfs($0, &fs) }) == 0 else {
            throw MountedCopyError.rootUnavailable
        }
        // Some mounted filesystems don't report capacity at all. Treat that
        // situation as unknown; avoid pretending they have zero free space.
        guard fs.f_blocks > 0, fs.f_bsize > 0 else { return nil }
        let available = UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
        return Int64(min(available, UInt64(Int64.max)))
    }

    /// The server needs space for the new staged file, for any safety copy of
    /// the previous target and for small metadata/temporary overhead.
    public static func requiredBytes(
        incomingSize: Int64,
        existingTargetSize: Int64 = 0,
        reserveBytes: Int64 = 16 * 1024 * 1024
    ) -> Int64 {
        let values = [max(0, incomingSize), max(0, existingTargetSize), max(0, reserveBytes)]
        var sum: Int64 = 0
        for value in values {
            let (result, overflow) = sum.addingReportingOverflow(value)
            if overflow { return Int64.max }
            sum = result
        }
        return sum
    }

    public static func requireCapacity(
        available: Int64?,
        incoming: Int64,
        existing: Int64,
        reserve: Int64 = 16 * 1024 * 1024
    ) throws {
        guard let available else { return }
        let needed = requiredBytes(
            incomingSize: incoming, existingTargetSize: existing, reserveBytes: reserve
        )
        guard available >= needed else {
            throw MountedCopyError.insufficientSpace(required: needed, available: available)
        }
    }
}
