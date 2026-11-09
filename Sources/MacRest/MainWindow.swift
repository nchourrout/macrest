import AppKit
import MacRestCore
import SwiftUI

/// The main window: Backrest's activity, snapshots and settings, natively,
/// so its web UI never needs opening. Backrest stays the engine (scheduling,
/// retention, checks, hooks); this is a client of the same local API.
struct MainWindow: View {
    static let id = "main"

    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailColumn
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { model.windowVisible = true }
        .onDisappear { model.windowVisible = false }
    }

    private var sidebar: some View {
        List(Pane.allCases, selection: $model.pane) { p in
            Label(p.rawValue, systemImage: p.symbol).tag(p)
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            banners
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.pane?.rawValue ?? "MacRest")
        .toolbar { toolbar }
    }

    @ViewBuilder private var banners: some View {
        if let error = model.actionError ?? model.loadError {
            Banner(text: error, severity: .error, dismiss: model.actionError != nil ? { model.dismissError() } : nil)
        }
        if model.isDirty, !model.problems.isEmpty {
            Banner(text: model.problems.joined(separator: " "), severity: .warning, dismiss: nil)
        }
    }

    @ViewBuilder private var detail: some View {
        if !model.loadedOnce {
            ProgressView().controlSize(.small)
        } else {
            switch model.pane ?? .activity {
            case .activity: ActivityView(model: model)
            case .browse: BrowseView(model: model)
            case .schedule: ScheduleView(model: model)
            case .folders: FoldersView(model: model)
            case .repository: RepositoryView(model: model)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.isDirty {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Revert") { model.revert() }
                Button("Save") { Task { await model.save() } }
                    .keyboardShortcut("s")
                    .disabled(!model.problems.isEmpty || model.saving)
                    .buttonStyle(.borderedProminent)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if let run = model.runningBackup {
                Button { Task { await model.cancel(run.primary) } } label: {
                    Label("Stop Backup", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .help("Stop the backup that is running")
            } else {
                Button { Task { await model.backupNow() } } label: {
                    Label("Back Up Now", systemImage: "arrow.clockwise.icloud")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.savedPlan == nil || model.starting)
                .help("Start a backup now")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Refresh") { Task { await model.reload() } }
                Divider()
                Button("Open Backrest in the Browser") { NSWorkspace.shared.open(URL(string: Links.backrestURL)!) }
                Divider()
                Toggle("Show in Menu Bar", isOn: Binding(get: { AppDelegate.showsMenuBarItem },
                                                         set: { AppDelegate.showsMenuBarItem = $0 }))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Building blocks

struct Banner: View {
    let text: String
    let severity: Severity
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.color(severity))
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.color(severity).opacity(0.12))
    }
}

/// When something runs: a short list of common choices, and Custom for an
/// arbitrary interval or a cron line.
struct ScheduleEditor: View {
    let title: String
    @Binding var schedule: ScheduleSetting
    /// Repo maintenance only takes days: an hourly prune is never wanted.
    var allowsHours = true
    /// Custom picked while the value is still one of the presets.
    @ViewState private var custom = false

    private var presets: [(String, ScheduleSetting)] {
        allowsHours
            ? [("Every hour", .everyHours(1)), ("Every 2 hours", .everyHours(2)), ("Every 4 hours", .everyHours(4)),
               ("Every 6 hours", .everyHours(6)), ("Every 12 hours", .everyHours(12)), ("Every day", .everyDays(1))]
            : [("Every day", .everyDays(1)), ("Every week", .everyDays(7)), ("Every 2 weeks", .everyDays(14)),
               ("Every month", .everyDays(30))]
    }

    private enum Choice: Hashable { case off, preset(ScheduleSetting), custom }

    private var choice: Binding<Choice> {
        Binding {
            if schedule == .disabled { return .off }
            if !custom, presets.contains(where: { $0.1 == schedule }) { return .preset(schedule) }
            return .custom
        } set: { new in
            switch new {
            case .off: custom = false; schedule = .disabled
            case let .preset(p): custom = false; schedule = p
            case .custom: custom = true; if schedule == .disabled { schedule = allowsHours ? .everyHours(3) : .everyDays(10) }
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case hours = "Hours", days = "Days", cron = "Cron"
        var id: String { rawValue }
    }

    private var kind: Binding<Kind> {
        Binding {
            switch schedule {
            case .everyHours: .hours
            case .cron: .cron
            default: .days
            }
        } set: { new in
            switch new {
            case .hours: schedule = .everyHours(3)
            case .days: schedule = .everyDays(allowsHours ? 2 : 10)
            case .cron: schedule = .cron("0 * * * *")
            }
        }
    }

    var body: some View {
        Picker(title, selection: choice) {
            ForEach(presets, id: \.0) { Text($0.0).tag(Choice.preset($0.1)) }
            Divider()
            Text("Custom…").tag(Choice.custom)
            Text("Off").tag(Choice.off)
        }
        if choice.wrappedValue == .custom {
            Picker("Repeat in", selection: kind) {
                ForEach(Kind.allCases.filter { allowsHours || $0 != .hours }) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch schedule {
            case let .everyHours(h):
                ValueStepper(label: "Every", value: h, text: h == 1 ? "1 hour" : "\(h) hours", range: 1...168) {
                    schedule = .everyHours($0)
                }
            case let .everyDays(d):
                ValueStepper(label: "Every", value: d, text: d == 1 ? "1 day" : "\(d) days", range: 1...365) {
                    schedule = .everyDays($0)
                }
            case let .cron(c):
                TextField("Cron expression", text: Binding(get: { c }, set: { schedule = .cron($0) }))
                    .font(.body.monospaced())
            case .disabled:
                EmptyView()
            }
        }
    }
}

/// How far back the kept snapshots reach, bucket by bucket, on a log scale
/// so a day of hourlies and two years of monthlies both read.
struct CoverageBar: View {
    let segments: [CoverageSegment]

    private static let floor = 1800.0

    var body: some View {
        if let last = segments.last {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    let total = log(last.to / Self.floor)
                    let gap = 2.0
                    let usable = geo.size.width - gap * Double(segments.count - 1)
                    HStack(spacing: gap) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                            let w = log(seg.to / max(seg.from, Self.floor)) / total * usable
                            VStack(alignment: .leading, spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.85 - Double(i) * 0.15))
                                    .frame(height: 10)
                                Text(seg.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: max(w, 1))
                        }
                    }
                }
                .frame(height: 30)
                HStack {
                    Text("Now")
                    Spacer()
                    Text("\(Self.span(last.to)) ago")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    static func span(_ seconds: TimeInterval) -> String {
        let days = seconds / 86400
        if days >= 365 { return Format.plural(Int((days / 365.25).rounded()), "year") }
        if days >= 60 { return Format.plural(Int((days / 30.44).rounded()), "month") }
        if days >= 14 { return Format.plural(Int((days / 7).rounded()), "week") }
        if days >= 1 { return Format.plural(Int(days.rounded()), "day") }
        return Format.plural(Int(seconds / 3600), "hour")
    }
}

extension Date {
    /// "Today 08:36", "Yesterday 14:02", "Mon 2 Nov 08:36".
    var activityLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today " + Format.date(self, "HH:mm") }
        if cal.isDateInYesterday(self) { return "Yesterday " + Format.date(self, "HH:mm") }
        if cal.isDateInTomorrow(self) { return "Tomorrow " + Format.date(self, "HH:mm") }
        let sameYear = cal.component(.year, from: self) == cal.component(.year, from: Date())
        return Format.date(self, sameYear ? "EEE d MMM HH:mm" : "d MMM yyyy HH:mm")
    }
}

// MARK: - Activity

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
                    StaleLockRow(count: lock.count, all: lock.all, reason: lock.reason) { Task { await model.repoTask(.unlock) } }
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
                Text("Retention failed after \(all ? "every backup in the log (\(count))" : "the last \(Format.plural(count, "backup"))"): a lock left behind by an earlier run. Backups still run, but the repository keeps growing.")
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
                            Text(step.outcome.label).foregroundStyle(Theme.color(step.outcome.severity == .ok ? .ok : step.outcome.severity))
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
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text ?? "", forType: .string)
                }
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

// MARK: - Schedule

struct ScheduleView: View {
    @Bindable var model: AppModel

    enum RetentionKind: String, CaseIterable, Identifiable {
        case buckets = "By age", lastN = "Last N snapshots", all = "Everything"
        var id: String { rawValue }
    }

    var body: some View {
        if let plan = Binding($model.plan) {
            Form {
                SwiftUI.Section {
                    ScheduleEditor(title: "Back up", schedule: plan.schedule)
                    Toggle("Skip the snapshot when nothing changed", isOn: plan.skipIfUnchanged)
                } header: {
                    Text("Backups")
                } footer: {
                    Text("An interval counts from the last run, so a Mac that was asleep backs up soon after it wakes.")
                }
                SwiftUI.Section {
                    Picker("Keep", selection: retentionKind(plan)) {
                        ForEach(RetentionKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if case let .buckets(b) = plan.wrappedValue.retention, !b.coverage.isEmpty {
                        CoverageBar(segments: b.coverage)
                    }
                    retentionFields(plan)
                } header: {
                    HStack {
                        Text("Snapshots to keep")
                        Spacer()
                        Button("Time Machine style") {
                            plan.wrappedValue.retention = .buckets(TimeBuckets(hourly: 24, daily: 30, weekly: 52, monthly: 24))
                        }
                        .controlSize(.small)
                        .help("Hourly for a day, daily for a month, weekly for a year, monthly for two years")
                    }
                } footer: {
                    Text(plan.wrappedValue.retention.summary + ". Applied after each backup; the space is freed by the next prune.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func retentionKind(_ plan: Binding<PlanSettings>) -> Binding<RetentionKind> {
        Binding {
            switch plan.wrappedValue.retention {
            case .buckets: .buckets
            case .lastN: .lastN
            case .keepAll: .all
            }
        } set: { kind in
            switch kind {
            case .buckets: plan.wrappedValue.retention = .buckets(TimeBuckets(daily: 7, weekly: 4, monthly: 3))
            case .lastN: plan.wrappedValue.retention = .lastN(30)
            case .all: plan.wrappedValue.retention = .keepAll
            }
        }
    }

    @ViewBuilder private func retentionFields(_ plan: Binding<PlanSettings>) -> some View {
        switch plan.wrappedValue.retention {
        case let .buckets(b):
            let set = { (b: TimeBuckets) in plan.wrappedValue.retention = .buckets(b) }
            CountStepper(label: "Hourly", unit: "hour", value: b.hourly) { var c = b; c.hourly = $0; set(c) }
            CountStepper(label: "Daily", unit: "day", value: b.daily) { var c = b; c.daily = $0; set(c) }
            CountStepper(label: "Weekly", unit: "week", value: b.weekly) { var c = b; c.weekly = $0; set(c) }
            CountStepper(label: "Monthly", unit: "month", value: b.monthly) { var c = b; c.monthly = $0; set(c) }
            CountStepper(label: "Yearly", unit: "year", value: b.yearly) { var c = b; c.yearly = $0; set(c) }
            CountStepper(label: "Always keep the latest", unit: "snapshot", value: b.keepLastN) { var c = b; c.keepLastN = $0; set(c) }
        case let .lastN(n):
            CountStepper(label: "Snapshots", unit: "snapshot", value: n, range: 1...10_000) {
                plan.wrappedValue.retention = .lastN($0)
            }
        case .keepAll:
            Text("Nothing is ever deleted. The repository only grows.").foregroundStyle(.secondary)
        }
    }
}

/// A labelled number with its stepper beside the value, the way System
/// Settings lays them out.
struct ValueStepper: View {
    let label: String
    let value: Int
    let text: String
    let range: ClosedRange<Int>
    var step = 1
    let set: (Int) -> Void

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                Stepper(label, value: Binding(get: { value }, set: { set($0) }), in: range, step: step)
                    .labelsHidden()
            }
        }
    }
}

struct CountStepper: View {
    let label: String
    let unit: String
    let value: Int
    var range: ClosedRange<Int> = 0...1000
    let set: (Int) -> Void

    var body: some View {
        ValueStepper(label: label, value: value, text: value == 0 ? "None" : Format.plural(value, unit), range: range, set: set)
    }
}

// MARK: - Folders

struct FoldersView: View {
    @Bindable var model: AppModel
    @ViewState private var newExclude = ""
    @ViewState private var filter = ""

    var body: some View {
        if let plan = Binding($model.plan) {
            Form {
                SwiftUI.Section {
                    ForEach(Array(plan.wrappedValue.paths.enumerated()), id: \.offset) { i, path in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(path).textSelection(.enabled)
                            Spacer()
                            Button { plan.wrappedValue.paths.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop backing up this folder")
                        }
                    }
                    Button("Add Folder…") { addFolder(plan) }
                } header: {
                    Text("Back up")
                }

                SwiftUI.Section {
                    HStack {
                        TextField("New pattern", text: $newExclude, prompt: Text("New pattern, e.g. **/node_modules or ~/Downloads"))
                            .labelsHidden()
                            .onSubmit { addExclude(plan) }
                        Button("Add") { addExclude(plan) }.disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(excludeRows(plan.wrappedValue.excludes), id: \.offset) { i, pattern in
                        HStack {
                            Text(pattern).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button { plan.wrappedValue.excludes.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    HStack {
                        Text("Exclude (\(plan.wrappedValue.excludes.count))")
                        Spacer()
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                } footer: {
                    Text("restic glob patterns. A pattern starting with / is a path; **/name matches that name at any depth. Folders tagged with CACHEDIR.TAG are skipped too.")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Indices into the full list, so a filtered row still removes the right
    /// pattern.
    private func excludeRows(_ all: [String]) -> [(offset: Int, element: String)] {
        let rows = Array(all.enumerated()).map { (offset: $0.offset, element: $0.element) }
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? rows : rows.filter { $0.element.localizedCaseInsensitiveContains(f) }
    }

    private func addExclude(_ plan: Binding<PlanSettings>) {
        var p = newExclude.trimmingCharacters(in: .whitespaces)
        // restic does not expand a tilde; the list holds absolute paths.
        if p.hasPrefix("~/") { p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst(1) }
        guard !p.isEmpty, !plan.wrappedValue.excludes.contains(p) else { return }
        plan.wrappedValue.excludes.insert(p, at: 0)
        newExclude = ""
    }

    private func addFolder(_ plan: Binding<PlanSettings>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !plan.wrappedValue.paths.contains(url.path) {
            plan.wrappedValue.paths.append(url.path)
        }
    }
}

// MARK: - Repository

/// One maintenance job: when it last ran and how that went, when it runs
/// next, and a button to run it now.
struct MaintenanceRow<Action: View>: View {
    let title: String
    let symbol: String
    let last: BackrestOperation?
    let next: Date?
    var note: String?
    var noteSeverity: Severity = .ok
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let last, last.outcome != .success { Tag(text: last.outcome.label, severity: last.outcome.severity) }
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
            parts.append(last.outcome == .success ? "Last ran \(ago)" : "\(last.outcome.label) \(ago)" + (last.reason.map { ": \($0)" } ?? ""))
        } else if note == nil {
            parts.append("Not in the recent log")
        }
        if let next { parts.append("next \(next.activityLabel)") }
        if let note { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

extension MaintenanceRow where Action == EmptyView {
    init(title: String, symbol: String, last: BackrestOperation?, next: Date?, note: String? = nil, noteSeverity: Severity = .ok) {
        self.init(title: title, symbol: symbol, last: last, next: next, note: note, noteSeverity: noteSeverity) { EmptyView() }
    }
}

struct RepositoryView: View {
    @Bindable var model: AppModel
    @ViewState private var confirmPrune = false

    var body: some View {
        if let repo = Binding($model.repo) {
            Form {
                SwiftUI.Section("Repository") {
                    LabeledContent("Location") { Text(repo.wrappedValue.uri).textSelection(.enabled) }
                    LabeledContent("Stored") {
                        HStack(spacing: 8) {
                            if let stats = model.stats?.0, let at = model.stats?.1, let size = stats.totalSize {
                                Text(storedText(stats, size: size)).monospacedDigit()
                                Text("· measured \(Format.ago(Int(Date().timeIntervalSince(at))))").foregroundStyle(.secondary)
                            } else {
                                Text("Not measured yet").foregroundStyle(.secondary)
                            }
                            Button("Measure") { Task { await model.repoTask(.stats) } }
                                .controlSize(.small)
                                .disabled(model.starting)
                        }
                    }
                }

                SwiftUI.Section {
                    MaintenanceRow(title: "Retention", symbol: "calendar.badge.minus",
                                   last: Activity.lastFinished(.forget, in: model.flows), next: nil,
                                   note: "Runs after every backup")
                    MaintenanceRow(title: "Check", symbol: "checkmark.shield",
                                   last: Activity.lastFinished(.check, in: model.flows),
                                   next: model.scheduled.first { $0.kind == .check }?.start) {
                        Button("Check Now") { Task { await model.repoTask(.check) } }
                    }
                    MaintenanceRow(title: "Prune", symbol: "scissors",
                                   last: Activity.lastFinished(.prune, in: model.flows),
                                   next: model.scheduled.first { $0.kind == .prune }?.start) {
                        Button("Prune Now…") { confirmPrune = true }
                    }
                    MaintenanceRow(title: "Locks", symbol: model.staleLock == nil ? "lock.open" : "lock.trianglebadge.exclamationmark",
                                   last: nil, next: nil,
                                   note: model.staleLock == nil ? "No stale lock reported" : "A stale lock is blocking retention and prune",
                                   noteSeverity: model.staleLock == nil ? .ok : .error) {
                        Button("Unlock") { Task { await model.repoTask(.unlock) } }
                            .help("Remove stale locks left by a run that crashed or was cut off")
                    }
                } header: {
                    Text("Maintenance")
                }
                .disabled(model.starting)

                SwiftUI.Section {
                    ScheduleEditor(title: "Check", schedule: repo.checkSchedule, allowsHours: false)
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
                    Text("Integrity check")
                } footer: {
                    Text("A structure check never reads the backed-up data, so a damaged pack only shows when you restore it. Reading a sample covers a different part each time.")
                }

                SwiftUI.Section {
                    ScheduleEditor(title: "Prune", schedule: repo.pruneSchedule, allowsHours: false)
                    ValueStepper(label: "Unused space allowed", value: Int(repo.wrappedValue.pruneMaxUnusedPercent),
                                 text: "\(Int(repo.wrappedValue.pruneMaxUnusedPercent))%", range: 0...100, step: 5) {
                        repo.wrappedValue.pruneMaxUnusedPercent = Double($0)
                    }
                } header: {
                    Text("Prune")
                } footer: {
                    Text("Retention only marks old snapshots as gone; prune is what frees their space on the server.")
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Prune the repository now?", isPresented: $confirmPrune) {
                Button("Prune") { Task { await model.repoTask(.prune) } }
            } message: {
                Text("Prune rewrites packs on the server and holds an exclusive lock: backups wait until it finishes, which can take a while on a large repository.")
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
