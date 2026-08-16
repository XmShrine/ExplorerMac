import AppKit

/// WinUI 3 design tokens as shipped in Windows 11, light and dark.
///
/// These are the literal values from the Fluent common resource dictionary
/// rather than approximations, because Explorer's surfaces are mostly layered
/// translucent fills: guessing a flat colour lands visibly off once two of them
/// overlap.
enum WinTheme {

    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func pick(_ light: NSColor, _ dark: NSColor) -> NSColor {
        isDark ? dark : light
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }
    private static func white(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
    private static func black(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }

    // MARK: - Backgrounds

    /// SolidBackgroundFillColorBase — the mica-backed window body.
    static var windowBackground: NSColor { pick(rgb(243, 243, 243), rgb(32, 32, 32)) }

    /// LayerFillColorDefault — the file list surface floating above mica.
    static var layerFill: NSColor { pick(white(0.5), rgb(58, 58, 58, 0.3)) }

    /// The details-view content area reads as near-white / near-black once the
    /// layer fill composites over mica.
    static var contentBackground: NSColor { pick(rgb(255, 255, 255), rgb(39, 39, 39)) }

    /// Flyout surface: menus and dropdowns. Windows renders these with acrylic
    /// over the desktop; a solid fill reads the same at this size and keeps the
    /// menu window free of the compositing quirks a blur layer brings.
    static var flyoutBackground: NSColor { pick(rgb(249, 249, 249), rgb(44, 44, 44)) }
    static var flyoutStroke: NSColor { pick(black(0.0578), white(0.0698)) }

    /// The legacy Win32 dialog palette, used only by the 属性 sheet. Windows
    /// leaves that dialog light even in dark mode because it predates theming;
    /// following the app theme instead reads as intentional rather than broken.
    static var dialogBackground: NSColor { pick(rgb(240, 240, 240), rgb(43, 43, 43)) }
    static var dialogPanel: NSColor { pick(rgb(255, 255, 255), rgb(50, 50, 50)) }
    static var dialogStroke: NSColor { pick(rgb(160, 160, 160), rgb(90, 90, 90)) }
    static var dialogEtchDark: NSColor { pick(rgb(160, 160, 160), rgb(28, 28, 28)) }
    static var dialogEtchLight: NSColor { pick(rgb(255, 255, 255), rgb(70, 70, 70)) }
    static var dialogButton: NSColor { pick(rgb(225, 225, 225), rgb(60, 60, 60)) }
    static var dialogButtonHover: NSColor { pick(rgb(229, 241, 251), rgb(72, 72, 72)) }
    static var dialogButtonPressed: NSColor { pick(rgb(204, 228, 247), rgb(52, 52, 52)) }

    /// CardStrokeColorDefault — the hairline around the content card.
    static var cardStroke: NSColor { pick(black(0.0578), white(0.0698)) }

    // MARK: - Subtle fills (hover / press states)

    static var subtleHover: NSColor { pick(black(0.0373), white(0.0605)) }
    static var subtlePressed: NSColor { pick(black(0.0241), white(0.0419)) }
    static var subtleSelected: NSColor { pick(black(0.0605), white(0.0837)) }

    // MARK: - Text

    static var textPrimary: NSColor { pick(black(0.8956), white(1.0)) }
    static var textSecondary: NSColor { pick(black(0.6063), white(0.786)) }
    static var textTertiary: NSColor { pick(black(0.4458), white(0.5442)) }
    static var textDisabled: NSColor { pick(black(0.3614), white(0.3628)) }

    // MARK: - Strokes

    static var dividerStroke: NSColor { pick(black(0.0803), white(0.0837)) }
    static var controlStroke: NSColor { pick(black(0.0578), white(0.0698)) }

    // MARK: - Accent

    /// Follows the user's macOS accent colour so the app feels native-ish while
    /// still being Explorer-shaped; falls back to Windows' own default blue
    /// (#0078D4) when the system is set to graphite/multicolour.
    static var accent: NSColor {
        let system = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        return system ?? pick(rgb(0, 95, 184), rgb(96, 205, 255))
    }

    static var accentText: NSColor { pick(rgb(0, 95, 184), rgb(96, 205, 255)) }

    // MARK: - Caption buttons

    /// Explorer's close button turns Windows' fixed red on hover regardless of
    /// accent colour.
    static var closeHover: NSColor { rgb(232, 17, 35) }
    static var closePressed: NSColor { rgb(241, 112, 122) }

    // MARK: - Metrics (Windows 11 Explorer, 100% scaling)

    enum Metrics {
        static let tabStripHeight: CGFloat = 40
        static let addressBarHeight: CGFloat = 48
        static let commandBarHeight: CGFloat = 48
        static let statusBarHeight: CGFloat = 26
        static let columnHeaderHeight: CGFloat = 30

        /// Explorer's default row height; the "紧凑视图" toggle drops it to 24.
        static let rowHeight: CGFloat = 32
        static let compactRowHeight: CGFloat = 24

        static let navPaneWidth: CGFloat = 200
        static let navPaneMinWidth: CGFloat = 148
        static let navPaneMaxWidth: CGFloat = 420
        static let navRowHeight: CGFloat = 32
        static let navIndent: CGFloat = 16

        static let captionButtonWidth: CGFloat = 46
        static let captionButtonHeight: CGFloat = 32

        /// WinUI corner radii: 4 for list rows and small controls, 8 for the
        /// window itself and flyouts.
        static let cornerSmall: CGFloat = 4
        static let cornerLarge: CGFloat = 8

        static let iconSize: CGFloat = 16
        static let rowIconGap: CGFloat = 10
        static let cellPadding: CGFloat = 12
    }
}
