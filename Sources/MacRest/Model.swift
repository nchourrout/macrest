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
    /// When a Backup or repo task was last sent: the poll runs fast until the
    /// oplog shows it running, or for 20 s at most (a stats run can finish
    /// between two polls and never be seen running).
    private var sentAt: Date?
    var starting: Bool { sentAt.map { Date().timeIntervalSince($0) < 20 } ?? false }

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
                let interval: Duration = runningAnything || starting ? .seconds(2) : windowVisible ? .seconds(15) : .seconds(60)
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
            let now = Date()
            let grouped = Activity.flows(ops, now: now)
            flows = grouped.flows
            scheduled = grouped.scheduled
            stats = Activity.latestStats(ops)
            overview = Overview.make(flows: flows, scheduled: scheduled, now: now, unlockedAt: unlockedAt)
            if runningAnything { sentAt = nil }
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
            actionError = "Not saved: \(error.localizedDescription)"
            if let fresh = try? await BackrestClient.getConfig() { adopt(fresh, keepingEdits: true) }
        }
    }

    // MARK: Setup

    struct SetupRequest {
        var uri: String
        var password: String
        var env: [String] = []
        var instance: String
        var paths: [String]
        var everyHours: Int
        var autoUnlock: Bool
    }

    /// Creates or connects the repository, adds the plan, and starts the
    /// first backup. Each step re-reads the config, since Backrest bumps its
    /// modno on every write.
    func setUp(_ r: SetupRequest) async throws {
        var config = try await BackrestClient.getConfig()
        if (config["instance"]?.string ?? "").isEmpty {
            config["instance"] = .string(r.instance)
            config = try await BackrestClient.setConfig(config)
        }
        let repoID = "main", planID = "home"
        config = try await BackrestClient.addRepo(SetupDefaults.repo(id: repoID, uri: r.uri, password: r.password,
                                                                    env: r.env, autoUnlock: r.autoUnlock))
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
        await perform { try await BackrestClient.backup(plan: id) }
    }

    func cancel(_ op: BackrestOperation) async {
        await perform { try await BackrestClient.cancel(operation: op.id) }
    }

    func repoTask(_ task: BackrestClient.RepoTask) async {
        guard let repo = savedRepo?.id else { return }
        await perform { try await BackrestClient.repoTask(task, repo: repo) }
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

    /// When Unlock last succeeded, kept across launches.
    private(set) var unlockedAt: Date? = UserDefaults.standard.object(forKey: "unlockedAt") as? Date
    /// A confirmation to show once, then dismiss.
    private(set) var notice: String?

    func dismissNotice() { notice = nil }

    func unlock() async {
        await repoTask(.unlock)
        guard actionError == nil else { return }
        unlockedAt = Date()
        UserDefaults.standard.set(unlockedAt, forKey: "unlockedAt")
        await refreshActivity()
        let next = scheduled.first { $0.kind == .backup }?.start
        notice = "Unlocked. Retention, prune and check can run again; retention next runs after the backup"
            + (next.map { " at \($0.activityLabel)" } ?? "") + "."
    }

    /// Retention, prune and check all need an exclusive lock, so a lock left
    /// behind by a crashed run fails every one of them while backups (shared
    /// lock) keep succeeding: easy to miss for weeks.
    ///
    /// A failure older than the last unlock no longer counts: the lock it hit
    /// is gone, and the next retention run (after the next backup) is the
    /// first that can say whether it worked.
    var staleLock: (count: Int, all: Bool, reason: String)? {
        let forgets = flows.flatMap(\.steps).filter { $0.kind == .forget }.sorted { $0.id > $1.id }
        guard let last = forgets.first, last.outcome.severity == .error,
              let reason = last.reason, reason.contains("locked") else { return nil }
        if let unlockedAt, (last.end ?? last.start) < unlockedAt { return nil }
        let count = forgets.prefix { $0.outcome.severity == .error && ($0.reason ?? "").contains("locked") }.count
        return (count, count == forgets.count, reason)
    }

    private func perform(_ work: () async throws -> Void) async {
        sentAt = Date()
        do {
            try await work()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            sentAt = nil
        }
        await refreshActivity()
        wake()
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

    func open(_ path: String) {
        guard let snapshot = selectedSnapshot, let repo = savedPlan?.repo else { return }
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
            } catch {
                guard !Task.isCancelled else { return }
                entries = []
                // A path this snapshot does not hold: an older snapshot from
                // before the folder existed. Say so rather than show an error.
                folderMissing = error.localizedDescription.contains("not found") || error.localizedDescription.contains("no such")
                browseError = folderMissing ? nil : error.localizedDescription
            }
        }
    }

    /// Restores `entry` from the selected snapshot into a new folder at
    /// `target`. Backrest runs it as an operation, so it shows in Activity.
    func restore(_ entry: SnapshotEntry, to target: String) async {
        guard let snapshot = selectedSnapshot, let plan = savedPlan else { return }
        await perform {
            try await BackrestClient.restore(repo: plan.repo, plan: plan.id, snapshot: snapshot.id, path: entry.path, target: target)
        }
    }
}
