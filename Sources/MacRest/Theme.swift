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

struct Chevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
    }
}

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

/// Two weeks of backups, one column per day, oldest on the left. A column is
/// split by outcome, so one failure among six runs is a red sliver, and a day
/// with no run is an empty slot.
struct DaysChart: View {
    let overview: Overview
    var height: CGFloat = 18

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(overview.days, id: \.start) { DayColumn(day: $0) }
            }
            .frame(height: height)
            HStack {
                Text("\(Overview.windowDays) days ago")
                Spacer()
                Text(overview.summary)
                Spacer()
                Text("today")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

private struct DayColumn: View {
    let day: Overview.Day

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height, n = CGFloat(max(day.total, 1))
            VStack(spacing: 0) {
                if day.total == 0 {
                    Theme.track
                } else {
                    Theme.error.frame(height: h * CGFloat(day.failed) / n)
                    Theme.warning.frame(height: h * CGFloat(day.warned) / n)
                    Color.primary.opacity(0.24).frame(height: h * CGFloat(day.ok) / n)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2.5))
        .frame(maxWidth: .infinity)
        .help(tooltip)
    }

    private var tooltip: String {
        let date = Format.date(day.start, "EEE d MMM")
        guard day.total > 0 else { return "\(date): no backup" }
        var parts = ["\(day.ok) ok"]
        if day.warned > 0 { parts.append("\(day.warned) warned") }
        if day.failed > 0 { parts.append("\(day.failed) failed") }
        return "\(date): " + parts.joined(separator: ", ")
    }
}

/// A determinate bar drawn by hand: `ProgressView` does not render offscreen
/// (`--render`), and this one matches the day columns' weight.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
