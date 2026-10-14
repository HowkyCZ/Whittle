import SwiftUI
import AppKit
import ScriberCore

/// Clay and dusky slate: warm paper, violet-leaning greys, terracotta for everything live (the mic, the editor
/// writing, what just changed), plum for the writer's exact words, slate teal for what's settled.
enum Theme {
    static let background = Color(hex: 0xF7F3EF)
    static let surface = Color(hex: 0xFFFDFB)
    static let hairline = Color(hex: 0xEBE5E1)
    static let border = Color(hex: 0xE6DFDB)
    static let control = Color(hex: 0xD9D2CE)
    static let chip = Color(hex: 0xEFE9E5)
    static let disabledFill = Color(hex: 0xECE6E2)
    static let quoteFill = Color(hex: 0xF4EFEB)

    static let ink = Color(hex: 0x24232A)
    static let body = Color(hex: 0x27262D)
    static let dockText = Color(hex: 0x2B2A31)
    static let controlText = Color(hex: 0x2F2E36)
    static let chipText = Color(hex: 0x403D47)
    static let secondary = Color(hex: 0x5E5B67)
    static let muted = Color(hex: 0x6C6975)
    static let destructive = Color(hex: 0xA3312A)

    /// Clay: the live mic, the editor writing, changes, targets. The brand colour.
    static let accent = Color(hex: 0xC55A3D)
    /// Slate teal: answers, ticks, approvals.
    static let unchanged = Color(hex: 0x3F6B66)
    static let unchangedFill = Color(hex: 0xE3ECEA)
    static let error = Color(hex: 0x9E2F2A)

    /// Peach: paraphrased gists.
    static let gistFill = Color(hex: 0xF8E4DA)
    static let gistInk = Color(hex: 0x9A5B40)
    /// Plum: the writer's exact words (locked wording, word-for-word dictation).
    static let exactFill = Color(hex: 0xF1E7EE)
    static let exactLine = Color(hex: 0x6E4466)

    /// The source banner: where the outside context came from.
    static let banner = Color(hex: 0xF3DFD3)
    static let bannerEdge = Color(hex: 0xE8BEAE)
    static let bannerInk = Color(hex: 0x954937)

    static let hud = Color(hex: 0x24232A)
    static let hudText = Color(hex: 0xF6F2EE)
    static let hudSecondary = Color(hex: 0xABA6B4)

    static let nsBackground = NSColor(hex: 0xF7F3EF)

    /// Review mode's chrome, so it reads as a different place; the draft sits on a sheet in it.
    static let reviewChrome = Color(hex: 0xEFE9E4)
    static let nsReviewChrome = NSColor(hex: 0xEFE9E4)
    static let emptyBox = Color(hex: 0xCCC5C2)

    /// An agent's colour, from its "#RRGGBB".
    static func agent(_ hex: String) -> Color { Color(hex: hexValue(hex)) }
    static func nsAgent(_ hex: String) -> NSColor { NSColor(hex: hexValue(hex)) }

    private static func hexValue(_ hex: String) -> UInt32 {
        UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x6C6975
    }
}

/// The same tokens for the AppKit text views.
extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static let scriberAccent = NSColor(hex: 0xC55A3D)
    static let scriberInk = NSColor(hex: 0x24232A)
    static let scriberBody = NSColor(hex: 0x27262D)
    static let scriberDockText = NSColor(hex: 0x2B2A31)
    static let scriberMuted = NSColor(hex: 0x6C6975)
    static let scriberGist = NSColor(hex: 0xF8E4DA)
    static let scriberExact = NSColor(hex: 0xF1E7EE)
    static let scriberExactLine = NSColor(hex: 0x6E4466)
    static let scriberDiscussed = NSColor(hex: 0xE3ECEA)
    /// Text selection: a neutral violet, so it's never mistaken for a change.
    static let scriberSelection = NSColor(hex: 0x8E87A3, alpha: 0.24)
}

/// Geist and Literata when installed; SF Pro, SF Mono and New York otherwise.
enum Typeface {
    private static let families = Set(NSFontManager.shared.availableFontFamilies)

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        families.contains("Geist")
            ? .custom("Geist", size: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    static let documentSize: CGFloat = 16.5
    static let documentLineHeight: CGFloat = 16.5 * 1.62

    static func nsUI(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if families.contains("Geist"),
           let font = NSFontManager.shared.font(withFamily: "Geist", traits: [], weight: weight == .medium ? 6 : 5, size: size) {
            return font
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func nsItalic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// The same face, bold and/or italic: by traits first, since the system serif's hidden names don't convert.
    static func nsStyled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if let styled = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize),
           styled.fontDescriptor.symbolicTraits.contains(traits) {
            return styled
        }
        var converted = font
        if bold { converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask) }
        if italic { converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask) }
        return converted
    }

    static func nsDocument(_ size: CGFloat = documentSize) -> NSFont {
        if let font = NSFont(name: "Literata", size: size) { return font }
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size)
    }
}

/// Text set at a fixed line height with the glyphs centered in it, like CSS line-height.
enum LineSetting {
    static func attributes(font: NSFont, color: NSColor, lineHeight: CGFloat) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        let natural = NSLayoutManager().defaultLineHeight(for: font)
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
            .baselineOffset: max(0, (lineHeight - natural) / 2)
        ]
    }
}

extension SpanRole {
    /// Transcript styling that lives in the text itself; fills are drawn behind it.
    func textAttributes(base font: NSFont) -> [NSAttributedString.Key: Any] {
        switch self {
        case .target:
            return [.underlineStyle: NSUnderlineStyle([.single, .patternDash]).rawValue, .underlineColor: NSColor.scriberAccent]
        case .meta:
            return [.foregroundColor: NSColor.scriberMuted, .font: Typeface.nsItalic(font)]
        case .instruction, .constraint:
            return [.foregroundColor: NSColor.scriberMuted]
        case .brief, .payload:
            return [:]
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
