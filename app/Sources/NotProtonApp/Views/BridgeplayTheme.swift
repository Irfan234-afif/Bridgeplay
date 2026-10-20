import CoreText
import SwiftUI

// The look of bridgeplay.dev (styles.css :root) for the app's own surfaces: black canvas,
// near-white type in Geist, hairline borders, small radii, and the violet-blue-pink
// gradient kept for emphasis only (progress, the last step, one word of a headline).
enum BP {
    static let bg = Color(hex: 0x000000)
    static let raise = Color(hex: 0x0D0D0F)
    static let raise2 = Color(hex: 0x161618)
    static let fg = Color(hex: 0xF5F5F7)
    static let fg2 = Color(hex: 0xA1A1A6)
    static let fg3 = Color(hex: 0x86868B)
    static let line = Color.white.opacity(0.08)
    static let lineStrong = Color.white.opacity(0.18)
    static let violet = Color(hex: 0x8B7BFF)
    static let blue = Color(hex: 0x4FB3FF)
    static let pink = Color(hex: 0xFF7AC6)
    static let green = Color(hex: 0x30D158)
    static let orange = Color(hex: 0xFF9F0A)
    static let red = Color(hex: 0xFF453A)

    static let iridescent = LinearGradient(colors: [violet, blue, pink], startPoint: .leading, endPoint: .trailing)
    static let iridescentDiagonal = LinearGradient(colors: [violet, blue, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let radius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    // cubic-bezier(0.16, 1, 0.3, 1), the site's --ease-out.
    static let easeOut = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.5)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        registerFonts()
        return .custom("Geist", size: size).weight(weight)
    }

    static func display(_ size: CGFloat) -> Font {
        registerFonts()
        return .custom("Unbounded", size: size).weight(.semibold)
    }

    // Process-scoped, so nothing is installed on the Mac. Missing glyphs (Chinese) fall
    // back to the system font.
    private static let registered: Void = {
        for name in ["geist", "unbounded"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "woff2", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static func registerFonts() { _ = registered }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// .pill on the site: white with black text, fully round. The secondary kind is a
// hairline capsule in the foreground colour.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    var kind: Kind = .primary
    var large = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BP.sans(large ? 14 : 13, .semibold))
            .tracking(-0.15)
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 4 : (large ? 18 : 13))
            .frame(height: large ? 34 : 28)
            .foregroundStyle(foreground)
            .background {
                switch kind {
                case .primary:
                    Capsule().fill(configuration.isPressed ? Color.white.opacity(0.85) : (isEnabled ? Color.white : BP.raise2))
                case .secondary:
                    Capsule().fill(configuration.isPressed ? BP.raise2 : Color.clear)
                        .overlay(Capsule().strokeBorder(BP.lineStrong, lineWidth: 1))
                case .plain:
                    Color.clear
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: isEnabled ? .black : BP.fg3
        case .secondary: isEnabled ? BP.fg : BP.fg3
        case .plain: isEnabled ? BP.fg2 : BP.fg3.opacity(0.6)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillLarge: PillButtonStyle { PillButtonStyle(large: true) }
    static var pillSecondary: PillButtonStyle { PillButtonStyle(kind: .secondary) }
    static var pillSecondaryLarge: PillButtonStyle { PillButtonStyle(kind: .secondary, large: true) }
    static var pillPlain: PillButtonStyle { PillButtonStyle(kind: .plain, large: true) }
}

// The Bridgeplay mark (helpers/icon/bridgeplay-mark.svg) as shapes in a 24-unit box, so the
// art can draw it in stroke by stroke: the deck and towers, the suspension cable, and the
// cable's reflection.
enum BridgePart { case deck, cable, echo }

struct BridgeShape: Shape {
    let part: BridgePart

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (2.4 + x * 0.8) * s, y: rect.minY + (2.4 + y * 0.8) * s)
        }
        var path = Path()
        switch part {
        case .deck:
            path.move(to: p(2, 14)); path.addLine(to: p(22, 14))
            path.move(to: p(6.5, 4)); path.addLine(to: p(6.5, 14))
            path.move(to: p(17.5, 4)); path.addLine(to: p(17.5, 14))
        case .cable:
            path.move(to: p(2, 7))
            path.addCurve(to: p(6.5, 4), control1: p(4.5, 7), control2: p(5.5, 4))
            path.addCurve(to: p(12, 11), control1: p(7.5, 4), control2: p(9.5, 11))
            path.addCurve(to: p(17.5, 4), control1: p(14.5, 11), control2: p(16.5, 4))
            path.addCurve(to: p(22, 7), control1: p(18.5, 4), control2: p(19.5, 7))
        case .echo:
            path.move(to: p(6.5, 16.5)); path.addLine(to: p(6.5, 19.5))
            path.move(to: p(17.5, 16.5)); path.addLine(to: p(17.5, 19.5))
            path.move(to: p(2, 21))
            path.addCurve(to: p(6.5, 19.4), control1: p(4.5, 21), control2: p(5.5, 19.4))
            path.addCurve(to: p(12, 17.3), control1: p(7.5, 19.4), control2: p(9.5, 17.3))
            path.addCurve(to: p(17.5, 19.4), control1: p(14.5, 17.3), control2: p(16.5, 19.4))
            path.addCurve(to: p(22, 21), control1: p(18.5, 19.4), control2: p(19.5, 21))
        }
        return path
    }

    // Stroke widths from the SVG, scaled to a mark drawn `size` points wide.
    static func width(_ part: BridgePart, size: CGFloat) -> CGFloat {
        let unit = size / 24 * 0.8
        switch part {
        case .deck: return 1.8 * unit
        case .cable: return 1.4 * unit
        case .echo: return 1.2 * unit
        }
    }
}

// The mark drawn flat on its black tile, as in the nav bar and favicon.
struct BridgeplayMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            BridgeShape(part: .deck)
                .stroke(BP.fg, style: StrokeStyle(lineWidth: BridgeShape.width(.deck, size: size), lineCap: .round))
            BridgeShape(part: .cable)
                .stroke(BP.fg, style: StrokeStyle(lineWidth: BridgeShape.width(.cable, size: size), lineCap: .round, lineJoin: .round))
            BridgeShape(part: .echo)
                .stroke(BP.fg.opacity(0.35), style: StrokeStyle(lineWidth: BridgeShape.width(.echo, size: size), lineCap: .round))
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(.black))
        .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(BP.lineStrong, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
