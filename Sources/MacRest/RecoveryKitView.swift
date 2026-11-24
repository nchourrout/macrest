import MacRestCore
import SwiftUI

/// The recovery kit: what opens the backups from another Mac, to print or
/// copy into a password manager, and the confirmation that it was kept.
struct RecoveryKitSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "key.viewfinder").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(RecoveryKit.title).font(.headline)
                    Text(RecoveryKit.warning).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let kit = model.recoveryKit {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(Array(kit.fields.enumerated()), id: \.offset) { _, field in
                        GridRow(alignment: .firstTextBaseline) {
                            Text(field.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(field.value).font(.body.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.track, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(RecoveryKit.stepsHeading).font(.callout.weight(.semibold))
                    ForEach(kit.steps, id: \.self) { step in
                        Text(step).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Button("Print…") { KitPrinter.print(kit) }
                        .help("Print it, or choose Save as PDF in the print panel")
                    CopyButton(title: "Copy All", secret: true) { kit.text(printed: Date()) }
                        .help("Copy the kit as text, to paste into a password manager")
                    Spacer()
                    Button("Close", role: .cancel) { dismiss() }
                    Button("I Have Kept It") {
                        model.markKitSaved()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("The storage settings could not be read.").foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { dismiss() } }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Shown in Activity until the kit is kept: the backups are encrypted with a
/// password that, so far, only exists on this Mac.
struct RecoveryKitRow: View {
    let open: () -> Void

    var body: some View {
        NoticeRow(symbol: "key",
                  text: "Only this Mac knows the password to your backups. If it is lost, they cannot be opened: keep a recovery kit somewhere else.",
                  button: "Recovery Kit…", action: open)
    }
}
