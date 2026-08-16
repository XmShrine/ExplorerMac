import AppKit

/// Everything Explorer remembers between launches.
///
/// Windows keeps this in the registry per folder; this is the flat version —
/// one set of preferences for the whole app, which covers the parts a user
/// actually notices being forgotten.
enum Settings {

    private static let store = UserDefaults.standard

    private enum Key {
        static let windowFrame = "window.frame"
        static let navWidth = "nav.width"
        static let columnWidths = "list.columnWidths"
        static let sortColumn = "list.sortColumn"
        static let sortAscending = "list.sortAscending"
        static let showHidden = "list.showHidden"
        static let compactView = "list.compactView"
        static let viewMode = "list.viewMode"
        static let lastPath = "nav.lastPath"
    }

    static var windowFrame: NSRect? {
        get {
            guard let raw = store.string(forKey: Key.windowFrame) else { return nil }
            let rect = NSRectFromString(raw)
            return rect.width > 200 && rect.height > 150 ? rect : nil
        }
        set {
            guard let newValue else { return }
            store.set(NSStringFromRect(newValue), forKey: Key.windowFrame)
        }
    }

    static var navWidth: CGFloat {
        get {
            let stored = store.double(forKey: Key.navWidth)
            return stored > 0 ? CGFloat(stored) : WinTheme.Metrics.navPaneWidth
        }
        set { store.set(Double(newValue), forKey: Key.navWidth) }
    }

    static var columnWidths: [CGFloat]? {
        get {
            guard let raw = store.array(forKey: Key.columnWidths) as? [Double],
                  !raw.isEmpty else { return nil }
            return raw.map { CGFloat($0) }
        }
        set {
            guard let newValue else { return }
            store.set(newValue.map { Double($0) }, forKey: Key.columnWidths)
        }
    }

    static var sortColumn: SortColumn {
        get { SortColumn(rawValue: store.integer(forKey: Key.sortColumn)) ?? .name }
        set { store.set(newValue.rawValue, forKey: Key.sortColumn) }
    }

    /// Defaults to true when unset, matching Explorer's ascending-by-name start.
    static var sortAscending: Bool {
        get { store.object(forKey: Key.sortAscending) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.sortAscending) }
    }

    static var showHidden: Bool {
        get { store.bool(forKey: Key.showHidden) }
        set { store.set(newValue, forKey: Key.showHidden) }
    }

    static var compactView: Bool {
        get { store.bool(forKey: Key.compactView) }
        set { store.set(newValue, forKey: Key.compactView) }
    }

    /// Defaults to 详细信息, which is where Explorer starts for most folders.
    static var viewMode: ViewMode {
        get {
            guard store.object(forKey: Key.viewMode) != nil else { return .details }
            return ViewMode(rawValue: store.integer(forKey: Key.viewMode)) ?? .details
        }
        set { store.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    /// Reopens where the user left off, but only if the folder still exists.
    static var lastPath: String? {
        get {
            guard let path = store.string(forKey: Key.lastPath) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return path
        }
        set { store.set(newValue, forKey: Key.lastPath) }
    }
}
