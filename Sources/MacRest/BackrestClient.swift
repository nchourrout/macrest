import Foundation
import MacRestCore

/// Backrest's Connect API on localhost, the same one its web UI calls. Unary
/// calls are a JSON POST; `GetLogs` is a server stream (see `ConnectStream`).
enum BackrestClient {
    struct Failure: LocalizedError {
        var message: String
        var isTimeout = false
        var errorDescription: String? { message }
    }

    static func call(_ method: String, _ body: some Encodable, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(Links.backrestURL)/v1.Backrest/\(method)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            // Snapshot listings read the storage over the network, and Backrest
            // runs one restic command per repository at a time, so a listing can
            // wait behind a backup or another listing.
            throw Failure(message: "The backup engine took too long to answer. It reads the storage over the network and may be busy with another task.", isTimeout: true)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure(message: "The backup engine (Backrest) is not running. MacRest restarts it on its own; if this stays, use Restart Backup Engine in the … menu.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // A Connect error is {"code": "...", "message": "..."}.
            let error = try? JSONDecoder().decode(JSONValue.self, from: data)
            throw Failure(message: error?["message"]?.string ?? "Backrest answered \(status) to \(method)")
        }
        return data
    }

    static func getConfig() async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await call("GetConfig", JSONValue.object([:])))
    }

    /// Returns the config Backrest saved, with its new modno.
    static func setConfig(_ config: JSONValue) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await call("SetConfig", config))
    }

    static func operations(lastN: Int) async throws -> [BackrestOperation] {
        let body = JSONValue.object(["selector": .object([:]), "lastN": .string(String(lastN))])
        return try Activity.decode(try await call("GetOperations", body))
    }

    static func backup(plan: String) async throws {
        // The plan id travels as `value`, a name Backrest kept for curl scripts.
        _ = try await call("Backup", JSONValue.object(["value": .string(plan)]))
    }

    static func cancel(operation: Int64) async throws {
        _ = try await call("Cancel", JSONValue.object(["operationId": .string(String(operation))]))
    }

    enum RepoTask: String, CaseIterable {
        case check = "TASK_CHECK", prune = "TASK_PRUNE", stats = "TASK_STATS", unlock = "TASK_UNLOCK"
        case indexSnapshots = "TASK_INDEX_SNAPSHOTS"
    }

    static func repoTask(_ task: RepoTask, repo: String) async throws {
        _ = try await call("DoRepoTask", JSONValue.object(["repoId": .string(repo), "task": .string(task.rawValue)]))
    }

    static func log(ref: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Links.backrestURL)/v1.Backrest/GetLogs")!)
        request.httpMethod = "POST"
        request.setValue(ConnectStream.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = ConnectStream.envelope(try JSONEncoder().encode(JSONValue.object(["ref": .string(ref)])))
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        let log = ConnectStream.logText(data)
        if let error = log.error, log.text.isEmpty { throw Failure(message: error) }
        return log.text
    }
}

extension BackrestClient {
    static func snapshots(repo: String, plan: String) async throws -> [ResticSnapshot] {
        try Snapshots.decode(try await call("ListSnapshots", JSONValue.object(["repoId": .string(repo), "planId": .string(plan)]), timeout: 180))
    }

    static func files(repo: String, snapshot: String, path: String) async throws -> [SnapshotEntry] {
        let body = JSONValue.object(["repoId": .string(repo), "snapshotId": .string(snapshot), "path": .string(path)])
        return try Snapshots.decodeEntries(try await call("ListSnapshotFiles", body, timeout: 180), folder: path)
    }

    /// Backrest restores `path` from the snapshot into `target`, which must
    /// not exist yet: restic creates it and puts the item inside.
    static func restore(repo: String, plan: String, snapshot: String, path: String, target: String) async throws {
        let body = JSONValue.object(["repoId": .string(repo), "planId": .string(plan), "snapshotId": .string(snapshot),
                                     "path": .string(path), "target": .string(target)])
        _ = try await call("Restore", body)
    }
}

extension BackrestClient {
    struct RepoProbe {
        var exists: Bool
        var error: String?
        var hostKeyUntrusted: Bool
    }

    /// Whether a repository already exists at the repo's URI, without adding
    /// it: picks "connect" or "create" before anything is written.
    static func checkRepoExists(_ repo: JSONValue) async throws -> RepoProbe {
        let data = try await call("CheckRepoExists", JSONValue.object(["repo": repo]), timeout: 60)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        return RepoProbe(exists: v["exists"]?.bool ?? false,
                         error: v["error"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                         hostKeyUntrusted: v["hostKeyUntrusted"]?.bool ?? false)
    }

    /// Adds the repository, creating it when the URI holds none (restic
    /// init) or checking the password against the one that is there.
    static func addRepo(_ repo: JSONValue) async throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: try await call("AddRepo", JSONValue.object(["repo": repo]), timeout: 120))
    }
}

extension BackrestClient {
    struct SSHKey {
        var publicKey: String
        var keyPath: String
        var knownHostsPath: String
        /// The host key could not be scanned (host unreachable from here).
        var warning: String?
    }

    /// Backrest generates a key pair for this host beside its config and
    /// scans the server's host key into its own known_hosts.
    static func setupSftp(host: String, port: String, user: String) async throws -> SSHKey {
        let body = JSONValue.object(["host": .string(host), "port": .string(port), "username": .string(user)])
        let v = try JSONDecoder().decode(JSONValue.self, from: try await call("SetupSftp", body, timeout: 60))
        return SSHKey(publicKey: v["publicKey"]?.string ?? "", keyPath: v["keyPath"]?.string ?? "",
                      knownHostsPath: v["knownHostsPath"]?.string ?? "",
                      warning: v["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
    }
}
