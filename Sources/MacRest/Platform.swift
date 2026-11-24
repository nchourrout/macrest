import AppKit
import Combine
import MacRestCore

/// The few places MacRest reaches into macOS directly, each in one place.

/// Puts text on the clipboard.
enum Pasteboard {
    /// `secret` marks it concealed, so clipboard history tools skip it.
    static func copy(_ text: String, secret: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if secret { NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }
}

/// Runs a command in a new Terminal window, for the one step that needs a
/// person at a prompt (a server password for ssh-copy-id).
enum Terminal {
    static func run(_ command: String) {
        let file = FileManager.default.temporaryDirectory.appending(path: "macrest-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\n\(command)\necho\nread -sk 1 '?Done. Press any key to close.'\n"
        guard (try? script.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

/// Full Disk Access is granted per program, to the one launchd starts: the
/// Backrest binary MacRest runs, whose restic inherits it. macOS offers no
/// way to ask for it, so this opens the list in System Settings and selects
/// that binary in Finder, to drag into it. The binary is versioned, so a
/// Backrest update needs the grant again.
@MainActor
enum FullDiskAccess {
    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func open() {
        NSWorkspace.shared.open(settings)
        if let binary = EngineService.shared.ownBinary { Finder.reveal(binary) }
    }
}

enum Finder {
    /// Opens a Finder window with the item selected.
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// Asks for a folder with the standard open panel.
@MainActor
enum FolderPicker {
    /// The chosen folders, empty when cancelled.
    static func choose(prompt: String, startingAt start: String? = nil, multiple: Bool = false,
                       canCreate: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = multiple
        panel.prompt = prompt
        if let start { panel.directoryURL = URL(fileURLWithPath: start) }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// The About panel: the version people quote in an issue, and where the
/// project lives.
enum About {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    @MainActor static func show() {
        let credits = NSMutableAttributedString(
            string: "A Time Machine alternative built on restic and Backrest.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/nchourrout/macrest",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: Links.project]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        // An empty build version drops the parenthesis: a local build's
        // version already carries its commit ("0.1.1-3-g7a482ed").
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .version: "",
            .credits: credits,
        ])
    }
}

/// Where Quick Look's files are restored: MacRest's own caches folder, which
/// Backrest can write to and nothing else reads. Emptied at each launch.
enum QuickLookCache {
    static let root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: Bundle.main.bundleIdentifier ?? EngineAgent.appBundleID)
        .appending(path: "Quick Look")

    static func clear() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

/// Prints the recovery kit: the system print panel, which also saves a PDF.
@MainActor
enum KitPrinter {
    static func print(_ kit: RecoveryKit) {
        let body = NSFont.systemFont(ofSize: 11)
        let label = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let grey = NSColor.darkGray
        let text = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: NSColor = .black) {
            text.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        add(RecoveryKit.title + "\n", .systemFont(ofSize: 20, weight: .bold))
        add(RecoveryKit.made(Date()) + "\n\n", body, grey)
        add(RecoveryKit.warning + "\n\n", body)
        for field in kit.fields {
            add(field.label + "\n", label, grey)
            add(field.value + "\n\n", mono)
        }
        add(RecoveryKit.stepsHeading + "\n", .systemFont(ofSize: 13, weight: .semibold))
        for step in kit.steps { add(step + "\n", body) }

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        info.topMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textStorage?.setAttributedString(text)
        view.isEditable = false
        view.drawsBackground = false
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = RecoveryKit.title
        op.run()
    }
}

/// Space in a list previews, as in Finder. SwiftUI's key handlers never see
/// it on a Table, whose table view takes it first, so this watches key
/// presses directly, and only while a table has focus: a space typed in the
/// search field stays a space.
@MainActor
final class SpaceKeyMonitor {
    private var monitor: Any?

    /// `handler` returns whether it used the key press.
    func start(_ handler: @escaping @MainActor () -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard event.keyCode == 49, modifiers.isEmpty else { return event }
            let used = MainActor.assumeIsolated {
                NSApp.keyWindow?.firstResponder is NSTableView && handler()
            }
            return used ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Disks plugged in or out, for a list of them to follow.
enum Volumes {
    static var changes: AnyPublisher<Notification, Never> {
        let center = NSWorkspace.shared.notificationCenter
        return center.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: center.publisher(for: NSWorkspace.didUnmountNotification))
            .eraseToAnyPublisher()
    }
}
