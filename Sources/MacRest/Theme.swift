import AppKit
import MacRestCore
import SwiftUI

/// Catppuccin, matching the terminal and MacStatus: Latte in light mode,
/// Mocha in dark. Colour is reserved for something going wrong; a healthy
/// reading is drawn in the system's own primary and secondary.
enum Theme {
    static let warning = dynamic(light: 0xFE640B, dark: 0xFAB387)
    static let error = dynamic(light: 0xD20F39, dark: 0xF38BA8)
    static let track = Color.primary.opacity(0.09)

    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .ok: .primary
        case .warning, .unknown: warning
        case .error: error
        }
    }

    /// For icons and secondary text: healthy is secondary, not primary.
    static func tint(_ severity: Severity) -> Color {
        severity == .ok ? .secondary : color(severity)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// On the macOS 27 SDK `@State` resolves to a macro whose implementation ships
/// only with the full Xcode, so the Command Line Tools cannot build a view
/// that uses it. The property wrapper it expands to is still public, and a
/// typealias reaches it without the macro. Use `@ViewState` for `@State`.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Overview {
    /// The menu bar glyph: the state is carried by the silhouette, so it reads
    /// in the menu bar's monochrome.
    var menuSymbol: String {
        if running { return "arrow.triangle.2.circlepath" }
        switch severity {
        case .ok: return "clock.arrow.circlepath"
        case .warning: return "clock.badge.exclamationmark"
        case .error: return "exclamationmark.arrow.circlepath"
        case .unknown: return "clock.badge.questionmark"
        }
    }

    var symbol: String {
        switch severity {
        case .ok: running ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

