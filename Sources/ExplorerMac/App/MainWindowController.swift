import AppKit

/// Assembles the Explorer window and owns navigation state.
final class MainWindowController: NSWindowController, NSWindowDelegate {

    private let backdrop = BackdropView()
    private let titleBar = TitleBarView()
    private let addressBar = AddressBarView()
    private let commandBar = CommandBarView()
    private let navPane = NavPaneView()
    private let navScroll = NSScrollView()
    private let splitter = SplitterView()
    private let columnHeader = ColumnHeaderView()
    private let listScroll = NSScrollView()
    private let listView = FileListView()
    private let statusBar = StatusBarView()

    private let model = DirectoryModel()
    private let watcher = FSWatcher()
    private let history = UndoStack()
    private let search = SearchController()
    /// The query currently showing, or nil when the list is a real folder.
    private var activeQuery: String?
    /// Held while a context menu or dropdown is on screen; it owns its own
    /// window and would otherwise deallocate immediately.
    private var activeMenu: WinMenu?
    private var keyMonitor: Any?
    /// Held open while the sheet is on screen; it owns its own window.
    private var propertiesWindow: PropertiesWindow?
    private var tabs: [ExplorerTab] = []
    private var activeIndex = 0
    private var navWidth = Settings.navWidth

    private var activeTab: ExplorerTab { tabs[activeIndex] }

    // MARK: - Construction

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        self.init(window: window)

        // Windows draws its own caption, so the native one is hidden entirely
        // rather than restyled; the tab strip takes over the drag region.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        if let saved = Settings.windowFrame { window.setFrame(saved, display: false) }

        buildContent()
        installShortcuts()
        openInitialTab()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// App-wide accelerators.
    ///
    /// These live in one monitor rather than scattered through `keyDown`
    /// overrides because most of them have to work no matter which view holds
    /// focus, and because the menus already advertise them — a listed shortcut
    /// that does nothing is worse than no shortcut at all.
    private func installShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        // Never steal keys from a field editor; renaming or typing a path has
        // to behave like plain text entry.
        if window?.firstResponder is NSTextView { return false }

        let flags = event.modifierFlags
        // Ctrl is what Explorer documents, Cmd is the muscle memory on Mac
        // hardware; both are accepted everywhere.
        let command = flags.contains(.command) || flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53 where activeQuery != nil:               // esc leaves search
            exitSearch(); return true
        case 96:                                        // F5
            model.reload(); return true
        case 51 where !command:                         // backspace
            // Explorer navigates back on Backspace; deleting is Delete, which
            // most Mac keyboards lack, so Cmd+Backspace covers it too.
            goBack(); return true
        case 123 where option: goBack(); return true    // alt+left
        case 124 where option: goForward(); return true // alt+right
        case 126 where option: goUp(); return true      // alt+up
        case 36, 76:                                    // alt+enter — properties
            guard option else { return false }
            showProperties(); return true
        default: break
        }

        guard command else { return false }

        // Ctrl+Shift+1 … Ctrl+Shift+8 switch layout, exactly as in Explorer.
        if shift, let digit = Self.viewModeDigit(in: event),
           let mode = ViewMode(rawValue: digit - 1) {
            setViewMode(mode)
            return true
        }

        switch key {
        case "n" where shift: performNewFolder(); return true
        case "c" where shift: copyPaths(); return true
        case "t": addTab(path: activeTab.path); return true
        case "w": closeTab(activeIndex); return true
        case "r": model.reload(); return true
        case "l": addressBar.focusPath(); return true
        case "f": addressBar.focusSearch(); return true
        default: return false
        }
    }

    /// `--view <0…7>` pins the layout for a snapshot run without writing it
    /// into the preferences a normal launch would restore.
    private static var debugViewMode: ViewMode? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--view"), index + 1 < args.count,
              let raw = Int(args[index + 1]) else { return nil }
        return ViewMode(rawValue: raw)
    }

    /// 1…8 out of a Shift-modified keystroke.
    ///
    /// `charactersIgnoringModifiers` drops Command but keeps Shift, so the top
    /// row arrives as "!@#$%^&*" on a US layout; `keyCode` covers the rest and
    /// is layout-independent.
    private static func viewModeDigit(in event: NSEvent) -> Int? {
        if let characters = event.charactersIgnoringModifiers, characters.count == 1 {
            if let digit = Int(characters), (1...8).contains(digit) { return digit }
            let shifted = "!@#$%^&*"
            if let index = shifted.firstIndex(of: Character(characters)) {
                return shifted.distance(from: shifted.startIndex, to: index) + 1
            }
        }
        // Key codes for the 1…8 keys along the number row.
        let row: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
        return row.firstIndex(of: event.keyCode).map { $0 + 1 }
    }

    private func buildContent() {
        guard let window else { return }

        // Mica is painted as a flat surface rather than built from an
        // NSVisualEffectView. A `.behindWindow` effect view makes AppKit inject
        // a window-level backdrop layer into its parent's layer, and that layer
        // lands part-way up the sublayer stack and paints over every sibling
        // beneath it — the tab strip, address bar, command bar and navigation
        // pane all vanished behind it. Windows' own Mica is a heavily blurred,
        // near-opaque wallpaper tint, so a solid theme fill reads almost the
        // same and costs nothing.
        window.contentView = backdrop

        // Every content view is lifted a hair above zPosition 0.
        //
        // The window carries an extra, unowned full-size layer in the content
        // view's sublayer stack. It sits at zPosition 0 like everything else,
        // but orders after most of our views and paints over them: the tab
        // strip, address bar, command bar and navigation pane all rendered
        // correctly — `draw(_:)` ran, the layers held content — and were simply
        // never composited, which is why they stayed invisible while remaining
        // fully clickable. Only the last few subviews, which happen to order
        // after it, came through. Any positive zPosition wins the tie; the
        // uniform value keeps our own views in subview order among themselves.
        for view in [titleBar, addressBar, commandBar, navScroll, splitter,
                     columnHeader, listScroll, statusBar] as [NSView] {
            backdrop.addSubview(view)
        }

        navScroll.drawsBackground = false
        navScroll.hasVerticalScroller = true
        navScroll.scrollerStyle = .overlay
        navScroll.documentView = navPane
        navScroll.contentView.postsBoundsChangedNotifications = true

        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        // 列表 view wraps into columns and grows sideways; every other mode
        // fits the viewport, so the scroller only ever appears there.
        listScroll.hasHorizontalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.documentView = listView
        listView.model = model
        columnHeader.list = listView

        // Restore the view state Explorer would have remembered.
        model.sortColumn = Settings.sortColumn
        model.sortAscending = Settings.sortAscending
        model.showHidden = Settings.showHidden
        listView.rowHeight = Settings.compactView
            ? WinTheme.Metrics.compactRowHeight : WinTheme.Metrics.rowHeight
        listView.viewMode = Self.debugViewMode ?? Settings.viewMode
        columnHeader.isHidden = listView.viewMode != .details
        if let widths = Settings.columnWidths, widths.count == listView.columns.count {
            for (index, width) in widths.enumerated() { listView.columns[index].width = width }
        }

        applyLayerOrder()
        wireCallbacks()
        buildNavigationTree()
    }

    /// Lifts the upper content views above an unowned layer in the window.
    ///
    /// The content view's sublayer stack carries one extra layer that belongs
    /// to no subview. It orders after the tab strip, address bar, command bar,
    /// navigation scroller and splitter, and paints over all five: those views
    /// laid out and drew correctly — the draw calls ran, their layers held
    /// content — but were never composited, so they were invisible on screen
    /// while staying fully clickable. The column header, file list and status
    /// bar happen to order after it and were unaffected, which is what made the
    /// symptom look so arbitrary.
    ///
    /// Raising only the affected five is deliberate. Lifting every subview by
    /// the same amount leaves the relative order untouched and changes nothing;
    /// the five have to end up above the intruder specifically. Verified
    /// against window-server captures, which is the only rendering path that
    /// tells the truth here — redrawing the hierarchy into a PDF or a bitmap
    /// shows a perfect window either way.
    private func applyLayerOrder() {
        for view in [titleBar, addressBar, commandBar, navScroll, splitter] as [NSView] {
            view.wantsLayer = true
            view.layer?.zPosition = 1
        }
    }

    private func wireCallbacks() {
        addressBar.backButton.onClick = { [weak self] in self?.goBack() }
        addressBar.forwardButton.onClick = { [weak self] in self?.goForward() }
        addressBar.upButton.onClick = { [weak self] in self?.goUp() }
        addressBar.refreshButton.onClick = { [weak self] in self?.model.reload() }
        addressBar.onNavigate = { [weak self] path in self?.navigate(to: path) }
        addressBar.siblingProvider = { path in Self.siblings(of: path) }
        addressBar.onSearch = { [weak self] text in self?.performSearch(text) }
        addressBar.onSearchCancelled = { [weak self] in self?.exitSearch() }

        titleBar.onSelectTab = { [weak self] index in self?.selectTab(index) }
        titleBar.onCloseTab = { [weak self] index in self?.closeTab(index) }
        titleBar.onNewTab = { [weak self] in
            guard let self else { return }
            self.addTab(path: self.activeTab.path)
        }

        navPane.onSelect = { [weak self] node in
            guard let path = node.path else { return }
            self?.navigate(to: path)
        }
        navPane.childProvider = { node in Self.children(of: node) }

        listView.onOpen = { [weak self] entry in self?.open(entry) }
        listView.onSelectionChanged = { [weak self] in self?.updateStatus() }
        listView.onContextMenu = { [weak self] entry, event in
            self?.showContextMenu(for: entry, event: event)
        }
        listView.onRename = { [weak self] entry, name in self?.performRename(entry, to: name) }
        listView.onDelete = { [weak self] permanent in self?.performDelete(permanent: permanent) }
        listView.onCopy = { [weak self] in self?.performClipboard(.copy) }
        listView.onCut = { [weak self] in self?.performClipboard(.move) }
        listView.onPaste = { [weak self] in self?.performPaste() }
        listView.onUndo = { [weak self] in self?.performUndo() }
        listView.onRedo = { [weak self] in self?.performRedo() }
        listView.onDrop = { [weak self] urls, destination, isCopy in
            self?.performDrop(urls, to: destination, isCopy: isCopy)
        }
        navPane.onDrop = { [weak self] urls, destination, isCopy in
            self?.performDrop(urls, to: destination, isCopy: isCopy)
        }

        columnHeader.onSort = { [weak self] column in
            self?.model.setSort(column: column)
        }
        columnHeader.onColumnsResized = { [weak self] in
            self?.listView.needsDisplay = true
            self?.persistState()
        }

        commandBar.onCommand = { [weak self] command, source in
            self?.handle(command, from: source)
        }

        splitter.onDrag = { [weak self] delta in
            guard let self else { return }
            self.navWidth = min(WinTheme.Metrics.navPaneMaxWidth,
                                max(WinTheme.Metrics.navPaneMinWidth, self.navWidth + delta))
            self.layoutContent()
        }

        model.onUpdate = { [weak self] complete in
            guard let self else { return }
            self.listView.reload()
            self.updateStatus()
            if complete { self.columnHeader.needsDisplay = true }
        }
        model.onError = { [weak self] code in
            self?.presentError(code)
        }
    }

    // MARK: - Navigation tree

    private func buildNavigationTree() {
        VolumeMapper.shared.refresh()

        var nodes: [NavNode] = [
            NavNode(title: "主页", icon: .user, glyph: .home, path: ShellLocations.home),
        ]

        for known in ShellLocations.known {
            let path = ShellLocations.path(for: known)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            nodes.append(NavNode(title: known.displayName, icon: known.icon,
                                 path: path, isExpandable: true,
                                 startsGroup: known.posixName == "Desktop",
                                 isPinned: true, childrenLoaded: false))
        }

        let drives = VolumeMapper.shared.volumes.map { volume in
            NavNode(title: volume.displayName,
                    icon: volume.isRemovable ? .driveRemovable
                        : (volume.isBoot ? .driveWindows : .driveFixed),
                    path: volume.mountPoint, isExpandable: true, childrenLoaded: false)
        }
        nodes.append(NavNode(title: "此电脑", icon: .thisPC,
                             path: ShellLocations.thisPCToken,
                             children: drives, isExpanded: true, isExpandable: true,
                             startsGroup: true))

        navPane.setRoots(nodes)
    }

    /// Immediate subfolders, sorted the way Explorer sorts them.
    private static func children(of node: NavNode) -> [NavNode] {
        guard let path = node.path, path.first != "\u{1}" else { return [] }
        var folders: [FileEntry] = []
        _ = FSEnumerator.enumerate(path: path, batch: { batch in
            folders.append(contentsOf: batch.filter { $0.isDirectory && !$0.isHidden })
        })
        return folders
            .sorted { NaturalSort.less($0.name, $1.name) }
            .map { entry in
                let child = (path as NSString).appendingPathComponent(entry.name)
                return NavNode(title: ShellLocations.displayName(for: child, fallback: entry.name),
                               icon: ShellLocations.icon(for: child),
                               path: child, isExpandable: true, childrenLoaded: false)
            }
    }

    /// Sibling folders behind a breadcrumb chevron.
    private static func siblings(of path: String) -> [(title: String, path: String)] {
        guard path.first != "\u{1}" else {
            return VolumeMapper.shared.volumes.map { ($0.displayName, $0.mountPoint) }
        }
        var folders: [FileEntry] = []
        _ = FSEnumerator.enumerate(path: path, batch: { batch in
            folders.append(contentsOf: batch.filter { $0.isDirectory && !$0.isHidden })
        })
        return folders
            .sorted { NaturalSort.less($0.name, $1.name) }
            .map { ($0.name, (path as NSString).appendingPathComponent($0.name)) }
    }

    // MARK: - Tabs

    private func openInitialTab() {
        // `--path <dir>` opens somewhere other than 主页, which the snapshot
        // mode uses to inspect large directories.
        let args = CommandLine.arguments
        var start = Settings.lastPath ?? ShellLocations.home
        if let index = args.firstIndex(of: "--path"), index + 1 < args.count {
            start = args[index + 1]
        }
        addTab(path: start)
    }

    private func persistState() {
        if let frame = window?.frame { Settings.windowFrame = frame }
        Settings.navWidth = navWidth
        Settings.columnWidths = listView.columns.map(\.width)
        Settings.sortColumn = model.sortColumn
        Settings.sortAscending = model.sortAscending
        Settings.showHidden = model.showHidden
        Settings.compactView = listView.rowHeight == WinTheme.Metrics.compactRowHeight
        if Self.debugViewMode == nil { Settings.viewMode = listView.viewMode }
        // A run started with the debug `--path` flag must not hijack where the
        // next normal launch opens.
        if !tabs.isEmpty, !CommandLine.arguments.contains("--path") {
            Settings.lastPath = activeTab.path
        }
    }

    func windowWillClose(_ notification: Notification) { persistState() }
    func windowDidMove(_ notification: Notification) { persistState() }

    private func addTab(path: String) {
        let tab = ExplorerTab(path: path, title: ShellLocations.title(for: path),
                              icon: ShellLocations.icon(for: path))
        tabs.append(tab)
        activeIndex = tabs.count - 1
        syncTabs()
        loadCurrent()
    }

    private func selectTab(_ index: Int) {
        guard index >= 0, index < tabs.count, index != activeIndex else { return }
        activeIndex = index
        syncTabs()
        loadCurrent()
    }

    private func closeTab(_ index: Int) {
        guard tabs.count > 1 else { window?.performClose(nil); return }
        tabs.remove(at: index)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        syncTabs()
        loadCurrent()
    }

    private func syncTabs() {
        titleBar.tabs = tabs
        titleBar.activeIndex = activeIndex
        titleBar.needsDisplay = true
    }

    // MARK: - Navigation

    private func navigate(to path: String) {
        if activeQuery != nil {
            activeQuery = nil
            search.cancel()
            listView.columns[2].showsPath = false
            listView.columns[2].title = "类型"
            statusBar.searchLabel = nil
            addressBar.clearSearch()
        }
        let tab = activeTab
        guard path != tab.path else { return }
        tab.back.append(tab.path)
        tab.forward.removeAll()
        tab.path = path
        loadCurrent()
    }

    private func goBack() {
        let tab = activeTab
        guard let previous = tab.back.popLast() else { return }
        tab.forward.append(tab.path)
        tab.path = previous
        loadCurrent()
    }

    private func goForward() {
        let tab = activeTab
        guard let next = tab.forward.popLast() else { return }
        tab.back.append(tab.path)
        tab.path = next
        loadCurrent()
    }

    private func goUp() {
        let path = activeTab.path
        guard path != "/" , path.first != "\u{1}" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        navigate(to: parent)
    }

    private func loadCurrent() {
        let tab = activeTab
        tab.title = ShellLocations.title(for: tab.path)
        tab.icon = ShellLocations.icon(for: tab.path)

        addressBar.setPath(tab.path)
        addressBar.backButton.isEnabled = !tab.back.isEmpty
        addressBar.forwardButton.isEnabled = !tab.forward.isEmpty
        addressBar.upButton.isEnabled = tab.path != "/" && tab.path.first != "\u{1}"

        navPane.syncSelection(to: tab.path)
        listView.clearSelection()
        listScroll.contentView.scroll(to: .zero)
        window?.title = tab.title
        syncTabs()

        ThumbnailProvider.shared.invalidateAll()
        listView.directoryPath = tab.path
        listView.cutPaths = Clipboard.cutPaths
        model.load(path: tab.path)

        // Explorer's list is live; a file created in a terminal shows up
        // without touching the window.
        if tab.path.first != "\u{1}" {
            watcher.watch(path: tab.path) { [weak self] in
                guard let self, self.activeTab.path == tab.path else { return }
                self.model.reload()
            }
        } else {
            watcher.stop()
        }
    }

    private func open(_ entry: FileEntry) {
        let full = listView.fullPath(for: entry)
        if entry.isDirectory {
            navigate(to: full)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
        }
    }

    // MARK: - Commands

    private func handle(_ command: CommandBarView.Command, from source: NSView) {
        switch command {
        case .newItem: showNewMenu(from: source)
        case .cut:     performClipboard(.move)
        case .copy:    performClipboard(.copy)
        case .paste:   performPaste()
        case .rename:  beginRenameSelection()
        case .delete:  performDelete(permanent: false)
        case .share:   shareSelection(from: source)
        case .sort:    showSortMenu(from: source)
        case .view:    showViewMenu(from: source)
        case .more:    showMoreMenu(from: source)
        }
    }

    // MARK: - Search

    private func performSearch(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { exitSearch(); return }
        guard currentDirectory.first != "\u{1}" else { NSSound.beep(); return }

        activeQuery = query
        // Search results span folders, so the type column becomes the path
        // column and the directory watcher stops fighting the result list.
        listView.columns[2].showsPath = true
        listView.columns[2].title = "文件夹路径"
        watcher.stop()
        listView.clearSelection()
        statusBar.searchLabel = "正在搜索..."

        search.search(root: currentDirectory, query: query,
                      includeHidden: model.showHidden) { [weak self] matches, finished in
            guard let self, self.activeQuery == query else { return }
            self.model.showExternal(matches)
            self.listView.reload()
            self.statusBar.searchLabel = finished
                ? "在“\(ShellLocations.title(for: self.currentDirectory))”中搜索“\(query)”"
                : "正在搜索..."
            self.updateStatus()
        }
    }

    private func exitSearch() {
        guard activeQuery != nil else { return }
        activeQuery = nil
        search.cancel()
        listView.columns[2].showsPath = false
        listView.columns[2].title = "类型"
        statusBar.searchLabel = nil
        addressBar.clearSearch()
        loadCurrent()
    }

    // MARK: - File operations

    private var currentDirectory: String { activeTab.path }

    private func url(for entry: FileEntry) -> URL {
        URL(fileURLWithPath: listView.fullPath(for: entry))
    }

    private func selectedURLs() -> [URL] { listView.selectedEntries().map(url(for:)) }

    private func performClipboard(_ effect: Clipboard.Effect) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        Clipboard.write(urls: urls, effect: effect)
        listView.cutPaths = Clipboard.cutPaths
        updateStatus()
    }

    private func performPaste() {
        let state = Clipboard.read()
        guard !state.urls.isEmpty else { return }
        let destination = currentDirectory
        let finish: (FileOperations.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            if state.effect == .move {
                // A cut is consumed by its paste, exactly as on Windows.
                Clipboard.clear()
                self.listView.cutPaths = []
            }
            self.history.record(FileTransaction(
                label: state.effect == .move ? "移动" : "复制", steps: outcome.steps))
            FileOperations.report(outcome, verb: state.effect == .move ? "移动" : "复制",
                                  in: self.window)
            self.model.reload()
        }
        if state.effect == .move {
            FileOperations.move(state.urls, to: destination, presenter: window, completion: finish)
        } else {
            FileOperations.copy(state.urls, to: destination, presenter: window, completion: finish)
        }
    }

    /// A drag landed. Goes through the same machinery as 粘贴, so a drop gets
    /// the same conflict prompts and the same undo entry.
    private func performDrop(_ urls: [URL], to destination: String, isCopy: Bool) {
        let finish: (FileOperations.Outcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            self.history.record(FileTransaction(
                label: isCopy ? "复制" : "移动", steps: outcome.steps))
            FileOperations.report(outcome, verb: isCopy ? "复制" : "移动", in: self.window)
            self.model.reload()
        }
        if isCopy {
            FileOperations.copy(urls, to: destination, presenter: window, completion: finish)
        } else {
            FileOperations.move(urls, to: destination, presenter: window, completion: finish)
        }
    }

    private func performDelete(permanent: Bool) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }

        if permanent {
            let alert = NSAlert()
            alert.messageText = urls.count == 1
                ? "确实要永久删除此文件吗?"
                : "确实要永久删除这 \(urls.count) 个项目吗?"
            alert.informativeText = urls.count == 1 ? urls[0].lastPathComponent : ""
            alert.alertStyle = .warning
            alert.addButton(withTitle: "是")
            alert.addButton(withTitle: "否")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            FileOperations.deletePermanently(urls) { [weak self] outcome in
                guard let self else { return }
                FileOperations.report(outcome, verb: "删除", in: self.window)
                self.model.reload()
            }
            return
        }

        FileOperations.trash(urls) { [weak self] outcome in
            guard let self else { return }
            self.history.record(FileTransaction(label: "删除", steps: outcome.steps))
            FileOperations.report(outcome, verb: "删除", in: self.window)
            self.model.reload()
        }
    }

    private func performRename(_ entry: FileEntry, to name: String) {
        do {
            let from = url(for: entry)
            let to = try FileOperations.rename(from, to: name)
            history.record(FileTransaction(label: "重命名", steps: [.moved(from: from, to: to)]))
            model.reload()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法重命名"
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    private func beginRenameSelection() {
        guard let entry = listView.selectedEntries().first,
              let row = model.entries.firstIndex(where: { $0.fileID == entry.fileID }) else { return }
        listView.beginRename(row: row)
    }

    private func performNewFolder() {
        do {
            let created = try FileOperations.createFolder(in: currentDirectory)
            history.record(FileTransaction(label: "新建", steps: [.created(created)]))
            model.reload()
            // Explorer drops straight into rename on a fresh folder.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let row = self.model.entries.firstIndex(
                        where: { $0.name == created.lastPathComponent }) else { return }
                self.listView.setSelection([row])
                self.listView.beginRename(row: row)
            }
        } catch {
            NSSound.beep()
        }
    }

    private func performNewFile(named name: String) {
        do {
            let created = try FileOperations.createFile(in: currentDirectory, name: name)
            history.record(FileTransaction(label: "新建", steps: [.created(created)]))
            model.reload()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let row = self.model.entries.firstIndex(
                        where: { $0.name == created.lastPathComponent }) else { return }
                self.listView.setSelection([row])
                self.listView.beginRename(row: row)
            }
        } catch {
            NSSound.beep()
        }
    }

    private func performUndo() {
        guard history.canUndo else { NSSound.beep(); return }
        applyHistory { try history.undo() }
    }

    private func performRedo() {
        guard history.canRedo else { NSSound.beep(); return }
        applyHistory { try history.redo() }
    }

    private func applyHistory(_ work: () throws -> Void) {
        do {
            try work()
            model.reload()
        } catch UndoStack.Failure.partial(let detail) {
            let alert = NSAlert()
            alert.messageText = "无法完全撤销"
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            if let window { alert.beginSheetModal(for: window) }
            model.reload()
        } catch {
            NSSound.beep()
        }
    }

    /// Alt+Enter, or 属性 in the context menu. With nothing selected Explorer
    /// shows the properties of the folder being viewed.
    private func showProperties() {
        let targets = selectedURLs().isEmpty
            ? [URL(fileURLWithPath: currentDirectory)]
            : selectedURLs()
        guard currentDirectory.first != "\u{1}" else { NSSound.beep(); return }

        let sheet = PropertiesWindow(urls: targets)
        propertiesWindow = sheet
        if let parent = window, let child = sheet.window {
            // Centre on the browser window, as a modeless dialog would appear.
            let origin = NSPoint(
                x: parent.frame.midX - child.frame.width / 2,
                y: parent.frame.midY - child.frame.height / 2)
            child.setFrameOrigin(origin)
        }
        sheet.showWindow(nil)
        sheet.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens the properties sheet and returns its window number so its
    /// rendering can be captured and checked.
    /// Runs a search so the results view can be captured and checked.
    func debugSearch(_ query: String) {
        addressBar.setSearchText(query)
        performSearch(query)
    }

    func debugShowProperties(onItem: Bool) -> Int? {
        if onItem, !model.entries.isEmpty {
            listView.setSelection([0])
        } else {
            listView.clearSelection()
        }
        showProperties()
        return propertiesWindow?.window?.windowNumber
    }

    private func copyPaths() {
        let paths = selectedURLs().map { "\"\(VolumeMapper.shared.windowsPath(from: $0.path))\"" }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    private func shareSelection(from source: NSView) {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls)
            .show(relativeTo: source.bounds, of: source, preferredEdge: .maxY)
    }

    private func openInTerminal() {
        let url = URL(fileURLWithPath: currentDirectory)
        NSWorkspace.shared.open([url],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Menus

    /// Top-left corner, in screen coordinates, of a dropdown hanging under a
    /// command-bar button.
    private func dropdownAnchor(_ source: NSView) -> NSPoint {
        let local = NSPoint(x: 0, y: source.isFlipped ? source.bounds.maxY : source.bounds.minY)
        let inWindow = source.convert(local, to: nil)
        return source.window?.convertPoint(toScreen: inWindow) ?? .zero
    }

    private func present(_ menu: WinMenu, at point: NSPoint) {
        activeMenu?.close()
        activeMenu = menu
        menu.show(at: point)
    }

    private func showNewMenu(from source: NSView) {
        var items: [WinMenuItem] = [
            .item("文件夹", glyph: .newFolder, shortcut: "Ctrl+Shift+N") { [weak self] in
                self?.performNewFolder()
            },
            .separator,
        ]
        for (label, name) in [("文本文档", "新建文本文档.txt"),
                              ("Markdown 文档", "新建 Markdown 文档.md"),
                              ("JSON 文件", "新建 JSON 文件.json")] {
            items.append(.item(label, glyph: .folderGlyph) { [weak self] in
                self?.performNewFile(named: name)
            })
        }
        present(WinMenu(items: items), at: dropdownAnchor(source))
    }

    private var sortItems: [WinMenuItem] {
        var items: [WinMenuItem] = []
        for (title, column) in [("名称", SortColumn.name), ("修改日期", .modified),
                                ("类型", .type), ("大小", .size)] {
            items.append(.item(title, checked: model.sortColumn == column) { [weak self] in
                guard let self, self.model.sortColumn != column else { return }
                self.model.setSort(column: column)
                self.listView.reload()
                self.persistState()
            })
        }
        items.append(.separator)
        // Re-sorting on the current column is what flips the direction.
        items.append(.item("递增", checked: model.sortAscending) { [weak self] in
            guard let self, !self.model.sortAscending else { return }
            self.model.setSort(column: self.model.sortColumn)
            self.listView.reload()
        })
        items.append(.item("递减", checked: !model.sortAscending) { [weak self] in
            guard let self, self.model.sortAscending else { return }
            self.model.setSort(column: self.model.sortColumn)
            self.listView.reload()
        })
        return items
    }

    /// Switches layout. The column header belongs to 详细信息 alone, so it comes
    /// and goes with the mode rather than sitting empty above an icon grid.
    private func setViewMode(_ mode: ViewMode) {
        guard listView.viewMode != mode else { return }
        listView.viewMode = mode
        columnHeader.isHidden = mode != .details
        layoutContent()
        persistState()
    }

    private var viewItems: [WinMenuItem] {
        var items: [WinMenuItem] = ViewMode.allCases.map { mode in
            .item(mode.title, shortcut: mode.shortcut,
                  checked: listView.viewMode == mode) { [weak self] in
                self?.setViewMode(mode)
            }
        }
        items.append(.separator)
        items += [
            .item("显示隐藏的项目", checked: model.showHidden) { [weak self] in
                guard let self else { return }
                self.model.setShowHidden(!self.model.showHidden)
                self.listView.reload()
                self.persistState()
            },
            .item("紧凑视图",
                  checked: listView.rowHeight == WinTheme.Metrics.compactRowHeight) { [weak self] in
                guard let self else { return }
                let toCompact = self.listView.rowHeight == WinTheme.Metrics.rowHeight
                self.listView.rowHeight = toCompact
                    ? WinTheme.Metrics.compactRowHeight : WinTheme.Metrics.rowHeight
                self.listView.reload()
                self.persistState()
            },
        ]
        return items
    }

    private func showSortMenu(from source: NSView) {
        present(WinMenu(items: sortItems), at: dropdownAnchor(source))
    }

    private func showViewMenu(from source: NSView) {
        present(WinMenu(items: viewItems), at: dropdownAnchor(source))
    }

    private func showMoreMenu(from source: NSView) {
        var items: [WinMenuItem] = []
        if let label = history.undoLabel {
            items.append(.item(label, glyph: .undo, shortcut: "Ctrl+Z") { [weak self] in
                self?.performUndo()
            })
        }
        if let label = history.redoLabel {
            items.append(.item(label, glyph: .redo, shortcut: "Ctrl+Y") { [weak self] in
                self?.performRedo()
            })
        }
        if !items.isEmpty { items.append(.separator) }
        items += [
            .item("复制路径", glyph: .copy, shortcut: "Ctrl+Shift+C",
                  enabled: !listView.selection.isEmpty) { [weak self] in self?.copyPaths() },
            .item("在终端中打开", glyph: .terminal) { [weak self] in self?.openInTerminal() },
            .item("属性", glyph: .properties, shortcut: "Alt+Enter") { [weak self] in
                self?.showProperties()
            },
            .separator,
            .item("刷新", glyph: .refresh, shortcut: "F5") { [weak self] in self?.model.reload() },
        ]
        present(WinMenu(items: items), at: dropdownAnchor(source))
    }

    /// Opens a context menu at a fixed point and returns its window number, so
    /// the menu's own rendering can be captured and checked.
    func debugShowContextMenu(onItem: Bool) -> Int? {
        if onItem, !model.entries.isEmpty {
            listView.setSelection([0])
            showContextMenu(for: model.entries[0], event: NSEvent())
        } else {
            listView.clearSelection()
            showContextMenu(for: nil, event: NSEvent())
        }
        return activeMenu?.windowNumber
    }

    private func showContextMenu(for entry: FileEntry?, event: NSEvent) {
        let selection = listView.selectedEntries()
        let menu: WinMenu

        if let entry {
            let single = selection.count <= 1
            // Windows 11 puts the verbs in an icon strip along the top edge and
            // keeps the worded list underneath.
            let commands: [WinMenuCommand] = [
                WinMenuCommand(glyph: .cut) { [weak self] in self?.performClipboard(.move) },
                WinMenuCommand(glyph: .copy) { [weak self] in self?.performClipboard(.copy) },
                WinMenuCommand(glyph: .rename, isEnabled: single) { [weak self] in
                    self?.beginRenameSelection()
                },
                WinMenuCommand(glyph: .share) { [weak self] in
                    guard let self else { return }
                    self.shareSelection(from: self.listView)
                },
                WinMenuCommand(glyph: .delete) { [weak self] in
                    self?.performDelete(permanent: false)
                },
            ]
            let items: [WinMenuItem] = [
                .item("打开", glyph: .folderGlyph, shortcut: "Enter") { [weak self] in
                    self?.open(entry)
                },
                .submenu("打开方式", glyph: .openWith, items: openWithItems(for: entry)),
                .separator,
                .item("复制路径", glyph: .copy, shortcut: "Ctrl+Shift+C") { [weak self] in
                    self?.copyPaths()
                },
                .separator,
                .item("在终端中打开", glyph: .terminal) { [weak self] in self?.openInTerminal() },
                .item("属性", glyph: .properties, shortcut: "Alt+Enter") { [weak self] in
                    self?.showProperties()
                },
            ]
            menu = WinMenu(items: items, commands: commands, commandsAtTop: true)
        } else {
            // Empty space: view/sort submenus first, then create verbs, with
            // 粘贴 as a single icon button along the bottom.
            var items: [WinMenuItem] = [
                .submenu("查看", glyph: .view, items: viewItems),
                .submenu("排序方式", glyph: .sort, items: sortItems),
                .separator,
            ]
            if let label = history.undoLabel {
                items.append(.item(label, glyph: .undo, shortcut: "Ctrl+Z") { [weak self] in
                    self?.performUndo()
                })
            }
            if let label = history.redoLabel {
                items.append(.item(label, glyph: .redo, shortcut: "Ctrl+Y") { [weak self] in
                    self?.performRedo()
                })
            }
            items += [
                .submenu("新建", glyph: .add, items: [
                    .item("文件夹", glyph: .newFolder, shortcut: "Ctrl+Shift+N") { [weak self] in
                        self?.performNewFolder()
                    },
                    .separator,
                    .item("文本文档") { [weak self] in self?.performNewFile(named: "新建文本文档.txt") },
                    .item("Markdown 文档") { [weak self] in self?.performNewFile(named: "新建 Markdown 文档.md") },
                    .item("JSON 文件") { [weak self] in self?.performNewFile(named: "新建 JSON 文件.json") },
                ]),
                .item("刷新", glyph: .refresh, shortcut: "F5") { [weak self] in self?.model.reload() },
                .separator,
                .item("在终端中打开", glyph: .terminal) { [weak self] in self?.openInTerminal() },
                .item("属性", glyph: .properties, shortcut: "Alt+Enter") { [weak self] in
                    self?.showProperties()
                },
            ]
            let commands = [
                WinMenuCommand(glyph: .paste, label: "粘贴",
                               isEnabled: Clipboard.hasFiles) { [weak self] in self?.performPaste() },
            ]
            menu = WinMenu(items: items, commands: commands, commandsAtTop: false)
        }
        present(menu, at: NSEvent.mouseLocation)
    }

    /// Real candidate applications from Launch Services, rather than a
    /// hard-coded editor.
    private func openWithItems(for entry: FileEntry) -> [WinMenuItem] {
        let target = url(for: entry)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: target).prefix(8)
        var items: [WinMenuItem] = apps.map { app in
            .item(FileManager.default.displayName(atPath: app.path)) {
                NSWorkspace.shared.open([target], withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        }
        if items.isEmpty {
            items.append(.item("没有可用的应用", enabled: false, action: {}))
        }
        return items
    }

    private func presentError(_ code: Int32) {
        let alert = NSAlert()
        alert.messageText = "无法访问此位置"
        alert.informativeText = String(cString: strerror(code))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func updateStatus() {
        let selected = listView.selectedEntries()
        statusBar.update(itemCount: model.entries.count,
                         selectionCount: selected.count,
                         selectionBytes: selected.reduce(0) { $0 + $1.size })
        commandBar.updateEnabled(selectionCount: selected.count,
                                 clipboardHasItems: Clipboard.hasFiles)
    }

    // MARK: - Layout

    /// Laying out from `BackdropView.layout()` looked tidy but broke rendering:
    /// this method moves sibling frames and calls `listView.reload()`, so
    /// running it *inside* the layout pass re-entered invalidation and AppKit
    /// dropped the pending redraw for anything that was only ever dirtied
    /// there. The bars kept blank layers while the list — independently
    /// invalidated by every model update — looked fine. Layout is driven from
    /// window events instead, and every view is explicitly marked dirty after.
    func layoutContent() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        var y = bounds.maxY

        typealias metrics = WinTheme.Metrics
        y -= metrics.tabStripHeight
        titleBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: metrics.tabStripHeight)

        y -= metrics.addressBarHeight
        addressBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: metrics.addressBarHeight)

        y -= metrics.commandBarHeight
        commandBar.frame = NSRect(x: 0, y: y, width: bounds.width, height: metrics.commandBarHeight)

        let statusHeight = metrics.statusBarHeight
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: statusHeight)

        let contentHeight = y - statusHeight
        navScroll.frame = NSRect(x: 0, y: statusHeight, width: navWidth, height: contentHeight)
        splitter.frame = NSRect(x: navWidth - 2, y: statusHeight, width: 5, height: contentHeight)

        let listX = navWidth + 1
        let listWidth = bounds.width - listX
        // The column header exists only in 详细信息; every other mode gives its
        // strip of height back to the list.
        let headerHeight = columnHeader.isHidden ? 0 : metrics.columnHeaderHeight
        columnHeader.frame = NSRect(x: listX, y: statusHeight + contentHeight - headerHeight,
                                    width: listWidth, height: headerHeight)
        listScroll.frame = NSRect(x: listX, y: statusHeight,
                                  width: listWidth,
                                  height: contentHeight - headerHeight)

        listView.frame.size.width = listWidth
        listView.layoutColumns()
        listView.reload()
        columnHeader.needsDisplay = true
        navPane.frame.size.width = navWidth

        applyLayerOrder()
        for view in [titleBar, addressBar, commandBar, navPane, splitter,
                     columnHeader, statusBar] as [NSView] {
            view.needsDisplay = true
        }
        // Marking the views dirty is not enough on its own here: nothing else
        // ever asks this window to run a display pass, so the bars drew once
        // before the window was composited and then sat blank — visible to hit
        // testing, invisible on screen. The list only looked right because
        // every model update dirtied it again. Asking the window for the pass
        // explicitly is what actually gets the pixels out.
        window?.viewsNeedDisplay = true
    }

    // MARK: - Window events

    func windowDidResize(_ notification: Notification) {
        layoutContent()
        persistState()
    }
    func windowDidChangeBackingProperties(_ notification: Notification) { layoutContent() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        layoutContent()
    }
}

/// Root container.
final class BackdropView: NSView {

    /// Opaque base so any region a child does not cover reads as the window
    /// surface rather than as a transparent hole.
    override func draw(_ dirtyRect: NSRect) {
        WinTheme.windowBackground.setFill()
        dirtyRect.fill()
    }

}

/// Draggable divider between the navigation pane and the file list.
final class SplitterView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        WinTheme.dividerStroke.setFill()
        NSRect(x: 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        // Report movement in window space; the view itself moves under us as
        // the layout updates, so local coordinates would drift.
        let x = superview?.convert(event.locationInWindow, from: nil).x ?? 0
        onDrag?(x - frame.minX - lastX)
    }
}
