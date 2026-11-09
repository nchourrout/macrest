import Foundation

/// A restic snapshot as Backrest's `ListSnapshots` returns it.
public struct ResticSnapshot: Decodable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var time: Date
    public var paths: [String]
    public var tags: [String]
    public var dataAdded: Int64?
    public var filesChanged: Int64?
    public var filesNew: Int64?

    public var shortID: String { String(id.prefix(8)) }

    enum CodingKeys: String, CodingKey { case id, unixTimeMs, paths, tags, summary }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let ms = (try? c.decode(LenientInt.self, forKey: .unixTimeMs))?.value ?? 0
        time = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        paths = (try? c.decode([String].self, forKey: .paths)) ?? []
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        let summary = try? c.decode(JSONValue.self, forKey: .summary)
        dataAdded = summary?["dataAdded"]?.number.map { Int64($0) }
        filesChanged = summary?["filesChanged"]?.number.map { Int64($0) }
        filesNew = summary?["filesNew"]?.number.map { Int64($0) }
    }
}

/// One file or folder inside a snapshot (`ListSnapshotFiles`).
public struct SnapshotEntry: Decodable, Sendable, Identifiable, Equatable, Hashable {
    public var name: String
    public var type: String
    public var path: String
    public var size: Int64?
    public var modified: Date?

    public var id: String { path }
    public var isDirectory: Bool { type == "dir" }

    enum CodingKeys: String, CodingKey { case name, type, path, size, mtime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? "file"
        path = try c.decode(String.self, forKey: .path)
        size = (try? c.decode(LenientInt.self, forKey: .size))?.value
        modified = (try? c.decode(String.self, forKey: .mtime)).flatMap(Snapshots.parseDate)
    }
}

public enum Snapshots {
    /// Newest first.
    public static func decode(_ data: Data) throws -> [ResticSnapshot] {
        struct List: Decodable { var snapshots: [ResticSnapshot]? }
        return (try JSONDecoder().decode(List.self, from: data).snapshots ?? []).sorted { $0.time > $1.time }
    }

    /// A folder's children: folders first, then by name. restic lists the
    /// folder itself as the first entry, which is dropped.
    public static func decodeEntries(_ data: Data, folder: String) throws -> [SnapshotEntry] {
        struct List: Decodable { var entries: [SnapshotEntry]? }
        let entries = try JSONDecoder().decode(List.self, from: data).entries ?? []
        return entries.filter { $0.path != folder }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// restic writes nanosecond fractions ("2026-11-09T12:36:32.53385299+01:00"),
    /// which ISO8601DateFormatter does not read, so the fraction is cut to
    /// milliseconds first.
    static func parseDate(_ s: String) -> Date? {
        var text = s
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            text = String(text[..<dot]) + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0) + String(text[zone...])
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// Where "restore next to the original" puts an item: a new folder beside
    /// it, named after it and the snapshot's date, that restic fills with the
    /// item itself. Backrest refuses a target that already exists, so a second
    /// restore of the same version gets a numbered name.
    public static func restoreTarget(for path: String, snapshotTime: Date, exists: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        let base = "\(url.lastPathComponent) (from \(Format.date(snapshotTime, "yyyy-MM-dd HH.mm")))"
        var candidate = (parent as NSString).appendingPathComponent(base)
        var n = 2
        while exists(candidate) {
            candidate = (parent as NSString).appendingPathComponent("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// The folders from the snapshot root down to `path`, for a breadcrumb:
    /// "/Users/nico/dev" under root "/Users/nico" gives ["/Users/nico", "/Users/nico/dev"].
    public static func breadcrumb(_ path: String, root: String) -> [String] {
        guard path.hasPrefix(root) else { return [root] }
        var out = [root]
        var current = root
        for part in path.dropFirst(root.count).split(separator: "/") {
            current += (current.hasSuffix("/") ? "" : "/") + part
            out.append(current)
        }
        return out
    }
}
