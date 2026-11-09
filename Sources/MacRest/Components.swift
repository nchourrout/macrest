import AppKit
import MacRestCore
import SwiftUI

struct Banner: View {
    let text: String
    let severity: Severity
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity == .error ? "xmark.octagon.fill" : severity == .ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severity == .ok ? Color.accentColor : Theme.color(severity))
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background((severity == .ok ? Color.accentColor : Theme.color(severity)).opacity(0.12))
    }
}

/// When something runs: a short list of common choices, and Custom for an
/// arbitrary interval or a cron line.
struct ScheduleEditor: View {
    let title: String
    @Binding var schedule: ScheduleSetting
    /// Repo maintenance only takes days: an hourly prune is never wanted.
    var allowsHours = true
    /// Custom picked while the value is still one of the presets.
    @ViewState private var custom = false

    private var presets: [(String, ScheduleSetting)] {
        allowsHours
            ? [("Every hour", .everyHours(1)), ("Every 2 hours", .everyHours(2)), ("Every 4 hours", .everyHours(4)),
               ("Every 6 hours", .everyHours(6)), ("Every 12 hours", .everyHours(12)), ("Every day", .everyDays(1))]
            : [("Every day", .everyDays(1)), ("Every week", .everyDays(7)), ("Every 2 weeks", .everyDays(14)),
               ("Every month", .everyDays(30))]
    }

    private enum Choice: Hashable { case off, preset(ScheduleSetting), custom }

    private var choice: Binding<Choice> {
        Binding {
            if schedule == .disabled { return .off }
            if !custom, presets.contains(where: { $0.1 == schedule }) { return .preset(schedule) }
            return .custom
        } set: { new in
            switch new {
            case .off: custom = false; schedule = .disabled
            case let .preset(p): custom = false; schedule = p
            case .custom: custom = true; if schedule == .disabled { schedule = allowsHours ? .everyHours(3) : .everyDays(10) }
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case hours = "Hours", days = "Days", cron = "Cron"
        var id: String { rawValue }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch schedule {
            case .everyHours: .hours
            case .cron: .cron
            default: .days
            }
        } set: { new in
            switch new {
            case .hours: schedule = .everyHours(3)
            case .days: schedule = .everyDays(allowsHours ? 2 : 10)
            case .cron: schedule = .cron("0 * * * *")
            }
        }
    }

    var body: some View {
        Picker(title, selection: choice) {
            ForEach(presets, id: \.0) { Text($0.0).tag(Choice.preset($0.1)) }
            Divider()
            Text("Custom…").tag(Choice.custom)
            Text("Off").tag(Choice.off)
        }
        if choice.wrappedValue == .custom {
            Picker("Repeat in", selection: kind) {
                ForEach(Kind.allCases.filter { allowsHours || $0 != .hours }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch schedule {
            case let .everyHours(h):
                ValueStepper(label: "Every", value: h, text: h == 1 ? "1 hour" : "\(h) hours", range: 1...168) {
                    schedule = .everyHours($0)
                }
            case let .everyDays(d):
                ValueStepper(label: "Every", value: d, text: d == 1 ? "1 day" : "\(d) days", range: 1...365) {
                    schedule = .everyDays($0)
                }
            case let .cron(c):
                TextField("Cron expression", text: Binding(get: { c }, set: { schedule = .cron($0) }))
                    .font(.body.monospaced())
            case .disabled:
                EmptyView()
            }
        }
    }
}

/// How far back the kept snapshots reach, bucket by bucket, on a log scale
/// so a day of hourlies and two years of monthlies both read.
struct CoverageBar: View {
    let segments: [CoverageSegment]

    private static let floor = 1800.0

    var body: some View {
        if let last = segments.last {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    let total = log(last.to / Self.floor)
                    let gap = 2.0
                    // Each stretch keeps room for its label; the log scale
                    // shares out what is left.
                    let minWidth = 76.0
                    let usable = max(geo.size.width - gap * Double(segments.count - 1) - minWidth * Double(segments.count), 0)
                    HStack(spacing: gap) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                            let w = minWidth + log(seg.to / max(seg.from, Self.floor)) / total * usable
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.85 - Double(i) * 0.15))
                                    .frame(height: 10)
                                Text(seg.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: max(w, 1))
                        }
                    }
                }
                .frame(height: 30)
                HStack {
                    Text("Now")
                    Spacer()
                    Text("\(Self.span(last.to)) ago")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    static func span(_ seconds: TimeInterval) -> String {
        let days = seconds / 86400
        if days >= 365 { return Format.plural(Int((days / 365.25).rounded()), "year") }
        if days >= 60 { return Format.plural(Int((days / 30.44).rounded()), "month") }
        if days >= 14 { return Format.plural(Int((days / 7).rounded()), "week") }
        if days >= 1 { return Format.plural(Int(days.rounded()), "day") }
        return Format.plural(Int(seconds / 3600), "hour")
    }
}

extension Date {
    /// "Today 08:36", "Yesterday 14:02", "Mon 2 Nov 08:36".
    var activityLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today " + Format.date(self, "HH:mm") }
        if cal.isDateInYesterday(self) { return "Yesterday " + Format.date(self, "HH:mm") }
        if cal.isDateInTomorrow(self) { return "Tomorrow " + Format.date(self, "HH:mm") }
        let sameYear = cal.component(.year, from: self) == cal.component(.year, from: Date())
        return Format.date(self, sameYear ? "EEE d MMM HH:mm" : "d MMM yyyy HH:mm")
    }
}

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

/// A centred wait with a line saying what is being waited on.
struct Loading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
