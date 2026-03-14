import SwiftUI

struct ActionPanelView: View {
    @Bindable var brewfileVM: BrewfileViewModel
    var log: ProcessingLog
    @Binding var isRunning: Bool
    var onError: (String) -> Void
    var brewfilePath: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ACTIONS")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let entry = brewfileVM.selectedEntry {
                        // Update badge in actions if outdated
                        if brewfileVM.outdatedNames.contains(entry.name) {
                            actionButton("Upgrade", icon: "arrow.up.circle.fill", tint: .orange) {
                                Task { await runBrew(["upgrade", entry.name]) }
                            }
                            Divider().padding(.vertical, 2)
                        }

                        if let detail = brewfileVM.selectedDetail, detail.isInstalled {
                            if !detail.isBrewManaged && entry.kind == .cask {
                                // App exists in /Applications but brew doesn't track it
                                actionButton("Adopt", icon: "square.and.arrow.down.on.square", tint: .blue) {
                                    Task { await adoptCask(entry.name) }
                                }
                            }

                            actionButton("Reinstall", icon: "arrow.down.circle") {
                                Task { await runBrew(["reinstall", entry.name]) }
                            }

                            actionButton("Uninstall", icon: "trash", role: .destructive) {
                                Task {
                                    var args = ["uninstall"]
                                    if entry.kind == .cask { args.append("--cask") }
                                    args.append(entry.name)
                                    await runBrew(args)
                                }
                            }
                        } else {
                            actionButton("Install", icon: "arrow.down.circle") {
                                Task { await runBrew(["install", entry.name]) }
                            }
                        }

                        Divider().padding(.vertical, 2)

                        actionButton("Remove from Brewfile", icon: "minus.circle", role: .destructive) {
                            brewfileVM.remove(entry: entry, brewfileURL: brewfilePath)
                        }
                    } else {
                        Text("Select a package\nto see actions.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func actionButton(
        _ label: String,
        icon: String,
        role: ButtonRole? = nil,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(label, systemImage: icon)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            tint.map { AnyShapeStyle($0) }
            ?? (role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        )
        .disabled(isRunning)
        .padding(.vertical, 2)
    }

    // MARK: - Brew execution

    private func runBrew(_ args: [String]) async {
        guard !isRunning else { return }
        isRunning = true
        log.clear()
        log.append("$ brew " + args.joined(separator: " "))

        do {
            try await BrewRunner.shared.run(args) { @MainActor line, level in
                log.append(line, level: level)
            }
            log.append("Done.")
            // Refresh outdated list after upgrade/install/uninstall
            await brewfileVM.refreshOutdated()
        } catch {
            log.append("Error: \(error.localizedDescription)", level: .error)
            onError(error.localizedDescription)
        }

        isRunning = false
    }

    /// Try --adopt first; if versions mismatch, fall back to --force install.
    private func adoptCask(_ name: String) async {
        guard !isRunning else { return }
        isRunning = true
        log.clear()
        log.append("$ brew install --adopt --cask \(name)")

        do {
            try await BrewRunner.shared.run(["install", "--adopt", "--cask", name]) { @MainActor line, level in
                log.append(line, level: level)
            }
            log.append("Done — adopted successfully.")
        } catch {
            // Adopt failed (likely version mismatch) — retry with --force
            log.append("Adopt failed, upgrading with --force…", level: .verbose)
            log.append("$ brew install --force --cask \(name)")
            do {
                try await BrewRunner.shared.run(["install", "--force", "--cask", name]) { @MainActor line, level in
                    log.append(line, level: level)
                }
                log.append("Done — installed and now managed by brew.")
            } catch {
                log.append("Error: \(error.localizedDescription)", level: .error)
                onError(error.localizedDescription)
            }
        }

        await brewfileVM.refreshOutdated()
        // Reload detail so isBrewManaged updates
        if let entry = brewfileVM.selectedEntry {
            Task { await brewfileVM.loadDetail(for: entry) }
        }
        isRunning = false
    }
}
