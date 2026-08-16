import AppKit
import CoreText

/// Resolves Explorer's typefaces from the Windows fonts bundled in Resources.
///
/// Two things about Segoe UI Variable make this less trivial than naming a
/// family. It ships as a single family whose optical sizes are *styles*
/// ("Regular Text", "Regular Display", "Regular Small"), so asking for a family
/// named "Segoe UI Variable Text" finds nothing — faces have to be selected by
/// PostScript name. And it carries no Han coverage at all: Windows composes
/// Chinese UI text with Microsoft YaHei UI, so the same cascade has to be built
/// explicitly here or CoreText silently substitutes PingFang and the rendering
/// stops matching.
enum FontManager {

    /// PostScript names, verified against the faces in the bundled files.
    private enum PS {
        static let regular   = "SegoeUIVariable"                  // Regular, Text optical size
        static let semilight = "SegoeUIVariable_Semilight-Text"
        static let semibold  = "SegoeUIVariable_Semibold-Text"
        static let bold      = "SegoeUIVariable_Bold-Text"
        static let display   = "SegoeUIVariable_Regular-Display"
        static let small     = "SegoeUIVariable_Regular-Small"

        static let legacy       = "SegoeUI"
        static let legacyBold   = "SegoeUI-Bold"

        static let icons = "SegoeFluentIcons"
        static let cjk   = "MicrosoftYaHeiUI"
        static let cjkBold = "MicrosoftYaHeiUI-Bold"
    }

    private(set) static var hasVariable = false
    private(set) static var hasLegacy = false
    private(set) static var hasIcons = false
    private(set) static var hasCJK = false

    /// Registers the bundled fonts process-wide. Must run before any view is
    /// built, since font resolution is cached from first use.
    static func bootstrap() {
        registerBundledFonts()
        hasVariable = exists(PS.regular)
        hasLegacy   = exists(PS.legacy)
        hasIcons    = exists(PS.icons)
        hasCJK      = exists(PS.cjk)
    }

    private static func exists(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 12) != nil
    }

    private static func registerBundledFonts() {
        guard let dir = resourcesDirectory()?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Resources live inside the .app bundle in a packaged build and beside the
    /// binary when running straight out of `swift build`.
    static func resourcesDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("Fonts").path) {
            return bundled
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        // Walk up out of .build/<config>/ when running from a dev build.
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("Resources")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Fonts").path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Sizes

    /// Explorer's UI is authored at 96dpi where body text is 12 device pixels.
    /// macOS points are 1/72", so the literal conversion would be 9pt — which
    /// renders visibly smaller than Windows because macOS then draws it at 2x
    /// on a Retina panel without Windows' scaling factor. These values match
    /// Explorer's *apparent* size on a 100%-scaled Windows display.
    enum Size {
        static let body: CGFloat = 12          // list rows, nav pane, menus
        static let caption: CGFloat = 12       // status bar, column headers
        static let tab: CGFloat = 12
        static let addressBar: CGFloat = 12
        static let dialogTitle: CGFloat = 20
        static let glyph: CGFloat = 16         // command bar icons
        static let glyphSmall: CGFloat = 12    // chevrons, sort arrows
    }

    // MARK: - Vending

    private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    enum Weight {
        case semilight, regular, semibold, bold
        var postScript: String {
            switch self {
            case .semilight: return PS.semilight
            case .regular:   return PS.regular
            case .semibold:  return PS.semibold
            case .bold:      return PS.bold
            }
        }
        var legacyPostScript: String {
            switch self {
            case .bold, .semibold: return PS.legacyBold
            default:               return PS.legacy
            }
        }
        var systemWeight: NSFont.Weight {
            switch self {
            case .semilight: return .light
            case .regular:   return .regular
            case .semibold:  return .semibold
            case .bold:      return .bold
            }
        }
    }

    static func ui(_ size: CGFloat = Size.body, _ weight: Weight = .regular) -> NSFont {
        let key = "ui-\(size)-\(weight.postScript)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        let base: NSFont
        if hasVariable, let f = NSFont(name: weight.postScript, size: size) {
            base = f
        } else if hasLegacy, let f = NSFont(name: weight.legacyPostScript, size: size) {
            base = f
        } else {
            base = NSFont.systemFont(ofSize: size, weight: weight.systemWeight)
        }

        // Chain YaHei UI in behind the Latin face. Without this, a name like
        // "项目说明.txt" gets its Han run resolved by CoreText's own fallback,
        // which picks PingFang and changes both the shapes and the advance
        // widths mid-string.
        let resolved: NSFont
        if hasCJK {
            let cjkName = (weight == .bold || weight == .semibold) ? PS.cjkBold : PS.cjk
            let fallback = NSFontDescriptor(fontAttributes: [.name: cjkName])
            let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
            resolved = NSFont(descriptor: descriptor, size: size) ?? base
        } else {
            resolved = base
        }

        lock.lock(); cache[key] = resolved; lock.unlock()
        return resolved
    }

    /// Segoe Fluent Icons, the glyph font every Win11 command surface draws from.
    static func icons(_ size: CGFloat = Size.glyph) -> NSFont {
        let key = "icons-\(size)"
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let f = NSFont(name: PS.icons, size: size) ?? NSFont.systemFont(ofSize: size)
        lock.lock(); cache[key] = f; lock.unlock()
        return f
    }

    static var body: NSFont { ui(Size.body) }
    static var bodyStrong: NSFont { ui(Size.body, .semibold) }
    static var caption: NSFont { ui(Size.caption) }
}

extension NSAttributedString {
    /// Single place where every piece of UI text is built, so alignment,
    /// truncation and tracking stay consistent across the custom-drawn views.
    /// Explorer truncates with a tail ellipsis everywhere except the address
    /// bar, which truncates the head to keep the leaf folder visible.
    static func winText(_ string: String, font: NSFont, color: NSColor,
                        alignment: NSTextAlignment = .left,
                        lineBreak: NSLineBreakMode = .byTruncatingTail) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreak
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }
}
