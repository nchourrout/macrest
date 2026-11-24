import AppKit
import Foundation
import MacRestCore
import Observation

/// The panes of the main window. Lives on the model so the menu bar panel can
/// open the window on a given one (Restore… opens Browse).
enum Pane: String, CaseIterable, Identifiable {
    case activity = "Activity", browse = "Browse", schedule = "Schedule", folders = "Folders", storage = "Storage"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .activity: "clock.arrow.circlepath"
        case .browse: "folder.badge.gearshape"
        case .schedule: "calendar"
        case .folders: "folder"
        case .storage: "externaldrive.connected.to.line.below"
        }
    }
}

/// The app's state: Backrest's config with the edits being made to it, the
/// oplog and the verdict drawn from it, and the snapshot being browsed. One
/// instance for the app's lifetime, because the menu bar icon needs the
/// verdict whether or not the window is open.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var pane: Pane? = .activity

    /// The whole document, as Backrest last returned it.
    private(set) var config: JSONValue?
    private(set) var savedPlan: PlanSettings?
    private(set) var savedRepo: RepoSettings?
    var plan: PlanSettings?
    var repo: RepoSettings?

    private(set) var flows: [ActivityFlow] = []
    private(set) var scheduled: [BackrestOperation] = []
    private(set) var overview: Overview?
    private(set) var stats: (BackrestOperation.Stats, Date)?
    private(set) var loadError: String?
    private(set) var actionError: String?
    private(set) var saving = false
    private(set) var loadedOnce = false
    /// What was just sent: the poll runs fast until the oplog shows it, or
    /// for 20 s at most, and each button waits on its own kind only.
    private var sent = SentRequests()
    var starting: Bool { sent.any(now: Date()) }
    func isBusy(_ kind: BackrestOperation.Kind) -> Bool { sent.isBusy(kind, flows: flows, now: Date()) }

    /// Bumped to ask for the window from outside a view: `openWindow` exists
    /// only in a view's environment, so the menu bar label carries it out.
    var windowRequests = 0

    /// The window is on screen: poll faster, and the app takes a Dock icon so
    /// it can be reached with Cmd-Tab.
    var windowVisible = false {
        didSet {
            guard windowVisible != oldValue else { return }
            AppDelegate.updateActivationPolicy()
            if windowVisible { wake() }
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var sleeper: Task<Void, Never>?

    var isDirty: Bool { plan != savedPlan || repo != savedRepo }
    /// Backrest answers but has no repository or plan yet: the setup shows.
    var needsSetup: Bool { config.map(SetupDefaults.needsSetup) ?? false }
    var problems: [String] { (plan?.problems ?? []) + (repo?.problems ?? []) }
    var runningBackup: ActivityFlow? { flows.first { $0.isActive && $0.primary.kind == .backup } }
    var runningAnything: Bool { flows.contains { $0.isActive } }

    // MARK: Polling

    /// Fast while something runs, so progress moves; every 15 s while the
    /// window is open; once a minute for the menu bar alone.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.reload()
            while !Task.isCancelled, let self {
                let interval: Duration = runningAnything || starting || measuring ? .seconds(2) : windowVisible ? .seconds(15) : .seconds(60)
                let nap = Task<Void, Never> { _ = try? await Task.sleep(for: interval) }
                sleeper = nap
                await nap.value
                await refreshActivity()
            }
        }
    }

    /// Cuts the current wait short: the window opened, or an action was sent.
    private func wake() { sleeper?.cancel() }

    func reload() async {
        do {
            let config = try await BackrestClient.getConfig()
            adopt(config, keepingEdits: isDirty)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        await refreshActivity()
        loadedOnce = true
    }

    func refreshActivity() async {
        do {
            let ops = try await BackrestClient.operations(lastN: 400)
                .filter { !Lookups.isLookup($0, previewRoot: QuickLookCache.root.path) }
            let now = Date()
            let grouped = Activity.flows(ops, now: now)
            flows = grouped.flows
            scheduled = grouped.scheduled
            if let latest = Activity.latestStats(ops) {
                stats = latest
                rememberStats(latest)
            } else if stats == nil {
                stats = rememberedStats()
            }
            // A size check that failed (storage offline) ends the wait too,
            // and says why rather than fall back to an old figure in silence.
            if let since = measuringSince, let run = Activity.sizeCheck(after: since, in: ops) {
                measuringSince = nil
                measureError = run.outcome.severity == .error ? (run.reason ?? "see Activity") : nil
                measureFailedAt = measureError == nil ? nil : run.finishedAt
            }
            // A later size check that worked makes the failure history.
            if let failedAt = measureFailedAt, let at = stats?.1, at > failedAt {
                measureError = nil
                measureFailedAt = nil
            }
            overview = Overview.make(flows: flows, scheduled: scheduled, now: now, unlockedAt: unlockedAt)
            sent.settle(ops, now: now)
            if loadError != nil, config != nil { loadError = nil }
        } catch {
            loadError = error.localizedDescription
            overview = nil
        }
    }

    // MARK: Config

    /// A fresh config replaces the saved baseline; edits in progress survive
    /// a background reload unless asked otherwise.
    private func adopt(_ config: JSONValue, keepingEdits: Bool) {
        self.config = config
        guard let (p, r) = BackrestConfig.read(config) else {
            savedPlan = nil
            savedRepo = nil
            plan = nil
            repo = nil
            return
        }
        savedPlan = p
        savedRepo = r
        if !keepingEdits || plan == nil {
            plan = p
            repo = r
        }
    }

    func revert() {
        plan = savedPlan
        repo = savedRepo
    }

    func save() async {
        guard let config, let plan, let repo, problems.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            let saved = try await BackrestClient.setConfig(BackrestConfig.applied(plan, repo, to: config))
            adopt(saved, keepingEdits: false)
            actionError = nil
        } catch {
            // Most likely a modno mismatch: the config changed since it was
            // read. Reload the baseline but keep the edits, so saving again
            // applies them on top of the new version.
            actionError = "Not saved: \(error.localizedDescription). Your changes are kept: click Save to try again."
            if let fresh = try? await BackrestClient.getConfig() { adopt(fresh, keepingEdits: true) }
        }
    }

    // MARK: Setup

    struct SetupRequest {
        var uri: String
        var password: String
        var env: [String] = []
        var flags: [String] = []
        var instance: String
        var paths: [String]
        var everyHours: Int
        var autoUnlock: Bool
    }

    /// Backrest refuses to touch a repository, even to probe one, until it
    /// has an instance name, so the setup names the Mac before testing.
    @discardableResult
    func ensureInstance(_ name: String) async throws -> JSONValue {
        var config = try await BackrestClient.getConfig()
        if (config["instance"]?.string ?? "").isEmpty {
            config["instance"] = .string(name)
            config = try await BackrestClient.setConfig(config)
            self.config = config
        }
        return config
    }

    /// Creates or connects the repository, adds the plan, and starts the
    /// first backup. Each step re-reads the config, since Backrest bumps its
    /// modno on every write.
    func setUp(_ r: SetupRequest) async throws {
        var config = try await ensureInstance(r.instance)
        let repoID = "main", planID = "home"
        config = try await BackrestClient.addRepo(SetupDefaults.repo(id: repoID, uri: r.uri, password: r.password,
                                                                    env: r.env, flags: r.flags, autoUnlock: r.autoUnlock))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var plans = config["plans"]?.array ?? []
        plans.removeAll { $0["id"]?.string == planID }
        plans.append(SetupDefaults.plan(id: planID, repo: repoID, paths: r.paths,
                                        excludes: SetupDefaults.excludes(home: home), everyHours: r.everyHours))
        config["plans"] = .array(plans)
        _ = try await BackrestClient.setConfig(config)
        Keychain.save(password: r.password, account: r.uri)
        await reload()
        pane = .activity
        await backupNow()
    }

    // MARK: Actions

    func backupNow() async {
        guard let id = savedPlan?.id else { return }
        await perform(.backup) { try await BackrestClient.backup(plan: id) }
    }

    func cancel(_ op: BackrestOperation) async {
        await perform(nil) { try await BackrestClient.cancel(operation: op.id) }
    }

    func repoTask(_ task: BackrestClient.RepoTask) async {
        guard let repo = savedRepo?.id else { return }
        await perform(task.kind) { try await BackrestClient.repoTask(task, repo: repo) }
    }

    func log(for op: BackrestOperation) async -> String {
        guard let ref = op.logref else { return op.message ?? "No log was kept for this operation." }
        do {
            let text = try await BackrestClient.log(ref: ref)
            return text.isEmpty ? (op.message ?? "The log is empty.") : text
        } catch {
            return op.message ?? "Could not read the log: \(error.localizedDescription)"
        }
    }

    func dismissError() { actionError = nil }

    // MARK: Size

    /// When Measure was clicked, until its result arrives (or 3 minutes).
    private var measuringSince: Date?
    var measuring: Bool { measuringSince.map { Date().timeIntervalSince($0) < 180 } ?? false }

    /// Why the last Measure failed, until a size check works.
    private(set) var measureError: String?
    private var measureFailedAt: Date?

    func measure() async {
        measuringSince = Date()
        measureError = nil
        await repoTask(.stats)
        if actionError != nil { measuringSince = nil }
    }

    /// The last measurement, kept across launches: a size check is rare, so
    /// it falls out of the fetched log within days.
    private struct RememberedStats: Codable {
        var uri: String
        var stats: BackrestOperation.Stats
        var at: Date
    }

    private func rememberStats(_ s: (BackrestOperation.Stats, Date)) {
        guard let uri = savedRepo?.uri,
              let data = try? JSONEncoder().encode(RememberedStats(uri: uri, stats: s.0, at: s.1)) else { return }
        UserDefaults.standard.set(data, forKey: "lastStats")
    }

    private func rememberedStats() -> (BackrestOperation.Stats, Date)? {
        guard let data = UserDefaults.standard.data(forKey: "lastStats"),
              let r = try? JSONDecoder().decode(RememberedStats.self, from: data),
              r.uri == savedRepo?.uri else { return nil }
        return (r.stats, r.at)
    }

    /// When Unlock last succeeded, kept across launches.
    private(set) var unlockedAt: Date? = UserDefaults.standard.object(forKey: "unlockedAt") as? Date
    /// A confirmation to show once, then dismiss.
    private(set) var notice: String?

    func dismissNotice() { notice = nil }

    private(set) var unlocking = false

    func unlock() async {
        unlocking = true
        defer { unlocking = false }
        let blocked = Activity.blockedByLock(flows, unlockedAt: unlockedAt)
        await repoTask(.unlock)
        guard actionError == nil else { return }
        // Nothing was failing on a lock: keep the earlier failures as they
        // are rather than grey them as "before unlock".
        guard blocked else {
            notice = "Unlocked. No leftover lock was blocking maintenance, so nothing else changes."
            return
        }
        unlockedAt = Date()
        UserDefaults.standard.set(unlockedAt, forKey: "unlockedAt")
        await refreshActivity()
        let next = Activity.next(.backup, in: scheduled)
        notice = "Unlocked. Cleanup, space recovery and verification can run again; cleanup next runs after the backup"
            + (next.map { " \($0.inlineLabel)" } ?? "") + "."
    }

    /// Retention, prune and check all need an exclusive lock, so a lock left
    /// behind by a crashed run fails every one of them while backups (shared
    /// lock) keep succeeding: easy to miss for weeks.
    ///
    /// A failure older than the last unlock no longer counts: the lock it hit
    /// is gone, and the next retention run (after the next backup) is the
    /// first that can say whether it worked.
    var staleLock: StaleLock? { Activity.staleLock(in: flows, unlockedAt: unlockedAt) }

    /// Sends a request; `kind` is the operation it starts in the oplog, if
    /// any. Returns whether it was sent.
    @discardableResult
    private func perform(_ kind: BackrestOperation.Kind?, _ work: () async throws -> Void) async -> Bool {
        if let kind { sent.send(kind, at: Date()) }
        var sentOK = true
        do {
            try await work()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            if let kind { sent.drop(kind) }
            sentOK = false
        }
        await refreshActivity()
        wake()
        return sentOK
    }

    // MARK: Recovery kit

    var recoveryKit: RecoveryKit? {
        guard let config, let id = savedRepo?.id else { return nil }
        return RecoveryKit.make(config: config, repoID: id)
    }

    /// When a kit was confirmed kept, by its fingerprint: a new storage, or a
    /// rotated key, makes a new kit to keep.
    private(set) var kitSaved: [String: Date] =
        (UserDefaults.standard.dictionary(forKey: "recoveryKitSaved") as? [String: Date]) ?? [:]

    var kitSavedAt: Date? { recoveryKit.flatMap { kitSaved[$0.fingerprint] } }

    func markKitSaved() {
        guard let kit = recoveryKit else { return }
        kitSaved[kit.fingerprint] = Date()
        UserDefaults.standard.set(kitSaved, forKey: "recoveryKitSaved")
    }

    // MARK: Browse

    private(set) var snapshots: [ResticSnapshot] = []
    private(set) var snapshotsLoading = false
    var selectedSnapshot: ResticSnapshot?
    /// The folder shown, kept when the snapshot changes: stepping back in
    /// time stays in the same place, the way Time Machine does.
    private(set) var folder: String?
    private(set) var entries: [SnapshotEntry] = []
    private(set) var entriesLoading = false
    private(set) var browseError: String?
    /// The folder no longer exists in the selected snapshot.
    private(set) var folderMissing = false
    @ObservationIgnored private var listings: [String: [SnapshotEntry]] = [:]
    @ObservationIgnored private var listingTask: Task<Void, Never>?

    /// The storage's host or folder name, for messages: "nas.local".
    var storageName: String {
        let uri = savedRepo?.uri ?? ""
        if uri.hasPrefix("sftp:") { return uri.dropFirst(5).split(separator: ":").first.map(String.init) ?? "the storage" }
        return uri.isEmpty ? "the storage" : (uri as NSString).lastPathComponent
    }

    func retryBrowse() {
        browseError = nil
        if snapshots.isEmpty || selectedSnapshot == nil {
            Task { await loadSnapshots(force: true) }
        } else {
            open(folder ?? snapshotRoot)
        }
    }

    var snapshotRoot: String { selectedSnapshot?.paths.first ?? savedPlan?.paths.first ?? "/" }

    func loadSnapshots(force: Bool = false) async {
        guard force || snapshots.isEmpty, let plan = savedPlan else { return }
        snapshotsLoading = true
        defer { snapshotsLoading = false }
        do {
            snapshots = try await BackrestClient.snapshots(repo: plan.repo, plan: plan.id)
            browseError = nil
            if selectedSnapshot == nil || !snapshots.contains(where: { $0.id == selectedSnapshot?.id }) {
                select(snapshots.first)
            }
        } catch {
            browseError = error.localizedDescription
        }
    }

    func select(_ snapshot: ResticSnapshot?) {
        selectedSnapshot = snapshot
        open(folder ?? snapshotRoot)
    }

    /// An item to select once its folder is listed: a search result shown in
    /// its backup. The view takes it and clears it.
    var highlight: String?

    /// Shows a found item where it lives, in the newest backup holding that
    /// version.
    func reveal(_ path: String, in snapshotID: String) {
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }) else { return }
        highlight = path
        selectedSnapshot = snapshot
        open((path as NSString).deletingLastPathComponent)
    }

    // MARK: Search

    private(set) var searchResult: FileSearchResult?
    private(set) var searching: String?
    private(set) var searchError: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var searchScope: [ResticSnapshot] { FileSearch.snapshotsToSearch(snapshots, now: Date()) }
    /// What a search covers, in words: "12 backups from the last 30 days",
    /// or the one older backup it falls back to.
    var searchScopeText: String? { FileSearch.scopeText(searchScope, now: Date()) }
    /// A search is running, or its results or error are on screen.
    var hasSearch: Bool { searching != nil || searchResult != nil || searchError != nil }

    /// Finds files and folders by name in the last 30 days of backups:
    /// restic find, run through Backrest, its output read from the log.
    func search(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let repo = savedPlan?.repo else { return }
        let scope = searchScope
        guard !scope.isEmpty else { return }
        clearSearch()
        searching = query
        searchError = nil
        searchResult = nil
        searchTask = Task {
            do {
                let id = try await BackrestClient.runCommand(repo: repo, command: FileSearch.command(query: query, snapshots: scope.map(\.id)))
                guard let op = try await BackrestClient.operation(id: id), let ref = op.outputLogref else {
                    throw Failure("The search finished but left no output.")
                }
                // A failed find (storage unreachable, a pattern restic
                // rejects) leaves no matches: say why, not "nothing found".
                guard op.outcome == .success || op.outcome == .warning else {
                    throw Failure(op.reason ?? "The search could not read the backups.")
                }
                let log = try await BackrestClient.log(ref: ref)
                let times = Dictionary(scope.map { ($0.id, $0.time) }, uniquingKeysWith: { a, _ in a })
                // Up to 2 MB of output to scan: off the main thread.
                let result = await Task.detached { FileSearch.parse(log, snapshotTimes: times) }.value
                guard !Task.isCancelled else { return }
                searchResult = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A timeout here leaves restic walking the backups: stop it.
                stopSearchRuns(before: Date())
                searchError = error.localizedDescription
            }
            searching = nil
        }
    }

    /// Backrest names a run only once it ends, so a search given up on is
    /// found in the oplog by its command and stopped there, queued or
    /// running: restic would otherwise keep walking every backup. Only runs
    /// from before `before`, so a search started right after keeps going.
    private func stopSearchRuns(before: Date) {
        Task {
            let runs = try? await BackrestClient.operations(lastN: 40).filter {
                $0.kind == .command && $0.outcome.isUnderway && $0.start < before
                    && $0.command?.hasPrefix(FileSearch.commandPrefix) == true
            }
            for op in runs ?? [] { try? await BackrestClient.cancel(operation: op.id) }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        if searching != nil { stopSearchRuns(before: Date()) }
        searching = nil
        searchResult = nil
        searchError = nil
    }

    // MARK: Quick Look

    /// The file Quick Look shows; set once it is restored to the cache.
    var previewURL: URL?
    /// The file being fetched for Quick Look.
    private(set) var previewing: SnapshotEntry?
    @ObservationIgnored private var previews: [String: URL] = [:]
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Past this, a preview waits too long on a slow link: restore it instead.
    static let previewLimit: Int64 = 512 * 1024 * 1024

    /// Restores one file from the selected backup into MacRest's cache
    /// through Backrest, then hands it to Quick Look. Kept out of Activity
    /// (see `Lookups`), and cached per backup and path.
    func preview(_ entry: SnapshotEntry) {
        guard !entry.isDirectory, let snapshot = selectedSnapshot, let plan = savedPlan else { return }
        if let size = entry.size, size > Self.previewLimit {
            actionError = "\u{201C}\(entry.name)\u{201D} is \(Format.size(size)), too large to preview. Restore it instead."
            return
        }
        let key = snapshot.id + "\u{0}" + entry.path
        // A fetch still under way would otherwise replace this one when done.
        previewTask?.cancel()
        previewing = nil
        if let url = previews[key], FileManager.default.fileExists(atPath: url.path) {
            previewURL = url
            return
        }
        previewing = entry
        let target = QuickLookCache.root.appending(path: UUID().uuidString).path
        previewTask = Task {
            defer { if !Task.isCancelled { previewing = nil } }
            do {
                guard let id = try await BackrestClient.restore(repo: plan.repo, plan: plan.id, snapshot: snapshot.id,
                                                                path: entry.path, target: target)
                else { throw Failure("The backup engine did not start the preview.") }
                // Backrest queues the restore. Behind a running backup it
                // waits for that to end, so the wait slows down until it runs,
                // and gives up after a minute of waiting: a backup can take hours.
                var wait = 0.5
                let queuedSince = Date()
                while true {
                    try await Task.sleep(for: .seconds(wait))
                    let op = try await BackrestClient.operation(id: id)
                    wait = op?.outcome == .running ? 0.5 : min(wait * 2, 4)
                    if op?.outcome != .running, op?.outcome != .success, Date().timeIntervalSince(queuedSince) > 60 {
                        try? await BackrestClient.cancel(operation: id)
                        throw Failure("The backup engine is busy with another task, so \u{201C}\(entry.name)\u{201D} cannot be previewed yet. Try again when it finishes.")
                    }
                    switch op?.outcome {
                    case .success?:
                        let url = URL(fileURLWithPath: target).appending(path: entry.name)
                        previews[key] = url
                        previewURL = url
                        return
                    case .failed?, .cancelled?, .warning?:
                        throw Failure("Could not preview \u{201C}\(entry.name)\u{201D}: \(op?.reason ?? "the restore failed").")
                    default:
                        continue
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                actionError = error.localizedDescription
            }
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewing = nil
    }

    func open(_ path: String) {
        guard let snapshot = selectedSnapshot, let repo = savedPlan?.repo else { return }
        // A found item waits for its own folder only.
        if let h = highlight, (h as NSString).deletingLastPathComponent != path { highlight = nil }
        folder = path
        let key = snapshot.id + "\u{0}" + path
        if let cached = listings[key] {
            entries = cached
            folderMissing = false
            return
        }
        listingTask?.cancel()
        entriesLoading = true
        listingTask = Task {
            defer { if !Task.isCancelled { entriesLoading = false } }
            do {
                let list = try await BackrestClient.files(repo: repo, snapshot: snapshot.id, path: path)
                guard !Task.isCancelled else { return }
                listings[key] = list
                entries = list
                folderMissing = false
                browseError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                entries = []
                highlight = nil
                // A path this snapshot does not hold: an older snapshot from
                // before the folder existed. Say so rather than show an error.
                folderMissing = error.localizedDescription.contains("not found") || error.localizedDescription.contains("no such")
                browseError = folderMissing ? nil : error.localizedDescription
            }
        }
    }

    /// Restores `entry` from the selected snapshot into a new folder at
    /// `target`. Backrest runs it as an operation, so it shows in Activity.
    /// Returns whether Backrest took it: a refused restore never reaches the
    /// oplog, so there is nothing to follow.
    func restore(_ entry: SnapshotEntry, to target: String) async -> Bool {
        guard let snapshot = selectedSnapshot, let plan = savedPlan else { return false }
        return await perform(.restore) {
            try await BackrestClient.restore(repo: plan.repo, plan: plan.id, snapshot: snapshot.id, path: entry.path, target: target)
        }
    }
}
