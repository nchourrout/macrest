import AppKit
import MacRestCore
import QuickLook
import SwiftUI

/// Browse a snapshot and restore from it. The folder stays put when the
/// snapshot changes, so stepping through the timeline on the right shows the
/// same place at other moments, the way Time Machine does.
struct BrowseView: View {
    @Bindable var model: AppModel
    @ViewState private var selection: Set<SnapshotEntry.ID> = []
    @ViewState private var restoring: SnapshotEntry?
    @ViewState private var lastTarget: String?
    /// The newest restore asked for: an older one answering late must not
    /// take the footer from it.
    @ViewState private var restoreRequest = 0
    /// Dot-files hidden by default, as in Finder; the home folder starts with
    /// forty of them.
    @AppStorage("showsHiddenFiles") private var showsHidden = false
    /// Typing filters the folder shown; Return searches the backups.
    @ViewState private var query = ""
    /// A hidden item opened from search, shown in its folder without turning
    /// on Hidden Files for good.
    @ViewState private var revealedHidden: String?
    @ViewState private var spaceKey = SpaceKeyMonitor()
    @FocusState private var listFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    private var shown: [SnapshotEntry] {
        let visible = showsHidden ? model.entries
            : model.entries.filter { !$0.name.hasPrefix(".") || $0.path == revealedHidden }
        let q = trimmedQuery
        return q.isEmpty ? visible : visible.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The search results are on screen rather than the folder.
    private var showsResults: Bool { !trimmedQuery.isEmpty && model.hasSearch }

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
        .searchable(text: $query, placement: .toolbar, prompt: "Filter or search backups")
        .onSubmit(of: .search) { model.search(query) }
        .onChange(of: query) {
            // A changed query is a new one: the old results no longer match it.
            if model.hasSearch { model.clearSearch() }
        }
        .onChange(of: model.entries) { applyHighlight() }
        .onChange(of: model.highlight) { applyHighlight() }
        .onChange(of: model.folder) {
            if let h = revealedHidden, (h as NSString).deletingLastPathComponent != model.folder { revealedHidden = nil }
        }
        .quickLookPreview($model.previewURL)
        .onAppear {
            // Space opens the preview, and closes it again, as in Finder.
            spaceKey.start {
                if model.previewURL != nil { model.previewURL = nil; return true }
                // The file list only: Space in the timeline is not a preview.
                guard listFocused, !showsResults, let e = entry(selection), !e.isDirectory else { return false }
                model.preview(e)
                return true
            }
        }
        .onDisappear { spaceKey.stop() }
        .sheet(item: $restoring) { entry in
            RestoreSheet(entry: entry, snapshot: model.selectedSnapshot) { target in
                lastTarget = nil
                restoreRequest += 1
                let request = restoreRequest
                Task {
                    if await model.restore(entry, to: target), request == restoreRequest { lastTarget = target }
                }
            }
        }
    }

    // MARK: Header: where and when

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { step(older: true) } label: { Image(systemName: "chevron.backward") }
                    .help("Older backup")
                    .accessibilityLabel("Older Backup")
                    .disabled(index.map { $0 >= model.snapshots.count - 1 } ?? true)
                Button { step(older: false) } label: { Image(systemName: "chevron.forward") }
                    .help("Newer backup")
                    .accessibilityLabel("Newer Backup")
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
        if showsResults {
            SearchResults(model: model, query: trimmedQuery) { path, snapshot in
                query = ""
                model.reveal(path, in: snapshot)
            }
        } else if let error = model.browseError {
            ContentUnavailableView {
                Label(model.selectedSnapshot == nil ? "Could not list the backups" : "Could not read this folder",
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
            Loading(title: "Reading backups…",
                    detail: "Listing what is stored on \(model.storageName). The first time takes a moment.")
        } else if model.entriesLoading && model.entries.isEmpty {
            Loading(title: "Opening \((model.folder.map { ($0 as NSString).lastPathComponent }) ?? "folder")…",
                    detail: "Reading it from the backup made \(model.selectedSnapshot?.time.inlineLabel ?? "").")
        } else if model.folderMissing {
            ContentUnavailableView("Not in this backup", systemImage: "folder.badge.questionmark",
                                   description: Text("This folder did not exist, or was excluded, in the backup made \(model.selectedSnapshot?.time.inlineLabel ?? "then"). Pick another backup."))
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
                    if !e.isDirectory { Button("Quick Look") { model.preview(e) } }
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
            .focused($listFocused)
        }
    }

    /// Selects a search result once its folder is listed, showing hidden
    /// files when it is one.
    private func applyHighlight() {
        guard let path = model.highlight, model.entries.contains(where: { $0.path == path }) else { return }
        if (path as NSString).lastPathComponent.hasPrefix(".") { revealedHidden = path }
        selection = [path]
        // The results list had the focus and is gone: give it to the folder,
        // so Space previews the item just found.
        listFocused = true
        model.highlight = nil
    }

    private func entry(_ ids: Set<SnapshotEntry.ID>) -> SnapshotEntry? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.entries.first { $0.id == id }
    }

    /// The icon Finder would show, from the extension alone: the file is not on
    /// disk to ask.
    static func icon(for entry: SnapshotEntry) -> NSImage { icon(name: entry.name, isDirectory: entry.isDirectory) }

    static func icon(name: String, isDirectory: Bool) -> NSImage {
        if isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (name as NSString).pathExtension
        return NSWorkspace.shared.icon(for: ext.isEmpty ? .data : (.init(filenameExtension: ext) ?? .data))
    }

    // MARK: Footer: restore and its outcome

    private var footer: some View {
        let selected = entry(selection)
        return HStack(spacing: 10) {
            if let searching = model.searching {
                ProgressView().controlSize(.small)
                Text("Searching \(model.searchScopeText ?? "the backups") for \u{201C}\(searching)\u{201D}…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.clearSearch() }
            } else if showsResults {
                Text(model.searchResult?.truncated == true
                     ? "Too many matches to show them all. Type more of the name."
                     : "Double-click a result to show it in its backup.")
                    .foregroundStyle(model.searchResult?.truncated == true ? Theme.warning : .secondary)
                Spacer()
            } else {
                if let previewing = model.previewing {
                    ProgressView().controlSize(.small)
                    Text("Fetching \u{201C}\(previewing.name)\u{201D} to preview…").lineLimit(1).truncationMode(.middle)
                    Button("Cancel") { model.cancelPreview() }
                } else if model.entriesLoading && !model.entries.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Opening…").foregroundStyle(.secondary)
                } else if !trimmedQuery.isEmpty {
                    Text(model.searchScopeText.map { "Press Return to search \($0)." } ?? "No backups to search yet.")
                        .foregroundStyle(.secondary)
                } else if let target = lastTarget {
                    RestoreStatus(target: target, flows: model.flows)
                } else {
                    Text("Double-click opens a folder. Space previews a file.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quick Look") { selected.map(model.preview) }
                    .disabled(selected?.isDirectory ?? true || model.previewing != nil)
                Button("Restore…") { restoring = selected }
                    .disabled(selected == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
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

/// Files and folders found by name, newest first. Each opens in the newest
/// backup holding it; the menu lists every version found.
struct SearchResults: View {
    let model: AppModel
    let query: String
    let reveal: (String, String) -> Void
    @ViewState private var selection: Set<FoundItem.ID> = []

    var body: some View {
        if let error = model.searchError {
            ContentUnavailableView {
                Label("The search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.search(query) }
            }
        } else if let result = model.searchResult {
            if result.items.isEmpty {
                ContentUnavailableView("Nothing named \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass",
                                       description: Text("No file or folder with that in its name in \(model.searchScopeText ?? "the backups searched")."))
            } else {
                table(result.items)
            }
        } else {
            Loading(title: "Searching the backups…",
                    detail: "Looking for \u{201C}\(query)\u{201D} in \(model.searchScopeText ?? "the backups"). Over the network this can take a minute.")
        }
    }

    private func table(_ items: [FoundItem]) -> some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                Label {
                    Text(item.name)
                } icon: {
                    Image(nsImage: BrowseView.icon(name: item.name, isDirectory: item.isDirectory)).resizable().frame(width: 16, height: 16)
                }
            }
            TableColumn("Folder") { item in
                Text((item.folder as NSString).abbreviatingWithTildeInPath)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            TableColumn("Versions") { item in
                Text(item.isDirectory ? "" : "\(item.versions.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(70)
            TableColumn("Last Backed Up") { item in
                Text(item.lastSeen.activityLabel).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(170)
        }
        .contextMenu(forSelectionType: FoundItem.ID.self) { ids in
            if let item = items.first(where: { ids.count == 1 && $0.id == ids.first }) {
                Button("Show in Backup") { show(item, item.versions[0]) }
                if item.versions.count > 1 {
                    Divider()
                    ForEach(Array(item.versions.enumerated()), id: \.offset) { _, v in
                        Button(versionTitle(v)) { show(item, v) }
                    }
                }
                Divider()
                Button("Copy Path") { Pasteboard.copy(item.path) }
            }
        } primaryAction: { ids in
            guard ids.count == 1, let item = items.first(where: { $0.id == ids.first }) else { return }
            show(item, item.versions[0])
        }
    }

    private func show(_ item: FoundItem, _ version: FoundItem.Version) {
        guard let snapshot = version.snapshots.first else { return }
        reveal(item.path, snapshot)
    }

    private func versionTitle(_ v: FoundItem.Version) -> String {
        var parts = ["Modified " + (v.modified.map { $0.activityLabel } ?? "at an unknown time")]
        if let size = v.size { parts.append(Format.size(size)) }
        parts.append("in \(Format.plural(v.snapshots.count, "backup"))")
        return parts.joined(separator: " · ")
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
                if loading { ProgressView().controlSize(.small) } else { ContentUnavailableView("No backups yet", systemImage: "clock") }
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
                    Text("As it was \(snapshot?.time.inlineLabel ?? "")").foregroundStyle(.secondary)
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
        Activity.restore(into: target, in: flows.flatMap(\.steps))
    }

    var body: some View {
        HStack(spacing: 8) {
            switch op?.outcome {
            case .success, .warning:
                // A warning is a finished restore with files it could not
                // write; Activity lists them.
                Image(systemName: op?.outcome == .warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(op?.outcome == .warning ? Theme.warning : .secondary)
                Text((op?.outcome == .warning ? "Restored with warnings to " : "Restored to ") + (target as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .help(op?.reason ?? "")
                Button("Show in Finder") {
                    Finder.reveal(target)
                }
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                Text("Restore cancelled").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.error)
                Text(op?.reason.map { "Restore failed: \($0)" } ?? "Restore failed. See Activity for details.")
                    .foregroundStyle(Theme.error).lineLimit(1)
            default:
                ProgressView().controlSize(.small)
                Text("Restoring \((target as NSString).lastPathComponent)…").lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

