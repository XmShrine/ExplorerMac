import AppKit

/// File clipboard with Windows' cut/copy semantics.
///
/// The important difference from macOS: on Windows, 剪切 does not move anything.
/// It marks the selection and the move happens on paste, so cutting and then
/// never pasting leaves the files where they were, and the cut items render
/// dimmed in the meantime. Windows carries that intent on the clipboard in a
/// `Preferred DropEffect` blob; we use a private pasteboard type for the same
/// purpose, while still writing plain file URLs so other apps can paste from us.
enum Clipboard {

    /// Private marker paralleling Windows' `Preferred DropEffect`.
    private static let effectType = NSPasteboard.PasteboardType("local.explorermac.dropeffect")

    enum Effect: String {
        case copy, move
    }

    static func write(urls: [URL], effect: Effect) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSPasteboardWriting])
        pasteboard.setString(effect.rawValue, forType: effectType)
    }

    static func read() -> (urls: [URL], effect: Effect) {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Anything pasted from another app is a copy; only our own cut marks a move.
        let effect = pasteboard.string(forType: effectType).flatMap(Effect.init) ?? .copy
        return (urls, effect)
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true])
    }

    /// Paths currently marked for a move, so the list can dim them the way
    /// Explorer does between 剪切 and 粘贴.
    static var cutPaths: Set<String> {
        let state = read()
        guard state.effect == .move else { return [] }
        return Set(state.urls.map(\.path))
    }

    static func clear() {
        NSPasteboard.general.clearContents()
    }
}
