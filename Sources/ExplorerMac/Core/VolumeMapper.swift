import Foundation

/// Maps macOS mount points onto Windows drive letters and renders POSIX paths
/// the way Explorer's address bar shows them.
///
/// The letters are synthetic: the boot volume is always `C:`, and other mounted
/// volumes take `D:` onward in mount order, which keeps a given USB stick on a
/// stable letter for as long as it stays mounted. Both notations parse on input
/// so a pasted POSIX path still navigates.
final class VolumeMapper {
    static let shared = VolumeMapper()

    struct Volume {
        var letter: Character
        var mountPoint: String     // "/" or "/Volumes/Foo"
        var name: String           // Explorer's label, e.g. "本地磁盘"
        var isRemovable: Bool
        var isBoot: Bool
        var totalBytes: Int64
        var freeBytes: Int64

        /// "本地磁盘 (C:)" — how Explorer labels a drive in the nav pane.
        var displayName: String { "\(name) (\(letter):)" }
    }

    private(set) var volumes: [Volume] = []
    private let lock = NSLock()

    private init() { refresh() }

    func refresh() {
        var found: [Volume] = []
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey,
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []

        // Boot volume first so it always claims C:.
        let sorted = mounted.sorted { a, b in
            let aRoot = (try? a.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem ?? false
            let bRoot = (try? b.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem ?? false
            if aRoot != bRoot { return aRoot }
            return a.path < b.path
        }

        var next: UInt8 = 67   // 'C'
        for url in sorted {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isBoot = v?.volumeIsRootFileSystem ?? false
            let removable = (v?.volumeIsRemovable ?? false) || (v?.volumeIsEjectable ?? false)
            // Explorer names the system drive "本地磁盘"; other volumes keep
            // their own label, which is what a formatted stick shows too.
            let name = isBoot ? "本地磁盘" : (v?.volumeName ?? "本地磁盘")
            found.append(Volume(
                letter: Character(UnicodeScalar(next)),
                mountPoint: url.path == "/" ? "/" : url.path,
                name: name,
                isRemovable: removable,
                isBoot: isBoot,
                totalBytes: Int64(v?.volumeTotalCapacity ?? 0),
                freeBytes: Int64(v?.volumeAvailableCapacity ?? 0)
            ))
            next = next < 90 ? next + 1 : next   // stop at Z:
        }

        lock.lock()
        volumes = found
        lock.unlock()
    }

    /// Longest mount point wins, so /Volumes/Foo/bar resolves to the Foo volume
    /// rather than to the root volume it is nested under.
    func volume(for posixPath: String) -> Volume? {
        lock.lock(); defer { lock.unlock() }
        return volumes
            .filter { posixPath == $0.mountPoint || posixPath.hasPrefix($0.mountPoint == "/" ? "/" : $0.mountPoint + "/") }
            .max { $0.mountPoint.count < $1.mountPoint.count }
    }

    func volume(letter: Character) -> Volume? {
        let upper = Character(String(letter).uppercased())
        lock.lock(); defer { lock.unlock() }
        return volumes.first { $0.letter == upper }
    }

    // MARK: - Display

    /// "/Users/x/Desktop" -> "C:\Users\x\Desktop"
    func windowsPath(from posixPath: String) -> String {
        guard let vol = volume(for: posixPath) else {
            return posixPath.replacingOccurrences(of: "/", with: "\\")
        }
        var rest = posixPath
        if vol.mountPoint != "/" {
            rest = String(posixPath.dropFirst(vol.mountPoint.count))
        }
        if rest.hasPrefix("/") { rest.removeFirst() }
        let tail = rest.replacingOccurrences(of: "/", with: "\\")
        return tail.isEmpty ? "\(vol.letter):\\" : "\(vol.letter):\\\(tail)"
    }

    /// Accepts either notation. "C:\Users\x", "C:/Users/x" and "/Users/x" all
    /// resolve; returns nil when the drive letter names no mounted volume.
    func posixPath(fromWindows input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("/") { return s }
        if s.hasPrefix("~") {
            return NSString(string: s).expandingTildeInPath
        }
        let chars = Array(s)
        guard chars.count >= 2, chars[1] == ":", chars[0].isLetter,
              let vol = volume(letter: chars[0]) else { return nil }

        var rest = String(chars.dropFirst(2))
        rest = rest.replacingOccurrences(of: "\\", with: "/")
        while rest.hasPrefix("/") { rest.removeFirst() }
        if rest.isEmpty { return vol.mountPoint }
        let base = vol.mountPoint == "/" ? "" : vol.mountPoint
        return base + "/" + rest
    }
}
