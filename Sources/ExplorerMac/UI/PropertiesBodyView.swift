import AppKit

/// The classic-dialog body of the 属性 window.
///
/// Everything here follows Win32 conventions rather than the WinUI ones the
/// rest of the app uses: a tab control, etched separator lines, a fixed label
/// column, 13pt checkboxes, and a 75x23 button row anchored bottom-right. The
/// jarring shift in visual language is the point — Explorer's properties sheet
/// really does look like this next to its modern window.
final class PropertiesBodyView: NSView {

    enum Row {
        case value(String, String)
        case separator
        case attributes(readOnly: Bool, hidden: Bool)
    }

    var title = ""
    var icon: NSImage?
    var nameEditable = false { didSet { nameField.isEditable = nameEditable } }
    var name: String {
        get { nameField.stringValue }
        set { nameField.stringValue = newValue }
    }
    var rows: [Row] = [] { didSet { rebuildAttributeState(); needsDisplay = true } }

    var onClose: (() -> Void)?
    var onApply: (() -> Void)?

    /// Current state of the 只读 / 隐藏 checkboxes, or nil when the dialog shows
    /// no attributes row.
    private(set) var attributes: (readOnly: Bool, hidden: Bool)?

    private let nameField = NSTextField()
    private let closeButton = WinCaptionButton(kind: .close)
    private let okButton = WinDialogButton(title: "确定")
    private let cancelButton = WinDialogButton(title: "取消")
    private let applyButton = WinDialogButton(title: "应用(A)")

    private var trackingArea: NSTrackingArea?
    private var hoveredCheckbox = -1

    // Win32 dialog metrics.
    private enum M {
        static let caption: CGFloat = 30
        static let tabStrip: CGFloat = 28
        static let tabWidth: CGFloat = 62
        static let margin: CGFloat = 12
        static let labelColumn: CGFloat = 100
        static let rowHeight: CGFloat = 21
        static let separatorGap: CGFloat = 11
        static let headerHeight: CGFloat = 52
        static let buttonWidth: CGFloat = 84
        static let buttonHeight: CGFloat = 25
        static let buttonRow: CGFloat = 48
        static let checkboxSize: CGFloat = 13
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        nameField.isBordered = true
        nameField.bezelStyle = .squareBezel
        nameField.drawsBackground = true
        nameField.focusRingType = .none
        nameField.font = FontManager.ui(FontManager.Size.body)
        nameField.isEditable = false
        addSubview(nameField)

        addSubview(closeButton)
        closeButton.onClick = { [weak self] in self?.onClose?() }

        okButton.onClick = { [weak self] in self?.onApply?() }
        cancelButton.onClick = { [weak self] in self?.onClose?() }
        applyButton.onClick = { [weak self] in self?.onApply?() }
        for button in [okButton, cancelButton, applyButton] { addSubview(button) }

        for view in subviews {
            view.wantsLayer = true
            view.layer?.zPosition = 2
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func rebuildAttributeState() {
        for row in rows {
            if case let .attributes(readOnly, hidden) = row {
                attributes = (readOnly, hidden)
                return
            }
        }
        attributes = nil
    }

    /// Replaces the text of the row carrying `label`, used while a folder's
    /// size is still being totalled.
    func updateValue(for label: String, to text: String) {
        for (index, row) in rows.enumerated() {
            if case let .value(rowLabel, _) = row, rowLabel == label {
                rows[index] = .value(rowLabel, text)
                needsDisplay = true
                return
            }
        }
    }

    /// Height needed to show every row without slack. The Win32 dialog sizes
    /// itself to its content rather than leaving a gap above the buttons.
    var preferredHeight: CGFloat {
        let rowsHeight = rows.reduce(CGFloat.zero) { total, row in
            switch row {
            case .separator: return total + M.separatorGap
            case .value, .attributes: return total + M.rowHeight
            }
        }
        return M.caption + M.tabStrip + M.margin + M.headerHeight
            + rowsHeight + M.margin + M.buttonRow
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.maxX - WinTheme.Metrics.captionButtonWidth, y: 0,
                                   width: WinTheme.Metrics.captionButtonWidth, height: M.caption)

        let panel = panelRect
        nameField.frame = NSRect(x: panel.minX + M.margin + 44,
                                 y: panel.minY + M.margin + 6,
                                 width: panel.width - M.margin * 2 - 44, height: 22)

        let y = bounds.maxY - M.buttonRow + (M.buttonRow - M.buttonHeight) / 2
        var x = bounds.maxX - M.margin - M.buttonWidth
        for button in [applyButton, cancelButton, okButton] {
            button.frame = NSRect(x: x, y: y, width: M.buttonWidth, height: M.buttonHeight)
            x -= M.buttonWidth + 6
        }
    }

    private var panelRect: NSRect {
        NSRect(x: M.margin,
               y: M.caption + M.tabStrip,
               width: bounds.width - M.margin * 2,
               height: bounds.height - M.caption - M.tabStrip - M.buttonRow)
    }

    private var contentOrigin: CGFloat {
        panelRect.minY + M.margin + M.headerHeight
    }

    private func rowFrames() -> [(row: Row, rect: NSRect)] {
        var result: [(Row, NSRect)] = []
        var y = contentOrigin
        let panel = panelRect
        for row in rows {
            let height: CGFloat
            switch row {
            case .separator: height = M.separatorGap
            case .value, .attributes: height = M.rowHeight
            }
            result.append((row, NSRect(x: panel.minX + M.margin, y: y,
                                       width: panel.width - M.margin * 2, height: height)))
            y += height
        }
        return result
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        WinTheme.dialogBackground.setFill()
        bounds.fill()

        drawCaption()
        drawTabStrip()
        drawPanel()

        for (row, rect) in rowFrames() {
            switch row {
            case let .value(label, text): drawValueRow(label, text, in: rect)
            case .separator: drawEtchedLine(y: rect.midY, in: rect)
            case let .attributes(readOnly, hidden):
                drawAttributes(readOnly: readOnly, hidden: hidden, in: rect)
            }
        }
    }

    private func drawCaption() {
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: M.caption)
        WinTheme.dialogBackground.setFill()
        rect.fill()
        let text = NSAttributedString.winText(
            title, font: FontManager.ui(FontManager.Size.body), color: WinTheme.textPrimary)
        let height = text.size().height
        text.draw(in: NSRect(x: M.margin, y: rect.midY - height / 2,
                             width: rect.width - M.margin - 60, height: height))
    }

    /// A single 常规 tab. Windows shows 安全 / 详细信息 / 以前的版本 alongside it;
    /// drawing tabs for panes that do not exist would be a lie.
    private func drawTabStrip() {
        let strip = NSRect(x: M.margin, y: M.caption, width: bounds.width - M.margin * 2,
                           height: M.tabStrip)
        let tab = NSRect(x: strip.minX, y: strip.minY + 4,
                         width: M.tabWidth, height: strip.height - 4)

        WinTheme.dialogPanel.setFill()
        NSBezierPath(roundedRect: tab, xRadius: 3, yRadius: 3).fill()
        WinTheme.dialogStroke.setStroke()
        let outline = NSBezierPath(roundedRect: tab.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        outline.stroke()

        let text = NSAttributedString.winText(
            "常规", font: FontManager.ui(FontManager.Size.body),
            color: WinTheme.textPrimary, alignment: .center)
        let height = text.size().height
        text.draw(in: NSRect(x: tab.minX, y: tab.midY - height / 2 + 1,
                             width: tab.width, height: height))
    }

    private func drawPanel() {
        let panel = panelRect
        WinTheme.dialogPanel.setFill()
        panel.fill()
        WinTheme.dialogStroke.setStroke()
        let outline = NSBezierPath(rect: panel.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        // The tab sits flush against the panel, so its bottom edge is erased.
        WinTheme.dialogPanel.setFill()
        NSRect(x: panel.minX + 1, y: panel.minY - 1, width: M.tabWidth - 2, height: 2).fill()

        if let icon {
            icon.draw(in: NSRect(x: panel.minX + M.margin, y: panel.minY + M.margin,
                                 width: 32, height: 32),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        drawEtchedLine(y: panel.minY + M.margin + 44,
                       in: NSRect(x: panel.minX + M.margin, y: 0,
                                  width: panel.width - M.margin * 2, height: 0))
    }

    private func drawValueRow(_ label: String, _ text: String, in rect: NSRect) {
        let font = FontManager.ui(FontManager.Size.body)
        let labelText = NSAttributedString.winText(label, font: font, color: WinTheme.textPrimary)
        let height = labelText.size().height
        labelText.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2,
                                  width: M.labelColumn, height: height))

        let value = NSAttributedString.winText(text, font: font, color: WinTheme.textPrimary)
        value.draw(in: NSRect(x: rect.minX + M.labelColumn, y: rect.midY - height / 2,
                              width: rect.width - M.labelColumn, height: height))
    }

    /// Win32's two-tone etched rule: a dark line with a light one beneath.
    private func drawEtchedLine(y: CGFloat, in rect: NSRect) {
        WinTheme.dialogEtchDark.setFill()
        NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
        WinTheme.dialogEtchLight.setFill()
        NSRect(x: rect.minX, y: y + 1, width: rect.width, height: 1).fill()
    }

    private func checkboxRects(in rect: NSRect) -> [NSRect] {
        [NSRect(x: rect.minX + M.labelColumn, y: rect.midY - M.checkboxSize / 2,
                width: M.checkboxSize, height: M.checkboxSize),
         NSRect(x: rect.minX + M.labelColumn + 96, y: rect.midY - M.checkboxSize / 2,
                width: M.checkboxSize, height: M.checkboxSize)]
    }

    private func drawAttributes(readOnly: Bool, hidden: Bool, in rect: NSRect) {
        let font = FontManager.ui(FontManager.Size.body)
        let label = NSAttributedString.winText("属性:", font: font, color: WinTheme.textPrimary)
        let height = label.size().height
        label.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2,
                              width: M.labelColumn, height: height))

        let boxes = checkboxRects(in: rect)
        for (index, (box, spec)) in zip(boxes, [("只读(R)", readOnly), ("隐藏(H)", hidden)]).enumerated() {
            WinTheme.contentBackground.setFill()
            box.fill()
            (index == hoveredCheckbox ? WinTheme.accent : WinTheme.dialogStroke).setStroke()
            let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()

            if spec.1 {
                WinTheme.textPrimary.setStroke()
                let check = NSBezierPath()
                check.lineWidth = 1.6
                check.move(to: NSPoint(x: box.minX + 2.5, y: box.midY))
                check.line(to: NSPoint(x: box.midX - 0.5, y: box.maxY - 3.5))
                check.line(to: NSPoint(x: box.maxX - 2.5, y: box.minY + 3))
                check.stroke()
            }

            let text = NSAttributedString.winText(spec.0, font: font, color: WinTheme.textPrimary)
            text.draw(in: NSRect(x: box.maxX + 6, y: rect.midY - height / 2,
                                 width: 90, height: height))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func attributesRowRect() -> NSRect? {
        rowFrames().first { if case .attributes = $0.row { return true } else { return false } }?.rect
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var index = -1
        if let rect = attributesRowRect() {
            index = checkboxRects(in: rect).firstIndex { $0.insetBy(dx: -3, dy: -3).contains(point) } ?? -1
        }
        guard index != hoveredCheckbox else { return }
        hoveredCheckbox = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredCheckbox = -1
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Dragging the caption moves the dialog, as it does on Windows.
        if point.y < M.caption, point.x < bounds.maxX - 60 {
            window?.performDrag(with: event)
            return
        }
        guard let rect = attributesRowRect(),
              let index = checkboxRects(in: rect).firstIndex(
                where: { $0.insetBy(dx: -3, dy: -3).contains(point) }),
              var current = attributes else { return }
        if index == 0 { current.readOnly.toggle() } else { current.hidden.toggle() }
        for (position, row) in rows.enumerated() {
            if case .attributes = row {
                rows[position] = .attributes(readOnly: current.readOnly, hidden: current.hidden)
                break
            }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?()          // esc
        case 36, 76: onApply?()      // return
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

/// A Win32 push button: square, 1pt border, flat fill, focus ring on the
/// default action.
final class WinDialogButton: WinControl {

    var title: String
    var isDefault = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        (isPressed ? WinTheme.dialogButtonPressed
            : isHovered ? WinTheme.dialogButtonHover : WinTheme.dialogButton).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        (isHovered ? WinTheme.accent : WinTheme.dialogStroke).setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1
        outline.stroke()

        let text = NSAttributedString.winText(
            title, font: FontManager.ui(FontManager.Size.body),
            color: foregroundColor, alignment: .center)
        let height = text.size().height
        text.draw(in: NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height))
    }
}
