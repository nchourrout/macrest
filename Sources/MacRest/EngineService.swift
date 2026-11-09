import CryptoKit
import Foundation
import MacRestCore
import Observation
import os

private let log = Logger(subsystem: "com.nchourrout.macrest", category: "engine")

/// Backrest, the engine, as MacRest's own background service: downloaded
/// from the pinned release, checksum-verified, and kept running by a
/// per-user LaunchAgent. Installing MacRest is then the whole install.
///
/// A Backrest already answering that MacRest did not start (Homebrew's
/// service, typically) is left alone until the user takes it over: stopping a
/// service someone set up is their call. The takeover keeps the same config
/// and data folders, so nothing is lost: repository, history, restic.
@MainActor
@Observable
final class EngineService {
    static let shared = EngineService()

    enum State: Equatable {
        case checking
        /// Ours, answering.
        case running
        /// Answering, but started by something else (Homebrew).
        case external(label: String?)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .checking

    var isRunning: Bool {
        switch state {
        case .running, .external: true
        default: false
        }
    }

    let paths: EngineAgent.Paths
    private let agentPlist: String
    private let uid = getuid()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacRest").path
        paths = EngineAgent.Paths(home: home, support: support)
        agentPlist = home + "/Library/LaunchAgents/\(EngineAgent.label).plist"
    }

    /// At launch: adopt whatever is running, or bring ours up. Installs the
    /// pinned release when it is missing, and moves our service to it when
    /// MacRest was updated with a new pin.
    func ensure() async {
        if Links.usesExternalBackrest {
            state = await answers() ? .running : .failed("No Backrest answers at \(Links.backrestURL).")
            return
        }
        let ours = await isLoaded(EngineAgent.label)
        if await answers() {
            if ours {
                if !FileManager.default.fileExists(atPath: paths.binary) || agentIsStale {
                    // A newer pin, or a service definition from an older
                    // MacRest: same folders, rewritten agent, restarted.
                    await install()
                } else {
                    state = .running
                }
            } else {
                var homebrew: String?
                for label in EngineAgent.homebrewLabels where await isLoaded(label) { homebrew = label; break }
                state = .external(label: homebrew)
            }
            return
        }
        await install()
    }

    /// Stops Homebrew's Backrest for good and starts ours on the same folders.
    func takeOver() async {
        state = .installing("Stopping Homebrew's Backrest…")
        // `brew services stop` unloads it and removes its plist, so it does
        // not come back at the next login; bootout covers a machine without brew.
        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            await run(brew, ["services", "stop", "backrest"])
        }
        for label in EngineAgent.homebrewLabels where await isLoaded(label) {
            await run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        }
        // The port has to be free before ours binds it.
        for _ in 0..<50 where await answers() { try? await Task.sleep(for: .milliseconds(200)) }
        await install()
    }

    func restart() async {
        guard await isLoaded(EngineAgent.label) else { await install(); return }
        await run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(EngineAgent.label)"])
        await waitUntilAnswering()
    }

    // MARK: Install

    private func install() async {
        do {
            if !FileManager.default.isExecutableFile(atPath: paths.binary) {
                state = .installing("Downloading Backrest \(BackrestRelease.version)…")
                try await Self.download(to: paths.binary)
            }
            state = .installing("Starting Backrest…")
            try await writeAgent()
            await waitUntilAnswering()
        } catch {
            log.error("install failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Off the main actor: hashing and unpacking a 30 MB archive is not UI work.
    nonisolated private static func download(to binary: String) async throws {
        guard let expected = BackrestRelease.checksum() else { throw Failure("No Backrest build for \(BackrestRelease.arch).") }
        let (file, response) = try await URLSession.shared.download(from: BackrestRelease.url())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The Backrest download failed.") }
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            throw Failure("The Backrest download did not match its published checksum, so it was not installed.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "macrest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appending(path: BackrestRelease.asset())
        try data.write(to: archive)
        guard await run("/usr/bin/tar", ["-xzf", archive.path, "-C", work.path]) == 0,
              FileManager.default.fileExists(atPath: work.appending(path: "backrest").path)
        else { throw Failure("Could not unpack the Backrest download.") }

        let dir = (binary as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: binary)
        try FileManager.default.moveItem(at: work.appending(path: "backrest"), to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        removeOldVersions(keeping: dir)
    }

    /// Earlier pinned versions, once the new one is in place.
    nonisolated private static func removeOldVersions(keeping dir: String) {
        let parent = (dir as NSString).deletingLastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []
        where name.hasPrefix("backrest-") && (parent as NSString).appendingPathComponent(name) != dir {
            try? FileManager.default.removeItem(atPath: (parent as NSString).appendingPathComponent(name))
        }
    }

    /// The plist on disk differs from what this MacRest would write.
    private var agentIsStale: Bool {
        guard let onDisk = FileManager.default.contents(atPath: agentPlist),
              let current = try? PropertyListSerialization.propertyList(from: onDisk, format: nil) as? NSDictionary
        else { return true }
        return current != EngineAgent.plist(paths) as NSDictionary
    }

    private func writeAgent() async throws {
        for dir in [(agentPlist as NSString).deletingLastPathComponent, (paths.log as NSString).deletingLastPathComponent,
                    (paths.config as NSString).deletingLastPathComponent, paths.data] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try EngineAgent.plistData(paths).write(to: URL(fileURLWithPath: agentPlist), options: .atomic)
        // Reload so a changed binary path or environment takes effect.
        if await isLoaded(EngineAgent.label) { await run("/bin/launchctl", ["bootout", "gui/\(uid)/\(EngineAgent.label)"]) }
        guard await run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentPlist]) == 0 else {
            throw Failure("launchd refused the Backrest service. Check Login Items in System Settings.")
        }
    }

    private func waitUntilAnswering() async {
        for _ in 0..<100 {
            if await answers() { state = .running; return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .failed("Backrest did not start. Its log is at \(paths.log).")
    }

    // MARK: Probes

    /// The dashboard rather than GetConfig: a liveness probe has no business
    /// fetching the config, which carries the repository passwords.
    private func answers() async -> Bool {
        (try? await BackrestClient.call("GetSummaryDashboard", JSONValue.object([:]), timeout: 2)) != nil
    }

    private func isLoaded(_ label: String) async -> Bool {
        await Self.run("/bin/launchctl", ["print", "gui/\(uid)/\(label)"], quiet: true) == 0
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) async -> Int32 {
        await Self.run(tool, args)
    }

    /// A tool run to completion off the main actor, so a slow one (`brew
    /// services stop` takes seconds) never stalls the UI.
    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String], quiet: Bool = false) async -> Int32 {
        await Task.detached { runBlocking(tool, args, quiet: quiet) }.value
    }

    nonisolated private static func runBlocking(_ tool: String, _ args: [String], quiet: Bool) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        if !quiet, p.terminationStatus != 0 {
            log.notice("\(tool, privacy: .public) \(args.joined(separator: " "), privacy: .public) exited \(p.terminationStatus)")
        }
        return p.terminationStatus
    }

    struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
