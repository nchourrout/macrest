import Foundation

/// Any JSON document, kept whole. Backrest's config travels through this
/// rather than through typed structs because `SetConfig` replaces the entire
/// config: a typed round trip would drop every field the app does not model
/// (the repo password, its guid, hooks, auth, sync identity) and Backrest would
/// save the loss. Edits touch only the keys they mean to.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        // Bool before number: a JSON `true` never decodes as a Double, and the
        // decoder refuses to read 0 or 1 as a Bool (covered by a test).
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n):
            // Whole numbers go out without a fraction: Backrest's int32 fields
            // reject "7.0".
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case let .object(o) = self else { return nil }
            return o[key]
        }
        set {
            guard case var .object(o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    /// Numbers, and the protobuf convention of int64 as a JSON string.
    public var number: Double? {
        switch self {
        case let .number(n): n
        case let .string(s): Double(s)
        default: nil
        }
    }

    /// Nil rather than a crash for a fraction, NaN or a value out of range:
    /// `Int(Double)` traps on those.
    public var int: Int? { number.flatMap { Int(exactly: $0.rounded()) } }

    public var int64: Int64? { number.flatMap { Int64(exactly: $0.rounded()) } }

    public var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    public var strings: [String] { array?.compactMap(\.string) ?? [] }
}
