import Foundation
import CoreServices

/// Thin wrapper around FSEvents with file-level granularity (the macOS analogue
/// of the Windows USN journal that Everything uses for live updates).
final class FSWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "everything.fsevents")
    private let handler: ([Event], UInt64) -> Void

    /// Set when a stream cannot be created (e.g. sandbox denial).
    private(set) var lastError: String?

    init(handler: @escaping ([Event], UInt64) -> Void) {
        self.handler = handler
    }

    deinit { stop() }

    func start(paths: [String], sinceWhen: UInt64, latency: Double = 0.6) -> Bool {
        stop()
        guard !paths.isEmpty else { return false }
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags: FSEventStreamCreateFlags =
            UInt32(kFSEventStreamCreateFlagFileEvents) |
            UInt32(kFSEventStreamCreateFlagNoDefer) |
            UInt32(kFSEventStreamCreateFlagWatchRoot) |
            UInt32(kFSEventStreamCreateFlagUseCFTypes)

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, eventIDs in
            guard let info = info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = unsafeBitCast(eventPaths, to: NSArray.self)
            var events: [Event] = []
            events.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                guard let p = cfPaths[i] as? String else { continue }
                events.append(Event(path: p, flags: eventFlags[i]))
            }
            let lastID = numEvents > 0 ? eventIDs[numEvents - 1] : sinceWhenPlaceholder
            watcher.handler(events, lastID)
        }

        let cfPaths = paths.map { $0 as CFString } as CFArray
        let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, cfPaths,
                                         FSEventStreamEventId(sinceWhen), latency, flags)
        guard let stream = stream else {
            lastError = "FSEventStreamCreate failed"
            return false
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            lastError = "FSEventStreamStart failed"
            FSEventStreamInvalidate(stream)
            return false
        }
        self.stream = stream
        withExtendedLifetime(cfPaths) {}
        return true
    }

    func stop() {
        guard let stream = self.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// The newest event id the system has recorded. Captured before a full scan
    /// so the stream can resume from there (nothing is lost, nothing is replayed
    /// from the distant past).
    static func currentEventID() -> UInt64 {
        FSEventsGetCurrentEventId()
    }

    /// True when the kernel dropped events and the volume must be rescanned.
    static func needsFullRescan(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagUserDropped) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
    }

    static func needsSubdirScan(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
    }

    static func isItemChange(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagItemCreated) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagItemModified) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagItemChangeOwner) != 0 ||
        flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod) != 0
    }

    static func isDirEvent(_ flags: FSEventStreamEventFlags) -> Bool {
        flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0
    }
}

private let sinceWhenPlaceholder: UInt64 = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
