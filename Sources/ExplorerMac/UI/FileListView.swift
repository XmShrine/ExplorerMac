import AppKit

/// Explorer's file list, in all eight of its layouts.
///
/// Deliberately not an `NSTableView` or an `NSCollectionView`. Items here are
/// uniform and drawn directly, so there are no row/cell view objects at all —
/// scrolling a 500k-entry listing allocates nothing and repaints only the cells
/// that intersect the dirty rect. It also means every pixel is ours, which
/// matters because Explorer's selection is a rounded plate inset from the cell
/// edges, something neither AppKit control can be talked into drawing.
///
/// All geometry comes from `ListLayout`; this file decides what a cell looks
/// like, never where it is.
final class FileListView: NSView {

    struct Column {
        var title: String
        var sort: SortColumn
        var width: CGFloat
        var minWidth: CGFloat
        var alignment: NSTextAlignment
        /// The name column absorbs leftover width the way Explorer's does.
        var isFlexible: Bool
        /// Search results replace the 类型 column with 文件夹路径, so this cell
        /// renders the entry's own directory instead.
        var showsPath = false
    }

    var columns: [Column] = [
        Column(title: "名称", sort: .name, width: 320, minWidth: 120, alignment: .left, isFlexible: true),
        Column(title: "修改日期", sort: .modified, width: 150, minWidth: 90, alignment: .left, isFlexible: false),
        Column(title: "类型", sort: .type, width: 130, minWidth: 70, alignment: .left, isFlexible: false),
        Column(title: "大小", sort: .size, width: 100, minWidth: 60, alignment: .right, isFlexible: false),
    ]

    var model: DirectoryModel?
    var rowHeight: CGFloat = WinTheme.Metrics.rowHeight

    var viewMode: ViewMode = .details {
        didSet {
            guard viewMode != oldValue else { return }
            cancelRename()
            // The icon ladder means a mode switch needs different-sized
            // thumbnails; the old ones are the wrong resolution entirely.
            ThumbnailProvider.shared.invalidateAll()
            reload()
            scroll(.zero)
        }
    }

    private(set) var selection: Set<Int> = []
    private var selectionAnchor: Int?
    private var hoveredRow: Int = -1

    var onOpen: ((FileEntry) -> Void)?
    var onSelectionChanged: (() -> Void)?
    var onSortRequested: ((SortColumn) -> Void)?
    var onContextMenu: ((FileEntry?, NSEvent) -> Void)?
    /// Fires when an inline rename is committed with a new, non-empty name.
    var onRename: ((FileEntry, String) -> Void)?
    /// Keyboard verbs the controller owns; `permanent` distinguishes
    /// Shift+Delete from a plain Delete.
    var onDelete: ((_ permanent: Bool) -> Void)?
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    /// A drop landed: the files, the folder they should end up in, and whether
    /// it is a copy or a move.
    var onDrop: ((_ urls: [URL], _ destination: String, _ isCopy: Bool) -> Void)?

    /// Paths sitting on the clipboard as a pending move, drawn dimmed the way
    /// Explorer shows them between 剪切 and 粘贴.
    var cutPaths: Set<String> = [] { didSet { needsDisplay = true } }
    /// Absolute path of the directory being listed, for building full paths.
    var directoryPath: String = ""

    /// Full path of an entry, honouring the per-entry directory search results
    /// carry.
    func fullPath(for entry: FileEntry) -> String {
        ((entry.directory ?? directoryPath) as NSString)
            .appendingPathComponent(entry.name)
    }

    private var renameEditor: NSTextField?
    private var renamingRow = -1

    private var trackingArea: NSTrackingArea?

    // Mouse state shared with the drag-and-drop extension.
    /// Item the mouse went down on, if a drag could start from it.
    var pressedItem = -1
    var mouseDownPoint: NSPoint = .zero
    /// Set when the press landed on an already-selected item: Explorer waits
    /// for mouse-up to collapse a multi-selection so the whole group can be
    /// dragged.
    var pendingSelectionCollapse = false
    /// Item currently highlighted as a drop target, or -1 for the whole list.
    var dropTarget: Int = -1
    var isDropTargetActive = false

    /// Marquee ("rubber band") selection state.
    private var marqueeOrigin: NSPoint?
    private var marqueeRect: NSRect = .zero
    private var marqueeBase: Set<Int> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var entries: [FileEntry] { model?.entries ?? [] }

    // MARK: - Layout

    /// Visible area of the scroll clip, which is what the wrapping views wrap
    /// against — the view's own bounds grow to the content and would feed the
    /// layout back its own output.
    private var viewport: NSSize {
        enclosingScrollView?.contentView.bounds.size ?? bounds.size
    }

    var layout: ListLayout {
        ListLayout(mode: viewMode, count: entries.count,
                   viewport: viewport, rowHeight: rowHeight)
    }

    /// Recomputes the flexible column's width so the set exactly fills the view.
    func layoutColumns() {
        let fixed = columns.filter { !$0.isFlexible }.reduce(0) { $0 + $1.width }
        guard let index = columns.firstIndex(where: { $0.isFlexible }) else { return }
        columns[index].width = max(columns[index].minWidth, bounds.width - fixed)
    }

    func columnX(_ index: Int) -> CGFloat {
        columns.prefix(index).reduce(0) { $0 + $1.width }
    }

    func reload() {
        let size = layout.contentSize
        if frame.size != size { setFrameSize(size) }
        layoutColumns()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { layout.contentSize }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutColumns()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        WinTheme.contentBackground.setFill()
        dirtyRect.fill()

        let list = entries
        guard !list.isEmpty else { return }

        let layout = self.layout
        let focused = window?.firstResponder === self && (window?.isKeyWindow ?? false)

        // Only touch cells intersecting the dirty rect — this is what keeps
        // scrolling flat regardless of how many entries the directory holds.
        for index in layout.indices(in: dirtyRect) where index < list.count {
            drawItem(index, entry: list[index], layout: layout, focused: focused)
        }

        drawMarquee()

        // A drop onto the folder being viewed highlights the whole surface,
        // since there is no single cell to point at.
        if isDropTargetActive, dropTarget < 0 {
            WinTheme.accent.withAlphaComponent(0.6).setStroke()
            let border = NSBezierPath(rect: visibleRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
        }
    }

    private func drawItem(_ index: Int, entry: FileEntry, layout: ListLayout, focused: Bool) {
        let box = layout.rect(for: index)
        let isSelected = selection.contains(index)

        // Win11 draws the selection as an inset rounded plate, not a full-bleed
        // bar, and does not alternate row colours.
        let plate: NSRect
        switch viewMode.flow {
        case .rows: plate = box.insetBy(dx: 4, dy: 2)
        case .grid, .columns:
            plate = viewMode.isCaptioned ? layout.hitRect(for: index) : box.insetBy(dx: 2, dy: 1)
        }
        if index == dropTarget && isDropTargetActive {
            WinTheme.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        } else if isSelected {
            (focused ? WinTheme.subtleSelected : WinTheme.subtleHover).setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        } else if index == hoveredRow {
            WinTheme.subtleHover.setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        }

        // Cut items keep their place but render at reduced opacity.
        let isCut = !cutPaths.isEmpty && cutPaths.contains(fullPath(for: entry))
        let color = isCut ? WinTheme.textDisabled : WinTheme.textPrimary
        let alpha: CGFloat = isCut ? 0.4 : 1

        switch viewMode {
        case .details:
            drawDetailsRow(entry, index: index, in: box, color: color, iconAlpha: alpha)
        case .content:
            drawContentRow(entry, index: index, in: box, color: color, iconAlpha: alpha)
        case .tile:
            drawTile(entry, index: index, in: box, color: color, iconAlpha: alpha)
        case .smallIcons, .list:
            drawCompactCell(entry, index: index, in: box, color: color, iconAlpha: alpha)
        case .extraLargeIcons, .largeIcons, .mediumIcons:
            drawCaptionedCell(entry, index: index, in: box, color: color, iconAlpha: alpha)
        }
    }

    // MARK: - Cell renderers

    private func drawDetailsRow(_ entry: FileEntry, index: Int, in rowRect: NSRect,
                                color: NSColor, iconAlpha: CGFloat) {
        var x: CGFloat = 0
        for (column, spec) in columns.enumerated() {
            let cell = NSRect(x: x, y: rowRect.minY, width: spec.width, height: rowRect.height)
            if column == 0 {
                drawIcon(for: entry, index: index,
                         in: NSRect(x: cell.minX + WinTheme.Metrics.cellPadding,
                                    y: cell.midY - WinTheme.Metrics.iconSize / 2,
                                    width: WinTheme.Metrics.iconSize,
                                    height: WinTheme.Metrics.iconSize),
                         alpha: iconAlpha)
                let textX = cell.minX + WinTheme.Metrics.cellPadding
                    + WinTheme.Metrics.iconSize + WinTheme.Metrics.rowIconGap
                drawText(entry.name,
                         in: NSRect(x: textX, y: cell.minY,
                                    width: cell.maxX - textX - 8, height: cell.height),
                         color: color, alignment: .left)
            } else {
                // A truncated path is only useful if the tail survives, so the
                // path column drops characters from the front instead.
                drawText(value(of: spec, for: entry),
                         in: cell.insetBy(dx: WinTheme.Metrics.cellPadding, dy: 0),
                         color: WinTheme.textPrimary, alignment: spec.alignment,
                         lineBreak: spec.showsPath ? .byTruncatingHead : .byTruncatingTail)
            }
            x += spec.width
        }
    }

    /// 内容 view: a full-width band with the name and type on the left, the
    /// date on the right, and a hairline between rows.
    private func drawContentRow(_ entry: FileEntry, index: Int, in box: NSRect,
                                color: NSColor, iconAlpha: CGFloat) {
        let icon = viewMode.iconSize
        drawIcon(for: entry, index: index,
                 in: NSRect(x: box.minX + 16, y: box.midY - icon / 2, width: icon, height: icon),
                 alpha: iconAlpha)

        let textX = box.minX + 16 + icon + 14
        let dateWidth: CGFloat = 150
        let width = max(40, box.maxX - textX - dateWidth - 24)
        drawText(entry.name,
                 in: NSRect(x: textX, y: box.minY + 12, width: width, height: 18),
                 color: color, alignment: .left)
        drawText(secondaryLine(for: entry),
                 in: NSRect(x: textX, y: box.minY + 30, width: width, height: 18),
                 color: WinTheme.textSecondary, alignment: .left)

        drawText(WinFormat.listDateString(entry.modified),
                 in: NSRect(x: box.maxX - dateWidth - 16, y: box.minY + 12,
                            width: dateWidth, height: 18),
                 color: WinTheme.textSecondary, alignment: .right)

        WinTheme.dividerStroke.setFill()
        NSRect(x: box.minX + 16, y: box.maxY - 1, width: box.width - 32, height: 1).fill()
    }

    /// 平铺 view: icon on the left, three stacked lines on the right.
    private func drawTile(_ entry: FileEntry, index: Int, in box: NSRect,
                          color: NSColor, iconAlpha: CGFloat) {
        let icon = viewMode.iconSize
        drawIcon(for: entry, index: index,
                 in: NSRect(x: box.minX + 6, y: box.midY - icon / 2, width: icon, height: icon),
                 alpha: iconAlpha)

        let textX = box.minX + 6 + icon + 10
        let width = max(20, box.maxX - textX - 8)
        drawText(entry.name, in: NSRect(x: textX, y: box.minY + 8, width: width, height: 16),
                 color: color, alignment: .left)
        drawText(FileTypeNamer.name(for: entry),
                 in: NSRect(x: textX, y: box.minY + 24, width: width, height: 16),
                 color: WinTheme.textSecondary, alignment: .left)
        if !entry.isDirectory {
            drawText(WinFormat.listSize(entry),
                     in: NSRect(x: textX, y: box.minY + 40, width: width, height: 16),
                     color: WinTheme.textSecondary, alignment: .left)
        }
    }

    /// 小图标 and 列表: a 16pt icon and one line of text.
    private func drawCompactCell(_ entry: FileEntry, index: Int, in box: NSRect,
                                 color: NSColor, iconAlpha: CGFloat) {
        let icon = viewMode.iconSize
        drawIcon(for: entry, index: index,
                 in: NSRect(x: box.minX + 6, y: box.midY - icon / 2, width: icon, height: icon),
                 alpha: iconAlpha)
        let textX = box.minX + 6 + icon + 8
        drawText(entry.name,
                 in: NSRect(x: textX, y: box.minY, width: max(10, box.maxX - textX - 6),
                            height: box.height),
                 color: color, alignment: .left)
    }

    /// The icon views: a centred icon with the name wrapped underneath.
    private func drawCaptionedCell(_ entry: FileEntry, index: Int, in box: NSRect,
                                   color: NSColor, iconAlpha: CGFloat) {
        let icon = viewMode.iconSize
        let top = box.minY + (viewMode == .extraLargeIcons ? 10 : 8)
        drawIcon(for: entry, index: index,
                 in: NSRect(x: box.midX - icon / 2, y: top, width: icon, height: icon),
                 alpha: iconAlpha)

        // Explorer shows two lines of name and truncates the second; only the
        // selected item expands to show the whole thing, which is why a long
        // name can be read without renaming it.
        let lines = selection.contains(index) ? 3 : viewMode.labelLines
        let labelRect = NSRect(x: box.minX + 4, y: top + icon + 6,
                               width: box.width - 8, height: 16 * CGFloat(lines))
        // The caption has to wrap first and only then truncate, which needs a
        // *wrapping* line break mode plus `.truncatesLastVisibleLine`. Asking
        // for `.byTruncatingTail` here instead produces a single line with an
        // ellipsis and no wrapping at all.
        let text = NSAttributedString.winText(
            entry.name, font: FontManager.ui(FontManager.Size.body),
            color: color, alignment: .center, lineBreak: .byWordWrapping)
        text.draw(with: labelRect,
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: - Drawing helpers

    private func value(of column: Column, for entry: FileEntry) -> String {
        switch column.sort {
        case .modified: return WinFormat.listDateString(entry.modified)
        case .type:
            return column.showsPath
                ? VolumeMapper.shared.windowsPath(from: entry.directory ?? directoryPath)
                : FileTypeNamer.name(for: entry)
        case .size: return WinFormat.listSize(entry)
        case .name: return entry.name
        }
    }

    private func secondaryLine(for entry: FileEntry) -> String {
        entry.isDirectory
            ? FileTypeNamer.name(for: entry)
            : "\(FileTypeNamer.name(for: entry))  ·  \(WinFormat.listSize(entry))"
    }

    /// A real preview where the file has one, the type icon otherwise. The
    /// request is issued from the draw pass but never waits on it; when the
    /// thumbnail lands, only this cell repaints.
    private func drawIcon(for entry: FileEntry, index: Int, in rect: NSRect, alpha: CGFloat) {
        let url = URL(fileURLWithPath: fullPath(for: entry))
        let preview = ThumbnailProvider.shared.thumbnail(
            for: url, entry: entry, size: rect.width) { [weak self] in
                self?.invalidateRow(index)
            }
        if let preview {
            // A preview keeps its own aspect ratio: Explorer letterboxes a wide
            // photo inside the cell rather than squaring it off.
            preview.draw(in: fit(preview.size, into: rect), from: .zero,
                         operation: .sourceOver, fraction: alpha,
                         respectFlipped: true, hints: nil)
            return
        }
        WinIcons.icon(for: entry, size: rect.width).draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: alpha,
            // These views are flipped. The shorter `draw(in:from:operation:fraction:)`
            // overload ignores that and renders every icon upside down — Explorer's
            // folders came out with the tab along the bottom edge.
            respectFlipped: true, hints: nil)
    }

    private func fit(_ size: NSSize, into rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let box = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2,
                      width: box.width, height: box.height)
    }

    private func drawText(_ string: String, in rect: NSRect,
                          color: NSColor, alignment: NSTextAlignment,
                          lineBreak: NSLineBreakMode = .byTruncatingTail) {
        guard rect.width > 4 else { return }
        let text = NSAttributedString.winText(
            string, font: FontManager.ui(FontManager.Size.body),
            color: color, alignment: alignment, lineBreak: lineBreak)
        let height = text.size().height
        text.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2,
                             width: rect.width, height: height))
    }

    private func drawMarquee() {
        guard marqueeOrigin != nil, marqueeRect.width > 1 || marqueeRect.height > 1 else { return }
        WinTheme.accent.withAlphaComponent(0.2).setFill()
        marqueeRect.fill()
        WinTheme.accent.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: marqueeRect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    // MARK: - Hit testing

    func row(at point: NSPoint) -> Int { layout.index(at: point) }

    /// Repaints one item. Named for the details view it started in; every mode
    /// routes through the layout so the rect is right in all of them.
    func invalidateRow(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        setNeedsDisplay(layout.rect(for: row).insetBy(dx: -2, dy: -2))
    }

    func scrollRowToVisible(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        scrollToVisible(layout.rect(for: row))
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row != hoveredRow else { return }
        invalidateRow(hoveredRow)
        hoveredRow = row
        invalidateRow(hoveredRow)
    }

    override func mouseExited(with event: NSEvent) {
        invalidateRow(hoveredRow)
        hoveredRow = -1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        mouseDownPoint = point
        pressedItem = row
        pendingSelectionCollapse = false

        if row < 0 {
            // Empty space starts a marquee; the existing selection survives
            // until the band actually moves, so a stray click still clears it.
            marqueeOrigin = point
            marqueeRect = NSRect(origin: point, size: .zero)
            marqueeBase = event.modifierFlags.contains(.command) ? selection : []
            if !event.modifierFlags.contains(.command) { setSelection([]) }
            return
        }

        if event.clickCount == 2 {
            onOpen?(entries[row])
            return
        }

        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        if shift, let anchor = selectionAnchor {
            setSelection(Set(min(anchor, row)...max(anchor, row)))
        } else if command {
            var next = selection
            if next.contains(row) { next.remove(row) } else { next.insert(row) }
            selectionAnchor = row
            setSelection(next)
        } else if selection.contains(row) {
            // Pressing inside an existing multi-selection must not collapse it
            // yet — that would make the group undraggable. The collapse happens
            // on mouse-up if no drag started.
            pendingSelectionCollapse = true
            selectionAnchor = row
        } else {
            selectionAnchor = row
            setSelection([row])
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if marqueeOrigin != nil {
            updateMarquee(to: point)
            autoscroll(with: event)
            return
        }

        guard pressedItem >= 0,
              hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y) > 4 else { return }
        pendingSelectionCollapse = false
        beginDrag(with: event)
        pressedItem = -1
    }

    override func mouseUp(with event: NSEvent) {
        if marqueeOrigin != nil {
            marqueeOrigin = nil
            setNeedsDisplay(marqueeRect.insetBy(dx: -2, dy: -2))
            marqueeRect = .zero
            marqueeBase = []
            return
        }
        if pendingSelectionCollapse, pressedItem >= 0 {
            setSelection([pressedItem])
        }
        pendingSelectionCollapse = false
        pressedItem = -1
    }

    private func updateMarquee(to point: NSPoint) {
        guard let origin = marqueeOrigin else { return }
        let old = marqueeRect
        marqueeRect = NSRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                             width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        setSelection(marqueeBase.union(layout.indices(touching: marqueeRect)))
        setNeedsDisplay(old.union(marqueeRect).insetBy(dx: -2, dy: -2))
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selection.contains(row) {
            selectionAnchor = row
            setSelection([row])
        } else if row < 0 {
            setSelection([])
        }
        onContextMenu?(row >= 0 ? entries[row] : nil, event)
    }

    // MARK: - Selection

    func setSelection(_ next: Set<Int>) {
        guard next != selection else { return }
        // Repaint only the items whose state actually flipped.
        let changed = selection.symmetricDifference(next)
        selection = next
        for row in changed { invalidateRow(row) }
        onSelectionChanged?()
    }

    func selectedEntries() -> [FileEntry] {
        let list = entries
        return selection.sorted().compactMap { $0 < list.count ? list[$0] : nil }
    }

    func clearSelection() { setSelection([]) }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let list = entries
        guard !list.isEmpty else { return super.keyDown(with: event); }

        let layout = self.layout
        let current = selection.max() ?? -1
        let shift = event.modifierFlags.contains(.shift)

        func move(to target: Int) {
            let clamped = max(0, min(list.count - 1, target))
            if shift, let anchor = selectionAnchor {
                setSelection(Set(min(anchor, clamped)...max(anchor, clamped)))
            } else {
                selectionAnchor = clamped
                setSelection([clamped])
            }
            scrollRowToVisible(clamped)
        }

        switch event.keyCode {
        case 125: move(to: layout.move(from: current, .down))
        case 126: move(to: current < 0 ? 0 : layout.move(from: current, .up))
        case 123: move(to: current < 0 ? 0 : layout.move(from: current, .left))
        case 124: move(to: layout.move(from: current, .right))
        case 121: move(to: current + layout.pageStep)          // page down
        case 116: move(to: max(0, current - layout.pageStep))  // page up
        case 115: move(to: 0)                                  // home
        case 119: move(to: list.count - 1)                     // end
        case 36, 76:                                           // return / enter
            if let first = selection.min(), first < list.count { onOpen?(list[first]) }
        case 120:                                              // F2 — rename
            if let row = selection.min(), row < list.count { beginRename(row: row) }
        case 117:                                              // forward delete
            if !selection.isEmpty { onDelete?(event.modifierFlags.contains(.shift)) }
        case 51 where event.modifierFlags.contains(.command):  // cmd+backspace
            // Plain Backspace navigates back, as in Explorer; most Mac keyboards
            // have no forward-delete key, so Cmd+Backspace deletes instead.
            if !selection.isEmpty { onDelete?(event.modifierFlags.contains(.shift)) }
        default:
            // Accept both Cmd and Ctrl: Cmd is the muscle memory on Mac
            // hardware, Ctrl is what Explorer documents.
            let flags = event.modifierFlags
            let isCommand = flags.contains(.command) || flags.contains(.control)
            switch (isCommand, event.charactersIgnoringModifiers?.lowercased()) {
            case (true, "a"): setSelection(Set(0..<list.count))
            case (true, "c"): onCopy?()
            case (true, "x"): onCut?()
            case (true, "v"): onPaste?()
            case (true, "z"): flags.contains(.shift) ? onRedo?() : onUndo?()
            case (true, "y"): onRedo?()
            default: super.keyDown(with: event)
            }
        }
    }

    // MARK: - Inline rename

    /// Explorer's rename edits in place over the name and preselects the stem,
    /// so typing replaces the name but keeps the extension.
    func beginRename(row: Int) {
        let list = entries
        guard row >= 0, row < list.count else { return }
        cancelRename()

        let entry = list[row]
        let box = layout.rect(for: row)
        let frame: NSRect
        if viewMode.isCaptioned {
            // Under the icon, where the caption sits.
            let top = box.minY + (viewMode == .extraLargeIcons ? 10 : 8) + viewMode.iconSize + 4
            frame = NSRect(x: box.minX + 2, y: top, width: box.width - 4, height: 20)
        } else if viewMode.flow == .rows {
            let x = WinTheme.Metrics.cellPadding + viewMode.iconSize + WinTheme.Metrics.rowIconGap
            frame = NSRect(x: box.minX + x - 4,
                           y: box.minY + (viewMode == .content ? 8 : 3),
                           width: min((columns.first?.width ?? box.width) - x, 420),
                           height: 22)
        } else {
            let x = box.minX + 6 + viewMode.iconSize + 4
            frame = NSRect(x: x, y: box.minY, width: box.maxX - x - 2, height: box.height)
        }

        let field = NSTextField(frame: frame)
        field.stringValue = entry.name
        field.font = FontManager.ui(FontManager.Size.body)
        field.focusRingType = .none
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = WinTheme.contentBackground
        field.alignment = viewMode.isCaptioned ? .center : .left
        field.delegate = self
        field.target = self
        field.action = #selector(commitRename)
        addSubview(field)
        renameEditor = field
        renamingRow = row

        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let stem = (entry.name as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0,
                                           length: entry.isDirectory ? entry.name.count : stem.count)
        }
    }

    @objc private func commitRename() {
        guard let field = renameEditor, renamingRow >= 0 else { return }
        let list = entries
        let row = renamingRow
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelRename()
        guard row < list.count, !name.isEmpty, name != list[row].name else { return }
        onRename?(list[row], name)
    }

    func cancelRename() {
        renameEditor?.removeFromSuperview()
        renameEditor = nil
        renamingRow = -1
        window?.makeFirstResponder(self)
    }

    var isRenaming: Bool { renameEditor != nil }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

extension FileListView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }
}
