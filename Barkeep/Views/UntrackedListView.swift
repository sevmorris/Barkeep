import SwiftUI

struct UntrackedListView: View {
    @Bindable var vm: UntrackedViewModel
    var outdatedNames: Set<String> = []
    /// mrk mode: the lists are what mrk's sync reports.
    var mrkMode = false

    var body: some View {
        VStack(spacing: 0) {
            filterBar(text: $vm.filterText)
            Divider()

            if mrkMode, let error = vm.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }

            if vm.isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Loading packages…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredFormulae.isEmpty && vm.filteredCasks.isEmpty && vm.filteredNotInstalled.isEmpty {
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
                    if !vm.filteredNotInstalled.isEmpty {
                        // In the Brewfile, not on this Mac: what sync would prune.
                        Section("In Brewfile, Not Installed (\(vm.filteredNotInstalled.count))") {
                            ForEach(vm.filteredNotInstalled) { pkg in
                                PackageRowView(name: pkg.name, kind: pkg.kind,
                                               description: pkg.description)
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
