import Foundation

/// Watches one directory and reports that it changed.
///
/// Explorer's list is live: create a file in a terminal and the row appears
/// without touching the window. FSEvents gives us that for the directory the
/// user is looking at. Events are coalesced by the stream's own latency and we
/// deliberately report nothing about *what* changed — re-enumerating is cheap
/// enough (a 120k directory reloads in under 400ms) that diffing would be more
/// machinery than it is worth.
final class FSWatcher {

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "ExplorerMac.fsevents")
    private var onChange: (() -> Void)?
    private var debounce: DispatchWorkItem?

    deinit { stop() }

    func watch(path: String, onChange: @escaping () -> Void) {
        stop()
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { watcher.schedule() }
        }

        // `.noDefer` fires on the leading edge so the first change shows up
        // immediately; the latency then coalesces the burst that follows a
        // paste or a delete of many files.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, flags) else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Coalesces a burst into one refresh. Copying a folder or letting Spotlight
    /// touch a directory produces a long stream of events, and re-enumerating on
    /// each one is both wasteful and visible.
    private func schedule() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        onChange = nil
    }
}
