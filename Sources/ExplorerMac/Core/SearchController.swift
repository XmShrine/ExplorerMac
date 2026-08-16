import Foundation

/// Recursive name search under a folder.
///
/// Spotlight would be the obvious backend, and is what Windows Search does, but
/// it only knows about indexed locations — a query inside /tmp, a freshly
/// mounted volume, or any excluded folder comes back empty with no way to tell
/// that apart from "no matches". Walking the tree with the same
/// `getattrlistbulk` enumerator the listing uses is fast enough (a 120k-entry
/// directory reads in under 200ms), always correct, and needs no index.
///
/// Results stream in as they are found, so deep trees fill the list
/// progressively instead of showing nothing until the walk completes.
final class SearchController {

    private let queue = DispatchQueue(label: "ExplorerMac.search", qos: .userInitiated)
    private var generation: Int64 = 0
    private let lock = NSLock()

    /// Stops any walk in progress. Called on a new query and when leaving
    /// search, so an abandoned deep walk does not keep burning IO.
    func cancel() {
        lock.lock(); generation &+= 1; lock.unlock()
    }

    private func isCurrent(_ token: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    /// `onResults` fires on the main thread with everything found so far.
    func search(root: String, query: String, includeHidden: Bool,
                onResults: @escaping (_ matches: [FileEntry], _ finished: Bool) -> Void) {
        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()

        let needle = query.lowercased()
        guard !needle.isEmpty else {
            onResults([], true)
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            var matches: [FileEntry] = []
            var directories = [root]
            var lastFlush = Date.distantPast

            func flush(_ finished: Bool) {
                let snapshot = matches
                DispatchQueue.main.async {
                    guard self.isCurrent(token) else { return }
                    onResults(snapshot, finished)
                }
            }

            while !directories.isEmpty {
                guard self.isCurrent(token) else { return }
                let current = directories.removeFirst()

                _ = FSEnumerator.enumerate(path: current, batch: { entries in
                    for entry in entries {
                        if !includeHidden && entry.isHidden { continue }
                        if entry.isDirectory {
                            directories.append(
                                (current as NSString).appendingPathComponent(entry.name))
                        }
                        // Explorer matches anywhere in the name, case-insensitively.
                        if entry.name.lowercased().contains(needle) {
                            var found = entry
                            found.directory = current
                            matches.append(found)
                        }
                    }
                }, shouldStop: { !self.isCurrent(token) })

                // Breadth-first, so shallow matches — the ones the user is most
                // likely after — appear first.
                if Date().timeIntervalSince(lastFlush) > 0.15 {
                    lastFlush = Date()
                    flush(false)
                }
            }
            guard self.isCurrent(token) else { return }
            flush(true)
        }
    }
}
