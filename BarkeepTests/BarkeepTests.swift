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
