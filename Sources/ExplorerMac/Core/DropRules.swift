import AppKit

/// Whether a drop copies or moves, and whether it is allowed at all.
///
/// Windows decides this from the *drive*, not from the app: dragging inside one
/// volume moves, dragging across volumes copies, and a modifier overrides
/// either way. That rule is the one people have in their fingers, so it is
/// worth reproducing exactly rather than inheriting macOS' always-copy default.
enum DropRules {

    /// Explorer's modifiers are Ctrl (copy) and Shift (move). On Mac hardware
    /// the equivalents are Option and Command, so both pairs are honoured.
    static func isCopy(sources: [URL], destination: String,
                       modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.option) || modifiers.contains(.control) { return true }
        if modifiers.contains(.command) || modifiers.contains(.shift) { return false }
        guard let first = sources.first else { return true }
        return !sameVolume(first.path, destination)
    }

    /// Rejects the drops Explorer refuses: onto the folder the item already
    /// lives in, onto itself, or into one of its own subfolders — the last one
    /// would otherwise delete the tree it is moving.
    static func canDrop(sources: [URL], destination: String, isCopy: Bool) -> Bool {
        guard !sources.isEmpty, destination.first != "\u{1}" else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        let target = standardized(destination)
        for source in sources {
            let path = standardized(source.path)
            if path == target { return false }
            if target.hasPrefix(path + "/") { return false }
            // Copying into the same folder is Explorer's "make a duplicate";
            // moving there is a no-op and gets no drop feedback.
            if !isCopy, standardized(source.deletingLastPathComponent().path) == target {
                return false
            }
        }
        return true
    }

    /// File URLs on a dragging pasteboard, or an empty array if it carries none.
    static func urls(from info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    /// Same volume in the sense that matters here: a rename can move the file
    /// without copying its bytes.
    private static func sameVolume(_ lhs: String, _ rhs: String) -> Bool {
        guard let a = identifier(of: lhs), let b = identifier(of: rhs) else { return false }
        return a.isEqual(b)
    }

    private static func identifier(of path: String) -> (any NSObjectProtocol)? {
        (try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }
}
