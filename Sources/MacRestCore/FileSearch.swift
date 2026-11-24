import Foundation

/// A file or folder found by name in the backups, with each version of it:
/// one per distinct modification time and size, newest first.
public struct FoundItem: Identifiable, Sendable, Equatable {
    public struct Version: Sendable, Equatable {
        public var modified: Date?
        public var size: Int64?
        /// The backups holding this version, newest first.
        public var snapshots: [String]
        /// When the newest of them was taken.
        public var lastSeen: Date
    }

    public var path: String
    public var isDirectory: Bool
    public var versions: [Version]

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var lastSeen: Date { versions.first?.lastSeen ?? .distantPast }
}

public struct FileSearchResult: Sendable, Equatable {
    public var items: [FoundItem]
    /// Backrest keeps the first 2 MB of a command's output: past that, the
    /// matches read so far are all there is.
    public var truncated: Bool
    public var snapshotCount: Int
}

/// Search by name across backups: restic `find`, run by Backrest's
/// `RunCommand` so it goes through the engine like every other restic call.
public enum FileSearch {
    /// How far back a search looks, one backup per day. restic walks each
    /// backup's whole tree, so every backup searched costs time over the
    /// network: hourly backups would be 720 walks.
    public static let days = 30
    /// What MacRest's own searches start with, to keep them out of Activity.
    public static let commandPrefix = "find --json --ignore-case"

    /// The backups a search covers: the last of each day over the last
    /// `days`, newest first, or the newest one when none is that recent.
    public static func snapshotsToSearch(_ all: [ResticSnapshot], now: Date, calendar: Calendar = .current) -> [ResticSnapshot] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let recent = Dictionary(grouping: all.filter { $0.time >= since }) { calendar.startOfDay(for: $0.time) }
            .compactMap { $0.value.max { $0.time < $1.time } }
            .sorted { $0.time > $1.time }
        if !recent.isEmpty { return recent }
        return all.max { $0.time < $1.time }.map { [$0] } ?? []
    }

    /// A name, or part of one, as a restic pattern: matched anywhere in the
    /// name unless it already carries wildcards.
    public static func pattern(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.contains(where: { "*?[".contains($0) }) ? q : "*\(q)*"
    }

    /// The `RunCommand` line. Backrest splits it like a shell would, so the
    /// pattern is double-quoted with `\` and `"` escaped.
    public static func command(query: String, snapshots: [String]) -> String {
        let quoted = "\"" + pattern(query).replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return ([commandPrefix] + snapshots.map { "--snapshot \($0)" } + [quoted]).joined(separator: " ")
    }

    /// Reads the command's log: Backrest's `command: …` line, then restic's
    /// JSON array of `{snapshot, matches}`, possibly cut off at the size
    /// limit. Complete entries before a cut are kept.
    public static func parse(_ log: String, snapshotTimes: [String: Date]) -> FileSearchResult {
        let (objects, complete) = arrayObjects(log)
        struct Hit: Decodable {
            var snapshot: String
            var matches: [Match]?
        }
        struct Match: Decodable {
            var path: String
            var type: String?
            var size: Int64?
            var mtime: String?
        }
        struct Found {
            var isDirectory: Bool
            /// By modification time and size: one entry per version.
            var versions: [String: FoundItem.Version] = [:]
        }
        let time = { (id: String) in snapshotTimes[id] ?? .distantPast }
        let decoder = JSONDecoder()
        var byPath: [String: Found] = [:]
        for object in objects {
            guard let hit = try? decoder.decode(Hit.self, from: Data(object.utf8)) else { continue }
            for m in hit.matches ?? [] {
                let isDir = m.type == "dir"
                let key = "\(m.mtime ?? "")|\(isDir ? -1 : (m.size ?? 0))"
                var found = byPath[m.path] ?? Found(isDirectory: isDir)
                var version = found.versions[key] ?? FoundItem.Version(
                    modified: m.mtime.flatMap(Snapshots.parseDate), size: isDir ? nil : m.size, snapshots: [], lastSeen: .distantPast)
                version.snapshots.append(hit.snapshot)
                found.versions[key] = version
                byPath[m.path] = found
            }
        }
        let items = byPath.map { path, found in
            let versions = found.versions.values.map { v -> FoundItem.Version in
                var v = v
                v.snapshots.sort { time($0) > time($1) }
                v.lastSeen = time(v.snapshots[0])
                return v
            }
            .sorted { $0.lastSeen != $1.lastSeen ? $0.lastSeen > $1.lastSeen : ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return FoundItem(path: path, isDirectory: found.isDirectory, versions: versions)
        }
        .sorted {
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return FileSearchResult(items: items, truncated: !complete, snapshotCount: snapshotTimes.count)
    }

    /// The top-level objects of the first JSON array in `text`, as strings,
    /// and whether the array was closed. A scanner rather than a decoder, so
    /// an array cut off mid-object still yields the objects before the cut.
    static func arrayObjects(_ text: String) -> ([String], Bool) {
        let chars = Array(text.utf8)
        // The array starts a line: Backrest's command line comes first, and
        // its arguments may contain a bracket.
        var i = 0
        var lineStart = true
        while i < chars.count {
            if lineStart && chars[i] == UInt8(ascii: "[") { break }
            lineStart = chars[i] == UInt8(ascii: "\n")
            i += 1
        }
        guard i < chars.count else { return ([], false) }
        var objects: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var objectStart = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else {
                switch c {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    if depth == 2 && c == UInt8(ascii: "{") { objectStart = i }
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 1 && c == UInt8(ascii: "}") {
                        objects.append(String(decoding: chars[objectStart...i], as: UTF8.self))
                    }
                    if depth == 0 { return (objects, true) }
                default: break
                }
            }
            i += 1
        }
        return (objects, false)
    }
}

/// Quick Look restores the file through Backrest into a cache folder of its
/// own; those restores, and the searches, are MacRest looking things up, not
/// something that happened to the backups.
public enum Lookups {
    public static func isLookup(_ op: BackrestOperation, previewRoot: String) -> Bool {
        switch op.kind {
        case .restore: op.restoreTarget?.hasPrefix(previewRoot) == true
        case .command: op.command?.hasPrefix(FileSearch.commandPrefix) == true
        default: false
        }
    }
}
