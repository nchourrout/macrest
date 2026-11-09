import AppKit
import MacRestCore
import SwiftUI

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
    @ViewBuilder var action: Action

    private var superseded: Bool {
        guard let last, last.outcome.severity != .ok, let unlockedAt else { return false }
        return (last.end ?? last.start) < unlockedAt
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
                Text(status).font(.callout).foregroundStyle(noteSeverity == .ok ? Color.secondary : Theme.color(noteSeverity))
                    .lineLimit(2)
                    .help(last?.reason ?? "")
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }

    private var status: String {
        var parts: [String] = []
        if let last {
            let ago = Format.ago(Int(Date().timeIntervalSince(last.end ?? last.start)))
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
                                Text("Measuring… this reads the storage and can take a minute").foregroundStyle(.secondary)
                            } else if let stats = model.stats?.0, let at = model.stats?.1, let size = stats.totalSize {
                                Text(storedText(stats, size: size)).monospacedDigit()
                                Text("· measured \(Format.ago(Int(Date().timeIntervalSince(at))))").foregroundStyle(.secondary)
                            } else {
                                Text("Not measured yet").foregroundStyle(.secondary)
                            }
                            Button("Measure") { Task { await model.measure() } }
                                .controlSize(.small)
                                .disabled(model.starting || model.measuring)
                        }
                    }
                }

                SwiftUI.Section {
                    MaintenanceRow(title: "Cleanup", symbol: "calendar.badge.minus",
                                   last: Activity.lastFinished(.forget, in: model.flows), next: nil,
                                   note: "Removes backups past their keep period, after every backup", unlockedAt: model.unlockedAt)
                    MaintenanceRow(title: "Verification", symbol: "checkmark.shield",
                                   last: Activity.lastFinished(.check, in: model.flows),
                                   next: model.scheduled.first { $0.kind == .check }?.start, unlockedAt: model.unlockedAt) {
                        Button("Verify Now") { Task { await model.repoTask(.check) } }
                    }
                    MaintenanceRow(title: "Space recovery", symbol: "scissors",
                                   last: Activity.lastFinished(.prune, in: model.flows),
                                   next: model.scheduled.first { $0.kind == .prune }?.start, unlockedAt: model.unlockedAt) {
                        Button("Free Up Space…") { confirmPrune = true }
                    }
                    MaintenanceRow(title: "Locks", symbol: model.staleLock == nil ? "lock.open" : "lock.trianglebadge.exclamationmark",
                                   last: nil, next: nil,
                                   note: model.staleLock == nil ? "No leftover lock" : "A leftover lock is blocking cleanup and space recovery",
                                   noteSeverity: model.staleLock == nil ? .ok : .error) {
                        Button("Unlock") { Task { await model.unlock() } }
                            .help("Remove locks left behind by a run that crashed or was cut off")
                    }
                    Toggle("Clear leftover locks automatically", isOn: repo.autoUnlock)
                } header: {
                    Text("Maintenance")
                } footer: {
                    Text("A lock left behind by a crashed run blocks cleanup, space recovery and verification until it is removed. Clearing it automatically is safe while this Mac is the only one backing up to this storage.")
                }
                .disabled(model.starting)

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
                    Text("Cleanup removes old backups from the list, but their data stays until space recovery deletes what no backup uses any more. Allowing some unused space makes it run less often.")
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Free up space now?", isPresented: $confirmPrune) {
                Button("Free Up Space") { Task { await model.repoTask(.prune) } }
            } message: {
                Text("This rewrites data on the storage and locks it while it runs: backups wait until it finishes, which can take a while when there is a lot stored.")
            }
        }
    }

    private func storedText(_ stats: BackrestOperation.Stats, size: Int64) -> String {
        var text = Format.size(size)
        if let n = stats.snapshotCount { text += " in \(n) snapshots" }
        if let raw = stats.uncompressedSize, size > 0 { text += String(format: ", %.1fx compressed", Double(raw) / Double(size)) }
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
