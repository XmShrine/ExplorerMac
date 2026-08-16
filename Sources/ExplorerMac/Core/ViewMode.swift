import AppKit

/// Explorer's eight layouts, in the order the 查看 menu lists them.
///
/// The raw values are persisted, so they must not be renumbered.
enum ViewMode: Int, CaseIterable {
    case extraLargeIcons = 0
    case largeIcons = 1
    case mediumIcons = 2
    case smallIcons = 3
    case list = 4
    case details = 5
    case tile = 6
    case content = 7

    var title: String {
        switch self {
        case .extraLargeIcons: return "超大图标"
        case .largeIcons:      return "大图标"
        case .mediumIcons:     return "中等图标"
        case .smallIcons:      return "小图标"
        case .list:            return "列表"
        case .details:         return "详细信息"
        case .tile:            return "平铺"
        case .content:         return "内容"
        }
    }

    /// Ctrl+Shift+1 … Ctrl+Shift+8, exactly as Windows assigns them.
    var shortcut: String { "Ctrl+Shift+\(rawValue + 1)" }

    /// Explorer's icon ladder: 256 / 96 / 48 / 16, with 平铺 and 内容 sitting on
    /// their own sizes.
    var iconSize: CGFloat {
        switch self {
        case .extraLargeIcons: return 256
        case .largeIcons:      return 96
        case .mediumIcons:     return 48
        case .smallIcons, .list, .details: return 16
        case .tile:            return 48
        case .content:         return 32
        }
    }

    /// How the items flow.
    enum Flow {
        /// One item per line, spanning the full width: 详细信息 and 内容.
        case rows
        /// Left to right, wrapping at the right edge: the icon views, 小图标
        /// and 平铺.
        case grid
        /// Top to bottom, wrapping into a new column at the bottom edge, which
        /// is what makes 列表 the only view that scrolls sideways.
        case columns
    }

    var flow: Flow {
        switch self {
        case .details, .content: return .rows
        case .list:              return .columns
        default:                 return .grid
        }
    }

    /// True where the label sits under a centred icon rather than beside it.
    var isCaptioned: Bool {
        switch self {
        case .extraLargeIcons, .largeIcons, .mediumIcons: return true
        default: return false
        }
    }

    /// Lines of filename the caption shows before truncating.
    var labelLines: Int { isCaptioned ? 2 : 1 }

    /// Cell size for the flowing views. `details` and `content` take their
    /// width from the viewport, so only the height matters there.
    func cellSize(rowHeight: CGFloat) -> NSSize {
        let lineHeight: CGFloat = 16
        switch self {
        case .extraLargeIcons:
            return NSSize(width: 268, height: 256 + 14 + lineHeight * 2 + 8)
        case .largeIcons:
            return NSSize(width: 120, height: 96 + 12 + lineHeight * 2 + 8)
        case .mediumIcons:
            return NSSize(width: 82, height: 48 + 10 + lineHeight * 2 + 8)
        case .smallIcons:
            return NSSize(width: 200, height: 22)
        case .list:
            return NSSize(width: 200, height: 22)
        case .tile:
            // 48pt icon beside three lines: name, type, size.
            return NSSize(width: 268, height: 60)
        case .content:
            return NSSize(width: 0, height: 60)
        case .details:
            return NSSize(width: 0, height: rowHeight)
        }
    }
}

/// Item geometry for whichever view mode is active.
///
/// Kept apart from the view so hit testing, keyboard movement, marquee
/// selection and drawing all read their rectangles from one place — three
/// separate derivations of "where is item n" is how a grid ends up selecting a
/// different cell than the one under the cursor.
struct ListLayout {

    var mode: ViewMode
    var count: Int
    /// Visible size of the scroll clip view, which is what 列表 wraps against.
    var viewport: NSSize
    var rowHeight: CGFloat

    /// Margin around the flowing views. 详细信息 keeps its rows flush to the
    /// edges, as Explorer does.
    private var inset: CGFloat { mode.flow == .rows ? 0 : 8 }

    private var cell: NSSize {
        var size = mode.cellSize(rowHeight: rowHeight)
        if size.width == 0 { size.width = max(1, viewport.width) }
        return size
    }

    /// Items across, for grid flow.
    var columns: Int {
        switch mode.flow {
        case .rows: return 1
        case .grid: return max(1, Int((viewport.width - inset * 2) / cell.width))
        case .columns: return max(1, Int(ceil(Double(count) / Double(rowsPerColumn))))
        }
    }

    /// Items down a single column, for column flow.
    var rowsPerColumn: Int {
        max(1, Int((viewport.height - inset * 2) / cell.height))
    }

    var contentSize: NSSize {
        guard count > 0 else { return viewport }
        switch mode.flow {
        case .rows:
            return NSSize(width: viewport.width,
                          height: max(viewport.height, CGFloat(count) * cell.height))
        case .grid:
            let rows = Int(ceil(Double(count) / Double(columns)))
            return NSSize(width: viewport.width,
                          height: max(viewport.height,
                                      inset * 2 + CGFloat(rows) * cell.height))
        case .columns:
            return NSSize(width: max(viewport.width,
                                     inset * 2 + CGFloat(columns) * cell.width),
                          height: viewport.height)
        }
    }

    /// The cell box, including its padding.
    func rect(for index: Int) -> NSRect {
        let column: Int, row: Int
        switch mode.flow {
        case .rows:
            column = 0; row = index
        case .grid:
            column = index % columns; row = index / columns
        case .columns:
            column = index / rowsPerColumn; row = index % rowsPerColumn
        }
        return NSRect(x: inset + CGFloat(column) * cell.width,
                      y: inset + CGFloat(row) * cell.height,
                      width: cell.width, height: cell.height)
    }

    /// The part of the cell that actually responds to a click — the icon and
    /// its label, not the gap between them. In the icon views Explorer starts a
    /// marquee from the whitespace inside a cell rather than selecting it, and
    /// that only works if hit testing is this tight.
    func hitRect(for index: Int) -> NSRect {
        let box = rect(for: index)
        guard mode.isCaptioned else { return box.insetBy(dx: 1, dy: 1) }
        let icon = mode.iconSize
        return NSRect(x: box.minX + 4, y: box.minY + 4,
                      width: box.width - 8, height: icon + 8 + 16 * CGFloat(mode.labelLines))
    }

    func index(at point: NSPoint) -> Int {
        guard count > 0 else { return -1 }
        let column: Int, row: Int
        switch mode.flow {
        case .rows:
            column = 0
            row = Int(floor((point.y - inset) / cell.height))
        case .grid:
            column = Int(floor((point.x - inset) / cell.width))
            row = Int(floor((point.y - inset) / cell.height))
        case .columns:
            column = Int(floor((point.x - inset) / cell.width))
            row = Int(floor((point.y - inset) / cell.height))
        }
        guard column >= 0, row >= 0 else { return -1 }
        let index: Int
        switch mode.flow {
        case .rows:    index = row
        case .grid:    index = row * columns + column
        case .columns: index = column * rowsPerColumn + row
        }
        guard index >= 0, index < count, hitRect(for: index).contains(point) else { return -1 }
        return index
    }

    /// Indices whose cells intersect `rect`, so drawing and marquee selection
    /// both touch only what they have to.
    func indices(in rect: NSRect) -> [Int] {
        guard count > 0 else { return [] }
        switch mode.flow {
        case .rows:
            let first = max(0, Int(floor((rect.minY - inset) / cell.height)))
            let last = min(count - 1, Int(ceil((rect.maxY - inset) / cell.height)))
            return first <= last ? Array(first...last) : []
        case .grid:
            let firstRow = max(0, Int(floor((rect.minY - inset) / cell.height)))
            let lastRow = Int(ceil((rect.maxY - inset) / cell.height))
            let first = firstRow * columns
            let last = min(count - 1, (lastRow + 1) * columns - 1)
            return first <= last ? Array(first...last) : []
        case .columns:
            let firstColumn = max(0, Int(floor((rect.minX - inset) / cell.width)))
            let lastColumn = Int(ceil((rect.maxX - inset) / cell.width))
            let first = firstColumn * rowsPerColumn
            let last = min(count - 1, (lastColumn + 1) * rowsPerColumn - 1)
            return first <= last ? Array(first...last) : []
        }
    }

    /// Indices whose hit area the marquee rectangle touches.
    func indices(touching rect: NSRect) -> Set<Int> {
        Set(indices(in: rect).filter { hitRect(for: $0).intersects(rect) })
    }

    enum Direction { case up, down, left, right }

    /// Where an arrow key lands. The mapping is not the same in every view:
    /// down moves a full row in a grid but a single item in 列表, which flows
    /// the other way.
    func move(from index: Int, _ direction: Direction) -> Int {
        guard count > 0 else { return -1 }
        guard index >= 0 else { return 0 }
        let step: Int
        switch (mode.flow, direction) {
        case (.rows, .up), (.rows, .left):     step = -1
        case (.rows, .down), (.rows, .right):  step = 1
        case (.grid, .left):   step = -1
        case (.grid, .right):  step = 1
        case (.grid, .up):     step = -columns
        case (.grid, .down):   step = columns
        case (.columns, .up):    step = -1
        case (.columns, .down):  step = 1
        case (.columns, .left):  step = -rowsPerColumn
        case (.columns, .right): step = rowsPerColumn
        }
        return max(0, min(count - 1, index + step))
    }

    /// One screenful, for Page Up / Page Down.
    var pageStep: Int {
        switch mode.flow {
        case .rows:    return max(1, Int(viewport.height / cell.height) - 1)
        case .grid:    return max(1, (Int(viewport.height / cell.height) - 1) * columns)
        case .columns: return max(1, (Int(viewport.width / cell.width) - 1) * rowsPerColumn)
        }
    }
}
