import Foundation

/// Backrest's oplog as Activity shows it: every operation, grouped into
/// flows. A flow is one execution: a scheduled backup brings its
/// snapshot indexing, its forget and the hooks that fired with it.
public struct BackrestOperation: Decodable, Sendable, Identifiable, Equatable {
    public enum Kind: Sendable, Equatable {
        case backup, forget, prune, check, indexSnapshot, restore, stats, hook, command, unknown

        public var title: String {
            switch self {
            case .backup: "Backup"
            case .forget: "Cleanup"
            case .prune: "Space recovery"
            case .check: "Verification"
            case .indexSnapshot: "Indexing"
            case .restore: "Restore"
            case .stats: "Size check"
            case .hook: "Script"
            case .command: "Command"
            case .unknown: "Operation"
            }
        }

        public var symbol: String {
            switch self {
            case .backup: "externaldrive.badge.timemachine"
            case .forget: "calendar.badge.minus"
            case .prune: "scissors"
            case .check: "checkmark.shield"
            case .indexSnapshot: "list.bullet.indent"
            case .restore: "arrow.uturn.backward"
            case .stats: "chart.bar"
            case .hook: "bell"
            case .command: "terminal"
            case .unknown: "circle.dashed"
            }
        }

        /// Steps that only ever ride along with another operation in a flow.
        var isAccessory: Bool { self == .indexSnapshot || self == .hook }
    }

    /// A backup's progress while it runs, or its summary once done.
    public struct BackupProgress: Sendable, Equatable {
        public var percentDone: Double?
        public var bytesDone: Int64?
        public var totalBytes: Int64?
        public var filesDone: Int64?
        public var totalFiles: Int64?
        public var currentFile: String?
        /// Set once the run finished.
        public var dataAdded: Int64?
        public var filesNew: Int64?
        public var filesChanged: Int64?
        public var bytesProcessed: Int64?
        public var errors = 0
        /// Those of them macOS privacy protection refused, which only Full
        /// Disk Access lifts.
        public var permissionDenied = 0

        /// The unreadable items, in plain words: the private folders apart
        /// from other unreadable files, since only the first need an action.
        public var skippedText: String? {
            let other = errors - permissionDenied
            let parts = [permissionDenied > 0 ? Format.plural(permissionDenied, "private folder") : nil,
                         other > 0 ? Format.plural(other, "unreadable file") : nil].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " and ") + " skipped"
        }
    }

    public struct Stats: Sendable, Equatable, Codable {
        public var totalSize: Int64?
        public var uncompressedSize: Int64?
        public var snapshotCount: Int64?
    }

    public var id: Int64
    public var flowID: Int64
    public var planID: String
    public var repoID: String
    public var snapshotID: String?
    public var status: String
    public var start: Date
    public var end: Date?
    public var message: String?
    public var logref: String?
    public var kind: Kind
    public var backup: BackupProgress?
    public var stats: Stats?
    public var restoreTarget: String?
    /// A `RunCommand`'s restic arguments, and the log holding its output.
    public var command: String?
    public var outputLogref: String?
    /// A failure to reach the storage at all (offline, server asleep, disk
    /// unplugged): nothing was backed up, but nothing is broken either, so
    /// the verdict counts it as a missed run rather than a failure. Classified
    /// once at decode, since the verdict asks on every poll.
    public var storageUnreachable = false

    public var outcome: Outcome { Outcome(status) }

    /// When it ended, or started while it has not.
    public var finishedAt: Date { end ?? start }

    /// Failed because the storage was locked. The word itself: "unlocked"
    /// is not a lock.
    public var failedOnLock: Bool {
        outcome.severity == .error && (reason ?? "").range(of: #"\blocked\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Finished before the last unlock: a failure then hit a lock that is
    /// gone, so it is history, not a live problem.
    public func predates(unlock unlockedAt: Date?) -> Bool {
        unlockedAt.map { finishedAt < $0 } ?? false
    }

    public enum Outcome: Sendable, Equatable {
        case success, warning, failed, cancelled, running, pending, unknown

        init(_ status: String) {
            switch status {
            case "STATUS_PENDING": self = .pending
            case "STATUS_INPROGRESS": self = .running
            case "STATUS_SUCCESS": self = .success
            case "STATUS_WARNING": self = .warning
            case "STATUS_ERROR": self = .failed
            // Backrest reports a backup killed by sleep as cancelled, not as
            // an error. It still backed nothing up, so it counts as a failure.
            case "STATUS_USER_CANCELLED", "STATUS_SYSTEM_CANCELLED": self = .cancelled
            default: self = .unknown
            }
        }

        /// Queued or running: not finished yet.
        public var isUnderway: Bool { self == .running || self == .pending }

        public var severity: Severity {
            switch self {
            case .success, .running, .pending: .ok
            case .warning: .warning
            case .failed, .cancelled: .error
            case .unknown: .unknown
            }
        }

        public var label: String {
            switch self {
            case .success: "Done"
            case .warning: "Warning"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .running: "Running"
            case .pending: "Scheduled"
            case .unknown: "Unknown"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, flowId, planId, repoId, snapshotId, status, unixTimeStartMs, unixTimeEndMs, displayMessage, logref
        case operationBackup, operationForget, operationPrune, operationCheck, operationIndexSnapshot
        case operationRestore, operationStats, operationRunHook, operationRunCommand
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int64? { (try? c.decode(LenientInt.self, forKey: key))?.value }
        func string(_ key: CodingKeys) -> String? {
            (try? c.decode(String.self, forKey: key)).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let id = int(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "operation without an id")
        }
        self.id = id
        flowID = int(.flowId) ?? id
        planID = string(.planId) ?? ""
        repoID = string(.repoId) ?? ""
        snapshotID = string(.snapshotId)
        status = string(.status) ?? "STATUS_UNKNOWN"
        start = Date(timeIntervalSince1970: TimeInterval(int(.unixTimeStartMs) ?? 0) / 1000)
        end = int(.unixTimeEndMs).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0) / 1000) : nil }
        message = string(.displayMessage)
        logref = string(.logref)
        if Outcome(status) == .failed, let message {
            storageUnreachable = Self.isUnreachable(message)
        }

        let kinds: [(CodingKeys, Kind)] = [
            (.operationBackup, .backup), (.operationForget, .forget), (.operationPrune, .prune),
            (.operationCheck, .check), (.operationIndexSnapshot, .indexSnapshot), (.operationRestore, .restore),
            (.operationStats, .stats), (.operationRunHook, .hook), (.operationRunCommand, .command),
        ]
        kind = kinds.first { c.contains($0.0) }?.1 ?? .unknown

        switch kind {
        case .backup:
            let b = try? c.decode(JSONValue.self, forKey: .operationBackup)
            let errors = b?["errors"]?.array ?? []
            let status = b?["lastStatus"]?["status"]
            let summary = b?["lastStatus"]?["summary"]
            func i64(_ v: JSONValue?) -> Int64? { v?.int64 }
            backup = BackupProgress(
                percentDone: status?["percentDone"]?.number, bytesDone: i64(status?["bytesDone"]),
                totalBytes: i64(status?["totalBytes"]), filesDone: i64(status?["filesDone"]),
                totalFiles: i64(status?["totalFiles"]), currentFile: status?["currentFile"]?.strings.first,
                dataAdded: i64(summary?["dataAdded"]), filesNew: i64(summary?["filesNew"]),
                filesChanged: i64(summary?["filesChanged"]), bytesProcessed: i64(summary?["totalBytesProcessed"]),
                errors: errors.count,
                permissionDenied: errors.filter { $0["message"]?.string?.contains("operation not permitted") == true }.count)
        case .stats:
            let s = (try? c.decode(JSONValue.self, forKey: .operationStats))?["stats"]
            stats = Stats(totalSize: s?["totalSize"]?.int64,
                          uncompressedSize: s?["totalUncompressedSize"]?.int64,
                          snapshotCount: s?["snapshotCount"]?.int64)
        case .restore:
            let r = try? c.decode(JSONValue.self, forKey: .operationRestore)
            restoreTarget = r?["target"]?.string
        case .command:
            let r = try? c.decode(JSONValue.self, forKey: .operationRunCommand)
            command = r?["command"]?.string
            outputLogref = r?["outputLogref"]?.string
        default:
            break
        }
    }

    /// Why it went wrong, in one line. restic's exit_error JSON is buried in
    /// Backrest's message after the command line, so its `message` is pulled
    /// out when there is one; otherwise its "Fatal:" line.
    public var reason: String? {
        guard let message, outcome.severity != .ok else { return nil }
        return Activity.reason(from: message)
    }
}

extension BackrestOperation {
    /// What restic and ssh say when the storage cannot be reached: a server
    /// that does not answer, a network that is down, a disk that is not
    /// mounted. Matched against the whole output, where ssh's own line
    /// ("connect to host … Operation timed out") and restic's second line
    /// for a missing repository are, not just the one-line reason.
    static let unreachableMarkers = ["operation timed out", "connection timed out", "i/o timeout", "connection refused",
                                     "no route to host", "network is unreachable", "could not resolve hostname",
                                     "no such host", "is there a repository at the following location",
                                     // ssh died before restic read a byte, its stderr lost: seen
                                     // after the same 75 s connect timeout as the lines above.
                                     "error reading packet length: 0 of 4"]
    /// Reaching the storage and being refused is broken, not missed, even
    /// when a timeout shows in the same output.
    static let refusalMarkers = ["permission denied", "host key verification failed", "access denied",
                                 "wrong password", "unauthorized", "forbidden"]

    static func isUnreachable(_ message: String) -> Bool {
        let text = message.lowercased()
        return unreachableMarkers.contains { text.contains($0) } && !refusalMarkers.contains { text.contains($0) }
    }

    /// What went wrong, in plain words, for a hover or a one-line caption:
    /// unreadable files on a warning, the cause on a failure.
    public var problem: String? {
        switch outcome {
        case .warning:
            if let b = backup, let skipped = b.skippedText {
                return b.permissionDenied > 0 ? skipped + ", no Full Disk Access" : skipped
            }
            return reason
        case .cancelled:
            return outcome.label
        case .failed:
            return storageUnreachable ? "Storage unreachable" : reason
        default:
            return nil
        }
    }
}

/// One execution: the operation it is about and the steps that came with it.
public struct ActivityFlow: Sendable, Identifiable, Equatable {
    public var id: Int64
    public var primary: BackrestOperation
    /// Every operation in the flow, the primary included, oldest first.
    public var steps: [BackrestOperation]

    public var start: Date { primary.start }

    /// The worst step: a backup that succeeded while its forget failed is a
    /// warning on the backup's row, not a clean one.
    public var severity: Severity {
        steps.map(\.outcome.severity).max() ?? .ok
    }

    /// Steps that went wrong, other than the primary.
    public var failedSteps: [BackrestOperation] {
        steps.filter { $0.id != primary.id && $0.outcome.severity != .ok && $0.kind != .hook }
    }

    public var isActive: Bool { primary.outcome == .running }
}

public enum Activity {
    /// Flows, newest first, from `GetOperations`' `operations` array. Future
    /// pending entries (Backrest pre-schedules the next backup, prune and
    /// check) are returned separately as `scheduled`.
    public static func flows(_ operations: [BackrestOperation], now: Date) -> (flows: [ActivityFlow], scheduled: [BackrestOperation]) {
        let scheduled = operations.filter { $0.outcome == .pending && $0.start > now }
            .sorted { $0.start < $1.start }
        let past = operations.filter { !($0.outcome == .pending && $0.start > now) }
        let groups = Dictionary(grouping: past, by: \.flowID)
        // A flow of bookkeeping alone (Backrest indexing a snapshot it found
        // in the repository, a hook firing on its own) is not something that
        // happened to the backups, so it is left out of the history.
        let flows = groups.compactMap { id, ops -> ActivityFlow? in
            let steps = ops.sorted { $0.id < $1.id }
            guard let primary = steps.first(where: { !$0.kind.isAccessory }) else { return nil }
            return ActivityFlow(id: id, primary: primary, steps: steps)
        }
        return (flows.sorted { $0.start > $1.start }, scheduled)
    }

    public static func decode(_ data: Data) throws -> [BackrestOperation] {
        struct List: Decodable {
            var operations: [Lenient]?
        }
        // One undecodable entry (a new operation type, say) drops itself, not the log.
        struct Lenient: Decodable {
            var op: BackrestOperation?
            init(from decoder: Decoder) throws { op = try? BackrestOperation(from: decoder) }
        }
        return try JSONDecoder().decode(List.self, from: data).operations?.compactMap(\.op) ?? []
    }

    /// The newest restore into `target`: the one a Restore or a Quick Look
    /// started, followed by where it goes.
    public static func restore(into target: String, in operations: [BackrestOperation]) -> BackrestOperation? {
        operations.filter { $0.kind == .restore && $0.restoreTarget == target }.max { $0.id < $1.id }
    }

    /// The newest finished stats run: the repository's size and snapshot count.
    public static func latestStats(_ operations: [BackrestOperation]) -> (BackrestOperation.Stats, Date)? {
        operations.filter { $0.kind == .stats && $0.outcome == .success && $0.stats?.totalSize != nil }
            .max { $0.id < $1.id }
            .map { ($0.stats!, $0.finishedAt) }
    }

    static func reason(from message: String) -> String? {
        if let range = message.range(of: #"{"message_type":"exit_error""#) {
            let tail = message[range.lowerBound...]
            let json = tail.prefix { $0 != "\n" }
            if let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
               let text = value["message"]?.string {
                return text.split(separator: "\n").first.map(String.init)
            }
        }
        // Plain-text restic output (check, prune) follows an "Output:" line,
        // after progress chatter: the line that says what failed is the one
        // worth showing, not Backrest's command-line header.
        if let range = message.range(of: "\nOutput:\n") {
            let lines = message[range.upperBound...].split(separator: "\n").map(String.init)
            let markers = ["Fatal:", "unable to", "error", "denied", "no such", "failed"]
            if let line = lines.first(where: { l in markers.contains { l.localizedCaseInsensitiveContains($0) } }) {
                return line.hasPrefix("Fatal: ") ? String(line.dropFirst(7)) : line
            }
        }
        if let range = message.range(of: "Fatal: ") {
            var line = String(message[range.upperBound...].prefix { $0 != "\n" })
            while line.hasSuffix("}") || line.hasSuffix("\"") { line.removeLast() }
            if !line.isEmpty { return line }
        }
        return message.split(separator: "\n").map(String.init)
            .first { !$0.isEmpty && !$0.contains("bytes truncated") }
    }
}

/// History grouped by local calendar day, newest first.
public struct ActivityDay: Sendable, Identifiable, Equatable {
    public var day: Date
    public var flows: [ActivityFlow]
    public var id: Date { day }

    public init(day: Date, flows: [ActivityFlow]) {
        self.day = day
        self.flows = flows
    }

    /// "Today", "Yesterday", "Monday 2 November".
    public func title(now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return Format.date(day, sameYear ? "EEEE d MMMM" : "d MMMM yyyy", timeZone: calendar.timeZone)
    }
}

extension Activity {
    public static func byDay(_ flows: [ActivityFlow], calendar: Calendar = .current) -> [ActivityDay] {
        let groups = Dictionary(grouping: flows) { calendar.startOfDay(for: $0.start) }
        return groups.map { ActivityDay(day: $0.key, flows: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    /// When the next run of `kind` is due, from the scheduled entries.
    public static func next(_ kind: BackrestOperation.Kind, in scheduled: [BackrestOperation]) -> Date? {
        scheduled.first { $0.kind == kind }?.start
    }

    /// Whether any maintenance job's last run failed on a lock since the last
    /// unlock: cleanup, space recovery or verification, whichever hit it.
    public static func blockedByLock(_ flows: [ActivityFlow], unlockedAt: Date?) -> Bool {
        [BackrestOperation.Kind.forget, .prune, .check].contains { kind in
            guard let last = lastFinished(kind, in: flows) else { return false }
            return last.failedOnLock && !last.predates(unlock: unlockedAt)
        }
    }

    /// The size check asked for at `since`, once it has finished: the newest
    /// stats run started after it (a few seconds' slack for the two clocks).
    public static func sizeCheck(after since: Date, in operations: [BackrestOperation]) -> BackrestOperation? {
        operations.filter { $0.kind == .stats && !$0.outcome.isUnderway && $0.start >= since.addingTimeInterval(-5) }
            .max { $0.id < $1.id }
    }

    /// The newest finished run of one kind, anywhere in the log: a check or a
    /// prune is its own flow, a forget rides inside a backup's.
    public static func lastFinished(_ kind: BackrestOperation.Kind, in flows: [ActivityFlow]) -> BackrestOperation? {
        flows.flatMap(\.steps)
            .filter { $0.kind == kind && !$0.outcome.isUnderway }
            .max { $0.id < $1.id }
    }
}

/// Retention keeps failing on a lock nobody holds any more.
public struct StaleLock: Sendable, Equatable {
    /// Consecutive retention runs that hit it, newest first.
    public var failedRuns: Int
    /// Every retention run in the fetched log failed, so the streak may go
    /// back further than the log does.
    public var coversWholeLog: Bool
    public var reason: String
}

extension Activity {
    /// Retention needs an exclusive lock, so a lock left by a crashed run
    /// fails it after every backup while the backups themselves (a shared
    /// lock) keep succeeding: easy to miss for weeks. A failure older than
    /// the last unlock does not count: the lock it hit is gone, and only the
    /// next run can say whether retention works again.
    public static func staleLock(in flows: [ActivityFlow], unlockedAt: Date?) -> StaleLock? {
        let lockFailure = { (op: BackrestOperation) in op.failedOnLock }
        let forgets = flows.flatMap(\.steps).filter { $0.kind == .forget }.sorted { $0.id > $1.id }
        guard let last = forgets.first, lockFailure(last), let reason = last.reason else { return nil }
        if last.predates(unlock: unlockedAt) { return nil }
        let streak = forgets.prefix(while: lockFailure).count
        return StaleLock(failedRuns: streak, coversWholeLog: streak == forgets.count, reason: reason)
    }
}

/// What MacRest just asked the engine to run, by kind, until the oplog shows
/// it. Each button waits on its own kind only: one flag shared by every
/// request greyed out every button at each click, for the moment between
/// the click and the next poll.
public struct SentRequests: Sendable, Equatable {
    /// How long a request counts as on its way when the oplog never shows it.
    public static let grace: TimeInterval = 20
    private var sent: [BackrestOperation.Kind: Date] = [:]

    public init() {}

    public mutating func send(_ kind: BackrestOperation.Kind, at now: Date) { sent[kind] = now }
    public mutating func drop(_ kind: BackrestOperation.Kind) { sent[kind] = nil }

    /// Forgets the requests the oplog now holds (running, queued or already
    /// finished, which a fast run can be by the next poll) and those that
    /// waited past the grace period.
    public mutating func settle(_ operations: [BackrestOperation], now: Date) {
        sent = sent.filter { kind, at in
            now.timeIntervalSince(at) < Self.grace
                // A couple of seconds of slack: the engine stamps the start.
                && !operations.contains { $0.kind == kind && $0.start >= at.addingTimeInterval(-2) }
        }
    }

    public func isSending(_ kind: BackrestOperation.Kind, now: Date) -> Bool {
        sent[kind].map { now.timeIntervalSince($0) < Self.grace } ?? false
    }

    public func any(now: Date) -> Bool { sent.values.contains { now.timeIntervalSince($0) < Self.grace } }

    /// A run of this kind was just asked for, is queued, or is running.
    public func isBusy(_ kind: BackrestOperation.Kind, flows: [ActivityFlow], now: Date) -> Bool {
        isSending(kind, now: now)
            || flows.contains { $0.steps.contains { $0.kind == kind && $0.outcome.isUnderway } }
    }
}
