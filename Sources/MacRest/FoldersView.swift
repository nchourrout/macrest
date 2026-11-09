import AppKit
import MacRestCore
import SwiftUI

struct FoldersView: View {
    @Bindable var model: AppModel
    @ViewState private var newExclude = ""
    @ViewState private var filter = ""

    var body: some View {
        if let plan = Binding($model.plan) {
            Form {
                SwiftUI.Section {
                    ForEach(Array(plan.wrappedValue.paths.enumerated()), id: \.offset) { i, path in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(path).textSelection(.enabled)
                            Spacer()
                            Button { plan.wrappedValue.paths.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .help("Stop backing up this folder")
                        }
                    }
                    Button("Add Folder…") { addFolder(plan) }
                } header: {
                    Text("Back up")
                }

                SwiftUI.Section {
                    HStack {
                        TextField("New pattern", text: $newExclude, prompt: Text("New pattern, e.g. **/node_modules or ~/Downloads"))
                            .labelsHidden()
                            .onSubmit { addExclude(plan) }
                        Button("Add") { addExclude(plan) }.disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(excludeRows(plan.wrappedValue.excludes), id: \.offset) { i, pattern in
                        HStack {
                            Text(pattern).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button { plan.wrappedValue.excludes.remove(at: i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    HStack {
                        Text("Exclude (\(plan.wrappedValue.excludes.count))")
                        Spacer()
                        TextField("Filter", text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                } footer: {
                    Text("restic glob patterns. A pattern starting with / is a path; **/name matches that name at any depth. Folders tagged with CACHEDIR.TAG are skipped too.")
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Indices into the full list, so a filtered row still removes the right
    /// pattern.
    private func excludeRows(_ all: [String]) -> [(offset: Int, element: String)] {
        let rows = Array(all.enumerated()).map { (offset: $0.offset, element: $0.element) }
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? rows : rows.filter { $0.element.localizedCaseInsensitiveContains(f) }
    }

    private func addExclude(_ plan: Binding<PlanSettings>) {
        var p = newExclude.trimmingCharacters(in: .whitespaces)
        // restic does not expand a tilde; the list holds absolute paths.
        if p.hasPrefix("~/") { p = FileManager.default.homeDirectoryForCurrentUser.path + p.dropFirst(1) }
        guard !p.isEmpty, !plan.wrappedValue.excludes.contains(p) else { return }
        plan.wrappedValue.excludes.insert(p, at: 0)
        newExclude = ""
    }

    private func addFolder(_ plan: Binding<PlanSettings>) {
        let urls = FolderPicker.choose(prompt: "Back Up", startingAt: FileManager.default.homeDirectoryForCurrentUser.path,
                                       multiple: true, canCreate: false)
        for url in urls where !plan.wrappedValue.paths.contains(url.path) {
            plan.wrappedValue.paths.append(url.path)
        }
    }
}
