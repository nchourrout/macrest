import AppKit
import MacRestCore

/// The few places MacRest reaches into macOS directly, each in one place.

/// Puts text on the clipboard.
enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
        // The same string for both keys shows "Version x" alone, without the
        // build hash, which means nothing to a person.
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: version,
            .version: version,
            .credits: credits,
        ])
    }
}
