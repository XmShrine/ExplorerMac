import AppKit

/// One row in a Windows 11 context menu.
struct WinMenuItem {
    var title: String = ""
    var glyph: WinIcons.Glyph?
    /// Right-aligned accelerator text, e.g. "Ctrl+Z".
    var shortcut: String?
    var isEnabled = true
    var isChecked = false
    var isSeparator = false
    var submenu: [WinMenuItem]?
    var action: (() -> Void)?

    static var separator: WinMenuItem { WinMenuItem(isSeparator: true) }

    static func item(_ title: String, glyph: WinIcons.Glyph? = nil, shortcut: String? = nil,
                     enabled: Bool = true, checked: Bool = false,
                     action: @escaping () -> Void) -> WinMenuItem {
        WinMenuItem(title: title, glyph: glyph, shortcut: shortcut,
                    isEnabled: enabled, isChecked: checked, action: action)
    }

    static func submenu(_ title: String, glyph: WinIcons.Glyph? = nil,
                        items: [WinMenuItem]) -> WinMenuItem {
        WinMenuItem(title: title, glyph: glyph, submenu: items)
    }
}

/// An icon button in the compact command strip Windows 11 puts at the edge of a
/// context menu — 剪切 / 复制 / 重命名 / 共享 / 删除 for a file, 粘贴 on empty space.
struct WinMenuCommand {
    var glyph: WinIcons.Glyph
    var label: String?
    var isEnabled = true
    var action: () -> Void
}

/// A context menu drawn to match Windows 11.
///
/// `NSMenu` cannot be made to look like this: the menu *window* — its corner
/// radius, background material and padding — belongs to AppKit, so even with
/// fully custom item views the result still reads as macOS. Windows' menu is a
/// different shape (8pt corners against macOS' much rounder ones), tints its
/// glyphs with the accent colour, reserves a right-hand column for
/// accelerators, and carries a strip of icon buttons at one edge. All of that
/// means owning the window.
final class WinMenu: NSObject {

    // Windows 11 flyout metrics at 100% scaling.
    private enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let itemHeight: CGFloat = 34
        static let separatorHeight: CGFloat = 9
        static let verticalPadding: CGFloat = 5
        static let horizontalPadding: CGFloat = 5
        static let glyphColumn: CGFloat = 40      // icon centre sits inside this
        static let textInset: CGFloat = 44
        static let trailingInset: CGFloat = 14
        static let minWidth: CGFloat = 200
        static let maxWidth: CGFloat = 420
        static let shortcutGap: CGFloat = 28
        static let commandRowHeight: CGFloat = 62
        static let commandButtonWidth: CGFloat = 58
    }

    private let items: [WinMenuItem]
    private let commands: [WinMenuCommand]
    private let commandsAtTop: Bool

    private var panel: NSPanel?
    private var content: MenuContentView?
    private var monitors: [Any] = []

    /// Child menu currently open, and the row it belongs to.
    private var submenu: WinMenu?
    private var submenuRow = -1
    private weak var parent: WinMenu?

    private var onClose: (() -> Void)?

    /// The menu lives in its own window, so verifying its rendering means
    /// capturing that window rather than the main one.
    var windowNumber: Int? { panel?.windowNumber }

    init(items: [WinMenuItem], commands: [WinMenuCommand] = [], commandsAtTop: Bool = true) {
        self.items = items
        self.commands = commands
        self.commandsAtTop = commandsAtTop
        super.init()
    }

    // MARK: - Presentation

    /// Shows the menu with its top-left at `point` in screen coordinates,
    /// flipping onto the other side of the cursor when it would run off screen.
    func show(at point: NSPoint, parent: WinMenu? = nil) {
        self.parent = parent

        let size = measure()
        var origin = NSPoint(x: point.x, y: point.y - size.height)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX { origin.x = point.x - size.width }
            if origin.y < visible.minY { origin.y = visible.minY + 4 }
            origin.x = max(visible.minX + 4, origin.x)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let view = MenuContentView(owner: self, items: items,
                                   commands: commands, commandsAtTop: commandsAtTop)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        self.panel = panel
        self.content = view

        panel.orderFrontRegardless()
        installMonitors()
    }

    func close() {
        submenu?.close()
        submenu = nil
        submenuRow = -1
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        content = nil
        onClose?()
    }

    /// Closes this menu and every ancestor, which is what choosing an item does.
    func dismissAll() {
        var root: WinMenu = self
        while let next = root.parent { root = next }
        root.close()
    }

    // MARK: - Event monitoring

    private func installMonitors() {
        // Only the root menu watches; children route through it.
        guard parent == nil else { return }

        let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissAll()
            }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    return self.handleKey(event) ? nil : event
                }
                // A click inside any menu in the chain is handled by that view.
                if self.chainContains(window: event.window) { return event }
                self.dismissAll()
                return nil
            }
        monitors = [outside, local].compactMap { $0 }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func chainContains(window: NSWindow?) -> Bool {
        guard let window else { return false }
        var node: WinMenu? = self
        while let current = node {
            if current.panel === window { return true }
            node = current.submenu
        }
        return false
    }

    /// Routes keys to the deepest open menu.
    private func handleKey(_ event: NSEvent) -> Bool {
        var deepest: WinMenu = self
        while let child = deepest.submenu { deepest = child }
        return deepest.content?.handleKey(event) ?? false
    }

    // MARK: - Submenus

    fileprivate func openSubmenu(_ items: [WinMenuItem], forRow row: Int, rowRect: NSRect) {
        guard row != submenuRow else { return }
        submenu?.close()

        guard let panel else { return }
        let child = WinMenu(items: items)
        child.parent = self
        // Windows overlaps the parent slightly and aligns the first child row
        // with the parent row that opened it.
        let screenPoint = panel.convertPoint(toScreen: NSPoint(
            x: rowRect.maxX - 4,
            y: rowRect.maxY + Metrics.verticalPadding))
        child.show(at: screenPoint, parent: self)
        submenu = child
        submenuRow = row
    }

    fileprivate func closeSubmenu() {
        submenu?.close()
        submenu = nil
        submenuRow = -1
    }

    fileprivate var hasOpenSubmenu: Bool { submenu != nil }

    // MARK: - Measurement

    private func measure() -> NSSize {
        let font = FontManager.ui(FontManager.Size.body)
        var width = Metrics.minWidth
        var height = Metrics.verticalPadding * 2

        for item in items {
            if item.isSeparator {
                height += Metrics.separatorHeight
                continue
            }
            height += Metrics.itemHeight
            var required = Metrics.textInset + Metrics.trailingInset
            required += NSAttributedString(string: item.title, attributes: [.font: font])
                .size().width
            if let shortcut = item.shortcut {
                required += Metrics.shortcutGap
                    + NSAttributedString(string: shortcut,
                                         attributes: [.font: font]).size().width
            }
            if item.submenu != nil { required += 18 }
            width = max(width, ceil(required))
        }

        if !commands.isEmpty {
            height += Metrics.commandRowHeight
            width = max(width, CGFloat(commands.count) * Metrics.commandButtonWidth
                + Metrics.horizontalPadding * 2)
        }
        return NSSize(width: min(width, Metrics.maxWidth), height: height)
    }

    // MARK: - Content view

    fileprivate final class MenuContentView: NSView {

        private unowned let owner: WinMenu
        private let items: [WinMenuItem]
        private let commands: [WinMenuCommand]
        private let commandsAtTop: Bool

        private var hovered = -1
        private var hoveredCommand = -1
        private var trackingArea: NSTrackingArea?
        private var submenuTimer: Timer?

        init(owner: WinMenu, items: [WinMenuItem],
             commands: [WinMenuCommand], commandsAtTop: Bool) {
            self.owner = owner
            self.items = items
            self.commands = commands
            self.commandsAtTop = commandsAtTop
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        // MARK: Geometry

        private var commandRowRect: NSRect {
            guard !commands.isEmpty else { return .zero }
            return commandsAtTop
                ? NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.commandRowHeight)
                : NSRect(x: 0, y: bounds.height - Metrics.commandRowHeight,
                         width: bounds.width, height: Metrics.commandRowHeight)
        }

        private var itemsOrigin: CGFloat {
            (!commands.isEmpty && commandsAtTop ? Metrics.commandRowHeight : 0)
                + Metrics.verticalPadding
        }

        private func rect(forRow row: Int) -> NSRect {
            var y = itemsOrigin
            for (index, item) in items.enumerated() {
                let height = item.isSeparator ? Metrics.separatorHeight : Metrics.itemHeight
                if index == row {
                    return NSRect(x: 0, y: y, width: bounds.width, height: height)
                }
                y += height
            }
            return .zero
        }

        private func row(at point: NSPoint) -> Int {
            var y = itemsOrigin
            for (index, item) in items.enumerated() {
                let height = item.isSeparator ? Metrics.separatorHeight : Metrics.itemHeight
                if point.y >= y, point.y < y + height {
                    return item.isSeparator || !item.isEnabled ? -1 : index
                }
                y += height
            }
            return -1
        }

        private func commandRect(_ index: Int) -> NSRect {
            let row = commandRowRect
            return NSRect(x: Metrics.horizontalPadding
                            + CGFloat(index) * Metrics.commandButtonWidth,
                          y: row.minY + 6,
                          width: Metrics.commandButtonWidth,
                          height: row.height - 12)
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                     xRadius: Metrics.cornerRadius,
                                     yRadius: Metrics.cornerRadius)
            WinTheme.flyoutBackground.setFill()
            shape.fill()
            WinTheme.flyoutStroke.setStroke()
            shape.lineWidth = 1
            shape.stroke()

            for (index, item) in items.enumerated() {
                drawItem(item, row: index)
            }
            if !commands.isEmpty { drawCommandRow() }
        }

        private func drawItem(_ item: WinMenuItem, row: Int) {
            let frame = rect(forRow: row)

            if item.isSeparator {
                WinTheme.dividerStroke.setFill()
                NSRect(x: Metrics.horizontalPadding + 6, y: frame.midY,
                       width: bounds.width - (Metrics.horizontalPadding + 6) * 2,
                       height: 1).fill()
                return
            }

            if row == hovered, item.isEnabled {
                WinTheme.subtleHover.setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: Metrics.horizontalPadding, dy: 2),
                             xRadius: 4, yRadius: 4).fill()
            }

            // Windows tints command glyphs with the accent colour; macOS menus
            // draw them in the label colour, which is the giveaway.
            let glyphColor = item.isEnabled ? WinTheme.accentText : WinTheme.textDisabled
            if let glyph = item.glyph {
                WinIcons.draw(glyph,
                              in: NSRect(x: 0, y: frame.minY,
                                         width: Metrics.glyphColumn, height: frame.height),
                              color: glyphColor, size: 16)
            } else if item.isChecked {
                WinIcons.draw(.checkmark,
                              in: NSRect(x: 0, y: frame.minY,
                                         width: Metrics.glyphColumn, height: frame.height),
                              color: glyphColor, size: 14)
            }

            let textColor = item.isEnabled ? WinTheme.textPrimary : WinTheme.textDisabled
            let title = NSAttributedString.winText(
                item.title, font: FontManager.ui(FontManager.Size.body), color: textColor)
            let titleHeight = title.size().height
            title.draw(in: NSRect(x: Metrics.textInset, y: frame.midY - titleHeight / 2,
                                  width: bounds.width - Metrics.textInset - 40,
                                  height: titleHeight))

            if item.submenu != nil {
                WinIcons.draw(.chevronRight,
                              in: NSRect(x: bounds.width - 28, y: frame.minY,
                                         width: 20, height: frame.height),
                              color: textColor, size: 10)
            } else if let shortcut = item.shortcut {
                let text = NSAttributedString.winText(
                    shortcut, font: FontManager.ui(FontManager.Size.body),
                    color: WinTheme.textTertiary, alignment: .right)
                let height = text.size().height
                text.draw(in: NSRect(x: bounds.width - Metrics.trailingInset - 200,
                                     y: frame.midY - height / 2,
                                     width: 200, height: height))
            }
        }

        private func drawCommandRow() {
            let row = commandRowRect
            // A hairline separates the strip from the list.
            WinTheme.dividerStroke.setFill()
            let lineY = commandsAtTop ? row.maxY - 1 : row.minY
            NSRect(x: Metrics.horizontalPadding + 6, y: lineY,
                   width: bounds.width - (Metrics.horizontalPadding + 6) * 2, height: 1).fill()

            for (index, command) in commands.enumerated() {
                let frame = commandRect(index)
                if index == hoveredCommand, command.isEnabled {
                    WinTheme.subtleHover.setFill()
                    NSBezierPath(roundedRect: frame.insetBy(dx: 3, dy: 0),
                                 xRadius: 4, yRadius: 4).fill()
                }
                let color = command.isEnabled ? WinTheme.accentText : WinTheme.textDisabled
                let hasLabel = command.label != nil
                let glyphBox = NSRect(x: frame.minX, y: frame.minY + (hasLabel ? 4 : 0),
                                      width: frame.width,
                                      height: hasLabel ? frame.height - 20 : frame.height)
                WinIcons.draw(command.glyph, in: glyphBox, color: color, size: 18)

                if let label = command.label {
                    let text = NSAttributedString.winText(
                        label, font: FontManager.ui(FontManager.Size.caption),
                        color: command.isEnabled ? WinTheme.textPrimary : WinTheme.textDisabled,
                        alignment: .center)
                    let height = text.size().height
                    text.draw(in: NSRect(x: frame.minX, y: frame.maxY - height - 4,
                                         width: frame.width, height: height))
                }
            }
        }

        // MARK: Mouse

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let newRow = row(at: point)
            var newCommand = -1
            if !commands.isEmpty, commandRowRect.contains(point) {
                newCommand = commands.indices.first { commandRect($0).contains(point) } ?? -1
            }
            guard newRow != hovered || newCommand != hoveredCommand else { return }
            hovered = newRow
            hoveredCommand = newCommand
            needsDisplay = true
            scheduleSubmenu(for: newRow)
        }

        override func mouseExited(with event: NSEvent) {
            hoveredCommand = -1
            needsDisplay = true
        }

        /// Windows opens a submenu on hover after a short delay, and leaves it
        /// open while the pointer travels toward it.
        private func scheduleSubmenu(for row: Int) {
            submenuTimer?.invalidate()
            guard row >= 0 else { return }
            if items[row].submenu == nil {
                if owner.hasOpenSubmenu {
                    submenuTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
                        [weak self] _ in self?.owner.closeSubmenu()
                    }
                }
                return
            }
            submenuTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) {
                [weak self] _ in
                guard let self, let sub = self.items[row].submenu else { return }
                self.owner.openSubmenu(sub, forRow: row, rowRect: self.rect(forRow: row))
            }
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)

            if !commands.isEmpty, commandRowRect.contains(point),
               let index = commands.indices.first(where: { commandRect($0).contains(point) }),
               commands[index].isEnabled {
                let action = commands[index].action
                owner.dismissAll()
                action()
                return
            }

            let index = row(at: point)
            guard index >= 0 else { return }
            let item = items[index]
            if let sub = item.submenu {
                owner.openSubmenu(sub, forRow: index, rowRect: rect(forRow: index))
                return
            }
            guard let action = item.action else { return }
            owner.dismissAll()
            action()
        }

        // MARK: Keyboard

        func handleKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 53:                        // esc
                owner.parent == nil ? owner.dismissAll() : owner.close()
                return true
            case 125, 126:                  // down / up
                let step = event.keyCode == 125 ? 1 : -1
                var next = hovered
                for _ in 0..<items.count {
                    next = (next + step + items.count) % items.count
                    if !items[next].isSeparator, items[next].isEnabled { break }
                }
                hovered = next
                needsDisplay = true
                return true
            case 36, 76:                    // return
                guard hovered >= 0 else { return true }
                let item = items[hovered]
                if let sub = item.submenu {
                    owner.openSubmenu(sub, forRow: hovered, rowRect: rect(forRow: hovered))
                } else if let action = item.action {
                    owner.dismissAll()
                    action()
                }
                return true
            case 124:                       // right — into submenu
                guard hovered >= 0, let sub = items[hovered].submenu else { return true }
                owner.openSubmenu(sub, forRow: hovered, rowRect: rect(forRow: hovered))
                return true
            case 123:                       // left — back out
                if owner.parent != nil { owner.close() }
                return true
            default:
                return false
            }
        }
    }
}
