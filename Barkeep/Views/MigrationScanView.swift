import SwiftUI

struct MigrationScanView: View {
    let brewfileVM: BrewfileViewModel
    let brewfileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [MigratableApp] = []
    @State private var isScanning = true
    @State private var scanStatus = "Fetching cask catalog…"

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Migratable Apps")
                    .font(.headline)
                Spacer()
                if !isScanning && !apps.isEmpty {
                    let selected = apps.filter(\.selected).count
                    Button("All")  { setAll(true) }
                        .buttonStyle(.borderless)
                        .disabled(selected == apps.count)
                    Button("None") { setAll(false) }
                        .buttonStyle(.borderless)
                        .disabled(selected == 0)
                    Text("\(selected) of \(apps.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding()

            Divider()

            // Content
            if isScanning {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(scanStatus)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if apps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Nothing to migrate")
                        .font(.headline)
                    Text("All apps in /Applications are already tracked.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List($apps) { $app in
                    Toggle(isOn: $app.selected) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.appName)
                            Text(app.caskToken)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !isScanning && !apps.isEmpty {
                    Button("Add to Brewfile") {
                        addSelected()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apps.filter(\.selected).isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 420, height: 460)
        .task {
            await scan()
        }
    }

    // MARK: - Actions

    private func scan() async {
        let brewfileNames = Set(brewfileVM.allEntries.map(\.name))
        let results = await BrewRunner.shared.findMigratableCasks(brewfileEntries: brewfileNames) { status in
            Task { @MainActor in scanStatus = status }
        }
        apps = results
        isScanning = false
    }

    private func addSelected() {
        for app in apps where app.selected {
            brewfileVM.add(name: app.caskToken, kind: .cask, section: "Migrated", brewfileURL: brewfileURL)
        }
    }

    private func setAll(_ value: Bool) {
        for i in apps.indices { apps[i].selected = value }
    }
}
