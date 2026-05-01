import SwiftUI

/// One untracked package — installed locally but not present in the Brewfile.
struct UntrackedPackage: Identifiable {
    let id = UUID()
    let name: String
    let kind: PackageKind
    var selected: Bool = true
}

/// Reusable sheet that scans the system for untracked installed packages and
/// hands a confirmed selection back to the caller. Two modes share the same
/// list and scan logic; only the strings and confirm-button role differ.
struct BundleUntrackedView: View {
    enum Mode {
        case adopt    // add selected packages to the Brewfile
        case cleanup  // uninstall selected packages from the system
    }

    let mode: Mode
    let brewfileVM: BrewfileViewModel
    let onConfirm: ([(name: String, kind: PackageKind)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var packages: [UntrackedPackage] = []
    @State private var isScanning = true
    @State private var error: String? = nil

    private var selectedCount: Int { packages.filter(\.selected).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 460, height: 480)
        .task { await scan() }
    }

    // MARK: - Layout

    private var header: some View {
        HStack {
            Text(headlineText)
                .font(.headline)
            Spacer()
            if !isScanning && !packages.isEmpty {
                Button("All")  { setAll(true) }
                    .buttonStyle(.borderless)
                    .disabled(selectedCount == packages.count)
                Button("None") { setAll(false) }
                    .buttonStyle(.borderless)
                    .disabled(selectedCount == 0)
                Text("\(selectedCount) of \(packages.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            Spacer()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Scanning installed packages…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else if let error {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("Couldn't list installed packages")
                    .font(.headline)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
        } else if packages.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
                Text(emptyTitle)
                    .font(.headline)
                Text(emptySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        } else {
            List($packages) { $pkg in
                Toggle(isOn: $pkg.selected) {
                    HStack(spacing: 8) {
                        Image(systemName: pkg.kind == .cask ? "app.gift" : "shippingbox")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(pkg.name)
                        Spacer()
                        Text(pkg.kind == .cask ? "cask" : "formula")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if !isScanning && !packages.isEmpty {
                Button(confirmTitle, role: confirmRole) {
                    let selected = packages.filter(\.selected)
                        .map { (name: $0.name, kind: $0.kind) }
                    onConfirm(selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func setAll(_ value: Bool) {
        for i in packages.indices { packages[i].selected = value }
    }

    private func scan() async {
        let tracked = Set(brewfileVM.allEntries.map { "\($0.kind.rawValue):\($0.name)" })
        do {
            // Drop transitive dependencies — only consider formulae the user
            // explicitly installed. Casks have no dep concept, so list all.
            async let formulae = BrewRunner.shared.listRequestedFormulae()
            async let casks    = BrewRunner.shared.listCasks()
            let (fs, cs) = try await (formulae, casks)

            var result: [UntrackedPackage] = []
            for name in fs where !tracked.contains("formula:\(name)") {
                result.append(UntrackedPackage(name: name, kind: .formula))
            }
            for name in cs where !tracked.contains("cask:\(name)") {
                result.append(UntrackedPackage(name: name, kind: .cask))
            }
            packages = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
        isScanning = false
    }

    // MARK: - Mode-dependent strings

    private var headlineText: String {
        switch mode {
        case .adopt:   return "Add Untracked to Brewfile"
        case .cleanup: return "Cleanup Untracked"
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .adopt:   return "Nothing to adopt"
        case .cleanup: return "Nothing to clean up"
        }
    }

    private var emptySubtitle: String {
        switch mode {
        case .adopt:   return "Every installed package is already in your Brewfile."
        case .cleanup: return "Everything installed is already in your Brewfile."
        }
    }

    private var confirmTitle: String {
        switch mode {
        case .adopt:   return "Add \(selectedCount)"
        case .cleanup: return "Uninstall \(selectedCount)"
        }
    }

    private var confirmRole: ButtonRole? {
        switch mode {
        case .adopt:   return nil
        case .cleanup: return .destructive
        }
    }
}
