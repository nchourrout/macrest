import AppKit
import MacRestCore
import SwiftUI

extension MaintenanceRow {
    /// A row for one kind of run, its title and symbol the kind's own.
    @MainActor init(_ kind: BackrestOperation.Kind, model: AppModel, note: String, @ViewBuilder action: () -> Action) {
        self.init(title: kind.title, symbol: kind.symbol, last: Activity.lastFinished(kind, in: model.flows),
                  next: kind == .forget ? nil : Activity.next(kind, in: model.scheduled), note: note,
                  unlockedAt: model.unlockedAt, busy: model.isBusy(kind), action: action)
    }
}

extension MaintenanceRow where Action == EmptyView {
    @MainActor init(_ kind: BackrestOperation.Kind, model: AppModel, note: String) {
        self.init(kind, model: model, note: note) { EmptyView() }
    }
}

/// One maintenance job: when it last ran and how that went, when it runs
/// next, and a button to run it now.
struct MaintenanceRow<Action: View>: View {
    let title: String
    let symbol: String
    let last: BackrestOperation?
    let next: Date?
    var note: String?
    var noteSeverity: Severity = .ok
    /// The last unlock. A failure before it hit a lock that is gone, so it is
    /// shown greyed as history rather than as a live problem.
    var unlockedAt: Date?
    /// Sent or running: the last finished run is not the news any more.
    var busy = false
    @ViewBuilder var action: Action

    private var superseded: Bool {
        guard let last, last.outcome.severity != .ok else { return false }
        return last.predates(unlock: unlockedAt)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let last, last.outcome != .success {
                        Tag(text: superseded ? "Failed before unlock" : last.outcome.label,
                            severity: superseded ? .ok : last.outcome.severity)
                    }
                }
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Running now. It can take a while; Activity shows it.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(status).font(.callout).foregroundStyle(Theme.tint(noteSeverity))
                        .lineLimit(2)
                        .help(last?.reason ?? "")
                }
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        var parts: [String] = []
        if let last {
            let ago = Format.ago(Int(Date().timeIntervalSince(last.finishedAt)))
            if last.outcome == .success {
                parts.append("Last ran \(ago)")
            } else if superseded {
                parts.append("Last run \(ago) hit the lock since removed; the next run will tell")
            } else {
                parts.append("\(last.outcome.label) \(ago)" + (last.reason.map { ": \($0)" } ?? ""))
            }
        } else if note == nil {
            parts.append("Not in the recent log")
        }
        if let next { parts.append("next \(next.activityLabel)") }
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

extension MaintenanceRow where Action == EmptyView {
    init(title: String, symbol: String, last: BackrestOperation?, next: Date?, note: String? = nil,
         noteSeverity: Severity = .ok, unlockedAt: Date? = nil) {
        self.init(title: title, symbol: symbol, last: last, next: next, note: note, noteSeverity: noteSeverity,
                  unlockedAt: unlockedAt) { EmptyView() }
    }
}

/// Where the backups are kept and keeping them healthy. Named Storage, not
/// restic's "repository", which stays only where a restic term helps.
struct StorageView: View {
    @Bindable var model: AppModel
    @ViewState private var confirmPrune = false
    @ViewState private var showsKit = false
    @ViewState private var revealsPassword = false

    var body: some View {
        if let repo = Binding($model.repo) {
            Form {
                SwiftUI.Section("Storage") {
                    LabeledContent("Backed up to") { Text(repo.wrappedValue.uri).textSelection(.enabled) }
                    // Credentials edit in place: rotating a key is changing the
                    // value and saving, no setup again.
                    ForEach(Array(repo.wrappedValue.env.enumerated()), id: \.offset) { i, line in
                        let (key, value) = Credential.split(line)
                        let binding = Binding<String>(get: { value },
                                                      set: { repo.wrappedValue.env[i] = key + "=" + $0 })
                        LabeledContent(Credential.label(key)) {
                            if Credential.isSecret(key) {
                                SecureField(Credential.label(key), text: binding).labelsHidden().frame(maxWidth: 320)
                            } else {
                                TextField(Credential.label(key), text: binding).labelsHidden().frame(maxWidth: 320)
                            }
                        }
                    }
                    LabeledContent("Stored") {
                        HStack(spacing: 8) {
                            if model.measuring {
                                ProgressView().controlSize(.small)
                                Text("Measuring. This reads the storage and can take a minute.").foregroundStyle(.secondary)
                            } else if let stats = model.stats?.0, let at = model.stats?.1, let size = stats.totalSize {
                                Text(storedText(stats, size: size)).monospacedDigit()
                                Text("· measured \(Format.ago(Int(Date().timeIntervalSince(at))))").foregroundStyle(.secondary)
                            } else if model.measureError == nil {
                                Text("Not measured yet").foregroundStyle(.secondary)
                            }
                            if !model.measuring, let failure = model.measureError {
                                Text("Size check failed: \(failure)").foregroundStyle(Theme.error).lineLimit(2)
                            }
                            Button("Measure") { Task { await model.measure() } }
                                .controlSize(.small)
                                .disabled(model.measuring)
                        }
                    }
                }

                recoveryKit

                // Each button waits on its own task only: disabling the whole
                // section while any task started made every button blink.
                SwiftUI.Section {
                    MaintenanceRow(.forget, model: model, note: "Removes backups past their keep period, after every backup")
                    MaintenanceRow(.check, model: model, note: "Reads the storage back to catch damage") {
                        Button("Verify Now") { Task { await model.repoTask(.check) } }
                            .disabled(model.isBusy(.check))
                    }
                    MaintenanceRow(.prune, model: model, note: "Deletes data that only removed backups used, so the storage shrinks") {
                        Button("Free Up Space…") { confirmPrune = true }
                            .disabled(model.isBusy(.prune))
                            .help("Delete stored data that no remaining backup needs")
                    }
                    MaintenanceRow(title: "Leftover lock", symbol: model.staleLock == nil ? "lock.open" : "lock.trianglebadge.exclamationmark",
                                   last: nil, next: nil,
                                   note: model.staleLock == nil ? "None: nothing is blocking maintenance" : "A leftover lock is blocking cleanup, space recovery and verification",
                                   noteSeverity: model.staleLock == nil ? .ok : .error) {
                        Button("Unlock") { Task { await model.unlock() } }
                            .disabled(model.unlocking)
                            .help("Remove locks left behind by a run that crashed or was cut off")
                    }
                    Toggle("Clear leftover locks automatically", isOn: repo.autoUnlock)
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("While a task changes the storage, it locks it so nothing else changes it at the same time, and unlocks it when done. A run cut off by a crash, sleep or a lost connection leaves its lock behind, and cleanup, space recovery and verification then fail until it is removed. Unlock removes only such leftovers. Clearing them automatically is safe while this Mac is the only one backing up to this storage.")
                }

                SwiftUI.Section {
                    ScheduleEditor(title: "Verify", schedule: repo.checkSchedule, allowsHours: false)
                    Picker("Depth", selection: checkDepth(repo)) {
                        Text("Structure only").tag(false)
                        Text("Read back a sample of the data").tag(true)
                    }
                    if case let .readData(pct) = repo.wrappedValue.checkMode {
                        ValueStepper(label: "Share read each time", value: Int(pct), text: "\(Int(pct))%", range: 1...100) {
                            repo.wrappedValue.checkMode = .readData(percent: Double($0))
                        }
                    }
                } header: {
                    Text("Verification")
                } footer: {
                    Text("Checking the structure is quick but never reads the backed-up files, so damaged data only shows when you restore it. Reading a sample covers a different part each time.")
                }

                SwiftUI.Section {
                    ScheduleEditor(title: "Free up space", schedule: repo.pruneSchedule, allowsHours: false)
                    ValueStepper(label: "Unused space allowed", value: Int(repo.wrappedValue.pruneMaxUnusedPercent),
                                 text: "\(Int(repo.wrappedValue.pruneMaxUnusedPercent))%", range: 0...100, step: 5) {
                        repo.wrappedValue.pruneMaxUnusedPercent = Double($0)
                    }
                } header: {
                    Text("Space recovery")
                } footer: {
                    Text("Cleanup removes old backups from the list, but their files stay on the storage, since newer backups share most of them. Space recovery deletes what no remaining backup uses, which is when the storage actually shrinks. Allowing some unused space makes it run less often.")
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Free up space now?", isPresented: $confirmPrune) {
                Button("Free Up Space") { Task { await model.repoTask(.prune) } }
            } message: {
                Text("This deletes stored data that no remaining backup uses. No backup is removed and nothing you can restore changes. It locks the storage while it runs: backups wait until it finishes, which can take a while when there is a lot stored.")
            }
            .sheet(isPresented: $showsKit) { RecoveryKitSheet(model: model) }
        }
    }

    /// The password and the kit: the one thing that, lost with this Mac,
    /// makes every backup unreadable.
    @ViewBuilder private var recoveryKit: some View {
        if let kit = model.recoveryKit {
            SwiftUI.Section {
                LabeledContent("Password") {
                    HStack(spacing: 8) {
                        Text(revealsPassword ? kit.password : String(repeating: "•", count: 12))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        RevealButton(revealed: $revealsPassword)
                        CopyButton(secret: true) { kit.password }.controlSize(.small)
                    }
                }
                LabeledContent("Recovery kit") {
                    HStack(spacing: 8) {
                        if let at = model.kitSavedAt {
                            Text("Kept \(Format.ago(Int(Date().timeIntervalSince(at))))").foregroundStyle(.secondary)
                        } else {
                            Text("Not kept yet").foregroundStyle(Theme.warning)
                        }
                        Button("Show…") { showsKit = true }.controlSize(.small)
                    }
                }
            } header: {
                Text("Password")
            } footer: {
                Text("Nothing can open the backups without this password. MacRest keeps it on this Mac, so if the Mac is lost it goes too: keep the recovery kit somewhere else.")
            }
        }
    }

    private func storedText(_ stats: BackrestOperation.Stats, size: Int64) -> String {
        var text = Format.size(size)
        if let n = stats.snapshotCount { text += " in " + Format.plural(Int(n), "backup") }
        if let raw = stats.uncompressedSize, size > 0 { text += String(format: ", compressed %.1f×", Double(raw) / Double(size)) }
        return text
    }

    private func checkDepth(_ repo: Binding<RepoSettings>) -> Binding<Bool> {
        Binding {
            if case .readData = repo.wrappedValue.checkMode { true } else { false }
        } set: { read in
            repo.wrappedValue.checkMode = read ? .readData(percent: 10) : .structureOnly
        }
    }
}
