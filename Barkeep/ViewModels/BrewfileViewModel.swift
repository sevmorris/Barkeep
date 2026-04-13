import SwiftUI

@Observable
@MainActor
final class BrewfileViewModel {
    var nodes: [BrewfileNode] = []
    var isLoading = false
    var error: String? = nil
    var selectedEntry: BrewfileEntry? = nil
    var selectedDetail: BrewPackage? = nil
    var isLoadingDetail = false
    var filterText = ""
    var outdatedNames: Set<String> = []

    private var undoStack: [[BrewfileNode]] = []
    private var redoStack: [[BrewfileNode]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Computed

    var allEntries: [BrewfileEntry] {
        BrewfileParser.entries(from: nodes)
    }

    var sections: [(name: String, entries: [BrewfileEntry])] {
        BrewfileParser.sections(from: nodes)
    }

    var filteredSections: [(name: String, entries: [BrewfileEntry])] {
        guard !filterText.isEmpty else { return sections }
        return sections.compactMap { section in
            let hits = section.entries.filter {
                $0.name.localizedCaseInsensitiveContains(filterText)
            }
            return hits.isEmpty ? nil : (name: section.name, entries: hits)
        }
    }

    var sectionNames: [String] {
        sections.map { $0.name }
    }

    // MARK: - Load

    func load(from url: URL) {
        isLoading = true
        error = nil
        do {
            nodes = try BrewfileParser.parse(url: url)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
        Task { await refreshOutdated() }
    }

    /// Refresh outdated names, filtered to Brewfile entries only.
    func refreshOutdated() async {
        let allOutdated = await BrewRunner.shared.outdatedNames()
        let brewfileNames = Set(allEntries.map(\.name))
        outdatedNames = allOutdated.intersection(brewfileNames)
    }

    // MARK: - On-demand detail

    func loadDetail(for entry: BrewfileEntry) async {
        guard entry.kind != .tap else { return }
        let entryID = entry.id
        selectedDetail = nil
        isLoadingDetail = true

        async let infoFetch = BrewRunner.shared.info(names: [entry.name], kind: entry.kind)
        async let tldrFetch = BrewRunner.shared.tldr(for: entry.name)
        async let manFetch  = BrewRunner.shared.manPage(for: entry.name)
        async let usesFetch = BrewRunner.shared.uses(for: entry.name)

        var infos: [BrewPackage]?
        var tldrResult: (summary: String, examples: [TldrExample])
        var manResult: [ManSection]
        var usesResult: [String]

        do {
            infos = try await infoFetch
        } catch {
            infos = nil
        }
        tldrResult = await tldrFetch
        manResult  = await manFetch
        usesResult = await usesFetch

        guard selectedEntry?.id == entryID else {
            isLoadingDetail = false
            return
        }

        if var pkg = infos?.first {
            pkg.isInBrewfile          = true
            pkg.brewfileSection       = entry.section
            pkg.tldr                  = tldrResult.examples
            pkg.tldrSummary           = tldrResult.summary
            pkg.manSections           = manResult
            pkg.reverseDependencies   = usesResult
            selectedDetail = pkg
        }
        isLoadingDetail = false
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(nodes)
        nodes = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(nodes)
        nodes = next
    }

    // MARK: - Mutations

    func contains(name: String, kind: PackageKind) -> Bool {
        allEntries.contains { $0.name == name && $0.kind == kind }
    }

    func add(name: String, kind: PackageKind, section: String, brewfileURL: URL) {
        guard !contains(name: name, kind: kind) else { return }

        let sanitized = sanitizeSectionName(section)
        let raw   = BrewfileEntry.canonicalLine(name: name, kind: kind)
        let entry = BrewfileEntry(name: name, kind: kind, section: sanitized, rawLine: raw)

        pushUndo()

        // Insert after the last entry in the matching section, or append
        if let idx = nodes.indices.last(where: {
            if case .entry(let e) = nodes[$0] { return e.section == sanitized } else { return false }
        }) {
            nodes.insert(.entry(entry), at: nodes.index(after: idx))
        } else {
            if !nodes.isEmpty { nodes.append(.blank) }
            nodes.append(.comment("# \(sanitized)"))
            nodes.append(.entry(entry))
        }

        save(to: brewfileURL)
    }

    func remove(entry: BrewfileEntry, brewfileURL: URL) {
        pushUndo()
        nodes.removeAll {
            if case .entry(let e) = $0 { return e.id == entry.id }
            return false
        }
        if selectedEntry?.id == entry.id { selectedEntry = nil }
        save(to: brewfileURL)
    }

    // MARK: - Private

    private func pushUndo() {
        undoStack.append(nodes)
        redoStack.removeAll()
    }

    private func sanitizeSectionName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        guard !trimmed.isEmpty else { return "General" }
        return String(trimmed.prefix(100))
    }

    private func withLoadingState(_ block: () async throws -> Void) async {
        isLoading = true
        do {
            try await block()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func save(to url: URL) {
        do {
            try BrewfileParser.write(nodes: nodes, to: url)
        } catch {
            self.error = "Failed to save Brewfile: \(error.localizedDescription)"
            // Roll back the mutation so in-memory state stays consistent with the file
            if let previous = undoStack.popLast() {
                nodes = previous
            }
        }
    }
}
