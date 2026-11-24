import Foundation

/// The one-glance verdict the menu bar icon and the top of the window show,
/// from the oplog alone.
///
/// Two families of signal. Backups: the last run that reached the storage,
/// and staleness. A failure that a later clean backup made up for no longer
/// counts, and a run that could not reach the storage at all (offline, server
/// asleep, disk unplugged) is a missed run, not a failure, until the misses
/// outlast the staleness limit. Maintenance: retention, prune and check,
/// which can fail on every run while backups succeed (a stale lock does
/// exactly that), so they raise the verdict to a warning of their own
/// instead of hiding behind a green backup.
public struct Overview: Sendable, Equatable {
    public var severity: Severity
    public var title: String
    public var subtitle: String
    /// One per local calendar day, oldest first, today last.
    public var days: [Day]
    public var ok: Int { days.map(\.ok).reduce(0, +) }
    public var warned: Int { days.map(\.warned).reduce(0, +) }
    public var failed: Int { days.map(\.failed).reduce(0, +) }
    public var missed: Int { days.map(\.missed).reduce(0, +) }
    public var running = false
    /// The maintenance jobs whose last run failed, by title.
    public var failingMaintenance: [String] = []
    /// Folders the last backup could not read because macOS privacy
    /// protection refused them: the backup engine lacks Full Disk Access.
    public var privateFoldersSkipped = 0

    public struct Day: Sendable, Equatable {
        public var start: Date
        public var ok = 0
        public var warned = 0
        public var failed = 0
        /// Runs that could not reach the storage.
        public var missed = 0
        /// What went wrong that day, each cause once, most frequent first,
        /// with its count when it happened more than once.
        public var problems: [String] = []
        public var total: Int { ok + warned + failed + missed }

        /// The day under the pointer: its runs, then what went wrong.
        public var summary: String {
            guard total > 0 else { return "no backup" }
            let counts = [(ok, "ok"), (warned, "warned"), (failed, "failed"), (missed, "missed")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            return ([counts] + problems).joined(separator: " · ")
        }
    }

    public static let windowDays = 14
    public static let staleHours = 36.0
    /// The share of failures since the last clean backup that turns a
    /// warning into an error.
    public static let errorPct = 50

    public var summary: String {
        var s = "\(ok) ok · \(failed) failed"
        if warned > 0 { s += " · \(warned) warned" }
        if missed > 0 { s += " · \(missed) missed" }
        return s
    }

    /// `unlockedAt`: maintenance failures from before the last unlock no
    /// longer count; the lock they hit is gone.
    public static func make(flows: [ActivityFlow], scheduled: [BackrestOperation], now: Date,
                            unlockedAt: Date? = nil, calendar: Calendar = .current) -> Overview {
        let backups = flows.map(\.primary).filter { $0.kind == .backup }.sorted { $0.id > $1.id }
        let finished = backups.filter { $0.outcome != .running && $0.outcome != .pending }
        let reached = finished.filter { !$0.storageUnreachable }
        let running = backups.contains { $0.outcome == .running }

        // The window, one column per day.
        let today = calendar.startOfDay(for: now)
        var days = (0..<windowDays).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { Day(start: $0) }
        }
        var causes = Array(repeating: [String](), count: days.count)
        for run in finished {
            guard let i = days.lastIndex(where: { $0.start <= run.start }), run.start >= days[0].start else { continue }
            if let problem = run.problem { causes[i].append(problem) }
            if run.storageUnreachable {
                days[i].missed += 1
                continue
            }
            switch run.outcome {
            case .success: days[i].ok += 1
            case .warning: days[i].warned += 1
            case .failed, .cancelled: days[i].failed += 1
            default: break
            }
        }
        for (i, list) in causes.enumerated() where !list.isEmpty {
            let counts = Dictionary(list.map { ($0, 1) }, uniquingKeysWith: +)
            days[i].problems = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .map { $0.value > 1 ? "\($0.value)× \($0.key)" : $0.key }
        }

        let next = scheduled.first { $0.kind == .backup }?.start
        let nextText = next.map { n in
            " · next " + Format.date(n, calendar.isDate(n, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm", timeZone: calendar.timeZone)
        } ?? ""

        let maintenance: [BackrestOperation.Kind] = [.forget, .prune, .check]
        let failing = maintenance.compactMap { kind -> String? in
            guard let last = Activity.lastFinished(kind, in: flows), last.outcome.severity == .error else { return nil }
            if let unlockedAt, (last.end ?? last.start) < unlockedAt { return nil }
            return kind.title
        }

        var o = Overview(severity: .ok, title: "", subtitle: "", days: days, running: running, failingMaintenance: failing)

        guard let last = reached.first else {
            if running {
                o.title = finished.isEmpty ? "First backup running" : "Backing up"
            } else if let oldest = finished.last {
                // Every loaded attempt missed the storage. The log is cut at
                // 400 operations, so a long outage can push the last good
                // backup out of it: the age of the misses is what is known.
                let stopped = now.timeIntervalSince(oldest.start) > staleHours * 3600
                o.severity = stopped ? .error : .warning
                o.title = stopped ? "Backups have stopped" : "Storage unreachable"
            } else {
                o.severity = .unknown
                o.title = "No backups yet"
            }
            o.subtitle = (finished.first.map { "Last try " + Format.ago(Int(now.timeIntervalSince($0.end ?? $0.start))) }
                          ?? "Never run") + nextText
            return o
        }
        o.privateFoldersSkipped = last.backup?.permissionDenied ?? 0
        let age = now.timeIntervalSince(last.end ?? last.start)
        // The newest attempt missed the storage: say so, the verdict still
        // stands on the last run that reached it.
        let missedSince = finished.first?.storageUnreachable == true ? " · storage unreachable" : ""
        o.subtitle = "Last backup " + Format.ago(Int(age)) + missedSince + nextText

        if age > staleHours * 3600 {
            o.severity = .error
            o.title = "Backups have stopped"
            return o
        }

        switch last.outcome {
        case .failed, .cancelled:
            o.severity = .error
            o.title = last.outcome == .cancelled ? "Last backup was cancelled" : "Last backup failed"
        case .warning:
            // Only what came after the last clean backup counts: a failure
            // it made up for is history, not a state.
            let sinceClean = reached.prefix { $0.outcome != .success }
            let failures = sinceClean.filter { $0.outcome.severity == .error }.count
            o.severity = failures * 100 >= errorPct * sinceClean.count ? .error : .warning
            o.title = "Last backup had warnings"
        default:
            o.title = running ? "Backing up" : "Backups healthy"
        }
        if o.severity == .ok, !failing.isEmpty {
            o.severity = .warning
            o.title = failing.count == 1 ? "\(failing[0]) is failing" : "Maintenance is failing"
        }
        return o
    }
}
