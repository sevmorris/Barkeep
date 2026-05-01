import SwiftUI

@Observable
@MainActor
final class BrewfileViewModel {
    var nodes: [BrewfileNode] = []
    var isLoading = false
    var error: String? = nil
    var selectedEntryIDs: Set<String> = []
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

    var selectedEntries: [BrewfileEntry] {
        let ids = selectedEntryIDs
        return allEntries.filter { ids.contains($0.id) }
    }

    /// Single focused entry — present only when exactly one row is selected.
    var selectedEntry: BrewfileEntry? {
        selectedEntryIDs.count == 1 ? selectedEntries.first : nil
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
        remove(entries: [entry], brewfileURL: brewfileURL)
    }

    func remove(entries: [BrewfileEntry], brewfileURL: URL) {
        guard !entries.isEmpty else { return }
        pushUndo()
        let removeIDs = Set(entries.map(\.id))
        nodes.removeAll {
            if case .entry(let e) = $0 { return removeIDs.contains(e.id) }
            return false
        }
        selectedEntryIDs.subtract(removeIDs)
        save(to: brewfileURL)
    }

    func renameSection(from oldName: String, to newName: String, brewfileURL: URL) {
        let trimmed = sanitizeSectionName(newName)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        pushUndo()

        var didChange = false
        for i in nodes.indices {
            if case .comment(let raw) = nodes[i],
               BrewfileParser.commentBody(raw) == oldName {
                nodes[i] = .comment("# \(trimmed)")
                didChange = true
            }
        }
        guard didChange else { return }

        nodes = BrewfileParser.resection(nodes)
        save(to: brewfileURL)
    }

    /// Remove a whole section: drop the header comment AND every entry
    /// the parser considered part of it.
    func deleteSection(_ name: String, brewfileURL: URL) {
        pushUndo()

        var newNodes: [BrewfileNode] = []
        var skippingHeader = false
        for node in nodes {
            switch node {
            case .comment(let raw):
                let body = BrewfileParser.commentBody(raw)
                if body == name {
                    skippingHeader = true   // drop this header
                    continue
                } else if !body.isEmpty {
                    skippingHeader = false  // entered a different section
                    newNodes.append(node)
                } else {
                    newNodes.append(node)
                }
            case .entry(let e):
                if e.section == name { continue }   // drop entries in deleted section
                newNodes.append(node)
            case .blank, .unknown:
                newNodes.append(node)
            }
        }
        _ = skippingHeader  // value tracked only to mirror parser flow

        nodes = BrewfileParser.resection(newNodes)
        // Drop selection IDs for entries we removed
        let liveIDs = Set(allEntries.map(\.id))
        selectedEntryIDs = selectedEntryIDs.intersection(liveIDs)
        save(to: brewfileURL)
    }

    /// Move entries to a target section. Creates the section if it
    /// doesn't exist. Insertion lands after the last entry of the
    /// target section, mirroring `add()`.
    func move(entries: [BrewfileEntry], to section: String, brewfileURL: URL) {
        let sanitized = sanitizeSectionName(section)
        guard !sanitized.isEmpty, !entries.isEmpty else { return }
        pushUndo()

        let moveIDs = Set(entries.map(\.id))

        // Pull the entries out, preserving their original order.
        var moving: [BrewfileNode] = []
        var remaining: [BrewfileNode] = []
        for node in nodes {
            if case .entry(let e) = node, moveIDs.contains(e.id) {
                var updated = e
                updated.section = sanitized
                moving.append(.entry(updated))
            } else {
                remaining.append(node)
            }
        }

        // Find the insertion point.
        let lastEntryIdx = remaining.indices.last(where: {
            if case .entry(let e) = remaining[$0] { return e.section == sanitized }
            return false
        })
        if let lastEntryIdx {
            remaining.insert(contentsOf: moving, at: remaining.index(after: lastEntryIdx))
        } else if let headerIdx = remaining.indices.first(where: {
            if case .comment(let raw) = remaining[$0] { return BrewfileParser.commentBody(raw) == sanitized }
            return false
        }) {
            remaining.insert(contentsOf: moving, at: remaining.index(after: headerIdx))
        } else {
            // No section yet — append a new section block.
            if !remaining.isEmpty { remaining.append(.blank) }
            remaining.append(.comment("# \(sanitized)"))
            remaining.append(contentsOf: moving)
        }

        nodes = BrewfileParser.resection(remaining)
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
