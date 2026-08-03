import SwiftUI

struct UntrackedListView: View {
    @Bindable var vm: UntrackedViewModel
    var outdatedNames: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            filterBar(text: $vm.filterText)
            Divider()

            if vm.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading packages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredFormulae.isEmpty && vm.filteredCasks.isEmpty {
                emptyLabel(vm.filterText.isEmpty ? "No untracked packages" : "No matches")
            } else {
                List(selection: $vm.selectedPackageIDs) {
                    if !vm.filteredFormulae.isEmpty {
                        Section("Formulae (\(vm.filteredFormulae.count))") {
                            ForEach(vm.filteredFormulae) { pkg in
                                PackageRowView(name: pkg.name, kind: pkg.kind,
                                               description: pkg.description,
                                               hasUpdate: outdatedNames.contains(pkg.name),
                                               untracked: true)
                                    .tag(pkg.id)
                            }
                        }
                    }
                    if !vm.filteredCasks.isEmpty {
                        Section("Casks (\(vm.filteredCasks.count))") {
                            ForEach(vm.filteredCasks) { pkg in
                                PackageRowView(name: pkg.name, kind: pkg.kind,
                                               description: pkg.description,
                                               hasUpdate: outdatedNames.contains(pkg.name),
                                               untracked: true)
                                    .tag(pkg.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}
