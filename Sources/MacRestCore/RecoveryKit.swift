import CryptoKit
import Foundation

/// Everything needed to open the backups from another Mac when this one is
/// gone: the storage, the password, the credentials to reach the storage,
/// and the Mac's name, which a plan uses to find its own backups. The
/// password is in Backrest's config and the keychain, both on this Mac, and
/// in the backups themselves, behind that same password: a copy has to live
/// somewhere else.
public struct RecoveryKit: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var label: String
        public var value: String
    }

    public var machine: String
    public var storage: String
    public var password: String
    /// The credentials to reach the storage (keys, user names), labelled as
    /// the Storage pane labels them.
    public var credentials: [Field]
    /// Extra restic options, such as the ssh key MacRest made for an SFTP
    /// server. They name files on this Mac.
    public var options: [String]

    /// The kit for the repository `repoID` in Backrest's config.
    public static func make(config: JSONValue, repoID: String) -> RecoveryKit? {
        guard let repo = config["repos"]?.array?.first(where: { $0["id"]?.string == repoID }),
              let uri = repo["uri"]?.string, let password = repo["password"]?.string
        else { return nil }
        let credentials = (repo["env"]?.strings ?? []).map { line in
            let (key, value) = Credential.split(line)
            return Field(label: Credential.label(key), value: value)
        }
        return RecoveryKit(machine: config["instance"]?.string ?? "", storage: uri, password: password,
                           credentials: credentials, options: repo["flags"]?.strings ?? [])
    }

    /// Identifies what the kit says without holding it: the confirmation that
    /// a kit was kept is stored by it, so any change asks for a new one.
    public var fingerprint: String {
        let text = fields.map { $0.label + "\u{0}" + $0.value }.joined(separator: "\u{1}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The rows of the sheet, in order.
    public var fields: [Field] {
        [Field(label: "Mac name", value: machine), Field(label: "Storage", value: storage),
         Field(label: "Password", value: password)]
            + credentials
            + (options.isEmpty ? [] : [Field(label: "Options", value: options.joined(separator: " "))])
    }

    public static let title = "MacRest Recovery Kit"
    public static let stepsHeading = "To restore on another Mac"
    public static func made(_ date: Date) -> String { "Made \(Format.date(date, "d MMMM yyyy"))" }
    public static let warning = "Anyone holding this sheet can open every backup. Keep it away from this Mac: in a password manager, or printed and put away."

    /// How to get the backups back with nothing but this sheet, numbered.
    public var steps: [String] {
        var steps = [
            "Install MacRest on the new Mac and choose the same kind of storage.",
            "Enter the storage address\(credentials.isEmpty ? "" : " and the credentials") above, then Check: MacRest finds the existing backups.",
            "Enter the password above and, to carry on this Mac's history, its name: \(machine.isEmpty ? "the name it had" : "\u{201C}\(machine)\u{201D}").",
        ]
        if !options.isEmpty {
            steps.append("The options name files on this Mac, such as its ssh key. On another Mac, sign in to the server with your own ssh setup instead.")
        }
        steps.append("Without MacRest, restic opens them too: restic -r \(storage) snapshots")
        return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
    }

    /// The whole kit as plain text, for the clipboard or a password manager.
    public func text(printed: Date) -> String {
        let width = fields.map(\.label.count).max() ?? 0
        let rows = fields.map { $0.label.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.value }
        return ([Self.title, Self.made(printed), "", Self.warning, ""] + rows
            + ["", Self.stepsHeading] + steps).joined(separator: "\n") + "\n"
    }
}
