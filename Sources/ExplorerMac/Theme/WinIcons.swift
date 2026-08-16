import AppKit

/// Explorer's iconography, sourced from the Windows assets in Resources.
///
/// Two separate systems, exactly as Windows uses them:
///   - shell icons (folders, drives, libraries, recycle bin) are multi-size
///     `.ico` files lifted from imageres.dll; macOS' ImageIO reads ICO natively
///     so they load with no conversion step and keep every embedded size
///   - command surfaces draw glyphs from Segoe Fluent Icons as *text*, which is
///     how WinUI does it, so they scale cleanly and take the theme's foreground
///     colour instead of needing a recolour pass
enum WinIcons {

    // MARK: - Shell icons

    enum Shell: String {
        case folder, folderOpen = "folder-open"
        case file, fileText = "file-text", fileImage = "file-image"
        case fileAudio = "file-audio", fileVideo = "file-video", fileZip = "file-zip"
        case fileExe = "file-exe", filePDF = "file-pdf", fileFont = "file-font"
        case driveWindows = "drive-windows", driveFixed = "drive-fixed"
        case driveRemovable = "drive-removable"
        case thisPC = "this-pc", network, onedrive, user, star
        case recycleEmpty = "recycle-empty", recycleFull = "recycle-full"
        case desktop, downloads, documents, pictures, music, videos
        case folderNetwork = "folder-network", folderSearch = "folder-search"
        case folderStar = "folder-star"
    }

    private static var shellCache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func shell(_ kind: Shell, size: CGFloat = 16) -> NSImage {
        let key = "\(kind.rawValue)-\(size)"
        lock.lock()
        if let hit = shellCache[key] { lock.unlock(); return hit }
        lock.unlock()

        let image = loadICO(named: kind.rawValue, size: size) ?? placeholder(size: size)
        lock.lock(); shellCache[key] = image; lock.unlock()
        return image
    }

    /// Picks the embedded ICO representation nearest the requested size rather
    /// than letting NSImage scale whatever it read first. Explorer's 16px
    /// folder is a separately hinted drawing, not a downscale of the 256px one,
    /// and using the right rep is most of why the list view looks correct.
    private static func loadICO(named: String, size: CGFloat) -> NSImage? {
        guard let dir = FontManager.resourcesDirectory()?.appendingPathComponent("Icons"),
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(named).ico")),
              let source = NSImage(data: data) else { return nil }

        let target = size * (NSScreen.main?.backingScaleFactor ?? 2)
        var best: NSImageRep?
        for rep in source.representations {
            let dimension = CGFloat(rep.pixelsWide)
            guard dimension > 0 else { continue }
            if best == nil { best = rep; continue }
            let bestDim = CGFloat(best!.pixelsWide)
            // Prefer the smallest rep that still covers the target, falling back
            // to the largest available when none is big enough.
            let bestCovers = bestDim >= target, thisCovers = dimension >= target
            if thisCovers && (!bestCovers || dimension < bestDim) { best = rep }
            else if !thisCovers && !bestCovers && dimension > bestDim { best = rep }
        }
        guard let rep = best, let cgImage = cgImage(from: rep) else { return nil }

        // Going through CGImage rather than `addRepresentation` matters: ICO
        // stores its bitmaps bottom-up in the BMP tradition, and a raw
        // NSBitmapImageRep carries that convention into any flipped view, so
        // every folder ends up drawn upside down. NSImage(cgImage:) normalises
        // the orientation.
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private static func cgImage(from rep: NSImageRep) -> CGImage? {
        if let bitmap = rep as? NSBitmapImageRep, let cg = bitmap.cgImage { return cg }
        var box = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        return rep.cgImage(forProposedRect: &box, context: nil, hints: nil)
    }

    private static func placeholder(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            WinTheme.textTertiary.setStroke()
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 2, yRadius: 2)
            p.lineWidth = 1
            p.stroke()
            return true
        }
    }

    /// Maps a listing entry onto the icon Explorer would show for it.
    static func icon(for entry: FileEntry, size: CGFloat = 16) -> NSImage {
        if entry.isDirectory { return shell(.folder, size: size) }
        switch entry.ext {
        case "txt", "log", "md", "ini", "cfg", "conf", "json", "xml", "yml", "yaml",
             "csv", "rtf", "c", "h", "cpp", "hpp", "cs", "java", "py", "swift", "rs",
             "go", "rb", "js", "ts", "css", "html", "htm", "sh":
            return shell(.fileText, size: size)
        case "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff", "svg", "ico":
            return shell(.fileImage, size: size)
        case "mp3", "wav", "flac", "m4a", "aac", "ogg", "wma":
            return shell(.fileAudio, size: size)
        case "mp4", "mov", "avi", "mkv", "webm", "wmv", "flv", "m4v":
            return shell(.fileVideo, size: size)
        case "zip", "7z", "rar", "gz", "tar", "bz2", "xz":
            return shell(.fileZip, size: size)
        case "exe", "msi", "app", "dll":
            return shell(.fileExe, size: size)
        case "pdf":
            return shell(.filePDF, size: size)
        case "ttf", "otf", "ttc", "woff", "woff2":
            return shell(.fileFont, size: size)
        default:
            return shell(.file, size: size)
        }
    }

    // MARK: - Segoe Fluent Icons glyphs

    /// Codepoints verified against the bundled SegoeIcons.ttf.
    enum Glyph: String {
        case back = "\u{E72B}"
        case forward = "\u{E72A}"
        case up = "\u{E74A}"
        case refresh = "\u{E72C}"
        case search = "\u{E721}"
        case home = "\u{E80F}"
        case add = "\u{E710}"
        case cut = "\u{E8C6}"
        case copy = "\u{E8C8}"
        case paste = "\u{E77F}"
        case rename = "\u{E8AC}"
        case delete = "\u{E74D}"
        case sort = "\u{E8CB}"
        case view = "\u{E8A9}"
        case more = "\u{E712}"
        case share = "\u{E72D}"
        case newFolder = "\u{E8F4}"
        case gallery = "\u{E91B}"
        case properties = "\u{E946}"
        case undo = "\u{E7A7}"
        case redo = "\u{E7A6}"
        case chevronDown = "\u{E70D}"
        case chevronUp = "\u{E70E}"
        case chevronRight = "\u{E76C}"
        case chevronLeft = "\u{E76B}"
        case pin = "\u{E718}"
        case checkmark = "\u{E73E}"
        case groupBy = "\u{F168}"
        case cloud = "\u{E753}"
        case pc = "\u{E977}"
        case folderGlyph = "\u{E8B7}"
        case detailsPane = "\u{E71D}"
        case previewPane = "\u{E8A1}"
        case selectAll = "\u{E8B3}"
        case compress = "\u{F012}"
        case openWith = "\u{E7AC}"
        case terminal = "\u{E756}"
    }

    /// Renders a glyph as an image for the places AppKit wants an NSImage.
    /// Views that draw their own content should call `draw(_:in:color:size:)`
    /// instead and skip the intermediate bitmap entirely.
    static func glyph(_ kind: Glyph, size: CGFloat = FontManager.Size.glyph,
                      color: NSColor) -> NSImage {
        let font = FontManager.icons(size)
        let attributed = NSAttributedString(string: kind.rawValue, attributes: [
            .font: font, .foregroundColor: color,
        ])
        let bounds = attributed.size()
        let box = NSSize(width: ceil(max(bounds.width, size)), height: ceil(max(bounds.height, size)))
        return NSImage(size: box, flipped: false) { rect in
            attributed.draw(at: NSPoint(
                x: (rect.width - bounds.width) / 2,
                y: (rect.height - bounds.height) / 2))
            return true
        }
    }

    /// Draws a glyph centred in `rect` using the current context.
    static func draw(_ kind: Glyph, in rect: NSRect, color: NSColor,
                     size: CGFloat = FontManager.Size.glyph) {
        let attributed = NSAttributedString(string: kind.rawValue, attributes: [
            .font: FontManager.icons(size), .foregroundColor: color,
        ])
        let measured = attributed.size()
        attributed.draw(at: NSPoint(
            x: rect.midX - measured.width / 2,
            y: rect.midY - measured.height / 2))
    }

    static func invalidate() {
        lock.lock(); shellCache.removeAll(); lock.unlock()
    }
}
