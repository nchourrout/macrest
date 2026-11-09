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
            ProgressView("Starting the backup engine…").controlSize(.small)
        case let .installing(step):
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(step)
                Text("MacRest runs Backrest, the backup engine built on restic, as its own background service.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("The backup engine is not running", systemImage: "exclamationmark.triangle")
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

/// One screen from nothing to a first backup: where the backups go, with the
/// credentials that storage needs, the password, and the defaults for what
/// and when, which the panes edit later.
struct SetupView: View {
    let model: AppModel

    @ViewState private var form = StorageForm(kind: .disk)
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
    @ViewState private var publicKey: String?

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var instanceIsSet: Bool { !((model.config?["instance"]?.string ?? "").isEmpty) }

    var body: some View {
        Form {
            SwiftUI.Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Back up this Mac").font(.title2.weight(.semibold))
                    Text("Choose where the encrypted backups go. MacRest takes care of the rest: the schedule, what to leave out, and keeping old versions tidy.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            SwiftUI.Section("Where") {
                KindPicker(selection: $form.kind)
                StorageFields(form: $form, publicKey: $publicKey, instance: instance)
                checkRow
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
                        .help(reveal ? "Hide" : "Show")
                    if existing != true {
                        Button("Generate") { password = SetupDefaults.password(); reveal = true }
                    }
                    Button("Copy") { Pasteboard.copy(password) }
                }
            } header: {
                Text(existing == true ? "Password of the existing backups" : "Encryption password")
            } footer: {
                Text("Everything is encrypted with it before it leaves this Mac, and nothing can recover the backups without it. MacRest saves it in your keychain; keep another copy somewhere off this Mac.")
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
                Toggle("Clear leftover locks automatically", isOn: $autoUnlock)
            } header: {
                Text("What and when")
            } footer: {
                Text((instanceIsSet ? "" : "The name labels every backup. To continue another Mac's history in existing backups, use that Mac's name. ")
                     + "A lock left behind by a crashed run otherwise stops old backups from being removed; clearing them is safe while this Mac is the only one backing up there. Everything here can be changed later.")
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
                        .disabled(form.missing != nil || password.count < 8 || working || (!instanceIsSet && instance.isEmpty))
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: form.uri) { probe = nil; existing = nil }
        .onChange(of: form.kind) { error = nil; publicKey = nil }
    }

    @ViewBuilder private var checkRow: some View {
        HStack(alignment: .firstTextBaseline) {
            if let missing = form.missing {
                Text(missing).font(.callout).foregroundStyle(.secondary)
            } else if let probe {
                Label(probe, systemImage: probeSeverity == .ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Theme.tint(probeSeverity))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(form.uri).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Test Connection") { Task { await check() } }.disabled(form.missing != nil || working)
        }
    }

    private func check() async {
        working = true
        defer { working = false }
        do {
            try await model.ensureInstance(instance)
            let p = try await BackrestClient.checkRepoExists(SetupDefaults.repo(
                id: "probe", uri: form.uri, password: password, env: form.env, flags: form.flags, autoUnlock: false))
            existing = p.exists
            if p.hostKeyUntrusted {
                probe = form.sshAuth == .dedicated
                    ? "The server's host key could not be recorded. Make sure it is reachable, then create the key again."
                    : "This Mac does not know the server's host key yet. Connect once with ssh \(form.host) in Terminal, or use a key for MacRest."
                probeSeverity = .warning
            } else if let e = p.error {
                probe = SetupView.explain(e)
                probeSeverity = .error
            } else if p.exists {
                probe = "Existing backups found. Enter their password to continue them."
                probeSeverity = .ok
                reveal = false
                password = ""
            } else {
                probe = "Connected. The location is empty: new backups will be created there."
                probeSeverity = .ok
            }
        } catch {
            probe = SetupView.explain(error.localizedDescription)
            probeSeverity = .error
        }
    }

    private func start() async {
        working = true
        error = nil
        defer { working = false }
        do {
            try await model.setUp(.init(uri: form.uri, password: password, env: form.env, flags: form.flags,
                                        instance: instance, paths: [home], everyHours: everyHours, autoUnlock: autoUnlock))
        } catch {
            self.error = Self.explain(error.localizedDescription)
        }
    }

    /// Backrest tries `restic init` when it cannot open a repository, so a
    /// wrong password on an existing one surfaces as "config file already
    /// exists". Says what it means, and the common credential failures too.
    static func explain(_ message: String) -> String {
        let m = message.lowercased()
        if m.contains("config file already exists") || m.contains("wrong password") {
            return "That is not the password of the backups at this location."
        }
        if m.contains("host key") { return "This Mac does not trust the server's host key yet." }
        if m.contains("permission denied (publickey") { return "The server refused the SSH key. Add the key to the server, then test again." }
        if m.contains("invalidaccesskeyid") || m.contains("signaturedoesnotmatch") || m.contains("access denied") {
            return "The storage refused the credentials. Check the keys and that they can access this bucket."
        }
        if m.contains("nosuchbucket") { return "That bucket does not exist." }
        if m.contains("401") || m.contains("unauthorized") { return "The server refused the user name or password." }
        if m.contains("no such host") || m.contains("could not resolve") { return "That server could not be found. Check the address." }
        return message
    }
}

/// The kinds of storage, as a row of cards.
struct KindPicker: View {
    @Binding var selection: StorageForm.Kind

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(StorageForm.Kind.allCases) { kind in
                let on = kind == selection
                Button { selection = kind } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: kind.symbol).font(.title3)
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(kind.title).font(.callout.weight(.semibold))
                        Text(kind.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.accentColor.opacity(0.12) : Theme.track))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The fields for one kind of storage, with its credentials.
struct StorageFields: View {
    @Binding var form: StorageForm
    @Binding var publicKey: String?
    let instance: String
    @ViewState private var keyWorking = false
    @ViewState private var keyError: String?

    var body: some View {
        switch form.kind {
        case .disk: disk
        case .sftp: sftp
        case .s3: s3
        case .b2: b2
        case .rest: rest
        case .other: other
        }
    }

    // MARK: Disk

    private var externalVolumes: [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [])
            .filter { url in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return v?.volumeIsRootFileSystem != true && v?.volumeIsInternal != true && v?.volumeIsBrowsable != false
            }
    }

    @ViewBuilder private var disk: some View {
        let volumes = externalVolumes
        if volumes.isEmpty {
            Text("No external disk is connected. Connect one, or choose any folder.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(volumes, id: \.self) { v in
                let target = v.appending(path: "MacRest Backups").path
                Button {
                    form.folder = target
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: v.path)).resizable().frame(width: 20, height: 20)
                        Text(v.lastPathComponent)
                        Spacer()
                        if form.folder == target { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        LabeledContent("Folder") {
            HStack {
                Text(form.folder.isEmpty ? "None" : form.folder).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose…") { choose() }
            }
        }
    }

    private func choose() {
        if let url = FolderPicker.choose(prompt: "Use This Folder").first { form.folder = url.path }
    }

    // MARK: SFTP

    @ViewBuilder private var sftp: some View {
        TextField("Server", text: $form.host, prompt: Text("nas.local, backup.example.com or an ssh alias"))
        TextField("User", text: $form.user, prompt: Text("optional: from ~/.ssh/config or your account"))
        TextField("Port", text: $form.port, prompt: Text("22"))
        TextField("Folder on the server", text: $form.remotePath, prompt: Text("/backups/\(instance)"))
        Picker("Sign in with", selection: $form.sshAuth) {
            Text("My SSH setup (~/.ssh)").tag(StorageForm.SSHAuth.system)
            Text("A key for MacRest").tag(StorageForm.SSHAuth.dedicated)
        }
        if form.sshAuth == .dedicated {
            if let publicKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add this key to the server's ~/.ssh/authorized_keys, or let ssh-copy-id do it (it asks for your server password in Terminal; MacRest never sees it).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(publicKey).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.track, in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Button("Copy Key") { Pasteboard.copy(publicKey) }
                        if let command = form.copyKeyCommand {
                            Button("Add to Server in Terminal…") { Terminal.run(command) }
                        }
                    }
                }
            }
            if let keyError { Text(keyError).font(.callout).foregroundStyle(Theme.warning) }
            HStack {
                Text(form.identityFile.isEmpty ? "No key yet" : (form.identityFile as NSString).lastPathComponent)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if keyWorking { ProgressView().controlSize(.small) }
                Button(form.identityFile.isEmpty ? "Create Key" : "Create Again") { Task { await createKey() } }
                    .disabled(form.host.isEmpty || keyWorking)
            }
        }
    }

    private func createKey() async {
        keyWorking = true
        defer { keyWorking = false }
        do {
            let key = try await BackrestClient.setupSftp(host: form.host, port: form.port.isEmpty ? "22" : form.port, user: form.user)
            form.identityFile = key.keyPath
            form.knownHostsFile = key.knownHostsPath
            publicKey = key.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            keyError = key.warning
        } catch {
            keyError = error.localizedDescription
        }
    }

    // MARK: Cloud

    @ViewBuilder private var s3: some View {
        TextField("Endpoint", text: $form.endpoint, prompt: Text("empty for AWS, or <account>.r2.cloudflarestorage.com, s3.wasabisys.com…"))
        TextField("Bucket", text: $form.bucket)
        TextField("Folder in the bucket", text: $form.prefix, prompt: Text("optional, e.g. \(instance)"))
        TextField("Region", text: $form.region, prompt: Text("optional, e.g. eu-west-1, or auto for R2"))
        TextField("Access key ID", text: $form.accessKey)
        SecureField("Secret access key", text: $form.secretKey)
        Text("Use a key limited to this bucket. It is kept in the backup engine's configuration on this Mac, readable by your account only.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var b2: some View {
        TextField("Bucket", text: $form.bucket)
        TextField("Folder in the bucket", text: $form.prefix, prompt: Text("optional, e.g. \(instance)"))
        TextField("Key ID", text: $form.b2KeyID)
        SecureField("Application key", text: $form.b2AppKey)
        Text("Create an application key restricted to this bucket in Backblaze's console.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var rest: some View {
        TextField("Server URL", text: $form.restURL, prompt: Text("https://backup.example.com:8000/\(instance)"))
        TextField("User", text: $form.restUser, prompt: Text("optional"))
        SecureField("Password", text: $form.restPassword, prompt: Text("optional"))
    }

    @ViewBuilder private var other: some View {
        TextField("Repository URI", text: $form.rawURI, prompt: Text("azure:container:/path, gs:bucket:/path, rclone:remote:path…"))
        VStack(alignment: .leading, spacing: 4) {
            Text("Credentials, one KEY=value per line").font(.callout)
            TextEditor(text: $form.rawEnv).font(.callout.monospaced()).frame(minHeight: 60)
                .scrollContentBackground(.hidden).padding(4)
                .background(Theme.track, in: RoundedRectangle(cornerRadius: 6))
        }
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
