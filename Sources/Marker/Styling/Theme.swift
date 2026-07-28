import AppKit

enum TypefaceChoice: String, CaseIterable, Codable {
    case system, serif, roundedSans, mono

    var displayName: String {
        switch self {
        case .system: return "System Sans"
        case .serif: return "New York (Serif)"
        case .roundedSans: return "SF Rounded"
        case .mono: return "Monospaced"
        }
    }
}

/// All fonts, colors and metrics used to render the editor.
///
/// Rebuilt whenever preferences change; the styler holds one and re-applies.
struct Theme {

    // MARK: Metrics

    var baseSize: CGFloat
    var contentWidth: CGFloat
    var lineHeightMultiple: CGFloat
    var paragraphSpacing: CGFloat
    var indentUnit: CGFloat
    var codePadding: CGFloat = 12
    var quoteIndent: CGFloat = 20

    // MARK: Fonts

    var body: NSFont
    var bodyItalic: NSFont
    var bodyBold: NSFont
    var bodyBoldItalic: NSFont
    var mono: NSFont
    var monoBold: NSFont
    var inlineCode: NSFont
    /// Effectively zero-width; used to conceal syntax markers without removing them.
    var concealed: NSFont

    private var headingFonts: [NSFont]

    // MARK: Colors

    var text: NSColor
    var secondaryText: NSColor
    var faintText: NSColor
    var marker: NSColor
    var heading: NSColor
    var accent: NSColor
    var link: NSColor
    var codeText: NSColor
    var codeBackground: NSColor
    var codeBorder: NSColor
    var inlineCodeBackground: NSColor
    var inlineCodeText: NSColor
    var quoteBar: NSColor
    var quoteText: NSColor
    var rule: NSColor
    var tableBorder: NSColor
    var tableHeaderBackground: NSColor
    var highlightBackground: NSColor
    var selection: NSColor
    var background: NSColor
    var insertionPoint: NSColor

    // MARK: Syntax colors

    var synKeyword: NSColor
    var synString: NSColor
    var synComment: NSColor
    var synNumber: NSColor
    var synType: NSColor
    var synFunction: NSColor
    var synPunctuation: NSColor
    var synAdded: NSColor
    var synRemoved: NSColor

    // MARK: - Construction

    init(preferences: Preferences) {
        let size = preferences.fontSize
        baseSize = size
        contentWidth = preferences.contentWidth
        lineHeightMultiple = preferences.lineHeight
        paragraphSpacing = size * 0.75
        indentUnit = size * 1.5

        let weightedBody: NSFont
        switch preferences.typeface {
        case .system:
            weightedBody = .systemFont(ofSize: size, weight: .regular)
        case .serif:
            weightedBody = Theme.designedSystemFont(size: size, design: .serif, weight: .regular)
        case .roundedSans:
            weightedBody = Theme.designedSystemFont(size: size, design: .rounded, weight: .regular)
        case .mono:
            weightedBody = .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        body = weightedBody
        bodyBold = Theme.applying(traits: .boldFontMask, to: weightedBody)
        bodyItalic = Theme.applying(traits: .italicFontMask, to: weightedBody)
        bodyBoldItalic = Theme.applying(traits: [.boldFontMask, .italicFontMask], to: weightedBody)

        let monoSize = round(size * 0.92)
        mono = .monospacedSystemFont(ofSize: monoSize, weight: .regular)
        monoBold = .monospacedSystemFont(ofSize: monoSize, weight: .semibold)
        inlineCode = .monospacedSystemFont(ofSize: round(size * 0.9), weight: .regular)
        concealed = .systemFont(ofSize: 0.01)

        let scales: [CGFloat] = [1.85, 1.45, 1.22, 1.08, 1.0, 0.94]
        let headingDesign: NSFontDescriptor.SystemDesign = preferences.typeface == .serif ? .serif : .default
        headingFonts = scales.enumerated().map { index, scale in
            let weight: NSFont.Weight = index < 2 ? .bold : .semibold
            return Theme.designedSystemFont(size: round(size * scale),
                                            design: headingDesign,
                                            weight: weight)
        }

        // Colors: semantic where AppKit has one, dynamic pairs where it doesn't.
        text = .labelColor
        secondaryText = .secondaryLabelColor
        faintText = .tertiaryLabelColor
        marker = Theme.dynamic(light: NSColor(calibratedWhite: 0.62, alpha: 1),
                               dark: NSColor(calibratedWhite: 0.46, alpha: 1))
        heading = .labelColor
        accent = Theme.dynamic(light: NSColor(srgbRed: 0.78, green: 0.40, blue: 0.19, alpha: 1),
                               dark: NSColor(srgbRed: 0.93, green: 0.58, blue: 0.36, alpha: 1))
        link = .linkColor
        codeText = .labelColor
        codeBackground = Theme.dynamic(light: NSColor(calibratedWhite: 0.965, alpha: 1),
                                       dark: NSColor(calibratedWhite: 0.14, alpha: 1))
        codeBorder = Theme.dynamic(light: NSColor(calibratedWhite: 0.88, alpha: 1),
                                   dark: NSColor(calibratedWhite: 0.24, alpha: 1))
        inlineCodeBackground = Theme.dynamic(light: NSColor(calibratedWhite: 0.94, alpha: 1),
                                             dark: NSColor(calibratedWhite: 0.20, alpha: 1))
        inlineCodeText = Theme.dynamic(light: NSColor(srgbRed: 0.72, green: 0.24, blue: 0.30, alpha: 1),
                                       dark: NSColor(srgbRed: 0.95, green: 0.60, blue: 0.62, alpha: 1))
        quoteBar = Theme.dynamic(light: NSColor(calibratedWhite: 0.80, alpha: 1),
                                 dark: NSColor(calibratedWhite: 0.36, alpha: 1))
        quoteText = .secondaryLabelColor
        rule = Theme.dynamic(light: NSColor(calibratedWhite: 0.85, alpha: 1),
                             dark: NSColor(calibratedWhite: 0.30, alpha: 1))
        tableBorder = Theme.dynamic(light: NSColor(calibratedWhite: 0.84, alpha: 1),
                                    dark: NSColor(calibratedWhite: 0.30, alpha: 1))
        tableHeaderBackground = Theme.dynamic(light: NSColor(calibratedWhite: 0.96, alpha: 1),
                                              dark: NSColor(calibratedWhite: 0.17, alpha: 1))
        highlightBackground = Theme.dynamic(light: NSColor(srgbRed: 1.0, green: 0.93, blue: 0.55, alpha: 1),
                                            dark: NSColor(srgbRed: 0.55, green: 0.46, blue: 0.10, alpha: 1))
        selection = .selectedTextBackgroundColor
        background = Theme.dynamic(light: NSColor(calibratedWhite: 1.0, alpha: 1),
                                   dark: NSColor(calibratedWhite: 0.11, alpha: 1))
        insertionPoint = Theme.dynamic(light: NSColor(srgbRed: 0.78, green: 0.40, blue: 0.19, alpha: 1),
                                       dark: NSColor(srgbRed: 0.95, green: 0.62, blue: 0.40, alpha: 1))

        synKeyword = Theme.dynamic(light: NSColor(srgbRed: 0.61, green: 0.14, blue: 0.58, alpha: 1),
                                   dark: NSColor(srgbRed: 0.87, green: 0.53, blue: 0.87, alpha: 1))
        synString = Theme.dynamic(light: NSColor(srgbRed: 0.77, green: 0.10, blue: 0.09, alpha: 1),
                                  dark: NSColor(srgbRed: 0.99, green: 0.51, blue: 0.45, alpha: 1))
        synComment = Theme.dynamic(light: NSColor(srgbRed: 0.36, green: 0.42, blue: 0.47, alpha: 1),
                                   dark: NSColor(srgbRed: 0.50, green: 0.58, blue: 0.62, alpha: 1))
        synNumber = Theme.dynamic(light: NSColor(srgbRed: 0.11, green: 0.00, blue: 0.81, alpha: 1),
                                  dark: NSColor(srgbRed: 0.83, green: 0.76, blue: 0.48, alpha: 1))
        synType = Theme.dynamic(light: NSColor(srgbRed: 0.16, green: 0.36, blue: 0.60, alpha: 1),
                                dark: NSColor(srgbRed: 0.56, green: 0.82, blue: 0.98, alpha: 1))
        synFunction = Theme.dynamic(light: NSColor(srgbRed: 0.19, green: 0.44, blue: 0.44, alpha: 1),
                                    dark: NSColor(srgbRed: 0.51, green: 0.83, blue: 0.75, alpha: 1))
        synPunctuation = .secondaryLabelColor
        synAdded = Theme.dynamic(light: NSColor(srgbRed: 0.13, green: 0.50, blue: 0.20, alpha: 1),
                                 dark: NSColor(srgbRed: 0.51, green: 0.84, blue: 0.54, alpha: 1))
        synRemoved = Theme.dynamic(light: NSColor(srgbRed: 0.70, green: 0.15, blue: 0.15, alpha: 1),
                                   dark: NSColor(srgbRed: 0.94, green: 0.55, blue: 0.53, alpha: 1))
    }

    // MARK: - Lookups

    func headingFont(level: Int) -> NSFont {
        headingFonts[min(max(level, 1), 6) - 1]
    }

    func headingSpacingBefore(level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize * 1.6
        case 2: return baseSize * 1.4
        case 3: return baseSize * 1.1
        default: return baseSize * 0.9
        }
    }

    func headingSpacingAfter(level: Int) -> CGFloat {
        switch level {
        case 1, 2: return baseSize * 0.5
        default: return baseSize * 0.35
        }
    }

    /// Width reserved for a concealed list marker, so text hangs consistently.
    func listMarkerColumn(depth: Int) -> CGFloat {
        indentUnit * CGFloat(depth + 1)
    }

    // MARK: - Helpers

    private static func designedSystemFont(size: CGFloat,
                                           design: NSFontDescriptor.SystemDesign,
                                           weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: size) else { return base }
        return font
    }

    private static func applying(traits: NSFontTraitMask, to font: NSFont) -> NSFont {
        let manager = NSFontManager.shared
        var result = font
        if traits.contains(.boldFontMask) {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if traits.contains(.italicFontMask) {
            let italic = manager.convert(result, toHaveTrait: .italicFontMask)
            // Some system faces have no true italic; synthesize a slant instead.
            if italic == result {
                let slant = AffineTransform(m11: 1, m12: 0, m21: 0.22, m22: 1, tX: 0, tY: 0)
                let descriptor = result.fontDescriptor.withMatrix(slant)
                if let slanted = NSFont(descriptor: descriptor, size: result.pointSize) {
                    return slanted
                }
            }
            result = italic
        }
        return result
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }
}
