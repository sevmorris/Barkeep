import SwiftUI

struct RootContentView: View {
    @Environment(AppState.self) var appState
    @State private var brewfileVM  = BrewfileViewModel()
    @State private var untrackedVM = UntrackedViewModel()
    @State private var mrk         = MrkMode()
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
        .onAppear { connectMrk() }
        .onChange(of: appState.brewfilePath, initial: true) { _, url in
            mrk.open(brewfile: url)
            if !mrk.isActive { untrackedVM.clearMrk() }
            guard let url else { brewfileWatcher.stop(); return }
            brewfileVM.load(from: url)
            brewfileWatcher.start(url: url)
            if mrk.isActive { Task { await mrk.refresh() } }
        }
        .onChange(of: mrk.isChecking) { _, checking in
            // In mrk mode the Untracked list is sync's drift, read again
            // after every decision and every brew command.
            guard mrk.isActive else { return }
            if checking {
                if untrackedVM.formulae.isEmpty && untrackedVM.casks.isEmpty
                    && untrackedVM.notInstalled.isEmpty {
                    untrackedVM.isLoading = true
                }
            } else {
                untrackedVM.load(candidates: mrk.candidates, error: mrk.checkError)
            }
        }
        .onChange(of: brewfileVM.error) { _, message in
            guard let message else { return }
            alertMessage = message
            brewfileVM.error = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .barkeepRefresh)) { _ in
            if let url = appState.brewfilePath { brewfileVM.load(from: url) }
        }
        // barkeep://untracked, from Dipstick's fix for a package the Brewfile
        // lacks: show the Untracked list, read again.
        .handlesExternalEvents(preferring: [BarkeepLink.untrackedHost], allowing: [BarkeepLink.untrackedHost])
        .onOpenURL { url in
            guard BarkeepLink.showsUntracked(url) else { return }
            if sidebarTab == .untracked {
                if mrk.isActive {
                    Task { await mrk.refresh() }
                } else {
                    Task { await untrackedVM.load(brewfileEntries: brewfileVM.allEntries) }
                }
            } else {
                sidebarTab = .untracked
            }
        }
        .onChange(of: sidebarTab) { _, tab in
            guard tab == .untracked else { return }
            if mrk.isActive {
                Task { await mrk.refresh() }
            } else {
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
                        BrewfileListView(vm: brewfileVM, brewfileURL: url, onRemove: removeEntries)
                    }
                } else {
                    UntrackedListView(vm: untrackedVM, outdatedNames: brewfileVM.outdatedNames,
                                      mrkMode: mrk.isActive)
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
                        brewfilePath: brewfilePath,
                        mrk:          mrk.isActive ? mrk : nil,
                        runMrk:       { await runMrk($0) },
                        removeEntries: removeEntries
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
        if brewfileVM.isLoading || mrk.isChecking {
            ToolbarItem(placement: .automatic) {
                ProgressView().controlSize(.small)
            }
        }

        if mrk.isActive {
            ToolbarItem(placement: .automatic) {
                Label("mrk", systemImage: "checkmark.seal")
                    .toolbarBadge()
                    .help("mrk mode: this Brewfile is in an mrk checkout, so mrk's sync decides what is untracked, and adds, ignores and prunes packages.")
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
                    .toolbarBadge()
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
                    mrk.cancel()
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
                if mrk.isActive { Task { await mrk.refresh() } }
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

    // MARK: - mrk mode

    /// The hooks between the Brewfile view model and mrk mode. Set once:
    /// both objects live as long as the window.
    private func connectMrk() {
        let mrk = self.mrk
        let brewfileVM = self.brewfileVM
        let log = self.log
        let appState = self.appState
        brewfileVM.writeGuard = {
            mrk.isWritingBrewfile
                ? "mrk's sync is changing the Brewfile. Make the change again when it is done."
                : nil
        }
        brewfileVM.onSave = {
            mrk.fixDescriptions(log: log)
        }
        mrk.onBrewfileWritten = {
            if let url = appState.brewfilePath { brewfileVM.load(from: url) }
        }
    }

    /// Runs mrk commands one after another, each in the console. A refusal
    /// does not stop the rest; the alert lists what sync said.
    private func runMrk(_ commands: [MrkCommand]) async {
        guard !isRunning, !commands.isEmpty, mrk.isActive else { return }
        isRunning = true
        log.clear()
        var failures: [String] = []
        for command in commands {
            if let error = await mrk.perform(command, log: log) {
                failures.append(error.localizedDescription)
            }
        }
        isRunning = false
        if !failures.isEmpty { alertMessage = failures.joined(separator: "\n") }
    }

    /// Remove from Brewfile. In mrk mode an entry whose package is not
    /// installed is pruned by sync; any other is removed by Barkeep, and
    /// the save that follows runs check-picker-desc --fix.
    private func removeEntries(_ entries: [BrewfileEntry]) {
        guard let url = appState.brewfilePath else { return }
        guard mrk.isActive else {
            brewfileVM.remove(entries: entries, brewfileURL: url)
            return
        }
        let stale = entries.filter { mrk.candidate(.prune, name: $0.name, kind: $0.kind) != nil }
        let staleIDs = Set(stale.map(\.id))
        let rest = entries.filter { !staleIDs.contains($0.id) }
        if !rest.isEmpty { brewfileVM.remove(entries: rest, brewfileURL: url) }
        if !stale.isEmpty {
            Task { await runMrk(stale.map { .prune(name: $0.name, kind: $0.kind) }) }
        }
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

private extension Label {
    /// A label in the toolbar that is not a button, such as the mrk badge.
    /// A button brings its own inset; a label has none, so on macOS 26 its
    /// icon touched the edge of the glass that groups the toolbar's items.
    /// The padding is the inset a toolbar button has.
    func toolbarBadge() -> some View {
        labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }
}
