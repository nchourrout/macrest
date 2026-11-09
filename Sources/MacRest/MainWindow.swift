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
        if case let .external(label) = EngineService.shared.state {
            TakeOverBanner(label: label) {
                Task { await EngineService.shared.takeOver(); await model.reload() }
            }
        }
        if let notice = model.notice {
            Banner(text: notice, severity: .ok, dismiss: { model.dismissNotice() })
        }
        if let error = model.actionError ?? model.loadError {
            Banner(text: error, severity: .error, dismiss: model.actionError != nil ? { model.dismissError() } : nil)
        }
        if model.isDirty, !model.problems.isEmpty {
            Banner(text: model.problems.joined(separator: " "), severity: .warning, dismiss: nil)
        }
    }

    @ViewBuilder private var detail: some View {
        if !EngineService.shared.isRunning || (model.loadedOnce && model.needsSetup) {
            EngineGate(engine: EngineService.shared, model: model)
        } else if !model.loadedOnce {
            ProgressView().controlSize(.small)
        } else {
            switch model.pane ?? .activity {
            case .activity: ActivityView(model: model)
            case .browse: BrowseView(model: model)
            case .schedule: ScheduleView(model: model)
            case .folders: FoldersView(model: model)
            case .storage: StorageView(model: model)
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
                Button("Restart Backup Engine") { Task { await EngineService.shared.restart(); await model.reload() } }
                Button("Open Backrest Web Interface") { NSWorkspace.shared.open(URL(string: Links.backrestURL)!) }
                Divider()
                Toggle("Open at Login", isOn: Binding(get: { AppDelegate.opensAtLogin },
                                                      set: { AppDelegate.opensAtLogin = $0 }))
                Toggle("Show in Menu Bar", isOn: Binding(get: { AppDelegate.showsMenuBarItem },
                                                         set: { AppDelegate.showsMenuBarItem = $0 }))
                Divider()
                Button("About MacRest") { About.show() }
                Button("MacRest on GitHub") { NSWorkspace.shared.open(Links.project) }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}
