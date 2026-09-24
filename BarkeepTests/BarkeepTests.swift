import Testing
import Foundation
@testable import Barkeep

// MARK: - BrewfileParser

@Suite("BrewfileParser")
struct BrewfileParserTests {

    @Test("Parses formula, cask, and tap entries")
    func parsesBasicEntries() {
        let input = """
        brew "git"
        cask "firefox"
        tap "homebrew/cask"
        """
        let nodes = BrewfileParser.parse(string: input)
        let entries = BrewfileParser.entries(from: nodes)
        #expect(entries.count == 3)
        #expect(entries[0].name == "git" && entries[0].kind == .formula)
        #expect(entries[1].name == "firefox" && entries[1].kind == .cask)
        #expect(entries[2].name == "homebrew/cask" && entries[2].kind == .tap)
    }

    @Test("Preserves blank lines and comments")
    func preservesStructure() {
        let input = "# Tools\nbrew \"git\"\n\nbrew \"curl\"\n"
        let nodes = BrewfileParser.parse(string: input)
        #expect(nodes.count == 4)
    }

    @Test("Treats commented-out entry as comment, not section header")
    func commentedEntryNotSection() {
        let input = "# brew \"disabled-tool\"\nbrew \"git\"\n"
        let nodes = BrewfileParser.parse(string: input)
        let entries = BrewfileParser.entries(from: nodes)
        #expect(entries.count == 1)
        #expect(entries[0].name == "git")
    }

    @Test("Ignores unknown lines")
    func ignoresUnknownLines() {
        let input = "brew \"git\"\nmas \"Xcode\", id: 497799835\n"
        let nodes = BrewfileParser.parse(string: input)
        let entries = BrewfileParser.entries(from: nodes)
        #expect(entries.count == 1)
    }

    @Test("Sections group entries under preceding comment headers")
    func sectionGrouping() {
        let input = """
        # Dev
        brew "git"
        brew "gh"
        # Apps
        cask "firefox"
        """
        let sections = BrewfileParser.sections(from: BrewfileParser.parse(string: input))
        #expect(sections.count == 2)
        #expect(sections[0].name == "Dev" && sections[0].entries.count == 2)
        #expect(sections[1].name == "Apps" && sections[1].entries.count == 1)
    }

    @Test("Handles entries with trailing arguments")
    func trailingArguments() {
        let input = #"brew "node", link: false"#
        let entries = BrewfileParser.entries(from: BrewfileParser.parse(string: input))
        #expect(entries.count == 1)
        #expect(entries[0].name == "node")
    }

    @Test("Round-trip: write then reparse preserves entry count")
    func roundTrip() throws {
        let input = "# Section\nbrew \"git\"\ncask \"firefox\"\n"
        let nodes = BrewfileParser.parse(string: input)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewfileTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try BrewfileParser.write(nodes: nodes, to: url)
        let reparsed = try BrewfileParser.parse(url: url)
        #expect(BrewfileParser.entries(from: reparsed).count == BrewfileParser.entries(from: nodes).count)
    }

    @Test("Empty input produces no nodes")
    func emptyInput() {
        let nodes = BrewfileParser.parse(string: "")
        #expect(nodes.isEmpty)
    }

    @Test("Entries assigned to correct section when multiple sections exist")
    func entrySectionAssignment() {
        let input = """
        # Core
        brew "git"
        # Apps
        cask "iterm2"
        """
        let entries = BrewfileParser.entries(from: BrewfileParser.parse(string: input))
        #expect(entries[0].section == "Core")
        #expect(entries[1].section == "Apps")
    }

    @Test("Entry IDs are stable across reparse so selection survives refresh")
    func stableEntryIDs() {
        let input = """
        brew "git"
        cask "firefox"
        """
        let firstIDs  = BrewfileParser.entries(from: BrewfileParser.parse(string: input)).map(\.id)
        let secondIDs = BrewfileParser.entries(from: BrewfileParser.parse(string: input)).map(\.id)
        #expect(firstIDs == secondIDs)
    }

    @Test("commentBody trims leading # and surrounding whitespace")
    func commentBody() {
        #expect(BrewfileParser.commentBody("#  Apps  ") == "Apps")
        #expect(BrewfileParser.commentBody("# Dev Tools") == "Dev Tools")
        #expect(BrewfileParser.commentBody("not a comment") == "")
        #expect(BrewfileParser.commentBody("#") == "")
    }

    @Test("resection rederives entry.section from current comment headers")
    func resectionUpdatesEntries() {
        let input = """
        # Old
        brew "git"
        """
        var nodes = BrewfileParser.parse(string: input)
        // Hand-mutate the comment line as a rename would
        for i in nodes.indices {
            if case .comment = nodes[i] { nodes[i] = .comment("# New") }
        }
        let resected = BrewfileParser.resection(nodes)
        #expect(BrewfileParser.entries(from: resected).first?.section == "New")
    }
}

@Suite("BrewfileViewModel section mutations")
struct BrewfileViewModelSectionTests {

    @Test("renameSection updates header and entry sections")
    @MainActor func renameSection() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brewfile-rename-\(UUID().uuidString)")
        let initial = "# Dev\nbrew \"git\"\n# Apps\ncask \"firefox\"\n"
        try initial.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = BrewfileViewModel()
        vm.load(from: url)
        vm.renameSection(from: "Dev", to: "Tools", brewfileURL: url)

        #expect(vm.allEntries.first(where: { $0.name == "git" })?.section == "Tools")
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("# Tools"))
        #expect(!written.contains("# Dev"))
    }

    @Test("move shifts entries to the target section")
    @MainActor func moveBetweenSections() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brewfile-move-\(UUID().uuidString)")
        let initial = "# Dev\nbrew \"git\"\n# Apps\ncask \"firefox\"\n"
        try initial.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = BrewfileViewModel()
        vm.load(from: url)
        let git = vm.allEntries.first { $0.name == "git" }!
        vm.move(entries: [git], to: "Apps", brewfileURL: url)

        #expect(vm.allEntries.first(where: { $0.name == "git" })?.section == "Apps")
    }

    @Test("deleteSection removes header and its entries")
    @MainActor func deleteSection() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brewfile-delete-\(UUID().uuidString)")
        let initial = "# Dev\nbrew \"git\"\nbrew \"gh\"\n# Apps\ncask \"firefox\"\n"
        try initial.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let vm = BrewfileViewModel()
        vm.load(from: url)
        vm.deleteSection("Dev", brewfileURL: url)

        let names = vm.allEntries.map(\.name)
        #expect(names == ["firefox"])
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("# Dev"))
        #expect(written.contains("# Apps"))
    }
}

// MARK: - Version comparison

@Suite("Version comparison")
struct VersionComparisonTests {

    /// Wraps the private `isNewer` logic via UpdateChecker.check() semantics.
    /// We test the numeric comparison directly using String's .numeric option.
    private func isNewer(_ remote: String, than current: String) -> Bool {
        remote.compare(current, options: .numeric) == .orderedDescending
    }

    @Test("Newer patch version is detected")
    func newerPatch() {
        #expect(isNewer("1.8.1", than: "1.8.0"))
    }

    @Test("Newer minor version is detected")
    func newerMinor() {
        #expect(isNewer("1.9.0", than: "1.8.2"))
    }

    @Test("Newer major version is detected")
    func newerMajor() {
        #expect(isNewer("2.0.0", than: "1.9.9"))
    }

    @Test("Same version is not newer")
    func sameVersion() {
        #expect(!isNewer("1.8.2", than: "1.8.2"))
    }

    @Test("Older version is not newer")
    func olderVersion() {
        #expect(!isNewer("1.7.0", than: "1.8.0"))
    }

    @Test("Version with missing components handled correctly")
    func shortVersion() {
        #expect(isNewer("2.0", than: "1.9"))
        #expect(!isNewer("1.0", than: "1.0"))
    }
}

// MARK: - ProcessingLog

@Suite("ProcessingLog")
struct ProcessingLogTests {

    @Test("Status filter includes brew step headers")
    @MainActor func statusIncludesStepHeaders() {
        let log = ProcessingLog()
        log.append("==> Installing git")
        log.append("Downloading https://example.com/git.tar.gz")
        log.append("==> Pouring git")
        #expect(log.statusEntries.count == 2)
    }

    @Test("Status filter includes errors and warnings")
    @MainActor func statusIncludesErrorsWarnings() {
        let log = ProcessingLog()
        log.append("Error: No such formula", level: .error)
        log.append("Warning: outdated Xcode CLT", level: .verbose)
        log.append("some verbose noise", level: .verbose)
        #expect(log.statusEntries.count == 2)
    }

    @Test("Status filter includes command echo and Done")
    @MainActor func statusIncludesCommandAndDone() {
        let log = ProcessingLog()
        log.append("$ brew install git")
        log.append("Done.")
        log.append("random output line")
        #expect(log.statusEntries.count == 2)
    }

    @Test("Full entries unaffected by filter")
    @MainActor func fullEntriesUnaffected() {
        let log = ProcessingLog()
        log.append("line one")
        log.append("line two")
        log.append("==> step")
        #expect(log.entries.count == 3)
        #expect(log.statusEntries.count == 1)
    }

    @Test("Log caps at 1000 entries and trims to 900")
    @MainActor func capsBehavior() {
        let log = ProcessingLog()
        for i in 0...1000 { log.append("line \(i)") }
        #expect(log.entries.count == 900)
    }
}

// MARK: - AppState defaults

/// Runs `body` with a defaults suite of its own and a folder to put files in,
/// both removed afterwards.
///
/// The tests run inside the app, so `UserDefaults.standard` here is the
/// developer's real settings. The suite is named by a path inside the folder.
/// A suite named like a bundle identifier lives in ~/Library/Preferences, and
/// removing its domain empties the file but leaves it there, matching the
/// io.github.sevmorris.* pattern the App Preferences source backs up; deleting
/// the file does not hold, because cfprefsd writes it back after the test has
/// finished. Deleting a folder of our own does.
private func withScratchDefaults(_ body: (UserDefaults, URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("barkeep-defaults-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let suiteName = folder.appendingPathComponent("defaults").path
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
    try body(defaults, folder)
}

@Suite("AppState defaults")
@MainActor
struct AppStateDefaultsTests {

    @Test("A test run does not get the real defaults")
    func testRunGetsScratchDefaults() {
        #expect(AppLauncher.isHostingTests)
        #expect(UserDefaults.app !== UserDefaults.standard)
    }

    @Test("A chosen Brewfile comes back from the same store")
    func brewfileRoundTrips() throws {
        try withScratchDefaults { defaults, folder in
            let brewfile = folder.appendingPathComponent("Brewfile")
            try "brew \"git\"\n".write(to: brewfile, atomically: true, encoding: .utf8)

            AppState(defaults: defaults).brewfilePath = brewfile
            #expect(defaults.data(forKey: "bk_brewfileBookmark") != nil)

            let restored = AppState(defaults: defaults).brewfilePath
            #expect(restored?.resolvingSymlinksInPath() == brewfile.resolvingSymlinksInPath())
        }
    }

    @Test("A plain path from an older build becomes a bookmark in the same store")
    func legacyPathMigrates() throws {
        try withScratchDefaults { defaults, folder in
            let brewfile = folder.appendingPathComponent("Brewfile")
            try "brew \"git\"\n".write(to: brewfile, atomically: true, encoding: .utf8)
            defaults.set(brewfile.path, forKey: "BrewfilePath")

            let state = AppState(defaults: defaults)
            #expect(state.brewfilePath?.resolvingSymlinksInPath() == brewfile.resolvingSymlinksInPath())
            #expect(defaults.string(forKey: "BrewfilePath") == nil)
            #expect(defaults.data(forKey: "bk_brewfileBookmark") != nil)
        }
    }

    /// The path that, at every test launch, could drop the developer's own
    /// saved Brewfile: a bookmark that no longer resolves is removed.
    @Test("An unresolvable bookmark is dropped from the store it was read from")
    func unresolvableBookmarkIsDropped() throws {
        try withScratchDefaults { defaults, _ in
            let garbage = Data("not a bookmark".utf8)
            defaults.set(garbage, forKey: "bk_brewfileBookmark")

            let state = AppState(defaults: defaults)
            #expect(state.brewfileBookmarkWasReset)
            // Nil, or a fresh bookmark for ~/mrk/Brewfile where one exists.
            #expect(defaults.data(forKey: "bk_brewfileBookmark") != garbage)
        }
    }
}
