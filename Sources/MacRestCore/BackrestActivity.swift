import Foundation

/// Backrest's oplog as the Backups window shows it: every operation, not only
/// backups (`BackrestOperations` keeps backups alone for the panel's tally),
/// grouped into flows. A flow is one execution: a scheduled backup brings its
/// snapshot indexing, its forget and the hooks that fired with it.
public struct BackrestOperation: Decodable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case backup, forget, prune, check, indexSnapshot, restore, stats, hook, command, unknown

        public var title: String {
            switch self {
            case .backup: "Backup"
            case .forget: "Retention"
            case .prune: "Prune"
            case .check: "Check"
            case .indexSnapshot: "Index snapshot"
            case .restore: "Restore"
            case .stats: "Stats"
            case .hook: "Hook"
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
    }

    public struct Stats: Sendable, Equatable {
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
    public var hookCondition: String?
    public var restoreTarget: String?

    public var outcome: Outcome { Outcome(status) }

    public enum Outcome: Sendable, Equatable {
        case success, warning, failed, cancelled, running, pending, unknown

        init(_ status: String) {
            switch status {
            case "STATUS_PENDING": self = .pending
            case "STATUS_INPROGRESS": self = .running
            default:
                switch RunOutcome(status) {
                case .success: self = .success
                case .warning: self = .warning
                case .failed: self = .failed
                case .cancelled: self = .cancelled
                default: self = .unknown
                }
            }
        }

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

        let kinds: [(CodingKeys, Kind)] = [
            (.operationBackup, .backup), (.operationForget, .forget), (.operationPrune, .prune),
            (.operationCheck, .check), (.operationIndexSnapshot, .indexSnapshot), (.operationRestore, .restore),
            (.operationStats, .stats), (.operationRunHook, .hook), (.operationRunCommand, .command),
        ]
        kind = kinds.first { c.contains($0.0) }?.1 ?? .unknown

        switch kind {
        case .backup:
            let b = try? c.decode(JSONValue.self, forKey: .operationBackup)
            let status = b?["lastStatus"]?["status"]
            let summary = b?["lastStatus"]?["summary"]
            func i64(_ v: JSONValue?) -> Int64? { v?.int64 }
            backup = BackupProgress(
                percentDone: status?["percentDone"]?.number, bytesDone: i64(status?["bytesDone"]),
                totalBytes: i64(status?["totalBytes"]), filesDone: i64(status?["filesDone"]),
                totalFiles: i64(status?["totalFiles"]), currentFile: status?["currentFile"]?.strings.first,
                dataAdded: i64(summary?["dataAdded"]), filesNew: i64(summary?["filesNew"]),
                filesChanged: i64(summary?["filesChanged"]), bytesProcessed: i64(summary?["totalBytesProcessed"]),
                errors: b?["errors"]?.array?.count ?? 0)
        case .stats:
            let s = (try? c.decode(JSONValue.self, forKey: .operationStats))?["stats"]
            stats = Stats(totalSize: s?["totalSize"]?.int64,
                          uncompressedSize: s?["totalUncompressedSize"]?.int64,
                          snapshotCount: s?["snapshotCount"]?.int64)
        case .hook:
            let h = try? c.decode(JSONValue.self, forKey: .operationRunHook)
            hookCondition = h?["condition"]?.string
        case .restore:
            let r = try? c.decode(JSONValue.self, forKey: .operationRestore)
            restoreTarget = r?["target"]?.string
        default:
            break
        }
    }

    /// Why it went wrong, in one line. restic's exit_error JSON is buried in
    /// Backrest's message after the command line, so its `message` is pulled
    /// out when there is one; otherwise the panel's "Fatal:" extraction.
    public var reason: String? {
        guard let message, outcome.severity != .ok else { return nil }
        return Activity.reason(from: message)
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
        steps.map(\.outcome.severity).max { $0.rank < $1.rank } ?? .ok
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

    /// The newest finished stats run: the repository's size and snapshot count.
    public static func latestStats(_ operations: [BackrestOperation]) -> (BackrestOperation.Stats, Date)? {
        operations.filter { $0.kind == .stats && $0.outcome == .success && $0.stats?.totalSize != nil }
            .max { $0.id < $1.id }
            .map { ($0.stats!, $0.end ?? $0.start) }
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
        return Format.date(day, sameYear ? "EEEE d MMMM" : "d MMMM yyyy")
    }
}

extension Activity {
    public static func byDay(_ flows: [ActivityFlow], calendar: Calendar = .current) -> [ActivityDay] {
        let groups = Dictionary(grouping: flows) { calendar.startOfDay(for: $0.start) }
        return groups.map { ActivityDay(day: $0.key, flows: $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    /// The newest finished run of one kind, anywhere in the log: a check or a
    /// prune is its own flow, a forget rides inside a backup's.
    public static func lastFinished(_ kind: BackrestOperation.Kind, in flows: [ActivityFlow]) -> BackrestOperation? {
        flows.flatMap(\.steps)
            .filter { $0.kind == kind && $0.outcome != .running && $0.outcome != .pending }
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
        func lockFailure(_ op: BackrestOperation) -> Bool {
            op.outcome.severity == .error && (op.reason ?? "").contains("locked")
        }
        let forgets = flows.flatMap(\.steps).filter { $0.kind == .forget }.sorted { $0.id > $1.id }
        guard let last = forgets.first, lockFailure(last), let reason = last.reason else { return nil }
        if let unlockedAt, (last.end ?? last.start) < unlockedAt { return nil }
        let streak = forgets.prefix(while: lockFailure).count
        return StaleLock(failedRuns: streak, coversWholeLog: streak == forgets.count, reason: reason)
    }
}
