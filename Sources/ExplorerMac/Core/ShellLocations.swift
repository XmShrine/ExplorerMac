import Foundation

/// Maps macOS home-directory folders onto the Windows shell's known folders, so
/// `~/Desktop` presents as 桌面 with the Desktop icon rather than as a plain
/// folder named "Desktop". Explorer localises these names independently of the
/// on-disk name, which is exactly what we reproduce.
enum ShellLocations {

    /// Sentinel path for the virtual "此电脑" root, which has no POSIX location.
    static let thisPCToken = "\u{1}ThisPC"
    static let networkToken = "\u{1}Network"
    static let homeToken = "\u{1}Home"
    static let recycleToken = "\u{1}RecycleBin"

    static var home: String { NSHomeDirectory() }

    struct Known {
        var posixName: String
        var displayName: String
        var icon: WinIcons.Shell
    }

    /// Ordered the way Explorer lists them in the navigation pane.
    static let known: [Known] = [
        Known(posixName: "Desktop", displayName: "桌面", icon: .desktop),
        Known(posixName: "Downloads", displayName: "下载", icon: .downloads),
        Known(posixName: "Documents", displayName: "文档", icon: .documents),
        Known(posixName: "Pictures", displayName: "图片", icon: .pictures),
        Known(posixName: "Music", displayName: "音乐", icon: .music),
        Known(posixName: "Movies", displayName: "视频", icon: .videos),
    ]

    static func path(for known: Known) -> String {
        (home as NSString).appendingPathComponent(known.posixName)
    }

    /// Explorer's label for a folder: the localised known-folder name where one
    /// applies, the drive label at a mount point, otherwise the folder's name.
    static func displayName(for path: String, fallback: String) -> String {
        if path == thisPCToken { return "此电脑" }
        if path == networkToken { return "网络" }
        if path == homeToken { return "主页" }
        if path == home { return "主文件夹" }
        for entry in known where path == self.path(for: entry) {
            return entry.displayName
        }
        if let volume = VolumeMapper.shared.volume(for: path), volume.mountPoint == path {
            return volume.displayName
        }
        return fallback
    }

    static func icon(for path: String, isDirectory: Bool = true) -> WinIcons.Shell {
        if path == thisPCToken { return .thisPC }
        if path == networkToken { return .network }
        if path == recycleToken { return .recycleEmpty }
        for entry in known where path == self.path(for: entry) { return entry.icon }
        if let volume = VolumeMapper.shared.volume(for: path), volume.mountPoint == path {
            if volume.isRemovable { return .driveRemovable }
            return volume.isBoot ? .driveWindows : .driveFixed
        }
        return isDirectory ? .folder : .file
    }

    /// Title for the window and the tab strip.
    static func title(for path: String) -> String {
        if path == thisPCToken { return "此电脑" }
        if path == networkToken { return "网络" }
        if path == homeToken { return "主页" }
        return displayName(for: path, fallback: (path as NSString).lastPathComponent)
    }
}
