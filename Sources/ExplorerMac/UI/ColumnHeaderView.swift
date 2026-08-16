import AppKit

/// The details-view column header strip.
///
/// Explorer's header has no bevel and no background: just labels, a hairline
/// under the row, a hover fill per column, drag handles on the dividers, and a
/// small sort chevron *above* the active column's label rather than beside it.
final class ColumnHeaderView: NSView {

    weak var list: FileListView?

    var onSort: ((SortColumn) -> Void)?
    var onColumnsResized: (() -> Void)?

    private var hoveredColumn = -1
    private var pressedColumn = -1
    /// Index of the divider being dragged, or -1.
    private var draggingDivider = -1
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    private var trackingArea: NSTrackingArea?

    /// Grab margin either side of a divider, in points.
    private let dividerGrab: CGFloat = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var columns: [FileListView.Column] { list?.columns ?? [] }

    override func draw(_ dirtyRect: NSRect) {
        WinTheme.contentBackground.setFill()
        dirtyRect.fill()

        guard let list else { return }
        var x: CGFloat = 0

        for (index, column) in columns.enumerated() {
            let cell = NSRect(x: x, y: 0, width: column.width, height: bounds.height)

            if index == pressedColumn {
                WinTheme.subtlePressed.setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if index == hoveredColumn {
                WinTheme.subtleHover.setFill()
                NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let isActive = list.model?.sortColumn == column.sort
            // The sort indicator sits centred above the label, which is the
            // detail that dates Explorer's header to Vista and survives in 11.
            if isActive {
                let ascending = list.model?.sortAscending ?? true
                let arrowRect = NSRect(x: cell.minX, y: -1, width: cell.width, height: 10)
                WinIcons.draw(ascending ? .chevronUp : .chevronDown, in: arrowRect,
                              color: WinTheme.textSecondary, size: 8)
            }

            let text = NSAttributedString.winText(
                column.title,
                font: FontManager.ui(FontManager.Size.caption),
                color: WinTheme.textSecondary,
                alignment: column.alignment)
            let height = text.size().height
            let inset = cell.insetBy(dx: WinTheme.Metrics.cellPadding, dy: 0)
            text.draw(in: NSRect(x: inset.minX, y: cell.midY - height / 2 + (isActive ? 2 : 0),
                                 width: inset.width, height: height))

            // Divider between columns
            if index < columns.count - 1 {
                WinTheme.dividerStroke.setFill()
                NSRect(x: cell.maxX - 0.5, y: 6, width: 1, height: bounds.height - 12).fill()
            }
            x += column.width
        }

        // Hairline under the whole strip
        WinTheme.dividerStroke.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Hit testing

    private func columnIndex(at point: NSPoint) -> Int {
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() {
            if point.x >= x && point.x < x + column.width { return index }
            x += column.width
        }
        return -1
    }

    /// Returns the index of the column whose right edge is under `point`.
    private func dividerIndex(at point: NSPoint) -> Int {
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() where index < columns.count - 1 {
            x += column.width
            if abs(point.x - x) <= dividerGrab { return index }
        }
        return -1
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
        let point = convert(event.locationInWindow, from: nil)
        if dividerIndex(at: point) >= 0 {
            NSCursor.resizeLeftRight.set()
            if hoveredColumn != -1 { hoveredColumn = -1; needsDisplay = true }
            return
        }
        NSCursor.arrow.set()
        let index = columnIndex(at: point)
        if index != hoveredColumn { hoveredColumn = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        if hoveredColumn != -1 { hoveredColumn = -1; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let divider = dividerIndex(at: point)
        if divider >= 0 {
            draggingDivider = divider
            dragStartX = point.x
            dragStartWidth = columns[divider].width
            return
        }
        pressedColumn = columnIndex(at: point)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggingDivider >= 0, let list else { return }
        let point = convert(event.locationInWindow, from: nil)
        let column = list.columns[draggingDivider]
        let proposed = dragStartWidth + (point.x - dragStartX)
        list.columns[draggingDivider].width = max(column.minWidth, proposed)
        list.layoutColumns()
        needsDisplay = true
        list.needsDisplay = true
        onColumnsResized?()
    }

    override func mouseUp(with event: NSEvent) {
        if draggingDivider >= 0 {
            draggingDivider = -1
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = columnIndex(at: point)
        if index >= 0, index == pressedColumn {
            onSort?(columns[index].sort)
        }
        pressedColumn = -1
        needsDisplay = true
    }

    override func resetCursorRects() {
        var x: CGFloat = 0
        for (index, column) in columns.enumerated() where index < columns.count - 1 {
            x += column.width
            addCursorRect(NSRect(x: x - dividerGrab, y: 0,
                                 width: dividerGrab * 2, height: bounds.height),
                          cursor: .resizeLeftRight)
        }
    }
}
