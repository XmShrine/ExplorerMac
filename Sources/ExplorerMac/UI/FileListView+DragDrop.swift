import AppKit

/// Dragging, in both directions.
///
/// Kept out of `FileListView` proper because it is a self-contained protocol
/// conformance: nothing here decides what a cell looks like, and nothing there
/// needs to know a drag exists beyond the two lines of mouse tracking that
/// start one.
extension FileListView: NSDraggingSource {

    // MARK: - Source

    /// Starts a drag of the whole selection. Every item carries its own
    /// pasteboard entry and its own on-screen frame, so AppKit animates them
    /// back to the exact cells they came from when a drop is refused.
    func beginDrag(with event: NSEvent) {
        let list = entries
        let indices = selection.sorted().filter { $0 < list.count }
        guard !indices.isEmpty else { return }

        let layout = self.layout
        let items: [NSDraggingItem] = indices.map { index in
            let url = URL(fileURLWithPath: fullPath(for: list[index]))
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let box = layout.rect(for: index)
            item.setDraggingFrame(box, contents: ghost(of: box))
            return item
        }

        let session = beginDraggingSession(with: items, event: event, source: self)
        // Windows shows a stack under the cursor once more than one item is in
        // flight, with the rest fanning out only on hover.
        session.draggingFormation = indices.count > 1 ? .stack : .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// A translucent copy of the cell as it is actually drawn, rather than a
    /// rebuilt approximation that would drift from the real renderer.
    private func ghost(of box: NSRect) -> NSImage? {
        guard box.width >= 1, box.height >= 1,
              let rep = bitmapImageRepForCachingDisplay(in: box) else { return nil }
        cacheDisplay(in: box, to: rep)

        let source = NSImage(size: box.size)
        source.addRepresentation(rep)

        let image = NSImage(size: box.size)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: box.size), from: .zero,
                    operation: .sourceOver, fraction: 0.7)
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    /// Modifiers have to reach us: they are what switches a drag between copy
    /// and move, and AppKit would otherwise resolve the operation on its own.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        clearDropFeedback()
    }

    // MARK: - Destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = DropRules.urls(from: sender)
        guard !urls.isEmpty else { clearDropFeedback(); return [] }

        // Dragging against the top or bottom edge scrolls the list, which is
        // the only way to reach a target that is not currently on screen.
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged {
            autoscroll(with: event)
        }

        let point = convert(sender.draggingLocation, from: nil)
        let row = self.row(at: point)
        let list = entries
        // Hovering a folder drops into it; anywhere else drops into the folder
        // being viewed.
        let overFolder = row >= 0 && row < list.count && list[row].isDirectory
        let destination = overFolder ? fullPath(for: list[row]) : directoryPath

        let modifiers = NSEvent.modifierFlags
        var isCopy = DropRules.isCopy(sources: urls, destination: destination,
                                      modifiers: modifiers)
        // The source may not be offering both; fall back rather than promising
        // an operation the drag cannot perform.
        let allowed = sender.draggingSourceOperationMask
        if isCopy, !allowed.contains(.copy), allowed.contains(.move) { isCopy = false }
        if !isCopy, !allowed.contains(.move), allowed.contains(.copy) { isCopy = true }

        guard DropRules.canDrop(sources: urls, destination: destination, isCopy: isCopy) else {
            clearDropFeedback()
            return []
        }

        setDropFeedback(item: overFolder ? row : -1)
        return isCopy ? .copy : .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropFeedback() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !DropRules.urls(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearDropFeedback() }
        let urls = DropRules.urls(from: sender)
        guard !urls.isEmpty else { return false }

        let point = convert(sender.draggingLocation, from: nil)
        let row = self.row(at: point)
        let list = entries
        let overFolder = row >= 0 && row < list.count && list[row].isDirectory
        let destination = overFolder ? fullPath(for: list[row]) : directoryPath

        let isCopy = DropRules.isCopy(sources: urls, destination: destination,
                                      modifiers: NSEvent.modifierFlags)
        guard DropRules.canDrop(sources: urls, destination: destination, isCopy: isCopy) else {
            return false
        }
        onDrop?(urls, destination, isCopy)
        return true
    }

    // MARK: - Feedback

    private func setDropFeedback(item: Int) {
        guard dropTarget != item || !isDropTargetActive else { return }
        let previous = dropTarget
        dropTarget = item
        isDropTargetActive = true
        invalidateRow(previous)
        invalidateRow(item)
        if item < 0 || previous < 0 { setNeedsDisplay(visibleRect) }
    }

    private func clearDropFeedback() {
        guard isDropTargetActive else { return }
        let previous = dropTarget
        isDropTargetActive = false
        dropTarget = -1
        invalidateRow(previous)
        setNeedsDisplay(visibleRect)
    }
}
