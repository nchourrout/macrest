import Foundation

/// The part of Backrest's config the Backups window edits, read out of the
/// whole document and written back into it (`applied(to:)`) so every other
/// field survives the round trip. See `JSONValue` for why.

/// When something runs. Backrest's `Schedule` is a oneof plus a clock.
public enum ScheduleSetting: Sendable, Equatable, Hashable {
    case disabled
    case everyHours(Int)
    case everyDays(Int)
    case cron(String)

    init(_ json: JSONValue?) {
        guard let json else { self = .disabled; return }
        if let h = json["maxFrequencyHours"]?.int { self = .everyHours(h) }
        else if let d = json["maxFrequencyDays"]?.int { self = .everyDays(d) }
        else if let c = json["cron"]?.string { self = .cron(c) }
        else { self = .disabled }
    }

    /// The clock is kept from the existing schedule when there is one: it is
    /// not edited here. A fresh interval counts from the last run (Backrest's
    /// own default for its interval schedules), a cron runs on local time.
    func json(keepingClock old: JSONValue?) -> JSONValue {
        let defaultClock = if case .cron = self { "CLOCK_LOCAL" } else { "CLOCK_LAST_RUN_TIME" }
        let clock = JSONValue.string(old?["clock"]?.string ?? defaultClock)
        switch self {
        case .disabled: return .object(["disabled": .bool(true)])
        case let .everyHours(h): return .object(["maxFrequencyHours": .number(Double(h)), "clock": clock])
        case let .everyDays(d): return .object(["maxFrequencyDays": .number(Double(d)), "clock": clock])
        case let .cron(c): return .object(["cron": .string(c), "clock": clock])
        }
    }

    public var summary: String {
        switch self {
        case .disabled: "Off"
        case let .everyHours(h): h == 1 ? "Every hour" : "Every \(h) hours"
        case let .everyDays(d): d == 1 ? "Every day" : "Every \(d) days"
        case let .cron(c): "Cron \(c)"
        }
    }
}

/// restic's `--keep-*` counts as Backrest names them.
public struct TimeBuckets: Sendable, Equatable, Hashable {
    public var hourly = 0
    public var daily = 0
    public var weekly = 0
    public var monthly = 0
    public var yearly = 0
    public var keepLastN = 0

    public init(hourly: Int = 0, daily: Int = 0, weekly: Int = 0, monthly: Int = 0, yearly: Int = 0, keepLastN: Int = 0) {
        self.hourly = hourly
        self.daily = daily
        self.weekly = weekly
        self.monthly = monthly
        self.yearly = yearly
        self.keepLastN = keepLastN
    }

    /// How far back the oldest kept snapshot reaches, roughly: the longest of
    /// the buckets, since each one keeps its own snapshots independently.
    public var horizon: String {
        if yearly > 0 { return Format.plural(yearly, "year") }
        if monthly > 0 { return Format.plural(monthly, "month") }
        if weekly > 0 { return Format.plural(weekly, "week") }
        if daily > 0 { return Format.plural(daily, "day") }
        if hourly > 0 { return Format.plural(hourly, "hour") }
        return keepLastN > 0 ? "the last \(Format.plural(keepLastN, "snapshot"))" : "nothing"
    }
}

public enum RetentionSetting: Sendable, Equatable, Hashable {
    case keepAll
    case lastN(Int)
    case buckets(TimeBuckets)

    init(_ json: JSONValue?) {
        if let n = json?["policyKeepLastN"]?.int { self = .lastN(n) }
        else if let b = json?["policyTimeBucketed"] {
            self = .buckets(TimeBuckets(hourly: b["hourly"]?.int ?? 0, daily: b["daily"]?.int ?? 0,
                                        weekly: b["weekly"]?.int ?? 0, monthly: b["monthly"]?.int ?? 0,
                                        yearly: b["yearly"]?.int ?? 0, keepLastN: b["keepLastN"]?.int ?? 0))
        } else { self = .keepAll }
    }

    var json: JSONValue {
        switch self {
        case .keepAll: return .object(["policyKeepAll": .bool(true)])
        case let .lastN(n): return .object(["policyKeepLastN": .number(Double(n))])
        case let .buckets(b):
            // Zero counts are left out, the way protojson writes them.
            var o: [String: JSONValue] = [:]
            for (key, value) in [("hourly", b.hourly), ("daily", b.daily), ("weekly", b.weekly),
                                 ("monthly", b.monthly), ("yearly", b.yearly), ("keepLastN", b.keepLastN)]
            where value > 0 { o[key] = .number(Double(value)) }
            return .object(["policyTimeBucketed": .object(o)])
        }
    }

    public var summary: String {
        switch self {
        case .keepAll: "Keeps every snapshot"
        case let .lastN(n): "Keeps the last \(Format.plural(n, "snapshot"))"
        case let .buckets(b): "Keeps about \(b.horizon) of history"
        }
    }
}

public enum CheckMode: Sendable, Equatable, Hashable {
    /// Indexes and trees only. Fast, but a damaged data pack goes unnoticed.
    case structureOnly
    /// Reads back this share of the pack data, a different sample each time.
    case readData(percent: Double)
}

/// One backup plan, as the window edits it.
public struct PlanSettings: Sendable, Equatable {
    public var id: String
    public var repo: String
    public var paths: [String]
    public var excludes: [String]
    public var schedule: ScheduleSetting
    public var retention: RetentionSetting
    public var skipIfUnchanged: Bool

    /// What would make Backrest refuse the plan, or make it back up nothing.
    public var problems: [String] {
        var p: [String] = []
        if paths.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty { p.append("Add at least one folder to back up.") }
        switch schedule {
        case let .everyHours(h) where h < 1, let .everyDays(h) where h < 1: p.append("The schedule needs an interval of at least 1.")
        case let .cron(c) where c.split(separator: " ").count != 5: p.append("A cron schedule has five fields.")
        default: break
        }
        switch retention {
        case let .lastN(n) where n < 1: p.append("Keep at least one snapshot.")
        case let .buckets(b) where b == TimeBuckets(): p.append("Retention keeps nothing: set at least one count.")
        default: break
        }
        return p
    }
}

/// The repository's maintenance schedules.
public struct RepoSettings: Sendable, Equatable {
    public var id: String
    public var uri: String
    public var checkSchedule: ScheduleSetting
    public var checkMode: CheckMode
    public var pruneSchedule: ScheduleSetting
    public var pruneMaxUnusedPercent: Double

    public var problems: [String] {
        var p: [String] = []
        if case let .readData(pct) = checkMode, !(pct > 0 && pct <= 100) { p.append("The share of data to read is between 1 and 100%.") }
        if !(pruneMaxUnusedPercent >= 0 && pruneMaxUnusedPercent <= 100) { p.append("Unused space before a prune is between 0 and 100%.") }
        return p
    }
}

public enum BackrestConfig {
    /// The first plan and its repository, which is the whole setup here. nil
    /// when the document has no plan or the plan names a missing repo.
    public static func read(_ config: JSONValue) -> (PlanSettings, RepoSettings)? {
        guard let plan = config["plans"]?.array?.first,
              let planID = plan["id"]?.string, let repoID = plan["repo"]?.string,
              let repo = config["repos"]?.array?.first(where: { $0["id"]?.string == repoID })
        else { return nil }
        let settings = PlanSettings(
            id: planID, repo: repoID, paths: plan["paths"]?.strings ?? [], excludes: plan["excludes"]?.strings ?? [],
            schedule: ScheduleSetting(plan["schedule"]), retention: RetentionSetting(plan["retention"]),
            skipIfUnchanged: plan["skipIfUnchanged"]?.bool ?? false)

        let check = repo["checkPolicy"]
        let mode: CheckMode = check?["readDataSubsetPercent"]?.number.map { .readData(percent: $0) } ?? .structureOnly
        let repoSettings = RepoSettings(
            id: repoID, uri: repo["uri"]?.string ?? "",
            checkSchedule: ScheduleSetting(check?["schedule"]), checkMode: mode,
            pruneSchedule: ScheduleSetting(repo["prunePolicy"]?["schedule"]),
            pruneMaxUnusedPercent: repo["prunePolicy"]?["maxUnusedPercent"]?.number ?? 0)
        return (settings, repoSettings)
    }

    /// `config` with the plan and repo replaced by these settings, everything
    /// else untouched, `modno` included: Backrest rejects a SetConfig whose
    /// modno is not the one it holds, so an edit made against a config that
    /// changed meanwhile fails instead of overwriting it.
    public static func applied(_ plan: PlanSettings, _ repo: RepoSettings, to config: JSONValue) -> JSONValue {
        var config = config
        if var plans = config["plans"]?.array, let i = plans.firstIndex(where: { $0["id"]?.string == plan.id }) {
            var p = plans[i]
            p["paths"] = .array(plan.paths.map(JSONValue.string))
            p["excludes"] = .array(plan.excludes.map(JSONValue.string))
            p["schedule"] = plan.schedule.json(keepingClock: p["schedule"])
            p["retention"] = plan.retention.json
            p["skipIfUnchanged"] = plan.skipIfUnchanged ? .bool(true) : nil
            plans[i] = p
            config["plans"] = .array(plans)
        }
        if var repos = config["repos"]?.array, let i = repos.firstIndex(where: { $0["id"]?.string == repo.id }) {
            var r = repos[i]
            var check = r["checkPolicy"] ?? .object([:])
            check["schedule"] = repo.checkSchedule.json(keepingClock: check["schedule"])
            switch repo.checkMode {
            case .structureOnly:
                check["structureOnly"] = .bool(true)
                check["readDataSubsetPercent"] = nil
            case let .readData(pct):
                check["structureOnly"] = nil
                check["readDataSubsetPercent"] = .number(pct)
            }
            r["checkPolicy"] = check
            var prune = r["prunePolicy"] ?? .object([:])
            prune["schedule"] = repo.pruneSchedule.json(keepingClock: prune["schedule"])
            prune["maxUnusedPercent"] = .number(repo.pruneMaxUnusedPercent)
            r["prunePolicy"] = prune
            repos[i] = r
            config["repos"] = .array(repos)
        }
        return config
    }
}

/// One stretch of the retention timeline: how far back a bucket reaches past
/// the buckets finer than it. A bucket reaching no further than a finer one
/// keeps nothing extra and is left out.
public struct CoverageSegment: Sendable, Equatable {
    public var label: String
    /// Seconds before now where the stretch starts and ends.
    public var from: TimeInterval
    public var to: TimeInterval
}

extension TimeBuckets {
    public var coverage: [CoverageSegment] {
        let hour = 3600.0, day = 86400.0
        let buckets: [(Int, String, Double)] = [
            (hourly, "hourly", hour), (daily, "daily", day), (weekly, "weekly", 7 * day),
            (monthly, "monthly", 30.44 * day), (yearly, "yearly", 365.25 * day),
        ]
        var reach = 0.0
        var out: [CoverageSegment] = []
        for (n, name, unit) in buckets where n > 0 {
            let end = Double(n) * unit
            guard end > reach else { continue }
            out.append(CoverageSegment(label: "\(n) \(name)", from: reach, to: end))
            reach = end
        }
        return out
    }
}
