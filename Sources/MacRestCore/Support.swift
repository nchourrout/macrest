import Foundation

public enum Links {
    /// Backrest's local API, the one its web UI calls. The mac-config Backrest
    /// template fixes the port.
    public static let backrestURL = "http://localhost:9898"
}

/// How bad a reading is. Unknown sits between warning and error: a Backrest
/// that cannot be reached is worse than a warning and less certain than a
/// failure. Every comparison goes through `rank`.
public enum Severity: Int, Sendable {
    case ok, warning, error, unknown

    var rank: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .unknown: 2
        case .error: 3
        }
    }
}

extension Severity: Comparable {
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

/// Backrest's int64 fields arrive as JSON strings ("1793732038492"), the
/// protobuf JSON convention. Accepts a number too, and anything unreadable
/// decodes as nil rather than failing the whole document.
public struct LenientInt: Decodable, Sendable, Equatable {
    public let value: Int64?

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            value = Int64(s)
        } else {
            value = try? c.decode(Int64.self)
        }
    }
}

/// What one Backrest run status means.
enum RunOutcome {
    case success, warning, failed, cancelled, running, unknown

    init(_ status: String?) {
        switch status {
        case "STATUS_SUCCESS": self = .success
        case "STATUS_WARNING": self = .warning
        case "STATUS_ERROR": self = .failed
        // Backrest reports a backup killed by sleep as cancelled, not as an
        // error. It still did not back anything up, so it counts as a failure.
        case "STATUS_USER_CANCELLED", "STATUS_SYSTEM_CANCELLED": self = .cancelled
        case "STATUS_INPROGRESS", "STATUS_PENDING": self = .running
        default: self = .unknown
        }
    }
}

public enum Format {
    /// Bytes to a compact size. Single digits keep a decimal.
    public static func size(_ bytes: Int64) -> String {
        let units = ["K", "M", "G", "T"]
        var v = Double(max(bytes, 0)) / 1024
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if bytes < 1024 { return "\(max(bytes, 0)) B" }
        return v < 10 && i > 0
            ? String(format: "%.1f%@", v, units[i])
            : String(format: "%.0f%@", v, units[i])
    }

    /// Seconds to a compact age. Under a minute is "just now".
    public static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60)m ago"
        case ..<86400: "\(seconds / 3600)h ago"
        default: "\(seconds / 86400)d ago"
        }
    }

    public static func duration(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h \((s % 3600) / 60)m"
        default: return "\(s / 86400)d \((s % 86400) / 3600)h"
        }
    }

    /// Dates are English whatever the system locale, like every label here.
    public static func date(_ date: Date, _ pattern: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// A count with English thousands separators: "1,036", never "1.036",
    /// which reads as a decimal.
    public static func count<N: BinaryInteger>(_ n: N) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: Int64(n))) ?? String(n)
    }

    public static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }
}
