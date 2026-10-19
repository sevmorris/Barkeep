import SwiftUI

struct ActionPanelView: View {
    enum Mode { case brewfile, installed }

    @Bindable var brewfileVM: BrewfileViewModel
    var untrackedVM: UntrackedViewModel? = nil
    var mode: Mode
    var log: ProcessingLog
    @Binding var isRunning: Bool
    var onError: (String) -> Void
    var brewfilePath: URL
    /// mrk mode, when the Brewfile is in an mrk checkout: adds, ignores and
    /// prunes go through mrk's sync, by way of `runMrk`.
    var mrk: MrkMode? = nil
    var runMrk: (([MrkCommand]) async -> Void)? = nil
    /// Removes Brewfile entries; in mrk mode it prunes the ones sync would.
    var removeEntries: (([BrewfileEntry]) -> Void)? = nil

    @State private var addToSection = ""
    @State private var newSectionText = ""
    /// mrk mode: the packages of a bulk add waiting on the formula section.
    @State private var pendingAdd: PendingAdd? = nil

    private struct PendingAdd: Identifiable {
        let id = UUID()
        let packages: [BrewPackage]
    }

    private var mrkActive: Bool { mrk?.isActive == true }
    /// Brewfile entries waiting on the uninstall question.
    @State private var pendingUninstall: [BrewfileEntry] = []
    @State private var showUninstallDialog = false

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
                    content
                }
                .padding(12)
            }
        }
        .confirmationDialog(uninstallTitle, isPresented: $showUninstallDialog,
                            titleVisibility: .visible, presenting: pendingUninstall) { entries in
            Button("Uninstall and Remove from Brewfile", role: .destructive) {
                Task { await uninstall(entries, removeFromBrewfile: true) }
            }
            Button("Uninstall, Keep in Brewfile") {
                Task { await uninstall(entries, removeFromBrewfile: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entries in
            Text(entries.count == 1
                 ? "Removing its Brewfile entry too stops brew bundle from installing it again."
                 : "Removing their Brewfile entries too stops brew bundle from installing them again.")
        }
        .sheet(item: $pendingAdd) { pending in
            let formulae = pending.packages.filter { $0.kind == .formula }
            SectionNameSheet(
                title: formulae.count == 1
                    ? "Add \(formulae[0].name) to which section?"
                    : "Add \(formulae.count) formulae to which section?",
                message: "mrk's sync files each cask by its app's category, and asks for a formula's section.",
                confirmLabel: "Add",
                choices: MrkCheckout.formulaSections(in: brewfileVM.nodes)
            ) { section in
                Task { await runMrk?(addCommands(pending.packages, section: section)) }
            }
        }
    }

    /// Remove entries the mrk-aware way when there is one.
    private func remove(_ entries: [BrewfileEntry]) {
        if let removeEntries {
            removeEntries(entries)
        } else {
            brewfileVM.remove(entries: entries, brewfileURL: brewfilePath)
        }
    }

    /// One `sync --add` for each package; a formula goes in `section`.
    private func addCommands(_ packages: [BrewPackage], section: String?) -> [MrkCommand] {
        packages.map { .add(name: $0.name, kind: $0.kind, section: $0.kind == .formula ? section : nil) }
    }

    private var uninstallTitle: String {
        pendingUninstall.count == 1
            ? "Uninstall \(pendingUninstall[0].name)?"
            : "Uninstall \(pendingUninstall.count) packages?"
    }

    /// Uninstall from the Brewfile view: ask first whether the entries go too.
    private func confirmUninstall(_ entries: [BrewfileEntry]) {
        guard !entries.isEmpty else { return }
        pendingUninstall = entries
        showUninstallDialog = true
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .installed: installedContent
        case .brewfile:  brewfileContent
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        let selected = untrackedVM?.selectedPackages ?? []
        if selected.count > 1 {
            bulkInstalledActions(selected)
        } else if let pkg = selected.first {
            singleInstalledActions(pkg: pkg)
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var brewfileContent: some View {
        let selected = brewfileVM.selectedEntries
        if selected.count > 1 {
            bulkBrewfileActions(selected)
        } else if let entry = selected.first {
            singleBrewfileActions(entry: entry)
        } else {
            placeholder
        }
    }

    // MARK: - Single-selection (Installed)

    @ViewBuilder
    private func singleInstalledActions(pkg: BrewPackage) -> some View {
        if mrkActive {
            if pkg.isInBrewfile {
                mrkNotInstalledActions(pkg: pkg)
            } else {
                mrkAddView(pkg: pkg)
            }
        } else if !pkg.isInBrewfile {
            addToBrewfileView(pkg: pkg)
        } else {
            Text("Tracked in Brewfile.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    // MARK: - Single-selection (Brewfile)

    @ViewBuilder
    private func singleBrewfileActions(entry: BrewfileEntry) -> some View {
        if entry.kind == .tap {
            tapActions(entry: entry)
        } else {
            packageActions(entry: entry)
        }
    }

    @ViewBuilder
    private func tapActions(entry: BrewfileEntry) -> some View {
        let isActive = brewfileVM.activeTaps.contains(entry.name)
        if isActive {
            Text("Tap is active.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButton("Untap", icon: "minus.circle", role: .destructive) {
                Task { await runBrew(["untap", entry.name]) }
            }
        } else {
            Text("Tap is not active.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButton("Tap", icon: "arrow.down.circle") {
                Task { await runBrew(["tap", entry.name]) }
            }
        }

        Divider().padding(.vertical, 2)

        actionButton("Remove from Brewfile", icon: "minus.circle", role: .destructive) {
            remove([entry])
        }
    }

    @ViewBuilder
    private func packageActions(entry: BrewfileEntry) -> some View {
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

            actionButton("Uninstall…", icon: "trash", role: .destructive) {
                confirmUninstall([entry])
            }
        } else {
            actionButton("Install", icon: "arrow.down.circle") {
                Task { await runBrew(["install", entry.name]) }
            }
        }

        Divider().padding(.vertical, 2)

        actionButton("Remove from Brewfile", icon: "minus.circle", role: .destructive) {
            remove([entry])
        }
    }

    // MARK: - Bulk (Installed)

    @ViewBuilder
    private func bulkInstalledActions(_ selected: [BrewPackage]) -> some View {
        if mrkActive {
            mrkBulkActions(selected)
        } else {
            plainBulkInstalledActions(selected)
        }
    }

    @ViewBuilder
    private func plainBulkInstalledActions(_ selected: [BrewPackage]) -> some View {
        let outdated = selected.filter { brewfileVM.outdatedNames.contains($0.name) }
        let untracked = selected.filter { !$0.isInBrewfile }

        bulkHeader(count: selected.count)

        if !outdated.isEmpty {
            actionButton("Upgrade Outdated (\(outdated.count))",
                         icon: "arrow.up.circle.fill", tint: .orange) {
                Task { await runBrew(["upgrade"] + outdated.map(\.name)) }
            }
            Divider().padding(.vertical, 2)
        }

        actionButton("Uninstall \(selected.count)", icon: "trash", role: .destructive) {
            Task { await uninstallEach(selected.map { ($0.name, $0.kind) }) }
        }

        if !untracked.isEmpty {
            Divider().padding(.vertical, 2)
            actionButton("Add \(untracked.count) to Brewfile", icon: "plus.circle") {
                for pkg in untracked {
                    brewfileVM.add(name: pkg.name, kind: pkg.kind,
                                   section: "Adopted", brewfileURL: brewfilePath)
                    untrackedVM?.markInBrewfile(name: pkg.name, kind: pkg.kind, inBrewfile: true)
                }
            }
        }
    }

    // MARK: - Bulk (Brewfile)

    @ViewBuilder
    private func bulkBrewfileActions(_ selected: [BrewfileEntry]) -> some View {
        let outdated = selected.filter { brewfileVM.outdatedNames.contains($0.name) }
        let installable = selected.filter { $0.kind != .tap }

        bulkHeader(count: selected.count)

        if !outdated.isEmpty {
            actionButton("Upgrade Outdated (\(outdated.count))",
                         icon: "arrow.up.circle.fill", tint: .orange) {
                Task { await runBrew(["upgrade"] + outdated.map(\.name)) }
            }
            Divider().padding(.vertical, 2)
        }

        if !installable.isEmpty {
            actionButton("Uninstall \(installable.count)…", icon: "trash", role: .destructive) {
                confirmUninstall(installable)
            }
            Divider().padding(.vertical, 2)
        }

        actionButton("Remove \(selected.count) from Brewfile",
                     icon: "minus.circle", role: .destructive) {
            remove(selected)
        }
    }

    // MARK: - mrk mode

    /// An untracked package: where sync would put it, Add, and Ignore.
    @ViewBuilder
    private func mrkAddView(pkg: BrewPackage) -> some View {
        let sections = MrkCheckout.formulaSections(in: brewfileVM.nodes)
        VStack(alignment: .leading, spacing: 8) {
            if pkg.kind == .cask {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files under")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(pkg.mrkSection ?? "Its app's category")
                        .font(.body)
                    if !pkg.mrkReason.isEmpty {
                        Text(pkg.mrkReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Picker("", selection: $addToSection) {
                    ForEach(sections, id: \.self) { Text($0).tag($0) }
                    Text("New Section…").tag(Self.newSectionSentinel)
                }
                .labelsHidden()
                if sections.isEmpty || addToSection == Self.newSectionSentinel {
                    TextField("Section name", text: $newSectionText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }
            }

            actionButton("Add to Brewfile", icon: "plus.circle") {
                var section: String? = nil
                if pkg.kind == .formula {
                    let chosen = sections.isEmpty || addToSection == Self.newSectionSentinel
                        ? newSectionText
                        : (addToSection.isEmpty ? (sections.first ?? "") : addToSection)
                    section = chosen.trimmingCharacters(in: .whitespaces)
                    guard section?.isEmpty == false else { return }
                }
                let command = MrkCommand.add(name: pkg.name, kind: pkg.kind, section: section)
                Task { await runMrk?([command]) }
            }

            actionButton("Ignore", icon: "eye.slash") {
                Task { await runMrk?([.ignore(name: pkg.name, kind: pkg.kind)]) }
            }
            Text("Ignore adds it to ~/.mrk/sync-ignore, so sync and Barkeep stop offering it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: pkg.id) { _, _ in
            addToSection = ""
            newSectionText = ""
        }
    }

    /// A Brewfile entry whose package is not installed: install it, or prune it.
    @ViewBuilder
    private func mrkNotInstalledActions(pkg: BrewPackage) -> some View {
        Text("In the Brewfile, not installed.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)

        actionButton("Install", icon: "arrow.down.circle") {
            Task { await runBrew(pkg.kind == .cask ? ["install", "--cask", pkg.name] : ["install", pkg.name]) }
        }

        Divider().padding(.vertical, 2)

        actionButton("Remove from Brewfile", icon: "minus.circle", role: .destructive) {
            Task { await runMrk?([.prune(name: pkg.name, kind: pkg.kind)]) }
        }
    }

    @ViewBuilder
    private func mrkBulkActions(_ selected: [BrewPackage]) -> some View {
        let adds = selected.filter { !$0.isInBrewfile }
        let prunes = selected.filter { $0.isInBrewfile }
        let outdated = adds.filter { brewfileVM.outdatedNames.contains($0.name) }

        bulkHeader(count: selected.count)

        if !outdated.isEmpty {
            actionButton("Upgrade Outdated (\(outdated.count))",
                         icon: "arrow.up.circle.fill", tint: .orange) {
                Task { await runBrew(["upgrade"] + outdated.map(\.name)) }
            }
            Divider().padding(.vertical, 2)
        }

        if !adds.isEmpty {
            actionButton("Add \(adds.count) to Brewfile", icon: "plus.circle") {
                if adds.contains(where: { $0.kind == .formula }) {
                    pendingAdd = PendingAdd(packages: adds)
                } else {
                    Task { await runMrk?(addCommands(adds, section: nil)) }
                }
            }
            actionButton("Ignore \(adds.count)", icon: "eye.slash") {
                Task { await runMrk?(adds.map { .ignore(name: $0.name, kind: $0.kind) }) }
            }
            Divider().padding(.vertical, 2)
            actionButton("Uninstall \(adds.count)", icon: "trash", role: .destructive) {
                Task { await uninstallEach(adds.map { ($0.name, $0.kind) }) }
            }
        }

        if !prunes.isEmpty {
            Divider().padding(.vertical, 2)
            actionButton("Remove \(prunes.count) from Brewfile", icon: "minus.circle", role: .destructive) {
                Task { await runMrk?(prunes.map { .prune(name: $0.name, kind: $0.kind) }) }
            }
        }
    }

    // MARK: - Subviews

    private static let newSectionSentinel = "__new__"

    private var placeholder: some View {
        Text("Select a package\nto see actions.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
    }

    private func bulkHeader(count: Int) -> some View {
        Text("\(count) packages selected")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func addToBrewfileView(pkg: BrewPackage) -> some View {
        let sections = brewfileVM.sectionNames
        VStack(alignment: .leading, spacing: 8) {
            if sections.isEmpty {
                TextField("Section name", text: $newSectionText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
            } else {
                Picker("", selection: $addToSection) {
                    ForEach(sections, id: \.self) { Text($0).tag($0) }
                    Text("New Section…").tag(Self.newSectionSentinel)
                }
                .labelsHidden()
                if addToSection == Self.newSectionSentinel {
                    TextField("Section name", text: $newSectionText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                }
            }
            actionButton("Add to Brewfile", icon: "plus.circle") {
                let section: String
                if sections.isEmpty || addToSection == Self.newSectionSentinel {
                    section = newSectionText.trimmingCharacters(in: .whitespaces)
                } else {
                    section = addToSection.isEmpty ? (sections.first ?? "") : addToSection
                }
                guard !section.isEmpty else { return }
                brewfileVM.add(name: pkg.name, kind: pkg.kind, section: section, brewfileURL: brewfilePath)
                untrackedVM?.markInBrewfile(name: pkg.name, kind: pkg.kind, inBrewfile: true)
            }
        }
        .onChange(of: pkg.id) { _, _ in
            addToSection = ""
            newSectionText = ""
        }
    }

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

    private func uninstallArgs(name: String, kind: PackageKind) -> [String] {
        var args = ["uninstall"]
        if kind == .cask { args.append("--cask") }
        args.append(name)
        return args
    }

    private func runBrew(_ args: [String]) async {
        guard !isRunning else { return }
        isRunning = true
        log.clear()
        log.append("$ brew " + args.joined(separator: " "))

        do {
            try await BrewRunner.shared.run(args) { @MainActor line, level in
                log.append(line, level: level)
            }
            // Drop cached `brew info` for any non-flag arg so the detail
            // panel re-fetches version, outdated state, etc.
            let names = args.dropFirst().filter { !$0.hasPrefix("-") }
            await BrewRunner.shared.invalidateCache(names: Array(names))
            log.append("Done.")
            await brewfileVM.refreshOutdated()
            let verb = args.first ?? "operation"
            if verb == "tap" || verb == "untap" {
                await brewfileVM.refreshTaps()
            }
            if let mrk, mrk.isActive { await mrk.refresh() }
            await NotificationService.showCompletionNotification(
                operation: "\(verb.capitalized) complete (\(names.count) package\(names.count == 1 ? "" : "s"))."
            )
        } catch {
            log.append("Error: \(error.localizedDescription)", level: .error)
            onError(error.localizedDescription)
        }

        isRunning = false
    }

    /// Uninstall Brewfile entries, then, when asked, remove the entries of
    /// the packages brew did uninstall. A failed uninstall keeps its entry.
    private func uninstall(_ entries: [BrewfileEntry], removeFromBrewfile: Bool) async {
        let uninstalled = await uninstallEach(entries.map { ($0.name, $0.kind) })
        guard removeFromBrewfile, !uninstalled.isEmpty else { return }
        brewfileVM.remove(packages: uninstalled, brewfileURL: brewfilePath)
        log.append("Removed \(uninstalled.count) from the Brewfile.")
    }

    /// Sequentially uninstall each package — one failure doesn't stop the rest.
    /// Returns the packages that were uninstalled.
    @discardableResult
    private func uninstallEach(_ packages: [(name: String, kind: PackageKind)]) async
        -> [(name: String, kind: PackageKind)] {
        guard !isRunning, !packages.isEmpty else { return [] }
        isRunning = true
        log.clear()

        var failures: [String] = []
        var uninstalled: [(name: String, kind: PackageKind)] = []
        for (name, kind) in packages {
            let args = uninstallArgs(name: name, kind: kind)
            log.append("$ brew " + args.joined(separator: " "))
            do {
                try await BrewRunner.shared.run(args) { @MainActor line, level in
                    log.append(line, level: level)
                }
                await BrewRunner.shared.invalidateCache(names: [name])
                uninstalled.append((name, kind))
            } catch {
                log.append("Error: \(error.localizedDescription)", level: .error)
                failures.append(name)
            }
        }

        log.append("Done. Uninstalled \(uninstalled.count) of \(packages.count) packages.")
        await brewfileVM.refreshOutdated()
        if let mrk, mrk.isActive { await mrk.refresh() }
        await NotificationService.showCompletionNotification(
            operation: "Uninstall complete — \(uninstalled.count) of \(packages.count) uninstalled."
        )
        if !failures.isEmpty {
            onError("Failed to uninstall: \(failures.joined(separator: ", "))")
        }
        isRunning = false
        return uninstalled
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

        await BrewRunner.shared.invalidateCache(names: [name])
        await brewfileVM.refreshOutdated()
        if let entry = brewfileVM.selectedEntry {
            Task { await brewfileVM.loadDetail(for: entry) }
        }
        isRunning = false
    }
}
