import AppKit
import MacRestCore
import SwiftUI

/// Shown instead of the panes until Backrest is running and has a repository:
/// the engine's own state first (downloading, starting, failed), then the
/// one-screen setup.
struct EngineGate: View {
    let engine: EngineService
    let model: AppModel

    var body: some View {
        switch engine.state {
        case .checking:
            ProgressView("Looking for Backrest…").controlSize(.small)
        case let .installing(step):
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(step)
                Text("MacRest runs Backrest, the restic engine, as its own background service.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Backrest is not running", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await engine.ensure(); await model.reload() } }
            }
        case .running, .external:
            SetupView(model: model)
        }
    }
}

/// One screen from nothing to a first backup: where, the password, and the
/// defaults for what and when, which the panes edit later.
struct SetupView: View {
    let model: AppModel

    @ViewState private var kind: SetupDefaults.Destination = .sftp
    @ViewState private var host = ""
    @ViewState private var user = ""
    @ViewState private var path = ""
    @ViewState private var raw = ""
    @ViewState private var awsKey = ""
    @ViewState private var awsSecret = ""
    @ViewState private var password = SetupDefaults.password()
    @ViewState private var reveal = true
    @ViewState private var probe: String?
    @ViewState private var probeSeverity: Severity = .ok
    @ViewState private var existing: Bool?
    @ViewState private var instance = SetupDefaults.instanceID(from: Host.current().localizedName ?? "mac")
    @ViewState private var everyHours = 1
    @ViewState private var autoUnlock = true
    @ViewState private var working = false
    @ViewState private var error: String?

    private var uri: String { SetupDefaults.uri(kind, host: host, user: user, path: path, raw: raw) }
    private var env: [String] {
        guard kind == .other, raw.hasPrefix("s3:"), !awsKey.isEmpty else { return [] }
        return ["AWS_ACCESS_KEY_ID=\(awsKey)", "AWS_SECRET_ACCESS_KEY=\(awsSecret)"]
    }
    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var instanceIsSet: Bool { !((model.config?["instance"]?.string ?? "").isEmpty) }

    var body: some View {
        Form {
            SwiftUI.Section {
                Text("Back up this Mac").font(.title2.weight(.semibold))
                Text("Pick where the encrypted backups go. MacRest sets up the rest: Backrest, a schedule, and what to leave out.")
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section("Where") {
                Picker("Destination", selection: $kind) {
                    ForEach(SetupDefaults.Destination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                destinationFields
                HStack {
                    Text(uri.isEmpty ? " " : uri).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button("Check") { Task { await check() } }.disabled(uri.isEmpty || working)
                }
                if let probe {
                    Text(probe).font(.callout).foregroundStyle(Theme.tint(probeSeverity))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SwiftUI.Section {
                HStack {
                    if reveal {
                        TextField("Password", text: $password).font(.body.monospaced())
                    } else {
                        SecureField("Password", text: $password)
                    }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                    if existing != true {
                        Button("Generate") { password = SetupDefaults.password(); reveal = true }
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(password, forType: .string)
                    }
                }
            } header: {
                Text(existing == true ? "Password of the existing repository" : "Repository password")
            } footer: {
                Text("It encrypts everything, and nothing can recover the backups without it. MacRest saves it in your keychain; keep another copy somewhere off this Mac.")
            }

            SwiftUI.Section {
                if !instanceIsSet {
                    TextField("Name of this Mac", text: $instance)
                }
                LabeledContent("Back up") { Text("Your home folder, without caches, VMs and build output") }
                Picker("How often", selection: $everyHours) {
                    Text("Every hour").tag(1)
                    Text("Every 2 hours").tag(2)
                    Text("Every 4 hours").tag(4)
                }
                LabeledContent("Keep") { Text("Hourly for a day, daily for a month, weekly for a year, monthly for two") }
                Toggle("Clear stale locks automatically", isOn: $autoUnlock)
            } header: {
                Text("What and when")
            } footer: {
                Text((instanceIsSet ? "" : "The name tags every snapshot. To continue another Mac's history in an existing repository, use that Mac's name. ")
                     + "Stale locks from a crashed run otherwise stop old snapshots from being removed; clearing them is safe while this Mac is the repository's only user. Everything here can be changed later.")
            }

            SwiftUI.Section {
                if let error {
                    Text(error).foregroundStyle(Theme.error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if working { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(existing == true ? "Connect and Back Up" : "Start Backing Up") { Task { await start() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(uri.isEmpty || password.count < 8 || working || (!instanceIsSet && instance.isEmpty))
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: uri) { probe = nil; existing = nil }
    }

    @ViewBuilder private var destinationFields: some View {
        switch kind {
        case .sftp:
            TextField("Server", text: $host, prompt: Text("ns, nas.local or 192.168.1.10"))
            TextField("User", text: $user, prompt: Text("optional, ~/.ssh/config is used"))
            TextField("Folder on the server", text: $path, prompt: Text("/home/you/restic/\(instance)"))
        case .local:
            HStack {
                TextField("Folder", text: $path, prompt: Text("/Volumes/Backup/restic"))
                Button("Choose…") { choose() }
            }
        case .rest:
            TextField("Server URL", text: $raw, prompt: Text("https://user:pass@host:8000/repo"))
        case .other:
            TextField("Repository", text: $raw, prompt: Text("s3:s3.amazonaws.com/bucket/path, b2:bucket:path, …"))
            if raw.hasPrefix("s3:") {
                TextField("Access key", text: $awsKey)
                SecureField("Secret key", text: $awsSecret)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }

    private func check() async {
        working = true
        defer { working = false }
        do {
            let p = try await BackrestClient.checkRepoExists(SetupDefaults.repo(id: "probe", uri: uri, password: password,
                                                                                env: env, autoUnlock: false))
            existing = p.exists
            if p.hostKeyUntrusted {
                probe = "This Mac does not know the server's host key yet. Connect once in Terminal (ssh \(host)) to trust it, then check again."
                probeSeverity = .warning
            } else if let e = p.error {
                probe = e
                probeSeverity = .error
            } else if p.exists {
                probe = "A repository is already there. Enter its password to continue it."
                probeSeverity = .ok
                reveal = false
                password = ""
            } else {
                probe = "Reachable, and empty: a new repository will be created."
                probeSeverity = .ok
            }
        } catch {
            probe = error.localizedDescription
            probeSeverity = .error
        }
    }

    private func start() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.setUp(.init(uri: uri, password: password, env: env, instance: instance,
                                        paths: [home], everyHours: everyHours, autoUnlock: autoUnlock))
        } catch {
            self.error = Self.explain(error.localizedDescription)
        }
    }

    /// Backrest tries `restic init` when it cannot open a repository, so a
    /// wrong password on an existing one surfaces as "config file already
    /// exists". Says what it means.
    static func explain(_ message: String) -> String {
        if message.contains("config file already exists") || message.contains("wrong password") {
            return "That is not the password of the repository at this location."
        }
        if message.contains("host key") { return "This Mac does not trust the server's host key yet. Connect once with ssh in Terminal, then try again." }
        return message
    }
}

/// A Backrest MacRest did not start (Homebrew's service): it works as is,
/// and this offers to move it under MacRest without losing anything.
struct TakeOverBanner: View {
    let label: String?
    let takeOver: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            Text(label?.contains("brew") == true
                 ? "Backrest is running from Homebrew. MacRest can run it itself, on the same settings and history."
                 : "Backrest is running outside MacRest. MacRest can run it itself, on the same settings and history.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Take Over", action: takeOver)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
    }
}
