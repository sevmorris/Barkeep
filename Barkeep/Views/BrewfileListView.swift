import SwiftUI

struct BrewfileListView: View {
    @Bindable var vm: BrewfileViewModel
    var brewfileURL: URL

    /// State for the rename / new-section sheet. The kind drives the
    /// title and what happens on submit.
    private struct SheetContext: Identifiable {
        enum Kind { case rename(String); case newSectionForMove([BrewfileEntry]) }
        let id = UUID()
        let kind: Kind
    }

    @State private var sheet: SheetContext? = nil
    @State private var deletingSection: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            filterBar(text: $vm.filterText)
            Divider()

            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredSections.isEmpty {
                emptyLabel(vm.filterText.isEmpty ? "No Brewfile loaded" : "No matches")
            } else {
                List(selection: $vm.selectedEntryIDs) {
                    ForEach(vm.filteredSections, id: \.name) { section in
                        Section {
                            ForEach(section.entries) { entry in
                                PackageRowView(
                                    name: entry.name,
                                    kind: entry.kind,
                                    hasUpdate: vm.outdatedNames.contains(entry.name)
                                )
                                .tag(entry.id)
                                .contextMenu { rowMenu(for: entry) }
                            }
                        } header: {
                            sectionHeader(section.name)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .sheet(item: $sheet) { ctx in
            switch ctx.kind {
            case .rename(let oldName):
                SectionNameSheet(
                    title: "Rename Section",
                    confirmLabel: "Rename",
                    initial: oldName
                ) { newName in
                    vm.renameSection(from: oldName, to: newName, brewfileURL: brewfileURL)
                }
            case .newSectionForMove(let entries):
                SectionNameSheet(
                    title: "Move to New Section",
                    confirmLabel: "Move"
                ) { newName in
                    vm.move(entries: entries, to: newName, brewfileURL: brewfileURL)
                }
            }
        }
        .alert("Delete Section?",
               isPresented: Binding(
                get: { deletingSection != nil },
                set: { if !$0 { deletingSection = nil } }
               ),
               presenting: deletingSection) { name in
            Button("Delete", role: .destructive) {
                vm.deleteSection(name, brewfileURL: brewfileURL)
            }
            Button("Cancel", role: .cancel) { }
        } message: { name in
            Text("Removes the “\(name)” header and every entry inside it. The packages will not be uninstalled.")
        }
    }

    // MARK: - Subviews

    private func sectionHeader(_ name: String) -> some View {
        Text(name)
            .contextMenu {
                Button("Rename Section…") {
                    sheet = SheetContext(kind: .rename(name))
                }
                Button("Delete Section", role: .destructive) {
                    deletingSection = name
                }
            }
    }

    @ViewBuilder
    private func rowMenu(for entry: BrewfileEntry) -> some View {
        // Standard macOS pattern: if the right-clicked row is part of the
        // current selection, the menu acts on the whole selection;
        // otherwise it acts only on the clicked row.
        let acting: [BrewfileEntry] = {
            if vm.selectedEntryIDs.contains(entry.id) && vm.selectedEntries.count > 1 {
                return vm.selectedEntries
            }
            return [entry]
        }()
        let actingSections = Set(acting.map(\.section))
        let targets = vm.sectionNames.filter { !actingSections.contains($0) }

        Menu("Move to") {
            ForEach(targets, id: \.self) { name in
                Button(name) {
                    vm.move(entries: acting, to: name, brewfileURL: brewfileURL)
                }
            }
            if !targets.isEmpty { Divider() }
            Button("New Section…") {
                sheet = SheetContext(kind: .newSectionForMove(acting))
            }
        }
        Divider()
        Button("Remove from Brewfile", role: .destructive) {
            vm.remove(entries: acting, brewfileURL: brewfileURL)
        }
    }
}
