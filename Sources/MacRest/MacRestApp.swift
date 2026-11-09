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
        set { newValue ? try? SMAppService.mainApp.register() : try? SMAppService.mainApp.unregister() }
    }

    /// A Dock icon while the window is open, or always when there is no menu
    /// bar icon (the Dock is then the only way back in). Otherwise the app
    /// lives in the menu bar alone, like MacStatus.
    @MainActor static func updateActivationPolicy() {
        let regular = AppModel.shared.windowVisible || !showsMenuBarItem
        NSApp.setActivationPolicy(regular ? .regular : .accessory)
        if regular { NSApp.activate() }
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

    var body: some View {
        let overview = model.overview
        Image(systemName: overview?.menuSymbol ?? "clock.badge.questionmark")
            .opacity(overview == nil ? 0.4 : 1)
            .accessibilityLabel("MacRest: \(overview?.title ?? "the backup engine is not answering")")
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

            if model.staleLock != nil {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(Theme.error)
                    Text("A leftover lock is stopping old backups from being removed.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Unlock") { Task { await model.unlock() } }.controlSize(.small)
                }
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let o = model.overview, !o.failingMaintenance.isEmpty {
                Label("\(o.failingMaintenance.joined(separator: ", ")) failed on its last run.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
            }

            HStack(spacing: 8) {
                Button { Task { await model.backupNow() } } label: {
                    Label("Back Up Now", systemImage: "arrow.clockwise.icloud").frame(maxWidth: .infinity)
                }
                .disabled(model.runningBackup != nil || model.starting || model.savedPlan == nil)
                Button { open(.browse) } label: {
                    Label("Restore…", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            Divider().padding(.horizontal, 4)
            // Menu rows, as in the system's own menu bar panels: full width,
            // highlighted on hover, with the shortcut on the right.
            VStack(spacing: 0) {
                MenuRow(title: "Open MacRest", shortcut: "⌘O") { open(nil) }
                    .keyboardShortcut("o")
                MenuRow(title: "About MacRest", shortcut: "v\(About.version)") { About.show() }
                MenuRow(title: "Quit", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, -8)
            .padding(.top, -6)
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

/// A plain menu item inside the panel: the title on the left, its shortcut
/// dimmed on the right, and the system's hover highlight.
private struct MenuRow: View {
    let title: String
    let shortcut: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
