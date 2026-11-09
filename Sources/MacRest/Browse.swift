import AppKit
import MacRestCore
import SwiftUI

/// Browse a snapshot and restore from it. The folder stays put when the
/// snapshot changes, so stepping through the timeline on the right shows the
/// same place at other moments, the way Time Machine does.
struct BrowseView: View {
    @Bindable var model: AppModel
    @ViewState private var selection: Set<SnapshotEntry.ID> = []
    @ViewState private var restoring: SnapshotEntry?
    @ViewState private var lastTarget: String?
    /// Dot-files hidden by default, as in Finder; the home folder starts with
    /// forty of them.
    @AppStorage("showsHiddenFiles") private var showsHidden = false

    private var shown: [SnapshotEntry] {
        showsHidden ? model.entries : model.entries.filter { !$0.name.hasPrefix(".") }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.selectedSnapshot != nil {
                    header
                    Divider()
                }
                files.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            timeline.frame(width: 250)
        }
        .task(id: model.savedPlan?.id) { await model.loadSnapshots() }
        .sheet(item: $restoring) { entry in
            RestoreSheet(entry: entry, snapshot: model.selectedSnapshot) { target in
                lastTarget = target
                Task { await model.restore(entry, to: target) }
            }
        }
    }

    // MARK: Header: where and when

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { step(older: true) } label: { Image(systemName: "chevron.backward") }
                    .help("Older snapshot")
                    .disabled(index.map { $0 >= model.snapshots.count - 1 } ?? true)
                Button { step(older: false) } label: { Image(systemName: "chevron.forward") }
                    .help("Newer snapshot")
                    .disabled(index.map { $0 == 0 } ?? true)
                if let s = model.selectedSnapshot {
                    Text(s.time.activityLabel).font(.headline)
                    Text(Format.ago(Int(Date().timeIntervalSince(s.time)))).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Hidden Files", isOn: $showsHidden).toggleStyle(.checkbox).font(.callout)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    let crumbs = Snapshots.breadcrumb(model.folder ?? model.snapshotRoot, root: model.snapshotRoot)
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, path in
                        if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button((path as NSString).lastPathComponent) { model.open(path) }
                            .buttonStyle(.borderless)
                            .fontWeight(i == crumbs.count - 1 ? .semibold : .regular)
                    }
                }
            }
        }
        .padding(12)
    }

    private var index: Int? {
        model.snapshots.firstIndex { $0.id == model.selectedSnapshot?.id }
    }

    private func step(older: Bool) {
        guard let i = index else { return }
        let j = older ? i + 1 : i - 1
        guard model.snapshots.indices.contains(j) else { return }
        selection = []
        model.select(model.snapshots[j])
    }

    // MARK: Files

    @ViewBuilder private var files: some View {
        if let error = model.browseError {
            ContentUnavailableView {
                Label(model.selectedSnapshot == nil ? "Could not list the snapshots" : "Could not read this folder",
                      systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.retryBrowse() }
            }
        } else if model.selectedSnapshot == nil {
            // The first listing reads every snapshot from the storage: seconds
            // to tens of seconds over the network. Say so rather than show an
            // empty table and a stray spinner.
            Loading(title: "Reading snapshots…",
                    detail: "Listing what is stored on \(model.storageName). The first time takes a moment.")
        } else if model.entriesLoading && model.entries.isEmpty {
            Loading(title: "Opening \((model.folder.map { ($0 as NSString).lastPathComponent }) ?? "folder")…",
                    detail: "Reading it from the snapshot of \(model.selectedSnapshot?.time.activityLabel ?? "")")
        } else if model.folderMissing {
            ContentUnavailableView("Not in this snapshot", systemImage: "folder.badge.questionmark",
                                   description: Text("This folder did not exist yet, or was excluded, at \(model.selectedSnapshot?.time.activityLabel ?? "that time"). Pick a newer snapshot."))
        } else {
            Table(shown, selection: $selection) {
                TableColumn("Name") { e in
                    Label {
                        Text(e.name)
                    } icon: {
                        Image(nsImage: Self.icon(for: e)).resizable().frame(width: 16, height: 16)
                    }
                }
                TableColumn("Size") { e in
                    Text(e.isDirectory ? "--" : Format.size(e.size ?? 0)).foregroundStyle(.secondary).monospacedDigit()
                }
                .width(80)
                TableColumn("Modified") { e in
                    Text(e.modified.map { $0.activityLabel } ?? "").foregroundStyle(.secondary).monospacedDigit()
                }
                .width(170)
            }
            .contextMenu(forSelectionType: SnapshotEntry.ID.self) { ids in
                if let e = entry(ids) {
                    if e.isDirectory { Button("Open") { model.open(e.path) } }
                    Button("Restore…") { restoring = e }
                    Divider()
                    Button("Copy Path") { Pasteboard.copy(e.path) }
                }
            } primaryAction: { ids in
                guard let e = entry(ids) else { return }
                // Double-click only ever navigates. Restoring is always an
                // explicit Restore… (button, menu or Cmd-Return): a stray
                // double-click on a file should not start one.
                if e.isDirectory { selection = []; model.open(e.path) }
            }
        }
    }

    private func entry(_ ids: Set<SnapshotEntry.ID>) -> SnapshotEntry? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.entries.first { $0.id == id }
    }

    /// The icon Finder would show, from the extension alone: the file is not on
    /// disk to ask.
    static func icon(for entry: SnapshotEntry) -> NSImage {
        if entry.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (entry.name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: ext.isEmpty ? .data : (.init(filenameExtension: ext) ?? .data))
    }

    // MARK: Footer: restore and its outcome

    private var footer: some View {
        HStack(spacing: 10) {
            if model.entriesLoading && !model.entries.isEmpty {
                ProgressView().controlSize(.small)
                Text("Opening…").foregroundStyle(.secondary)
            } else if let target = lastTarget {
                RestoreStatus(target: target, flows: model.flows)
            } else {
                Text("Double-click a folder to open it. Select a file or folder, then Restore….").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore…") { restoring = entry(selection) }
                .disabled(entry(selection) == nil)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .font(.callout)
        .padding(10)
    }

    // MARK: Timeline

    private var timeline: some View {
        SnapshotTimeline(snapshots: model.snapshots, selected: model.selectedSnapshot?.id,
                         loading: model.snapshotsLoading) { s in
            selection = []
            model.select(s)
        }
    }
}

/// Every snapshot, newest first, grouped by day, with what each one added.
struct SnapshotTimeline: View {
    let snapshots: [ResticSnapshot]
    let selected: String?
    let loading: Bool
    let pick: (ResticSnapshot) -> Void

    private struct Day: Identifiable {
        var day: Date
        var snapshots: [ResticSnapshot]
        var id: Date { day }
    }

    private var days: [Day] {
        Dictionary(grouping: snapshots) { Calendar.current.startOfDay(for: $0.time) }
            .map { Day(day: $0.key, snapshots: $0.value.sorted { $0.time > $1.time }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        let binding = Binding<String?>(get: { selected }, set: { id in
            if let s = snapshots.first(where: { $0.id == id }) { pick(s) }
        })
        List(selection: binding) {
            ForEach(days) { day in
                Section(ActivityDay(day: day.day, flows: []).title(now: Date())) {
                    ForEach(day.snapshots) { s in row(s).tag(Optional(s.id)) }
                }
            }
        }
        .overlay {
            if snapshots.isEmpty {
                if loading { ProgressView().controlSize(.small) } else { ContentUnavailableView("No snapshots", systemImage: "clock") }
            }
        }
    }

    private func row(_ s: ResticSnapshot) -> some View {
        HStack {
            Text(Format.date(s.time, "HH:mm")).monospacedDigit()
            Spacer()
            if let added = s.dataAdded {
                Text("+" + Format.size(added)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// Where a restore goes: next to the original by default, so nothing is
/// overwritten, or a folder picked by hand.
struct RestoreSheet: View {
    let entry: SnapshotEntry
    let snapshot: ResticSnapshot?
    let restore: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var chosen: String?

    private var alongside: String {
        Snapshots.restoreTarget(for: entry.path, snapshotTime: snapshot?.time ?? Date()) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private var target: String { chosen ?? alongside }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: BrowseView.icon(for: entry)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore \u{201C}\(entry.name)\u{201D}").font(.headline)
                    Text("As it was \(snapshot?.time.activityLabel ?? "")").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Into a new folder").font(.callout).foregroundStyle(.secondary)
                Text(target)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.track, in: RoundedRectangle(cornerRadius: 6))
                Text(chosen == nil
                     ? "Next to the original. The current version is left untouched; compare them, then keep the one you want."
                     : "The folder is created there and the item restored inside it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose Location…") { choose() }
                if chosen != nil { Button("Next to Original") { chosen = nil } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Restore") {
                    restore(target)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func choose() {
        guard let dir = FolderPicker.choose(prompt: "Restore Here",
                                            startingAt: (entry.path as NSString).deletingLastPathComponent).first?.path
        else { return }
        let inside = (dir as NSString).appendingPathComponent(entry.name)
        chosen = Snapshots.restoreTarget(for: inside, snapshotTime: snapshot?.time ?? Date()) {
            FileManager.default.fileExists(atPath: $0)
        }
    }
}

/// The last restore's progress, read from the oplog by its target.
struct RestoreStatus: View {
    let target: String
    let flows: [ActivityFlow]

    private var op: BackrestOperation? {
        flows.flatMap(\.steps).filter { $0.kind == .restore && $0.restoreTarget == target }.max { $0.id < $1.id }
    }

    var body: some View {
        HStack(spacing: 8) {
            switch op?.outcome {
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                Text("Restored to \((target as NSString).lastPathComponent)").lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
                }
            case .failed, .cancelled:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.error)
                Text("Restore failed: \(op?.reason ?? "see Activity")").foregroundStyle(Theme.error).lineLimit(1)
            default:
                ProgressView().controlSize(.small)
                Text("Restoring \((target as NSString).lastPathComponent)…").lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

