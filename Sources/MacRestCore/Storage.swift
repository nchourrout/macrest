import Foundation

/// Where backups are stored, as a form a person fills in, and what restic
/// needs from it: a repository URI, environment variables for credentials,
/// and extra flags. Credentials never go into the URI, where they would show
/// in every log line and process listing; restic reads them from the
/// environment, and Backrest keeps that environment in its config (readable
/// by this user only).
public struct StorageForm: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case disk, sftp, s3, b2, rest, other
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .disk: "External Disk"
            case .sftp: "Server (SFTP)"
            case .s3: "S3-Compatible"
            case .b2: "Backblaze B2"
            case .rest: "REST Server"
            case .other: "Other"
            }
        }

        public var subtitle: String {
            switch self {
            case .disk: "A drive or a folder on this Mac"
            case .sftp: "A NAS or any machine with SSH"
            case .s3: "AWS, Cloudflare R2, Wasabi, MinIO…"
            case .b2: "Backblaze's own API"
            case .rest: "restic's rest-server"
            case .other: "Any restic repository URI"
            }
        }

        public var symbol: String {
            switch self {
            case .disk: "externaldrive"
            case .sftp: "server.rack"
            case .s3: "cloud"
            case .b2: "flame"
            case .rest: "network"
            case .other: "ellipsis.curlybraces"
            }
        }
    }

    /// How an SFTP connection authenticates.
    public enum SSHAuth: String, CaseIterable, Sendable {
        /// Whatever `ssh` would use on its own: ~/.ssh/config, the agent,
        /// the default keys.
        case system
        /// A key generated for MacRest (Backrest's SetupSftp), kept beside
        /// Backrest's config with its own known_hosts.
        case dedicated
    }

    public var kind: Kind = .disk
    // disk
    public var folder = ""
    // sftp
    public var host = ""
    public var port = ""
    public var user = ""
    public var remotePath = ""
    public var sshAuth: SSHAuth = .system
    public var identityFile = ""
    public var knownHostsFile = ""
    // s3
    public var endpoint = ""
    public var bucket = ""
    public var prefix = ""
    public var region = ""
    public var accessKey = ""
    public var secretKey = ""
    // b2
    public var b2KeyID = ""
    public var b2AppKey = ""
    // rest
    public var restURL = ""
    public var restUser = ""
    public var restPassword = ""
    // other
    public var rawURI = ""
    /// KEY=VALUE, one per line.
    public var rawEnv = ""

    public init(kind: Kind = .disk) { self.kind = kind }

    private func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func joined(_ parts: String...) -> String {
        parts.map { trim($0).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    public var uri: String {
        switch kind {
        case .disk:
            return trim(folder)
        case .sftp:
            let who = trim(user).isEmpty ? "" : trim(user) + "@"
            let path = trim(remotePath)
            // A non-default port goes in sftp.args (see `flags`); restic's
            // sftp:host:path form has no port.
            return path.isEmpty || trim(host).isEmpty ? "" : "sftp:\(who)\(trim(host)):\(path)"
        case .s3:
            guard !trim(bucket).isEmpty else { return "" }
            var host = trim(endpoint).isEmpty ? "s3.amazonaws.com" : trim(endpoint)
            if !host.hasPrefix("http://") && !host.hasPrefix("https://") { host = "https://" + host }
            return "s3:" + host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + joined(bucket, prefix)
        case .b2:
            guard !trim(bucket).isEmpty else { return "" }
            return "b2:\(trim(bucket)):" + joined(prefix)
        case .rest:
            var url = trim(restURL)
            guard !url.isEmpty else { return "" }
            if !url.hasPrefix("http://") && !url.hasPrefix("https://") { url = "https://" + url }
            return "rest:" + url
        case .other:
            return trim(rawURI)
        }
    }

    /// Credentials, as restic's environment variables.
    public var env: [String] {
        func pair(_ k: String, _ v: String) -> String? { trim(v).isEmpty ? nil : "\(k)=\(trim(v))" }
        switch kind {
        case .disk, .sftp:
            return []
        case .s3:
            return [pair("AWS_ACCESS_KEY_ID", accessKey), pair("AWS_SECRET_ACCESS_KEY", secretKey),
                    pair("AWS_DEFAULT_REGION", region)].compactMap { $0 }
        case .b2:
            return [pair("B2_ACCOUNT_ID", b2KeyID), pair("B2_ACCOUNT_KEY", b2AppKey)].compactMap { $0 }
        case .rest:
            return [pair("RESTIC_REST_USERNAME", restUser), pair("RESTIC_REST_PASSWORD", restPassword)].compactMap { $0 }
        case .other:
            return rawEnv.split(whereSeparator: \.isNewline).map { trim(String($0)) }.filter { $0.contains("=") }
        }
    }

    /// Extra restic flags: for SFTP, the port and a dedicated key, in the
    /// form Backrest's own UI writes (no double quotes: restic's option parser
    /// rejects them).
    public var flags: [String] {
        guard kind == .sftp else { return [] }
        var args = "-oBatchMode=yes"
        if sshAuth == .dedicated, !trim(identityFile).isEmpty { args += " -i \(trim(identityFile))" }
        if let p = Int(trim(port)), p != 22 { args += " -p \(p)" }
        if sshAuth == .dedicated, !trim(knownHostsFile).isEmpty { args += " -oUserKnownHostsFile=\(trim(knownHostsFile))" }
        return args == "-oBatchMode=yes" ? [] : ["--option=sftp.args='\(args)'"]
    }

    /// What is missing before the storage can be checked.
    public var missing: String? {
        switch kind {
        case .disk: return trim(folder).isEmpty ? "Choose a disk or a folder." : nil
        case .sftp:
            if trim(host).isEmpty { return "Enter the server's address." }
            if trim(remotePath).isEmpty { return "Enter the folder on the server." }
            if sshAuth == .dedicated, trim(identityFile).isEmpty { return "Create the key for MacRest first." }
            return nil
        case .s3:
            if trim(bucket).isEmpty { return "Enter the bucket." }
            if trim(accessKey).isEmpty || trim(secretKey).isEmpty { return "Enter the access key and the secret key." }
            return nil
        case .b2:
            if trim(bucket).isEmpty { return "Enter the bucket." }
            if trim(b2KeyID).isEmpty || trim(b2AppKey).isEmpty { return "Enter the key ID and the application key." }
            return nil
        case .rest: return trim(restURL).isEmpty ? "Enter the server's URL." : nil
        case .other: return trim(rawURI).isEmpty ? "Enter the repository URI." : nil
        }
    }

    /// The ssh command a person runs once to put the dedicated key on the
    /// server (it asks for their password there, which MacRest never sees).
    public var copyKeyCommand: String? {
        guard kind == .sftp, sshAuth == .dedicated, !trim(identityFile).isEmpty, !trim(host).isEmpty else { return nil }
        let who = trim(user).isEmpty ? trim(host) : "\(trim(user))@\(trim(host))"
        let port = Int(trim(port)).map { $0 != 22 ? " -p \($0)" : "" } ?? ""
        return "ssh-copy-id -i '\(trim(identityFile)).pub'\(port) \(who)"
    }
}

/// A credential variable as people call it.
public enum Credential {
    public static func label(_ key: String) -> String {
        switch key {
        case "AWS_ACCESS_KEY_ID": "Access key ID"
        case "AWS_SECRET_ACCESS_KEY": "Secret access key"
        case "AWS_DEFAULT_REGION": "Region"
        case "B2_ACCOUNT_ID": "Key ID"
        case "B2_ACCOUNT_KEY": "Application key"
        case "RESTIC_REST_USERNAME": "User"
        case "RESTIC_REST_PASSWORD": "Password"
        default: key
        }
    }

    /// Whether a value is a secret to mask (everything but ids and regions).
    public static func isSecret(_ key: String) -> Bool {
        !["AWS_ACCESS_KEY_ID", "AWS_DEFAULT_REGION", "B2_ACCOUNT_ID", "RESTIC_REST_USERNAME"].contains(key)
    }

    public static func split(_ line: String) -> (key: String, value: String) {
        guard let eq = line.firstIndex(of: "=") else { return (line, "") }
        return (String(line[..<eq]), String(line[line.index(after: eq)...]))
    }
}
