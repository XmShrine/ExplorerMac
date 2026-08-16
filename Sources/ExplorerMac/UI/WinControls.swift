import AppKit

/// Base class giving every custom control the hover/press tracking WinUI
/// controls rely on. AppKit has no built-in hover state, and Explorer's whole
/// command surface is built out of subtle-fill buttons that only exist on
/// hover, so this has to be wired by hand once and reused.
class WinControl: NSView {

    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }

    private(set) var isHovered = false { didSet { needsDisplay = true } }
    private(set) var isPressed = false { didSet { needsDisplay = true } }

    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        guard isEnabled, wasPressed,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// WinUI's layered fill: nothing at rest, `SubtleFillColorSecondary` on
    /// hover, `SubtleFillColorTertiary` while held.
    func drawSubtleBackground(_ rect: NSRect, radius: CGFloat = WinTheme.Metrics.cornerSmall) {
        guard isEnabled else { return }
        let fill: NSColor?
        if isPressed { fill = WinTheme.subtlePressed }
        else if isHovered { fill = WinTheme.subtleHover }
        else { fill = nil }
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    var foregroundColor: NSColor {
        isEnabled ? WinTheme.textPrimary : WinTheme.textDisabled
    }
}

/// A command-bar / address-bar button: a Fluent glyph, optionally with a label
/// and a dropdown chevron.
final class WinGlyphButton: WinControl {

    var glyph: WinIcons.Glyph
    var label: String?
    var showsChevron = false
    var glyphSize: CGFloat = FontManager.Size.glyph
    /// Explorer tints only the "新建" button's glyph with the accent colour.
    var accentGlyph = false

    init(glyph: WinIcons.Glyph, label: String? = nil, showsChevron: Bool = false) {
        self.glyph = glyph
        self.label = label
        self.showsChevron = showsChevron
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Explorer sizes these to their content: 36pt square when icon-only, and
    /// icon + text + padding when labelled.
    var intrinsicWidth: CGFloat {
        var width: CGFloat = 36
        if let label, !label.isEmpty {
            let measured = NSAttributedString(
                string: label,
                attributes: [.font: FontManager.ui(FontManager.Size.body)]).size().width
            width = 8 + glyphSize + 6 + ceil(measured) + 10
        }
        if showsChevron { width += 14 }
        return width
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: intrinsicWidth, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSubtleBackground(bounds)

        let color = foregroundColor
        var x: CGFloat = 0

        if label == nil {
            WinIcons.draw(glyph, in: bounds, color: accentGlyph ? WinTheme.accent : color,
                          size: glyphSize)
            x = bounds.maxX
        } else {
            let glyphBox = NSRect(x: 8, y: 0, width: glyphSize, height: bounds.height)
            WinIcons.draw(glyph, in: glyphBox, color: accentGlyph ? WinTheme.accent : color,
                          size: glyphSize)
            x = glyphBox.maxX + 6

            let text = NSAttributedString.winText(
                label!, font: FontManager.ui(FontManager.Size.body), color: color)
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x += size.width + 4
        }

        if showsChevron {
            let box = NSRect(x: bounds.maxX - 16, y: 0, width: 12, height: bounds.height)
            WinIcons.draw(.chevronDown, in: box, color: color, size: FontManager.Size.glyphSmall)
        }
    }
}

/// The ─ □ × cluster. Windows sizes these 46x32 and turns only close red.
final class WinCaptionButton: WinControl {

    enum Kind { case minimize, maximize, close }
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: WinTheme.Metrics.captionButtonWidth,
               height: WinTheme.Metrics.captionButtonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Caption buttons fill square to the window edge — no rounding, unlike
        // every other button in the app.
        if kind == .close {
            if isPressed { WinTheme.closePressed.setFill(); bounds.fill() }
            else if isHovered { WinTheme.closeHover.setFill(); bounds.fill() }
        } else {
            drawSubtleBackground(bounds, radius: 0)
        }

        let color: NSColor = (kind == .close && (isHovered || isPressed))
            ? .white : WinTheme.textPrimary
        color.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 1
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        // Half-pixel offsets keep these hairlines from landing between device
        // pixels and going soft, which is very visible at this size.
        let px: CGFloat = 0.5

        switch kind {
        case .minimize:
            path.move(to: NSPoint(x: c.x - 5, y: floor(c.y) + px))
            path.line(to: NSPoint(x: c.x + 5, y: floor(c.y) + px))
        case .maximize:
            let r = NSRect(x: floor(c.x - 5) + px, y: floor(c.y - 5) + px, width: 10, height: 10)
            path.appendRect(r)
        case .close:
            path.move(to: NSPoint(x: c.x - 5, y: c.y - 5))
            path.line(to: NSPoint(x: c.x + 5, y: c.y + 5))
            path.move(to: NSPoint(x: c.x + 5, y: c.y - 5))
            path.line(to: NSPoint(x: c.x - 5, y: c.y + 5))
        }
        path.stroke()
    }
}

/// One breadcrumb segment in the address bar, plus its trailing chevron.
final class WinCrumbButton: WinControl {

    var title: String
    var isLast: Bool
    var showsChevron: Bool
    /// Fires when the chevron itself is clicked, which in Explorer opens a
    /// sibling-folder dropdown rather than navigating.
    var onChevronClick: (() -> Void)?

    private var chevronHovered = false

    init(title: String, isLast: Bool, showsChevron: Bool = true) {
        self.title = title
        self.isLast = isLast
        self.showsChevron = showsChevron
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var titleWidth: CGFloat {
        ceil(NSAttributedString(string: title,
                                attributes: [.font: FontManager.ui(FontManager.Size.addressBar)])
            .size().width)
    }

    var chevronWidth: CGFloat { showsChevron ? 20 : 0 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titleWidth + 16 + chevronWidth, height: 24)
    }

    private var textRect: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width - chevronWidth, height: bounds.height)
    }
    private var chevronRect: NSRect {
        NSRect(x: bounds.width - chevronWidth, y: 0, width: chevronWidth, height: bounds.height)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inChevron = chevronRect.contains(point)
        if inChevron != chevronHovered { chevronHovered = inChevron; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let wasPressed = isPressed
        super.mouseUp(with: event)
        if wasPressed, showsChevron, chevronRect.contains(point) { onChevronClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Hovering a crumb highlights the name and its chevron separately.
        if isHovered {
            let target = chevronHovered ? chevronRect : textRect
            (isPressed ? WinTheme.subtlePressed : WinTheme.subtleHover).setFill()
            NSBezierPath(roundedRect: target,
                         xRadius: WinTheme.Metrics.cornerSmall,
                         yRadius: WinTheme.Metrics.cornerSmall).fill()
        }

        let text = NSAttributedString.winText(
            title,
            font: FontManager.ui(FontManager.Size.addressBar),
            color: WinTheme.textPrimary)
        let size = text.size()
        text.draw(at: NSPoint(x: 8, y: (bounds.height - size.height) / 2))

        if showsChevron {
            WinIcons.draw(.chevronRight, in: chevronRect,
                          color: WinTheme.textSecondary, size: FontManager.Size.glyphSmall)
        }
    }
}
