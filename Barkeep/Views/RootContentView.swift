import SwiftUI

struct RootContentView: View {
    @Environment(AppState.self) var appState
    @State private var brewfileVM  = BrewfileViewModel()
    @State private var untrackedVM = UntrackedViewModel()
    @State private var sidebarTab  = SidebarTab.brewfile
    @State private var log         = ProcessingLog()
    @State private var isRunning   = false
    @State private var showConsole = false
    @State private var alertMessage: String? = nil

    @State private var consoleHeight: CGFloat = 170
    @State private var consoleDragStart: CGFloat? = nil
    @State private var brewfileWatcher = BrewfileWatcher()

    private static let consoleMinHeight: CGFloat = 80
    private static let consoleMaxHeight: CGFloat = 600

    @State private var showInspector = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private enum SidebarTab: String, Hashable {
        case brewfile = "Brewfile"
        case untracked = "Untracked"
    }

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.brewfilePath == nil || appState.showBrewfilePicker {
                BrewfilePickerView()
                    .environment(appState)
            } else {
                mainWindow
            }
        }
        .onChange(of: appState.brewfilePath, initial: true) { _, url in
            guard let url else { brewfileWatcher.stop(); return }
            brewfileVM.load(from: url)
            brewfileWatcher.start(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .barkeepRefresh)) { _ in
            if let url = appState.brewfilePath { brewfileVM.load(from: url) }
        }
        .onChange(of: sidebarTab) { _, tab in
            if tab == .untracked {
                Task { await untrackedVM.load(brewfileEntries: brewfileVM.allEntries) }
            }
        }
        .onChange(of: brewfileVM.selectedEntryIDs) { _, _ in
            if let entry = brewfileVM.selectedEntry {
                Task { await brewfileVM.loadDetail(for: entry) }
            } else {
                brewfileVM.selectedDetail = nil
                brewfileVM.isLoadingDetail = false
            }
        }
        .onChange(of: untrackedVM.selectedPackageIDs) { _, _ in
            if let pkg = untrackedVM.selectedPackage {
                Task { await untrackedVM.loadDetail(for: pkg) }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: - Main layout

    private var mainWindow: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $sidebarTab) {
                NavigationLink(value: SidebarTab.brewfile) {
                    Label("Brewfile", systemImage: "doc.text")
                }
                NavigationLink(value: SidebarTab.untracked) {
                    Label("Untracked", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle("Categories")
        } content: {
            Group {
                if sidebarTab == .brewfile {
                    if let url = appState.brewfilePath {
                        BrewfileListView(vm: brewfileVM, brewfileURL: url)
                    }
                } else {
                    UntrackedListView(vm: untrackedVM, outdatedNames: brewfileVM.outdatedNames)
                }
            }
            .navigationTitle(sidebarTab.rawValue)
        } detail: {
            VStack(spacing: 0) {
                detailPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showConsole {
                    consoleResizeHandle
                    ConsoleView(log: log)
                        .frame(height: consoleHeight)
                }
            }
            .navigationTitle(appState.brewfilePath?.lastPathComponent ?? "Barkeep")
            .navigationSubtitle(appState.brewfilePath?.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
            .inspector(isPresented: $showInspector) {
                if let brewfilePath = appState.brewfilePath {
                    ActionPanelView(
                        brewfileVM:   brewfileVM,
                        untrackedVM:  untrackedVM,
                        mode:         sidebarTab == .untracked ? .installed : .brewfile,
                        log:          log,
                        isRunning:    $isRunning,
                        onError:      { alertMessage = $0 },
                        brewfilePath: brewfilePath
                    )
                    .inspectorColumnWidth(min: 220, ideal: 240, max: 300)
                }
            }
            .toolbar {
                toolbarContent
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if brewfileVM.isLoading {
            ToolbarItem(placement: .automatic) {
                ProgressView().controlSize(.small)
            }
        }

        if !brewfileVM.outdatedNames.isEmpty {
            ToolbarItem(placement: .automatic) {
                Button {
                    showConsole = true
                    Task {
                        let names = Array(brewfileVM.outdatedNames)
                        await runStreaming(["upgrade"] + names, successMessage: "All updates complete.")
                        await BrewRunner.shared.invalidateCache(names: names)
                        await brewfileVM.refreshOutdated()
                    }
                } label: {
                    Label("\(brewfileVM.outdatedNames.count) updates", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
                .disabled(isRunning)
                .help("Upgrade all outdated packages")
            }
        }

        if untrackedVM.untrackedCount > 0 {
            ToolbarItem(placement: .automatic) {
                Label("\(untrackedVM.untrackedCount) untracked", systemImage: "questionmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Untracked packages")
            }
        }

        if let update = appState.availableUpdate {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await checkForUpdates(silent: false, appState: appState) }
                } label: {
                    Label("Barkeep \(update.version)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                }
                .help("Update available — click to download or view release notes")
            }
        }

        ToolbarItem(placement: .automatic) {
            if isRunning {
                Button {
                    Task { await BrewRunner.shared.cancel() }
                } label: {
                    Image(systemName: "stop.circle").foregroundStyle(.red)
                }
                .help("Cancel")
            } else {
                EmptyView()
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showConsole.toggle() }
            } label: {
                Image(systemName: showConsole ? "terminal.fill" : "terminal")
            }
            .help("Toggle console")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                guard let url = appState.brewfilePath else { return }
                brewfileVM.load(from: url)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isRunning)
            .help("Refresh")
        }

        ToolbarItem(placement: .automatic) {
            Button {
                appState.showBrewfilePicker = true
            } label: {
                Image(systemName: "folder")
            }
            .help("Change Brewfile")
        }
        
        ToolbarItem(placement: .automatic) {
            Button {
                showInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle Inspector")
        }
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        if sidebarTab == .untracked {
            if untrackedVM.selectedPackages.count > 1 {
                MultiSelectSummary(count: untrackedVM.selectedPackages.count,
                                   names: untrackedVM.selectedPackages.map(\.name))
            } else if let pkg = untrackedVM.selectedPackage {
                PackageDetailView(package: pkg)
            } else {
                EmptyStateView()
            }
        } else if brewfileVM.selectedEntries.count > 1 {
            MultiSelectSummary(count: brewfileVM.selectedEntries.count,
                               names: brewfileVM.selectedEntries.map(\.name))
        } else if let entry = brewfileVM.selectedEntry {
            if brewfileVM.isLoadingDetail {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                detailView(for: brewfileVM.selectedDetail,
                           fallbackName: entry.name,
                           fallbackKind: entry.kind,
                           section: entry.section)
            }
        } else {
            EmptyStateView()
        }
    }

    @ViewBuilder
    private func detailView(
        for pkg: BrewPackage?,
        fallbackName: String = "",
        fallbackKind: PackageKind = .formula,
        section: String = ""
    ) -> some View {
        let resolved = pkg ?? BrewPackage(name: fallbackName, kind: fallbackKind)
        let display = {
            var p = resolved
            p.isInBrewfile = true
            if p.brewfileSection == nil { p.brewfileSection = section }
            if !p.outdated { p.outdated = brewfileVM.outdatedNames.contains(p.name) }
            return p
        }()
        PackageDetailView(package: display)
    }

    // MARK: - Console resize handle

    /// Thin draggable strip above the console. Drag up to grow, down to shrink.
    private var consoleResizeHandle: some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(height: 6)
                .onHover { hovering in
                    if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            if consoleDragStart == nil { consoleDragStart = consoleHeight }
                            let proposed = (consoleDragStart ?? consoleHeight) - value.translation.height
                            consoleHeight = min(max(proposed, Self.consoleMinHeight), Self.consoleMaxHeight)
                        }
                        .onEnded { _ in consoleDragStart = nil }
                )
        }
        .frame(height: 6)
    }

    // MARK: - Bundle commands

    /// Run `brew bundle install --file=<path>`. Idempotent — installs whatever's
    /// missing and skips what's already present.
    private func runBundleInstall() async {
        guard !isRunning, let url = appState.brewfilePath else { return }
        showConsole = true
        await runStreaming(
            ["bundle", "install", "--file=\(url.path)"],
            successMessage: "Brewfile install complete."
        )
        // We don't know which packages got installed — drop everything.
        await BrewRunner.shared.invalidateAllCache()
        if let url = appState.brewfilePath { brewfileVM.load(from: url) }
    }

    /// Add the selected untracked packages to the Brewfile under "Adopted".
    private func adoptIntoBrewfile(
        _ selected: [(name: String, kind: PackageKind)],
        brewfileURL: URL
    ) {
        for (name, kind) in selected {
            brewfileVM.add(name: name, kind: kind, section: "Adopted", brewfileURL: brewfileURL)
        }
    }

    /// Uninstall the selected untracked packages one by one, streaming output.
    private func runCleanup(_ selected: [(name: String, kind: PackageKind)]) async {
        guard !isRunning, !selected.isEmpty else { return }
        showConsole = true
        isRunning = true
        log.clear()

        var failures: [String] = []
        for (name, kind) in selected {
            var args = ["uninstall"]
            if kind == .cask { args.append("--cask") }
            args.append(name)
            log.append("$ brew " + args.joined(separator: " "))
            do {
                try await BrewRunner.shared.run(args) { @MainActor line, level in
                    log.append(line, level: level)
                }
                await BrewRunner.shared.invalidateCache(names: [name])
            } catch {
                log.append("Error: \(error.localizedDescription)", level: .error)
                failures.append(name)
            }
        }

        let removed = selected.count - failures.count
        log.append("Done. Removed \(removed) of \(selected.count) packages.")
        await brewfileVM.refreshOutdated()
        await NotificationService.showCompletionNotification(
            operation: "Cleanup complete — removed \(removed) of \(selected.count)."
        )
        if !failures.isEmpty {
            alertMessage = "Failed to uninstall: \(failures.joined(separator: ", "))"
        }
        isRunning = false
    }

    /// Shared streaming runner used for toolbar-level brew commands.
    private func runStreaming(_ args: [String], successMessage: String) async {
        isRunning = true
        log.clear()
        log.append("$ brew " + args.joined(separator: " "))
        do {
            try await BrewRunner.shared.run(args) { @MainActor line, level in
                log.append(line, level: level)
            }
            log.append(successMessage)
            await NotificationService.showCompletionNotification(operation: successMessage)
        } catch {
            log.append("Error: \(error.localizedDescription)", level: .error)
            alertMessage = error.localizedDescription
        }
        isRunning = false
    }
}
