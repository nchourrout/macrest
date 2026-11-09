import AppKit
import MacRestCore
import SwiftUI

struct ActivityView: View {
    let model: AppModel
    @ViewState private var filter: Filter = .all
    @ViewState private var expanded: Set<Int64> = []
    @ViewState private var logFor: BackrestOperation?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", backups = "Backups", problems = "Problems"
        var id: String { rawValue }
    }

    private var days: [ActivityDay] {
        let flows: [ActivityFlow] = switch filter {
        case .all: model.flows
        case .backups: model.flows.filter { $0.primary.kind == .backup }
        case .problems: model.flows.filter { $0.severity != .ok }
        }
        return Activity.byDay(flows)
    }

    var body: some View {
        let now = Date()
        List {
            SwiftUI.Section {
                OverviewCard(overview: model.overview, stats: model.stats?.0, scheduled: model.scheduled)
            }
            if let lock = model.staleLock {
                SwiftUI.Section {
                    StaleLockRow(count: lock.failedRuns, all: lock.coversWholeLog, reason: lock.reason) { Task { await model.unlock() } }
                }
            }
            if let run = model.runningBackup {
                SwiftUI.Section("Now") { RunningBackupRow(op: run.primary) }
            }
            SwiftUI.Section {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if days.isEmpty {
                    Text(filter == .problems ? "No problems in the recent log." : "Nothing in the log yet.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(days) { day in
                SwiftUI.Section(day.title(now: now)) {
                    ForEach(day.flows) { flow in
                        FlowRow(flow: flow, expanded: expanded.contains(flow.id),
                                toggle: { toggle(flow.id) }, showLog: { logFor = $0 })
                    }
                }
            }
        }
        .sheet(item: $logFor) { op in LogSheet(op: op, model: model) }
    }

    private func toggle(_ id: Int64) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// The verdict at window size: state, last and next run, the 14 days as
/// columns, and what the repository holds.
struct OverviewCard: View {
    let overview: Overview?
    let stats: BackrestOperation.Stats?
    let scheduled: [BackrestOperation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = overview {
                HStack(spacing: 12) {
                    Image(systemName: report.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.color(report.severity))
                        .frame(width: 44, height: 44)
                        .background(Theme.track, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.color(report.severity))
                        Text(report.subtitle).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let size = stats?.totalSize {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Format.size(size)).font(.title3.weight(.semibold)).monospacedDigit()
                            Text(stats?.snapshotCount.map { "\($0) snapshots" } ?? "stored").foregroundStyle(.secondary)
                        }
                    }
                }
                DaysChart(overview: report)
            } else {
                ProgressView().controlSize(.small)
            }
            if !scheduled.isEmpty {
                HStack(spacing: 14) {
                    Text("Up next").foregroundStyle(.secondary)
                    ForEach(scheduled) { op in
                        Label(op.kind.title + " " + op.start.activityLabel, systemImage: op.kind.symbol)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .font(.callout)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 6)
    }
}

struct StaleLockRow: View {
    let count: Int
    /// Every retention run in the fetched log failed, so the streak may go
    /// back further than the log does.
    let all: Bool
    let reason: String
    let unlock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(Theme.error)
            VStack(alignment: .leading, spacing: 3) {
                Text("Old snapshots are not being removed")
                    .font(.headline)
                Text("Retention failed after \(all ? "every backup in the log (\(count))" : "the last \(Format.plural(count, "backup"))"): a lock left behind by an earlier run. Backups still run, but the storage keeps growing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Unlock removes only locks restic can tell are stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(reason)
            Spacer()
            Button("Unlock", action: unlock).buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 6)
    }
}

struct RunningBackupRow: View {
    let op: BackrestOperation

    var body: some View {
        let p = op.backup
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: op.kind.symbol).frame(width: 20)
                Text("Backing up").font(.headline)
                Spacer()
                Text("started \(Format.ago(Int(Date().timeIntervalSince(op.start))))").foregroundStyle(.secondary)
            }
            if let pct = p?.percentDone {
                ProgressView(value: min(max(pct, 0), 1))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                if let done = p?.bytesDone, let total = p?.totalBytes, total > 0 {
                    Text("\(Format.size(done)) of \(Format.size(total))")
                }
                if let done = p?.filesDone, let total = p?.totalFiles, total > 0 {
                    Text("· \(Format.count(done)) of \(Format.count(total)) files")
                }
                Spacer()
                if let pct = p?.percentDone { Text("\(Int(pct * 100))%").monospacedDigit() }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let file = p?.currentFile {
                Text(file).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 4)
    }
}

struct FlowRow: View {
    let flow: ActivityFlow
    let expanded: Bool
    let toggle: () -> Void
    let showLog: (BackrestOperation) -> Void

    private var op: BackrestOperation { flow.primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // The row's colour is the operation's own outcome. A step that
                // failed alongside it (retention after a good backup) gets a
                // tag, not a red row: the backup itself is safe.
                Image(systemName: op.kind.symbol)
                    .frame(width: 20)
                    .foregroundStyle(op.outcome.severity == .ok ? Color.secondary : Theme.color(op.outcome.severity))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(op.kind.title).fontWeight(.medium)
                        if op.outcome != .success {
                            Tag(text: op.outcome.label, severity: op.outcome.severity)
                        }
                        ForEach(flow.failedSteps) { step in
                            Tag(text: "\(step.kind.title) \(step.outcome.label.lowercased())", severity: step.outcome.severity)
                                .help(step.reason ?? "")
                        }
                    }
                    if let line = detail { Text(line).font(.callout).foregroundStyle(.secondary) }
                    if let reason = op.reason {
                        Text(reason).font(.callout).foregroundStyle(Theme.color(op.outcome.severity)).lineLimit(2)
                    }
                }
                Spacer()
                Text(Format.date(op.start, "HH:mm")).monospacedDigit()
                Text(op.end.map { Format.duration(Int($0.timeIntervalSince(op.start))) } ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Chevron(expanded: expanded)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let id = op.snapshotID {
                        LabeledContent("Snapshot") {
                            Text(String(id.prefix(8))).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                    ForEach(flow.steps) { step in
                        HStack {
                            Image(systemName: step.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                            Text(step.kind.title)
                            Text(step.outcome.label).foregroundStyle(Theme.color(step.outcome.severity))
                            if let reason = step.reason {
                                Text(reason).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(reason)
                            }
                            Spacer()
                            if step.logref != nil || step.message != nil {
                                Button("Log") { showLog(step) }.controlSize(.small)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 30)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String? {
        switch op.kind {
        case .backup:
            guard let b = op.backup, b.dataAdded != nil else { return nil }
            var parts = ["\(Format.size(b.dataAdded ?? 0)) added"]
            if let c = b.filesChanged, c > 0 { parts.append("\(Format.count(c)) changed") }
            if let n = b.filesNew, n > 0 { parts.append("\(Format.count(n)) new") }
            if let total = b.bytesProcessed { parts.append("\(Format.size(total)) scanned") }
            if b.errors > 0 { parts.append(Format.plural(b.errors, "unreadable file")) }
            return parts.joined(separator: " · ")
        case .stats:
            guard let s = op.stats, let size = s.totalSize else { return nil }
            return "\(Format.size(size)) stored" + (s.snapshotCount.map { " · \($0) snapshots" } ?? "")
        case .restore:
            return op.restoreTarget.map { "to \($0)" }
        default:
            return nil
        }
    }
}

/// A small capsule naming a state: "Failed", "Retention failed".
struct Tag: View {
    let text: String
    let severity: Severity

    var body: some View {
        let color = severity == .ok ? Color.secondary : Theme.color(severity)
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct LogSheet: View {
    let op: BackrestOperation
    let model: AppModel
    @ViewState private var text: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(op.kind.title) · \(op.start.activityLabel)").font(.headline)
                Spacer()
                Button("Copy") { Pasteboard.copy(text ?? "") }
                .disabled(text == nil)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
        .task { text = await model.log(for: op) }
    }
}
