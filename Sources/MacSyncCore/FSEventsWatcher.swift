import Foundation
import CoreServices

public struct SourceEvent: Sendable {
    public let path: String
    public let flags: FSEventStreamEventFlags
    public let eventID: FSEventStreamEventId

    var isDirectoryRename:Bool {
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed) != 0 &&
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    }

    var isHistoryMarkerOnly:Bool {
        flags == FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
    }

    /// These flags indicate global stream loss, so ALL watched roots must be
    /// rescanned, not only the path carried by the individual event.
    public var streamHistoryLost: Bool {
        let lost = kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped
        return flags & FSEventStreamEventFlags(lost) != 0
    }

    public var requiresFullReconciliation: Bool {
        let unsafeFlags =
            kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged |
            kFSEventStreamEventFlagEventIdsWrapped
        return flags & FSEventStreamEventFlags(unsafeFlags) != 0
    }
}

public enum WatcherError: Error, LocalizedError {
    case couldNotCreateStream
    case couldNotStartStream
    case noPaths

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateStream: return "Unable to create the FSEvents stream"
        case .couldNotStartStream: return "Unable to start the FSEvents stream"
        case .noPaths: return "No source directories configured"
        }
    }
}

/// Native macOS file-events bridge. Use exactly one serial DispatchQueue for
/// processing the callback and for accessing LocalInventory.
/// The stream starts at the caller's pre-scan event ID to capture changes
/// that occur during initial inventory enumeration.
public final class FSEventsWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let onEvents: ([SourceEvent]) -> Void

    public init(queue: DispatchQueue, onEvents: @escaping ([SourceEvent]) -> Void) {
        self.queue = queue
        self.onEvents = onEvents
    }

    public static func currentEventID() -> FSEventStreamEventId {
        FSEventsGetCurrentEventId()
    }

    public func start(paths: [String], since eventID: FSEventStreamEventId) throws {
        guard !paths.isEmpty else { throw WatcherError.noPaths }
        stop()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, callbackInfo, eventCount, eventPaths, eventFlags, eventIDs in
            guard let callbackInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(callbackInfo).takeUnretainedValue()
            let names = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var events: [SourceEvent] = []
            events.reserveCapacity(eventCount)
            for i in 0..<eventCount {
                events.append(SourceEvent(
                    path: String(cString: names[i]),
                    flags: eventFlags[i],
                    eventID: eventIDs[i]
                ))
            }
            watcher.onEvents(events)
        }

        let options = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            eventID, 1.0, options
        ) else {
            throw WatcherError.couldNotCreateStream
        }
        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            throw WatcherError.couldNotStartStream
        }
        stream = newStream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
