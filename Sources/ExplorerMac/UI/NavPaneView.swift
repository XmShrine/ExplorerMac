import AppKit

/// One entry in the navigation tree.
final class NavNode {
    var title: String
    var icon: WinIcons.Shell
    /// Some nav entries (主页, 网络) are Fluent glyphs in Explorer rather than
    /// shell icons; when set this wins over `icon`.
    var glyph: WinIcons.Glyph?
    var path: String?
    var children: [NavNode]
    var isExpanded: Bool
    var isExpandable: Bool
    /// Explorer draws a thin separator above certain group headers.
    var startsGroup: Bool
    /// Pinned Quick Access items carry a pin glyph on the trailing edge.
    var isPinned: Bool
    /// Filled lazily the first time the node is expanded.
    var childrenLoaded: Bool

    init(title: String, icon: WinIcons.Shell, glyph: WinIcons.Glyph? = nil, path: String? = nil,
         children: [NavNode] = [], isExpanded: Bool = false,
         isExpandable: Bool = false, startsGroup: Bool = false,
         isPinned: Bool = false, childrenLoaded: Bool = true) {
        self.title = title
        self.icon = icon
        self.glyph = glyph
        self.path = path
        self.children = children
        self.isExpanded = isExpanded
        self.isExpandable = isExpandable
        self.startsGroup = startsGroup
        self.isPinned = isPinned
        self.childrenLoaded = childrenLoaded
    }
}

/// Explorer's left navigation pane.
///
/// Same direct-draw approach as the file list. The pane's visual signature is
/// the selected item: a rounded plate plus a short accent bar pinned to the
/// left edge, which is a WinUI `NavigationViewItem` and looks nothing like an
/// `NSOutlineView` row.
final class NavPaneView: NSView {

    private(set) var roots: [NavNode] = []
    /// Flattened visible rows, rebuilt on every expand/collapse.
    private var rows: [(node: NavNode, depth: Int)] = []

    var selectedPath: String?
    var onSelect: ((NavNode) -> Void)?
    /// Asked to supply children when a node is expanded for the first time.
    var childProvider: ((NavNode) -> [NavNode])?
    /// A drop landed on one of the pane's folders.
    var onDrop: ((_ urls: [URL], _ destination: String, _ isCopy: Bool) -> Void)?

    private var hoveredRow = -1
    private var pressedRow = -1
    /// Row highlighted as a drop target, or -1.
    private var dropRow = -1
    private var trackingArea: NSTrackingArea?

    private let rowHeight = WinTheme.Metrics.navRowHeight

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func setRoots(_ nodes: [NavNode]) {
        roots = nodes
        rebuild()
    }

    /// Recomputes the flat row list from the expanded state of the tree.
    func rebuild() {
        rows.removeAll(keepingCapacity: true)
        func visit(_ node: NavNode, depth: Int) {
            rows.append((node, depth))
            guard node.isExpanded else { return }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for root in roots { visit(root, depth: 0) }
        frame.size.height = max(CGFloat(rows.count) * rowHeight + 8, bounds.height)
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(rows.count) * rowHeight + 8)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The pane sits directly on the window's mica surface with no fill of
        // its own, which is why it reads as translucent in Explorer.
        let first = max(0, Int(floor((dirtyRect.minY - 4) / rowHeight)))
        let last = min(rows.count - 1, Int(ceil((dirtyRect.maxY - 4) / rowHeight)))
        guard first <= last, !rows.isEmpty else { return }

        for index in first...last {
            drawRow(index)
        }
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: 4 + CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    private func drawRow(_ index: Int) {
        let (node, depth) = rows[index]
        let rect = rowRect(index)
        let isSelected = node.path != nil && node.path == selectedPath

        if node.startsGroup {
            WinTheme.dividerStroke.setFill()
            NSRect(x: 12, y: rect.minY - 1, width: bounds.width - 24, height: 1).fill()
        }

        let plate = NSRect(x: 4, y: rect.minY + 2, width: bounds.width - 8, height: rect.height - 4)
        if index == dropRow {
            WinTheme.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        } else if isSelected {
            WinTheme.subtleSelected.setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
            // Accent indicator: 3pt wide, vertically inset, fully rounded.
            WinTheme.accent.setFill()
            let bar = NSRect(x: plate.minX, y: plate.midY - 8, width: 3, height: 16)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        } else if index == pressedRow {
            WinTheme.subtlePressed.setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        } else if index == hoveredRow {
            WinTheme.subtleHover.setFill()
            NSBezierPath(roundedRect: plate, xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        }

        let indent = 12 + CGFloat(depth) * WinTheme.Metrics.navIndent
        let chevronBox = NSRect(x: indent, y: rect.minY, width: 16, height: rect.height)
        if node.isExpandable {
            WinIcons.draw(node.isExpanded ? .chevronDown : .chevronRight,
                          in: chevronBox, color: WinTheme.textSecondary, size: 8)
        }

        let iconRect = NSRect(x: chevronBox.maxX + 4, y: rect.midY - 8, width: 16, height: 16)
        if let glyph = node.glyph {
            WinIcons.draw(glyph, in: iconRect, color: WinTheme.textPrimary, size: 15)
        } else {
            WinIcons.shell(node.icon, size: 16).draw(
                in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
            // These views are flipped. The shorter `draw(in:from:operation:fraction:)`
            // overload ignores that and renders every icon upside down — Explorer's
            // folders came out with the tab along the bottom edge.
            respectFlipped: true, hints: nil)
        }

        var textWidth = bounds.width - iconRect.maxX - 18
        if node.isPinned { textWidth -= 18 }
        let text = NSAttributedString.winText(
            node.title, font: FontManager.ui(FontManager.Size.body),
            color: WinTheme.textPrimary)
        let height = text.size().height
        text.draw(in: NSRect(x: iconRect.maxX + 8, y: rect.midY - height / 2,
                             width: max(0, textWidth), height: height))

        if node.isPinned {
            let pinRect = NSRect(x: bounds.width - 26, y: rect.minY, width: 16, height: rect.height)
            WinIcons.draw(.pin, in: pinRect, color: WinTheme.textTertiary, size: 12)
        }
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

    private func rowIndex(at point: NSPoint) -> Int {
        let index = Int(floor((point.y - 4) / rowHeight))
        return (index >= 0 && index < rows.count) ? index : -1
    }

    private func invalidateRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        setNeedsDisplay(rowRect(index))
    }

    override func mouseMoved(with event: NSEvent) {
        let index = rowIndex(at: convert(event.locationInWindow, from: nil))
        guard index != hoveredRow else { return }
        invalidateRow(hoveredRow)
        hoveredRow = index
        invalidateRow(hoveredRow)
    }

    override func mouseExited(with event: NSEvent) {
        invalidateRow(hoveredRow)
        hoveredRow = -1
    }

    override func mouseDown(with event: NSEvent) {
        pressedRow = rowIndex(at: convert(event.locationInWindow, from: nil))
        invalidateRow(pressedRow)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = rowIndex(at: point)
        let wasPressed = pressedRow
        pressedRow = -1
        invalidateRow(wasPressed)
        guard index >= 0, index == wasPressed else { return }

        let (node, depth) = rows[index]
        let indent = 12 + CGFloat(depth) * WinTheme.Metrics.navIndent

        // Clicking the chevron toggles; clicking anywhere else navigates.
        if node.isExpandable, point.x >= indent, point.x < indent + 16 {
            toggle(node)
            return
        }
        if let path = node.path {
            selectedPath = path
            needsDisplay = true
            onSelect?(node)
        } else if node.isExpandable {
            toggle(node)
        }
    }

    func toggle(_ node: NavNode) {
        if !node.isExpanded, !node.childrenLoaded {
            node.children = childProvider?(node) ?? []
            node.childrenLoaded = true
        }
        node.isExpanded.toggle()
        rebuild()
    }

    /// Highlights the row matching `path` without firing `onSelect`.
    func syncSelection(to path: String) {
        selectedPath = path
        needsDisplay = true
    }
}

/// Dropping onto a place in the tree.
///
/// Explorer treats the navigation pane as a set of drop targets with the same
/// copy/move rules as the list, which is how "drag this into 下载" works without
/// navigating there first.
extension NavPaneView {

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = DropRules.urls(from: sender)
        let point = convert(sender.draggingLocation, from: nil)
        let index = rowIndex(at: point)
        guard !urls.isEmpty, index >= 0, let destination = rows[index].node.path else {
            setDropRow(-1)
            return []
        }

        var isCopy = DropRules.isCopy(sources: urls, destination: destination,
                                      modifiers: NSEvent.modifierFlags)
        let allowed = sender.draggingSourceOperationMask
        if isCopy, !allowed.contains(.copy), allowed.contains(.move) { isCopy = false }
        if !isCopy, !allowed.contains(.move), allowed.contains(.copy) { isCopy = true }

        guard DropRules.canDrop(sources: urls, destination: destination, isCopy: isCopy) else {
            setDropRow(-1)
            return []
        }
        setDropRow(index)
        return isCopy ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { setDropRow(-1) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropRow(-1) }
        let urls = DropRules.urls(from: sender)
        let point = convert(sender.draggingLocation, from: nil)
        let index = rowIndex(at: point)
        guard !urls.isEmpty, index >= 0, let destination = rows[index].node.path else {
            return false
        }
        let isCopy = DropRules.isCopy(sources: urls, destination: destination,
                                      modifiers: NSEvent.modifierFlags)
        guard DropRules.canDrop(sources: urls, destination: destination, isCopy: isCopy) else {
            return false
        }
        onDrop?(urls, destination, isCopy)
        return true
    }

    private func setDropRow(_ index: Int) {
        guard index != dropRow else { return }
        let previous = dropRow
        dropRow = index
        invalidateRow(previous)
        invalidateRow(index)
    }
}
