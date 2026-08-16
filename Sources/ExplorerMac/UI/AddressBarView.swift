import AppKit

/// Navigation row: back / forward / up / refresh, the breadcrumb, and search.
///
/// The breadcrumb is Explorer's, not a path label: each segment is its own
/// button with a chevron that opens that folder's siblings, and clicking the
/// empty space to the right swaps the whole strip for an editable text field
/// pre-filled with the `C:\…` form.
final class AddressBarView: NSView {

    let backButton = WinGlyphButton(glyph: .back)
    let forwardButton = WinGlyphButton(glyph: .forward)
    let upButton = WinGlyphButton(glyph: .up)
    let refreshButton = WinGlyphButton(glyph: .refresh)

    var onNavigate: ((String) -> Void)?
    var onSearch: ((String) -> Void)?
    /// Fires when the search box is emptied, which leaves the results view.
    var onSearchCancelled: (() -> Void)?
    /// Asked for the sibling folders behind a crumb's chevron.
    var siblingProvider: ((String) -> [(title: String, path: String)])?

    private var crumbs: [(title: String, path: String)] = []
    private var crumbButtons: [WinCrumbButton] = []
    private let crumbContainer = NSView()

    private let pathField = NSTextField()
    private let searchField = NSTextField()
    private var isEditing = false

    private var currentPath = ""

    override init(frame: NSRect) {
        super.init(frame: frame)

        for button in [backButton, forwardButton, upButton, refreshButton] {
            addSubview(button)
        }
        crumbContainer.wantsLayer = true
        crumbContainer.layer?.masksToBounds = true
        addSubview(crumbContainer)

        configure(pathField, placeholder: nil)
        pathField.isHidden = true
        pathField.target = self
        pathField.action = #selector(commitPath)
        addSubview(pathField)

        configure(searchField, placeholder: "搜索")
        searchField.target = self
        searchField.action = #selector(commitSearch)
        addSubview(searchField)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ field: NSTextField, placeholder: String?) {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = FontManager.ui(FontManager.Size.addressBar)
        field.textColor = WinTheme.textPrimary
        field.lineBreakMode = .byTruncatingHead
        if let placeholder {
            field.placeholderAttributedString = NSAttributedString.winText(
                placeholder, font: FontManager.ui(FontManager.Size.addressBar),
                color: WinTheme.textTertiary)
        }
    }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    private let buttonSize: CGFloat = 36
    private var searchWidth: CGFloat { min(240, max(160, bounds.width * 0.24)) }

    override func layout() {
        super.layout()
        let y = (bounds.height - buttonSize) / 2
        var x: CGFloat = 6
        for button in [backButton, forwardButton, upButton] {
            button.frame = NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
            x += buttonSize
        }
        x += 4

        let searchX = bounds.maxX - searchWidth - 8
        // Refresh sits at the trailing end of the breadcrumb field, inside it.
        let fieldRect = NSRect(x: x, y: (bounds.height - 32) / 2,
                               width: searchX - x - 8, height: 32)
        refreshButton.frame = NSRect(x: fieldRect.maxX - 34, y: y, width: buttonSize, height: buttonSize)

        crumbContainer.frame = NSRect(x: fieldRect.minX + 6, y: fieldRect.minY,
                                      width: fieldRect.width - 40, height: fieldRect.height)
        pathField.frame = NSRect(x: fieldRect.minX + 8, y: fieldRect.minY + 7,
                                 width: fieldRect.width - 44, height: 18)
        searchField.frame = NSRect(x: searchX + 30, y: fieldRect.minY + 7,
                                   width: searchWidth - 40, height: 18)
        layoutCrumbs()
    }

    private var breadcrumbFieldRect: NSRect {
        let searchX = bounds.maxX - searchWidth - 8
        let x: CGFloat = 6 + buttonSize * 3 + 4
        return NSRect(x: x, y: (bounds.height - 32) / 2, width: searchX - x - 8, height: 32)
    }

    private var searchFieldRect: NSRect {
        NSRect(x: bounds.maxX - searchWidth - 8, y: (bounds.height - 32) / 2,
               width: searchWidth, height: 32)
    }

    private func layoutCrumbs() {
        var x: CGFloat = 0
        for button in crumbButtons {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: (crumbContainer.bounds.height - 24) / 2,
                                  width: width, height: 24)
            x += width
        }
        // Explorer drops leading crumbs when the trail overflows; the tail is
        // what the user needs to see.
        let overflow = x - crumbContainer.bounds.width
        if overflow > 0 {
            for button in crumbButtons { button.frame.origin.x -= overflow }
        }
    }

    // MARK: - Content

    func setPath(_ path: String) {
        currentPath = path
        crumbs = Self.breadcrumbs(for: path)
        crumbButtons.forEach { $0.removeFromSuperview() }
        crumbButtons = crumbs.enumerated().map { index, crumb in
            let button = WinCrumbButton(title: crumb.title, isLast: index == crumbs.count - 1)
            button.onClick = { [weak self] in self?.onNavigate?(crumb.path) }
            button.onChevronClick = { [weak self] in
                self?.showSiblings(for: crumb.path, from: button)
            }
            crumbContainer.addSubview(button)
            return button
        }
        pathField.stringValue = VolumeMapper.shared.windowsPath(from: path)
        layoutCrumbs()
        needsDisplay = true
    }

    /// Builds the crumb trail Explorer would show, rooted at 此电脑 and the
    /// drive rather than at the POSIX filesystem root.
    static func breadcrumbs(for path: String) -> [(title: String, path: String)] {
        var result: [(String, String)] = [("此电脑", ShellLocations.thisPCToken)]
        guard let volume = VolumeMapper.shared.volume(for: path) else {
            return result + [(path, path)]
        }
        result.append((volume.displayName, volume.mountPoint))

        var relative = path
        if volume.mountPoint != "/" { relative = String(path.dropFirst(volume.mountPoint.count)) }
        let components = relative.split(separator: "/").map(String.init)

        var accumulated = volume.mountPoint == "/" ? "" : volume.mountPoint
        for component in components {
            accumulated += "/" + component
            result.append((ShellLocations.displayName(for: accumulated, fallback: component),
                           accumulated))
        }
        return result
    }

    private func showSiblings(for path: String, from button: NSView) {
        guard let siblings = siblingProvider?(path), !siblings.isEmpty else { return }
        let menu = NSMenu()
        menu.font = FontManager.ui(FontManager.Size.body)
        for sibling in siblings {
            let item = NSMenuItem(title: sibling.title, action: #selector(siblingPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = sibling.path
            item.image = WinIcons.shell(.folder, size: 16)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY + 4),
                   in: button)
    }

    @objc private func siblingPicked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onNavigate?(path)
    }

    // MARK: - Edit mode

    private func beginEditing() {
        isEditing = true
        crumbContainer.isHidden = true
        pathField.isHidden = false
        pathField.stringValue = VolumeMapper.shared.windowsPath(from: currentPath)
        window?.makeFirstResponder(pathField)
        pathField.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        crumbContainer.isHidden = false
        pathField.isHidden = true
        needsDisplay = true
    }

    @objc private func commitPath() {
        let input = pathField.stringValue
        endEditing()
        guard let resolved = VolumeMapper.shared.posixPath(fromWindows: input) else {
            NSSound.beep()
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSSound.beep()
            return
        }
        onNavigate?(resolved)
    }

    @objc private func commitSearch() {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { onSearchCancelled?() } else { onSearch?(text) }
    }

    func clearSearch() {
        searchField.stringValue = ""
    }

    func setSearchText(_ text: String) {
        searchField.stringValue = text
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if breadcrumbFieldRect.contains(point), !isEditing { beginEditing() }
        else if searchFieldRect.contains(point) { window?.makeFirstResponder(searchField) }
    }

    /// Ctrl+L / Alt+D — jump to the editable path, as in Explorer.
    func focusPath() { beginEditing() }

    /// Ctrl+F — jump to the search box.
    func focusSearch() { window?.makeFirstResponder(searchField) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Both fields are WinUI TextBoxes: a tinted fill, a hairline border,
        // and 4pt corners.
        for rect in [breadcrumbFieldRect, searchFieldRect] {
            WinTheme.layerFill.setFill()
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: WinTheme.Metrics.cornerSmall,
                                    yRadius: WinTheme.Metrics.cornerSmall)
            path.fill()
            WinTheme.controlStroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let searchRect = searchFieldRect
        WinIcons.draw(.search,
                      in: NSRect(x: searchRect.minX + 4, y: searchRect.minY,
                                 width: 24, height: searchRect.height),
                      color: WinTheme.textSecondary, size: 14)
    }
}
