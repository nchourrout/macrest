import AppKit
import MacRestCore
import ServiceManagement
import SwiftUI

@main
struct MacRestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppDelegate.menuBarKey) private var showsMenuBarItem = true

    var body: some Scene {
        // Opens at launch only when there is no menu bar icon to open it from:
        // with the icon, a login launch stays quiet. `--window [pane]` forces
        // it, for checking the window without clicking.
        Window("MacRest", id: MainWindow.id) {
            MainWindow(model: AppModel.shared)
        }
        .defaultSize(width: 980, height: 660)
        .defaultLaunchBehavior(AppDelegate.opensWindowAtLaunch ? .presented : .suppressed)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacRest") { About.show() }
            }
            CommandGroup(replacing: .help) {
                Button("MacRest on GitHub") { NSWorkspace.shared.open(Links.project) }
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarItem) {
            MenuPanel(model: AppModel.shared)
        } label: {
            MenuLabel(model: AppModel.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let menuBarKey = "showsMenuBarItem"

    @MainActor static var showsMenuBarItem: Bool {
        get { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: menuBarKey)
            updateActivationPolicy()
        }
    }

    static var opensWindowAtLaunch: Bool {
        CommandLine.arguments.contains("--window")
            || !(UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await Render.run(to: URL(fileURLWithPath: args[i + 1]))
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--window"), i + 1 < args.count, let pane = Pane(rawValue: args[i + 1].capitalized) {
            AppModel.shared.pane = pane
        }
        QuickLookCache.clear()
        Self.updateActivationPolicy()
        Self.registerLoginItemOnce()
        AppModel.shared.start()
        // `--take-over` moves a Homebrew Backrest under MacRest without a
        // click, for a scripted migration.
        let takeOver = args.contains("--take-over")
        Task { @MainActor in
            let engine = EngineService.shared
            await engine.ensure()
            if takeOver, case .external = engine.state { await engine.takeOver() }
            await AppModel.shared.reload()
        }
    }

    /// MacRest opens at login, registered once on first launch so installing
    /// the app is the whole setup; turning it off in the `…` menu (or System
    /// Settings) sticks, since this never registers again.
    @MainActor static func registerLoginItemOnce() {
        let key = "loginItemRegistered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: key)
    }

    @MainActor static var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard newValue else { try? SMAppService.mainApp.unregister(); return }
            // macOS may hold it for approval: show where to give it rather
            // than leave the toggle off with no reason.
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    /// A Dock icon while the window is open, or always when there is no menu
    /// bar icon (the Dock is then the only way back in). Otherwise the app
    /// lives in the menu bar alone, like MacStatus.
    @MainActor static func updateActivationPolicy() {
        let regular = AppModel.shared.windowVisible || !showsMenuBarItem
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        if regular { NSApp.activate() }
    }

    /// Opening MacRest while it runs (MacStatus's backup card, Finder, `open
    /// -a`) is a reopen. With the menu bar icon and the window closed, the
    /// default only activated an app with nothing on screen, so the click
    /// seemed to do nothing: it opens the window instead. Without the icon
    /// the window is the app, and SwiftUI's default handles it.
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Self.showsMenuBarItem else { return true }
        if !AppModel.shared.windowVisible { AppModel.shared.windowRequests += 1 }
        NSApp.activate()
        return false
    }

    /// Without a menu bar icon, closing the window is quitting: nothing would
    /// be left to reach the app by, and it sends no notifications.
    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.showsMenuBarItem
    }
}

/// The menu bar glyph. It follows the verdict by silhouette, so it reads in
/// the menu bar's monochrome; dimmed while Backrest cannot be read.
struct MenuLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let overview = model.overview
        Image(systemName: overview?.menuSymbol ?? "clock.badge.questionmark")
            .opacity(overview == nil ? 0.4 : 1)
            .accessibilityLabel("MacRest: \(overview?.title ?? "the backup engine is not answering")")
            // The label is always there while the icon is, so it opens the
            // window asked for by a reopen (see `applicationShouldHandleReopen`).
            .onChange(of: model.windowRequests) {
                NSApp.activate()
                openWindow(id: MainWindow.id)
            }
    }
}

/// The menu bar panel: the verdict, what is running, and the three things one
/// comes here for: back up now, restore something, open the window.
struct MenuPanel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = model.overview {
                HStack(spacing: 10) {
                    Image(systemName: o.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.tint(o.severity))
                        .frame(width: 32, height: 32)
                        .background(Theme.track, in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.color(o.severity))
                        Text(o.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                DaysChart(overview: o)
            } else if model.needsSetup {
                Label("Backups are not set up yet.", systemImage: "externaldrive.badge.plus")
                Button("Set Up Backups…") { open(.activity) }.controlSize(.large)
            } else {
                Label(engineText ?? model.loadError ?? "Connecting to the backup engine…", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }

            if let run = model.runningBackup {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Backing up").font(.callout.weight(.medium))
                        Spacer()
                        if let pct = run.primary.backup?.percentDone { Text("\(Int(pct * 100))%").monospacedDigit() }
                        Button("Stop") { Task { await model.cancel(run.primary) } }.controlSize(.small)
                    }
                    ProgressBar(value: run.primary.backup?.percentDone ?? 0)
                }
                .font(.callout)
            }

            if let error = model.actionError {
                // The window banner is not there while only the panel is.
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.error)
                    Text(error).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { model.dismissError() }.controlSize(.small)
                }
            } else if model.staleLock != nil {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(Theme.error)
                    Text("A leftover lock is stopping old backups from being removed.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(model.unlocking ? "Unlocking…" : "Unlock") { Task { await model.unlock() } }
                        .controlSize(.small).disabled(model.unlocking)
                }
            } else if let notice = model.notice {
                HStack(alignment: .firstTextBaseline) {
                    Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("OK") { model.dismissNotice() }.controlSize(.small)
                }
            } else if let skipped = model.overview?.privateFoldersSkipped, skipped > 0 {
                FullDiskAccessRow(skipped: skipped).font(.callout).controlSize(.small)
            } else if let o = model.overview, !o.failingMaintenance.isEmpty {
                Label(Format.failing(o.failingMaintenance), systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            }

            HStack(spacing: 8) {
                Button { Task { await model.backupNow() } } label: {
                    Label("Back Up Now", systemImage: "arrow.clockwise.icloud").frame(maxWidth: .infinity)
                }
                .disabled(model.runningBackup != nil || model.isBusy(.backup) || model.savedPlan == nil)
                Button { open(.browse) } label: {
                    Label("Restore…", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            Divider().padding(.horizontal, 4)
            // One footer line, as MacStatus's: Open on the left, the version
            // (About) and Quit on the right. Three full-width menu rows took
            // a third of the panel for actions used once a day at most.
            HStack(spacing: 2) {
                FooterButton(action: { open(nil) }) {
                    HStack(spacing: 6) {
                        Text("Open MacRest").foregroundStyle(.primary)
                        Text("⌘O")
                    }
                }
                .keyboardShortcut("o")
                Spacer(minLength: 8)
                FooterButton(action: { About.show() }) { Text("v\(About.version)").monospacedDigit() }
                    .accessibilityLabel("About MacRest")
                FooterButton(action: { NSApp.terminate(nil) }) { Image(systemName: "power") }
                    .keyboardShortcut("q")
                    .accessibilityLabel("Quit MacRest")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, -6)
            .padding(.vertical, -4)
        }
        .padding(14)
        .frame(width: 330)
    }

    private var engineText: String? {
        switch EngineService.shared.state {
        case let .installing(step): step
        case let .failed(message): message
        default: nil
        }
    }

    private func open(_ pane: Pane?) {
        if let pane { model.pane = pane }
        NSApp.activate()
        openWindow(id: MainWindow.id)
    }
}

/// A borderless footer control with the system's hover highlight.
private struct FooterButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
