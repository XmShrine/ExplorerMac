import AppKit

/// The Windows 11 command bar — the row that replaced the Windows 10 ribbon.
///
/// Layout is: an accented 新建 split button, a divider, the icon-only clipboard
/// and file verbs, then 排序 / 查看 / ⋯ pushed to the trailing edge. Verbs that
/// need a selection are disabled until there is one, which the bar reflects by
/// dimming both glyph and label.
final class CommandBarView: NSView {

    enum Command {
        case newItem, cut, copy, paste, rename, share, delete
        case sort, view, more
    }

    var onCommand: ((Command, NSView) -> Void)?

    private let newButton = WinGlyphButton(glyph: .add, label: "新建", showsChevron: true)
    private let cutButton = WinGlyphButton(glyph: .cut)
    private let copyButton = WinGlyphButton(glyph: .copy)
    private let pasteButton = WinGlyphButton(glyph: .paste)
    private let renameButton = WinGlyphButton(glyph: .rename)
    private let shareButton = WinGlyphButton(glyph: .share)
    private let deleteButton = WinGlyphButton(glyph: .delete)
    private let sortButton = WinGlyphButton(glyph: .sort, label: "排序", showsChevron: true)
    private let viewButton = WinGlyphButton(glyph: .view, label: "查看", showsChevron: true)
    private let moreButton = WinGlyphButton(glyph: .more)

    /// Index in `leading` after which the divider is drawn.
    private let dividerAfter = 0
    private var leading: [WinGlyphButton] = []
    private var trailing: [WinGlyphButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)

        newButton.accentGlyph = true
        leading = [newButton, cutButton, copyButton, pasteButton,
                   renameButton, shareButton, deleteButton]
        trailing = [sortButton, viewButton, moreButton]
        for button in leading + trailing { addSubview(button) }

        wire(newButton, .newItem)
        wire(cutButton, .cut)
        wire(copyButton, .copy)
        wire(pasteButton, .paste)
        wire(renameButton, .rename)
        wire(shareButton, .share)
        wire(deleteButton, .delete)
        wire(sortButton, .sort)
        wire(viewButton, .view)
        wire(moreButton, .more)

        updateEnabled(selectionCount: 0, clipboardHasItems: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func wire(_ button: WinGlyphButton, _ command: Command) {
        button.onClick = { [weak self, weak button] in
            guard let self, let button else { return }
            self.onCommand?(command, button)
        }
    }

    override var isFlipped: Bool { true }

    /// Explorer greys the verbs that need a target, and 粘贴 tracks the
    /// clipboard rather than the selection.
    func updateEnabled(selectionCount: Int, clipboardHasItems: Bool) {
        let hasSelection = selectionCount > 0
        cutButton.isEnabled = hasSelection
        copyButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        shareButton.isEnabled = hasSelection
        renameButton.isEnabled = selectionCount == 1
        pasteButton.isEnabled = clipboardHasItems
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 32
        let y = (bounds.height - height) / 2
        var x: CGFloat = 8
        for (index, button) in leading.enumerated() {
            let width = button.intrinsicWidth
            button.frame = NSRect(x: x, y: y, width: width, height: height)
            x += width + 2
            if index == dividerAfter { x += 8 }
        }
        var trailingX = bounds.maxX - 8
        for button in trailing.reversed() {
            let width = button.intrinsicWidth
            trailingX -= width
            button.frame = NSRect(x: trailingX, y: y, width: width, height: height)
            trailingX -= 2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard leading.count > dividerAfter + 1 else { return }
        // Vertical rule between 新建 and the clipboard verbs.
        let x = leading[dividerAfter].frame.maxX + 6
        WinTheme.dividerStroke.setFill()
        NSRect(x: x, y: bounds.midY - 10, width: 1, height: 20).fill()
    }
}

/// The thin footer: item count, selection count and selected size.
final class StatusBarView: NSView {

    var itemCount = 0
    var selectionCount = 0
    var selectionBytes: Int64 = 0
    /// Replaces the item count while search results are showing.
    var searchLabel: String? { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(itemCount: Int, selectionCount: Int, selectionBytes: Int64) {
        self.itemCount = itemCount
        self.selectionCount = selectionCount
        self.selectionBytes = selectionBytes
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        WinTheme.dividerStroke.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let font = FontManager.ui(FontManager.Size.caption)
        let left = NSAttributedString.winText(
            searchLabel.map { "\($0) — \(itemCount) 个结果" } ?? "\(itemCount) 个项目",
            font: font, color: WinTheme.textSecondary)
        left.draw(at: NSPoint(x: 12, y: (bounds.height - left.size().height) / 2))

        guard selectionCount > 0 else { return }
        var detail = "选中 \(selectionCount) 个项目"
        if selectionBytes > 0 { detail += "  \(WinFormat.detailedSize(selectionBytes))" }
        let right = NSAttributedString.winText(detail, font: font, color: WinTheme.textSecondary)
        right.draw(at: NSPoint(x: left.size().width + 32,
                               y: (bounds.height - right.size().height) / 2))
    }
}
