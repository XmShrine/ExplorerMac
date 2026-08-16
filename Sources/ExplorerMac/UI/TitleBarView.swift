import AppKit

/// A browser-style tab, each carrying its own location and history.
final class ExplorerTab {
    var path: String
    var title: String
    var icon: WinIcons.Shell
    var back: [String] = []
    var forward: [String] = []

    init(path: String, title: String, icon: WinIcons.Shell = .folder) {
        self.path = path
        self.title = title
        self.icon = icon
    }
}

/// The Win11 tab strip, which shares its row with the caption buttons.
///
/// Tabs are drawn rather than built from subviews so the active tab's shape —
/// rounded top corners sitting flush against the content below, with no bottom
/// border — comes out right; that silhouette is what makes the strip read as
/// Windows 11 rather than as a generic tab bar.
final class TitleBarView: NSView {

    var tabs: [ExplorerTab] = []
    var activeIndex = 0

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private let minimizeButton = WinCaptionButton(kind: .minimize)
    private let maximizeButton = WinCaptionButton(kind: .maximize)
    private let closeButton = WinCaptionButton(kind: .close)

    private var hoveredTab = -1
    private var hoveredClose = -1
    private var hoveredNew = false
    private var trackingArea: NSTrackingArea?

    private let tabHeight = WinTheme.Metrics.tabStripHeight
    private let tabMaxWidth: CGFloat = 220
    private let tabMinWidth: CGFloat = 120
    private let newTabWidth: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [minimizeButton, maximizeButton, closeButton] { addSubview(button) }
        minimizeButton.onClick = { [weak self] in self?.window?.miniaturize(nil) }
        maximizeButton.onClick = { [weak self] in self?.window?.zoom(nil) }
        closeButton.onClick = { [weak self] in self?.window?.performClose(nil) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Lets the user drag the window by the empty part of the strip, which is
    /// what the real title bar does.
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        let width = WinTheme.Metrics.captionButtonWidth
        let height = WinTheme.Metrics.captionButtonHeight
        let y = (bounds.height - height) / 2
        closeButton.frame = NSRect(x: bounds.maxX - width, y: y, width: width, height: height)
        maximizeButton.frame = NSRect(x: bounds.maxX - width * 2, y: y, width: width, height: height)
        minimizeButton.frame = NSRect(x: bounds.maxX - width * 3, y: y, width: width, height: height)
    }

    private var captionWidth: CGFloat { WinTheme.Metrics.captionButtonWidth * 3 }

    private var tabWidth: CGFloat {
        guard !tabs.isEmpty else { return tabMinWidth }
        let available = bounds.width - captionWidth - newTabWidth - 8
        return max(tabMinWidth, min(tabMaxWidth, available / CGFloat(tabs.count)))
    }

    private func tabRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * tabWidth, y: 0, width: tabWidth, height: tabHeight)
    }

    private func closeRect(_ index: Int) -> NSRect {
        let tab = tabRect(index)
        return NSRect(x: tab.maxX - 28, y: tab.midY - 10, width: 20, height: 20)
    }

    private var newTabRect: NSRect {
        NSRect(x: CGFloat(tabs.count) * tabWidth + 4, y: (tabHeight - 28) / 2,
               width: 28, height: 28)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        for index in tabs.indices { drawTab(index) }

        if hoveredNew {
            WinTheme.subtleHover.setFill()
            NSBezierPath(roundedRect: newTabRect, xRadius: 4, yRadius: 4).fill()
        }
        WinIcons.draw(.add, in: newTabRect, color: WinTheme.textPrimary, size: 12)
    }

    private func drawTab(_ index: Int) {
        let rect = tabRect(index)
        let isActive = index == activeIndex
        let inset = rect.insetBy(dx: 2, dy: 0)

        if isActive {
            // Active tab: content-coloured plate with only its top corners
            // rounded, merging into the address bar below.
            let plate = NSRect(x: inset.minX, y: 4, width: inset.width, height: rect.height - 4)
            let path = NSBezierPath()
            let radius = WinTheme.Metrics.cornerLarge
            path.move(to: NSPoint(x: plate.minX, y: plate.maxY))
            path.line(to: NSPoint(x: plate.minX, y: plate.minY + radius))
            path.appendArc(withCenter: NSPoint(x: plate.minX + radius, y: plate.minY + radius),
                           radius: radius, startAngle: 180, endAngle: 270)
            path.line(to: NSPoint(x: plate.maxX - radius, y: plate.minY))
            path.appendArc(withCenter: NSPoint(x: plate.maxX - radius, y: plate.minY + radius),
                           radius: radius, startAngle: 270, endAngle: 360)
            path.line(to: NSPoint(x: plate.maxX, y: plate.maxY))
            path.close()
            WinTheme.contentBackground.setFill()
            path.fill()
        } else if index == hoveredTab {
            WinTheme.subtleHover.setFill()
            NSBezierPath(roundedRect: inset.insetBy(dx: 0, dy: 4),
                         xRadius: 4, yRadius: 4).fill()
        }

        let tab = tabs[index]
        let iconRect = NSRect(x: inset.minX + 10, y: rect.midY - 8, width: 16, height: 16)
        WinIcons.shell(tab.icon, size: 16).draw(
            in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
            // These views are flipped. The shorter `draw(in:from:operation:fraction:)`
            // overload ignores that and renders every icon upside down — Explorer's
            // folders came out with the tab along the bottom edge.
            respectFlipped: true, hints: nil)

        let textWidth = inset.width - 10 - 16 - 8 - 26
        if textWidth > 8 {
            let text = NSAttributedString.winText(
                tab.title, font: FontManager.ui(FontManager.Size.tab),
                color: isActive ? WinTheme.textPrimary : WinTheme.textSecondary)
            let height = text.size().height
            text.draw(in: NSRect(x: iconRect.maxX + 8, y: rect.midY - height / 2,
                                 width: textWidth, height: height))
        }

        // Close affordance appears on the active tab and on hover only.
        if isActive || index == hoveredTab {
            let close = closeRect(index)
            if index == hoveredClose {
                WinTheme.subtleHover.setFill()
                NSBezierPath(roundedRect: close, xRadius: 4, yRadius: 4).fill()
            }
            WinTheme.textSecondary.setStroke()
            let x = NSBezierPath()
            x.lineWidth = 1
            let c = NSPoint(x: close.midX, y: close.midY)
            x.move(to: NSPoint(x: c.x - 3.5, y: c.y - 3.5))
            x.line(to: NSPoint(x: c.x + 3.5, y: c.y + 3.5))
            x.move(to: NSPoint(x: c.x + 3.5, y: c.y - 3.5))
            x.line(to: NSPoint(x: c.x - 3.5, y: c.y + 3.5))
            x.stroke()
        }

        // Separator between inactive neighbours
        if !isActive, index + 1 != activeIndex, index < tabs.count - 1 {
            WinTheme.dividerStroke.setFill()
            NSRect(x: rect.maxX - 0.5, y: 10, width: 1, height: rect.height - 20).fill()
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

    private func tabIndex(at point: NSPoint) -> Int {
        guard !tabs.isEmpty, point.y < tabHeight else { return -1 }
        let index = Int(floor(point.x / tabWidth))
        return (index >= 0 && index < tabs.count) ? index : -1
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let tab = tabIndex(at: point)
        let close = (tab >= 0 && closeRect(tab).contains(point)) ? tab : -1
        let new = newTabRect.contains(point)
        guard tab != hoveredTab || close != hoveredClose || new != hoveredNew else { return }
        hoveredTab = tab
        hoveredClose = close
        hoveredNew = new
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTab = -1; hoveredClose = -1; hoveredNew = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if newTabRect.contains(point) { onNewTab?(); return }
        let index = tabIndex(at: point)
        guard index >= 0 else {
            // Empty strip area: double-click zooms, drag moves the window.
            if event.clickCount == 2 { window?.zoom(nil) }
            else { window?.performDrag(with: event) }
            return
        }
        if closeRect(index).contains(point) { onCloseTab?(index); return }
        onSelectTab?(index)
    }
}
