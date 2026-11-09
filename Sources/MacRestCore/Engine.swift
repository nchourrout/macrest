import Foundation

/// The Backrest release MacRest installs and runs. Pinned, with checksums,
/// rather than "latest": an update is a deliberate bump here, verified before
/// anything runs. Keep it at or above the version that last wrote the config,
/// since an older Backrest refuses a newer config.
public enum BackrestRelease {
    public static let version = "1.14.1"

    /// From the release's `backrest_<version>_checksums.txt`.
    static let sha256 = [
        "arm64": "ee938b56d796c96a8aaa5e40f8e8deb8c435f152992c541a5f53120892275695",
        "x86_64": "d59cb358f05ddcd265122091f249b0a1df493498909ea91d54f98fe84de27ebb",
    ]

    public static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    public static func asset(arch: String = arch) -> String { "backrest_Darwin_\(arch).tar.gz" }

    public static func url(arch: String = arch) -> URL {
        URL(string: "https://github.com/garethgeorge/backrest/releases/download/v\(version)/\(asset(arch: arch))")!
    }

    public static func checksum(arch: String = arch) -> String? { sha256[arch] }
}

/// The per-user LaunchAgent that keeps Backrest running, written to
/// ~/Library/LaunchAgents by MacRest. `AssociatedBundleIdentifiers` makes
/// System Settings list it under MacRest in Login Items rather than as a bare
/// executable, so the pair reads as one app.
public enum EngineAgent {
    public static let label = "com.nchourrout.macrest.backrest"
    public static let appBundleID = "com.nchourrout.macrest"
    /// Homebrew's service for the same thing, which a migration takes over
    /// from. Older Homebrew named it homebrew.mxcl.backrest.
    public static let homebrewLabels = ["sh.brew.backrest", "homebrew.mxcl.backrest"]

    public struct Paths: Sendable, Equatable {
        public var binary: String
        /// The same folders Homebrew's Backrest used (its defaults), so a
        /// takeover keeps the config, the oplog and restic, whose Full Disk
        /// Access grant is tied to that binary.
        public var config: String
        public var data: String
        public var log: String
        /// The restic Backrest downloads into its data folder. Named
        /// explicitly: left to search PATH, Backrest takes any restic of the
        /// right version it finds there (Homebrew's), and Full Disk Access is
        /// granted per executable, so Mail, Messages and Safari would be
        /// skipped silently.
        public var restic: String

        public init(home: String, support: String) {
            binary = support + "/backrest-\(BackrestRelease.version)/backrest"
            config = home + "/.config/backrest/config.json"
            data = home + "/.local/share/backrest"
            log = home + "/Library/Logs/MacRest/backrest.log"
            restic = home + "/.local/share/backrest/restic"
        }
    }

    public static func plist(_ paths: Paths) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [paths.binary],
            "EnvironmentVariables": [
                "BACKREST_CONFIG": paths.config,
                "BACKREST_DATA": paths.data,
                // Loopback only: the API has no auth, and it hands out the repo password.
                "BACKREST_PORT": "127.0.0.1:9898",
                "BACKREST_RESTIC_COMMAND": paths.restic,
                // System tools only (ssh is /usr/bin/ssh). No /opt/homebrew/bin:
                // see `restic` above.
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            // Standard, never Background: launchd throttles a Background job's
            // CPU and I/O and its restic children inherit it, which made a
            // folder listing take 25 s instead of 3 (restic decrypts the index
            // on every call).
            "ProcessType": "Standard",
            "StandardOutPath": paths.log,
            "StandardErrorPath": paths.log,
            "AssociatedBundleIdentifiers": [appBundleID],
        ]
    }

    public static func plistData(_ paths: Paths) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(paths), format: .xml, options: 0)
    }
}

/// What a fresh setup starts from.
public enum SetupDefaults {
    /// Caches, VMs, build output and app state that is rebuilt or synced on
    /// its own: worth nothing in a backup and most of its size. Paths are
    /// under `home`; `**/` patterns match at any depth. Taken from the setup
    /// mac-config used to template, which ran for months without one of them
    /// being missed.
    public static func excludes(home: String) -> [String] {
        let underHome = [
            ".Trash", ".cache", ".colima", ".docker", ".orbstack", ".lima", ".local/share/backrest",
            "Library/Caches", "Library/Logs", "Library/Metadata", "Library/Biome", "Library/IntelligencePlatform",
            "Library/DuetExpertCenter", "Library/Daemon Containers", "Library/Trial", "Library/Mobile Documents",
            "Library/CloudStorage", "Library/Containers", "Library/Group Containers",
            "Pictures/Photos Library.photoslibrary", "Library/Developer/Xcode/DerivedData",
            "Library/Developer/CoreSimulator", "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Application Support/backrest", "Library/Application Support/com.apple.wallpaper",
            "Library/Application Support/MacRest", "Library/Application Support/FileProvider",
            "Library/Preferences/ByHost/com.apple.notificationcenterui.plist",
        ].map { home + "/" + $0 }
        let anywhere = [
            "node_modules", ".venv", "__pycache__", ".next", ".turbo", ".DS_Store", "Cache", "Caches", "Code Cache",
            "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "ShaderCache", "GrShaderCache",
            "CachedData", "CachedExtensionVSIXs", "CachedProfilesData", "Service Worker", "WebStorage",
            "Partitions", "blob_storage", "Crashpad", "User/workspaceStorage", "User/History",
        ].map { "**/" + $0 }
        return underHome + anywhere
    }

    /// Backrest's instance id, from the machine name: it tags every snapshot
    /// (`created-by:<id>`), and a plan only lists snapshots carrying its own.
    /// A new Mac continuing an old one's repository should reuse that id.
    public static func instanceID(from name: String) -> String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "mac" : collapsed
    }

    /// A repository password: 32 characters from an alphabet without
    /// look-alikes, so it survives being written down.
    public static func password(length: Int = 32) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    public enum Destination: String, CaseIterable, Sendable {
        case sftp = "SFTP server", local = "Folder or disk", rest = "REST server", other = "Other (restic URI)"
    }

    /// The restic repository URI for a destination.
    public static func uri(_ kind: Destination, host: String = "", user: String = "", path: String = "", raw: String = "") -> String {
        let host = host.trimmingCharacters(in: .whitespaces), user = user.trimmingCharacters(in: .whitespaces)
        let path = path.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .sftp: return "sftp:" + (user.isEmpty ? "" : user + "@") + host + ":" + path
        case .local: return path
        case .rest: return "rest:" + (raw.isEmpty ? host : raw)
        case .other: return raw.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The repo and plan a setup creates, as Backrest JSON. Retention and
    /// checks start Time Machine style; `autoUnlock` clears a lock left by a
    /// crashed run, which otherwise fails retention, prune and check on every
    /// run while backups keep succeeding (safe while this Mac is the
    /// repository's only client).
    public static func repo(id: String, uri: String, password: String, env: [String] = [], autoUnlock: Bool) -> JSONValue {
        .object([
            "id": .string(id), "uri": .string(uri), "password": .string(password),
            "env": .array(env.map(JSONValue.string)),
            // No autoInitialize: AddRepo runs restic init itself and stamps the
            // repo's guid, and Backrest rejects the two together.
            "autoUnlock": .bool(autoUnlock),
            "prunePolicy": .object([
                "schedule": .object(["maxFrequencyDays": .number(7), "clock": .string("CLOCK_LAST_RUN_TIME")]),
                "maxUnusedPercent": .number(10),
            ]),
            "checkPolicy": .object([
                "schedule": .object(["maxFrequencyDays": .number(30), "clock": .string("CLOCK_LAST_RUN_TIME")]),
                "readDataSubsetPercent": .number(5),
            ]),
        ])
    }

    public static func plan(id: String, repo: String, paths: [String], excludes: [String], everyHours: Int) -> JSONValue {
        .object([
            "id": .string(id), "repo": .string(repo),
            "paths": .array(paths.map(JSONValue.string)),
            "excludes": .array(excludes.map(JSONValue.string)),
            "schedule": .object(["maxFrequencyHours": .number(Double(everyHours)), "clock": .string("CLOCK_LAST_RUN_TIME")]),
            "retention": .object(["policyTimeBucketed": .object([
                "hourly": .number(24), "daily": .number(30), "weekly": .number(52), "monthly": .number(24),
            ])]),
            "backup_flags": .array([.string("--exclude-caches")]),
        ])
    }

    /// Whether Backrest's config still needs a setup: no repository or no plan.
    public static func needsSetup(_ config: JSONValue) -> Bool {
        (config["repos"]?.array ?? []).isEmpty || (config["plans"]?.array ?? []).isEmpty
    }
}
