import Foundation

enum SortColumn: Int {
    case name, modified, type, size
}

/// Owns the listing for one directory: background enumeration, Explorer's sort
/// order, the hidden-item filter, and incremental delivery to the view.
///
/// Enumeration runs on a serial background queue and hands rows to the main
/// thread in coalesced chunks, so opening a directory with hundreds of
/// thousands of entries paints its first screenful immediately instead of
/// blocking until the walk finishes.
final class DirectoryModel {

    private(set) var path: String = ""
    private(set) var entries: [FileEntry] = []      // filtered + sorted, what the view draws
    private var raw: [FileEntry] = []               // everything the walk returned
    /// Scratch accumulator for a refresh, kept apart from `raw` so the view
    /// keeps drawing the old listing until the new one is known to differ.
    private var pending: [FileEntry] = []

    /// Settable so the previous session's view state can be restored before
    /// the first load, without going through `setSort` and its direction flip.
    var sortColumn: SortColumn = .name
    var sortAscending = true
    var showHidden = false

    /// Fires on the main thread whenever `entries` changes. `isComplete` marks
    /// the final callback for a load.
    var onUpdate: ((_ isComplete: Bool) -> Void)?
    var onError: ((Int32) -> Void)?

    private let queue = DispatchQueue(label: "ExplorerMac.enumerate", qos: .userInitiated)
    /// Bumped on every load so a walk that is still running for the previous
    /// directory drops its results instead of racing the new one onto screen.
    private var generation: Int64 = 0
    private let genLock = NSLock()

    private var currentGeneration: Int64 {
        genLock.lock(); defer { genLock.unlock() }
        return generation
    }

    func load(path newPath: String) {
        start(path: newPath, preservingContents: false)
    }

    /// Re-reads the current directory without blanking the list.
    ///
    /// `load` clears `entries` up front so navigation feels instant, but doing
    /// that on a watcher-driven refresh makes the list flash empty every time
    /// anything in the folder changes. A refresh instead accumulates into a
    /// scratch array and only touches the view if the result actually differs.
    func refresh() {
        guard !path.isEmpty else { return }
        start(path: path, preservingContents: true)
    }

    private func start(path newPath: String, preservingContents: Bool) {
        genLock.lock()
        generation &+= 1
        let gen = generation
        genLock.unlock()

        path = newPath
        if preservingContents {
            pending = []
        } else {
            raw = []
            entries = []
            onUpdate?(false)
        }

        queue.async { [weak self] in
            guard let self else { return }
            var batched: [FileEntry] = []
            // Rows are flushed to the UI in batches; the first flush is small so
            // something appears within a frame, then batches grow to keep
            // main-thread hops down on very large directories.
            var flushThreshold = 128

            // Sorting is O(n log n) over everything accumulated so far, so
            // re-sorting on every batch makes a large directory quadratic.
            // Rows still stream in, but the sorted view is rebuilt at most once
            // per interval and then once more when the walk finishes.
            var lastReapply = DispatchTime.now()
            let reapplyInterval = DispatchTimeInterval.milliseconds(150)

            func flush(_ complete: Bool) {
                let chunk = batched
                batched = []
                let now = DispatchTime.now()
                let due = complete || now > lastReapply.advanced(by: reapplyInterval)
                if due { lastReapply = now }
                DispatchQueue.main.async {
                    guard self.currentGeneration == gen else { return }
                    if preservingContents {
                        self.pending.append(contentsOf: chunk)
                        // Nothing is shown until the walk finishes, and even
                        // then only if something changed.
                        guard complete else { return }
                        let changed = self.pending.count != self.raw.count
                            || !zip(self.pending, self.raw).allSatisfy { $0.isSame(as: $1) }
                        guard changed else { self.pending = []; return }
                        self.raw = self.pending
                        self.pending = []
                    } else {
                        self.raw.append(contentsOf: chunk)
                        guard due else { return }
                    }
                    self.reapply()
                    self.onUpdate?(complete)
                }
            }

            let err = FSEnumerator.enumerate(
                path: newPath,
                batch: { batch in
                    batched.append(contentsOf: batch)
                    if batched.count >= flushThreshold {
                        flush(false)
                        flushThreshold = min(flushThreshold * 4, 8192)
                    }
                },
                shouldStop: { self.currentGeneration != gen }
            )

            guard self.currentGeneration == gen else { return }
            if err != 0 {
                DispatchQueue.main.async {
                    guard self.currentGeneration == gen else { return }
                    self.onError?(err)
                }
                return
            }
            flush(true)
        }
    }

    /// Shows a listing the model did not enumerate — search results, which span
    /// directories. Any navigation or refresh replaces it.
    func showExternal(_ list: [FileEntry]) {
        genLock.lock(); generation &+= 1; genLock.unlock()
        raw = list
        pending = []
        reapply()
        onUpdate?(true)
    }

    func reload() { refresh() }

    func setSort(column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            // Explorer starts name and type ascending but dates and sizes
            // descending, so the newest and largest land on top first.
            sortAscending = (column == .name || column == .type)
        }
        reapply()
        onUpdate?(true)
    }

    func setShowHidden(_ show: Bool) {
        guard showHidden != show else { return }
        showHidden = show
        reapply()
        onUpdate?(true)
    }

    /// Rebuilds `entries` from `raw`. Folders always precede files regardless of
    /// column or direction, which is Explorer's behaviour in every view.
    private func reapply() {
        var list = showHidden ? raw : raw.filter { !$0.isHidden }
        let asc = sortAscending
        let column = sortColumn

        list.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: ComparisonResult
            switch column {
            case .name:
                result = NaturalSort.compare(a.name, b.name)
            case .modified:
                result = a.modified == b.modified
                    ? NaturalSort.compare(a.name, b.name)
                    : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .size:
                result = a.size == b.size
                    ? NaturalSort.compare(a.name, b.name)
                    : (a.size < b.size ? .orderedAscending : .orderedDescending)
            case .type:
                let ta = FileTypeNamer.name(for: a), tb = FileTypeNamer.name(for: b)
                result = ta == tb
                    ? NaturalSort.compare(a.name, b.name)
                    : NaturalSort.compare(ta, tb)
            }
            if result == .orderedSame { return false }
            return asc ? (result == .orderedAscending) : (result == .orderedDescending)
        }
        entries = list
    }

    // MARK: - Status bar figures

    var folderCount: Int { entries.lazy.filter { $0.isDirectory }.count }
    var fileCount: Int { entries.count - folderCount }
}
