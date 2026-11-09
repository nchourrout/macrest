import Foundation

/// The one-glance verdict the menu bar icon and the top of the window show,
/// from the oplog alone.
///
/// Two families of signal. Backups: the last run, staleness, and the share of
/// failures over two weeks (a plan can fail most runs and still end on a good
/// one). Maintenance: retention, prune and check, which can fail on every run
/// while backups succeed (a stale lock does exactly that), so they raise the
/// verdict to a warning of their own instead of hiding behind a green backup.
public struct Overview: Sendable, Equatable {
    public var severity: Severity
    public var title: String
    public var subtitle: String
    /// One per local calendar day, oldest first, today last.
    public var days: [Day]
    public var ok = 0
    public var warned = 0
    public var failed = 0
    public var running = false
    /// The maintenance jobs whose last run failed, by title.
    public var failingMaintenance: [String] = []

    public struct Day: Sendable, Equatable {
        public var start: Date
        public var ok = 0
        public var warned = 0
        public var failed = 0
        public var total: Int { ok + warned + failed }
    }

    public static let windowDays = 14
    public static let staleHours = 36.0
    public static let warnPct = 10
    public static let errorPct = 50

    public var summary: String {
        var s = "\(ok) ok · \(failed) failed"
        if warned > 0 { s += " · \(warned) warned" }
        return s
    }

    public static func make(flows: [ActivityFlow], scheduled: [BackrestOperation], now: Date,
                            calendar: Calendar = .current) -> Overview {
        let backups = flows.map(\.primary).filter { $0.kind == .backup }.sorted { $0.id > $1.id }
        let finished = backups.filter { $0.outcome != .running && $0.outcome != .pending }
        let running = backups.contains { $0.outcome == .running }

        // The window, one column per day.
        let today = calendar.startOfDay(for: now)
        var days = (0..<windowDays).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Day(start: $0) }
        }
        for run in finished {
            guard let i = days.lastIndex(where: { $0.start <= run.start }), run.start >= days[0].start else { continue }
            switch run.outcome {
            case .success: days[i].ok += 1
            case .warning: days[i].warned += 1
            case .failed, .cancelled: days[i].failed += 1
            default: break
            }
        }
        let ok = days.map(\.ok).reduce(0, +), warned = days.map(\.warned).reduce(0, +), failed = days.map(\.failed).reduce(0, +)
        let total = ok + warned + failed

        let next = scheduled.first { $0.kind == .backup }?.start
        let nextText = next.map { n in
            " · next " + Format.date(n, calendar.isDate(n, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm", timeZone: calendar.timeZone)
        } ?? ""

        let maintenance: [BackrestOperation.Kind] = [.forget, .prune, .check]
        let failing = maintenance.compactMap { kind -> String? in
            guard let last = Activity.lastFinished(kind, in: flows), last.outcome.severity == .error else { return nil }
            return kind.title
        }

        var o = Overview(severity: .ok, title: "", subtitle: "", days: days, ok: ok, warned: warned, failed: failed,
                         running: running, failingMaintenance: failing)

        guard let last = finished.first else {
            o.severity = running ? .ok : .unknown
            o.title = running ? "First backup running" : "No backups yet"
            o.subtitle = "never run" + nextText
            return o
        }
        let age = now.timeIntervalSince(last.end ?? last.start)
        o.subtitle = "last backup " + Format.ago(Int(age)) + nextText

        if age > staleHours * 3600 {
            o.severity = .error
            o.title = "Backups have stopped"
            return o
        }
        let failPct = total > 0 ? failed * 100 / total : 0
        let warnPct = total > 0 ? warned * 100 / total : 0
        let chronic: Severity = failPct >= errorPct ? .error
            : (failPct >= Self.warnPct || warnPct >= Self.warnPct) ? .warning : .ok

        switch last.outcome {
        case .failed, .cancelled:
            o.severity = .error
            o.title = last.outcome == .cancelled ? "Last backup was cancelled" : "Last backup failed"
        case .warning:
            o.severity = max(.warning, chronic)
            o.title = "Last backup warned"
        default:
            o.severity = chronic
            o.title = chronic != .ok ? "Backups failing often" : running ? "Backing up" : "Backups healthy"
        }
        if o.severity == .ok, !failing.isEmpty {
            o.severity = .warning
            o.title = failing.count == 1 ? "\(failing[0]) is failing" : "Maintenance is failing"
        }
        return o
    }
}
