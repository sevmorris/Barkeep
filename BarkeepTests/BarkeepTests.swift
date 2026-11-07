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

@Suite("BrewfileViewModel adds and removals")
struct BrewfileViewModelAddRemoveTests {

    /// A view model loaded from a Brewfile in the temporary folder, and the
    /// file's URL. The caller removes the file.
    @MainActor private func loaded(_ contents: String) throws -> (BrewfileViewModel, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Brewfile-addremove-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let vm = BrewfileViewModel()
        vm.load(from: url)
        return (vm, url)
    }

    @Test("A cask added where most casks are greedy is greedy too; a formula never is")
    @MainActor func addFollowsGreedyCasks() throws {
        // mrk's Brewfile carries greedy: true on every cask.
        let (vm, url) = try loaded("""
        # Tools
        brew "git"
        # Apps
        cask "alpha", greedy: true
        cask "beta", greedy: true
        cask "gamma"
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        vm.add(name: "zed", kind: .cask, section: "Apps", brewfileURL: url)
        vm.add(name: "jq", kind: .formula, section: "Tools", brewfileURL: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains(#"cask "zed", greedy: true"#))
        #expect(written.contains("brew \"jq\"\n"))
        #expect(!written.contains(#"brew "jq","#))
    }

    @Test("A cask added where most casks are not greedy stays bare")
    @MainActor func addLeavesBareCasksBare() throws {
        let (vm, url) = try loaded("""
        cask "alpha", greedy: true
        cask "beta"
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        vm.add(name: "zed", kind: .cask, section: "General", brewfileURL: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("cask \"zed\"\n"))
        #expect(!written.contains(#"cask "zed", greedy"#))
    }

    @Test("A cask added to a Brewfile with no casks stays bare")
    @MainActor func addToFileWithoutCasks() throws {
        let (vm, url) = try loaded("brew \"git\"\n")
        defer { try? FileManager.default.removeItem(at: url) }

        vm.add(name: "zed", kind: .cask, section: "Apps", brewfileURL: url)

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("cask \"zed\"\n"))
    }

    @Test("isGreedy reads greedy: true and nothing else")
    func isGreedy() {
        func entry(_ line: String) -> BrewfileEntry {
            BrewfileParser.entries(from: BrewfileParser.parse(string: line))[0]
        }
        #expect(entry(#"cask "a", greedy: true"#).isGreedy)
        #expect(entry(#"cask "a",greedy:true"#).isGreedy)
        #expect(!entry(#"cask "a", greedy: false"#).isGreedy)
        #expect(!entry(#"cask "greedy""#).isGreedy)
        #expect(!entry(#"cask "a""#).isGreedy)
    }

    @Test("remove(packages:) removes exactly the named kind and name")
    @MainActor func removeByPackage() throws {
        // A formula and a cask can share a name; only the one uninstalled goes.
        let (vm, url) = try loaded("""
        # Tools
        brew "git"
        brew "gh"
        # Apps
        cask "git"
        cask "firefox", greedy: true
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        vm.remove(packages: [("git", .cask), ("not-there", .formula)], brewfileURL: url)

        #expect(vm.allEntries.map(\.id) == ["formula:git", "formula:gh", "cask:firefox"])
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains(#"cask "git""#))
        #expect(written.contains(#"brew "git""#))
        #expect(written.contains("# Apps"))
        #expect(vm.canUndo)
    }

    @Test("remove(packages:) with no match leaves the file and the undo stack alone")
    @MainActor func removeByPackageNoMatch() throws {
        let original = "brew \"git\"\n"
        let (vm, url) = try loaded(original)
        defer { try? FileManager.default.removeItem(at: url) }

        vm.remove(packages: [("git", .cask)], brewfileURL: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(!vm.canUndo)
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

// MARK: - UpdateChecker: minimum macOS

/// `minimumMacOS(inReleaseNotes:)` and its helpers decide whether the update
/// check offers a release, from the marker release.sh writes into its notes.
/// A missing or malformed marker sets no minimum, so the release is offered as
/// it always was.
@Suite("UpdateChecker minimum macOS")
struct UpdateCheckerMinimumMacOSTests {

    private func version(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private func fields(_ version: OperatingSystemVersion?) -> [Int]? {
        version.map { [$0.majorVersion, $0.minorVersion, $0.patchVersion] }
    }

    @Test("Reads the marker release.sh writes")
    func readsTheMarker() {
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.\n\n---\nRequires macOS 15.0 or later.\n<!-- minimum-macos: 15.0 -->")) == [15, 0, 0])
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.2.1 -->")) == [15, 2, 1])
        #expect(fields(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 26 -->")) == [26, 0, 0])
    }

    @Test("Notes without a marker set no minimum")
    func noMarker() {
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: nil) == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "**Fixed**\n- Something.") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "Requires macOS 15.0 or later.") == nil)
    }

    @Test("A malformed marker sets no minimum")
    func malformedMarker() {
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: fifteen -->") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15.0") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 15..0 -->") == nil)
        #expect(UpdateChecker.minimumMacOS(inReleaseNotes: "<!-- minimum-macos: 1.2.3.4 -->") == nil)
    }

    @Test("Compares major, then minor, then patch")
    func comparison() {
        #expect(!UpdateChecker.runs(on: version(14, 6), given: version(15)))
        #expect(UpdateChecker.runs(on: version(15), given: version(15)))
        #expect(UpdateChecker.runs(on: version(26, 7, 1), given: version(15)))
        #expect(!UpdateChecker.runs(on: version(15), given: version(15, 1)))
        #expect(UpdateChecker.runs(on: version(15, 1), given: version(15, 0, 1)))
    }

    @Test("Describes a version the way macOS does")
    func description() {
        #expect(UpdateChecker.describe(version(15)) == "15.0")
        #expect(UpdateChecker.describe(version(15, 2, 1)) == "15.2.1")
    }
}

// MARK: - Links

@Suite("barkeep:// links")
struct BarkeepLinkTests {

    @Test("barkeep://untracked shows the Untracked list, in any case")
    func untracked() throws {
        #expect(BarkeepLink.showsUntracked(try #require(URL(string: "barkeep://untracked"))))
        #expect(BarkeepLink.showsUntracked(try #require(URL(string: "Barkeep://Untracked"))))
    }

    @Test("Another host or scheme is not the link")
    func others() throws {
        for link in ["barkeep://brewfile", "barkeep:untracked", "https://untracked", "dipstick://untracked"] {
            #expect(!BarkeepLink.showsUntracked(try #require(URL(string: link))), "\(link)")
        }
    }

    @Test("The built app declares the barkeep scheme")
    func declared() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Barkeep/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url))
        let types = try #require(plist["CFBundleURLTypes"] as? [[String: Any]])
        #expect(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } == [BarkeepLink.scheme])
    }
}

// MARK: - HomebrewRecord

/// Runs `body` with a scratch Homebrew prefix and an Applications folder of
/// its own, both removed afterwards. Nothing here touches the real Caskroom.
private func withScratchPrefix(_ body: (_ prefix: URL, _ applications: URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("barkeep-homebrew-\(UUID().uuidString)", isDirectory: true)
    let prefix = folder.appendingPathComponent("homebrew", isDirectory: true)
    let applications = folder.appendingPathComponent("Applications", isDirectory: true)
    for dir in ["Cellar", "Caskroom"] {
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try body(prefix, applications)
}

@Suite("HomebrewRecord")
struct HomebrewRecordTests {
    /// The artifacts of an installed cask, as `brew info --json=v2` gives
    /// them: one stanza each, and where it went.
    private func artifacts(_ json: String) throws -> [[String: Any]] {
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private let everywhere: (String) -> Bool = { _ in true }

    @Test("A cask of an app, and links into it, can be forgotten")
    func appAndLinksIntoIt() throws {
        // Calibre's, cut short.
        let calibre = try artifacts("""
        [{"uninstall": [{"quit": "net.kovidgoyal.calibre"}]},
         {"app": ["calibre.app"], "target": "/Applications/calibre.app"},
         {"binary": ["/Applications/calibre.app/Contents/MacOS/ebook-convert"], "target": "/opt/homebrew/bin/ebook-convert"},
         {"binary": ["/Applications/calibre.app/Contents/MacOS/calibredb"], "target": "/opt/homebrew/bin/calibredb"},
         {"zap": [{"trash": ["~/Library/Preferences/calibre"]}]}]
        """)
        #expect(HomebrewRecord.canForget(artifacts: calibre, exists: everywhere))
        let whatsapp = try artifacts("""
        [{"uninstall": [{"quit": "net.whatsapp.WhatsApp"}]},
         {"app": ["WhatsApp.app"], "target": "/Applications/WhatsApp.app"},
         {"zap": [{"trash": ["~/Library/Containers/net.whatsapp.WhatsApp"]}]}]
        """)
        #expect(HomebrewRecord.canForget(artifacts: whatsapp, exists: everywhere))
    }

    @Test("A cask that installs more than an app cannot")
    func moreThanAnApp() throws {
        let cases = [
            // android-platform-tools: its programs live in the Caskroom.
            #"[{"binary": ["/opt/homebrew/Caskroom/android-platform-tools/37.0.2/platform-tools/adb"], "target": "/opt/homebrew/bin/adb"}]"#,
            // temurin@21: a pkg.
            #"[{"uninstall": [{"pkgutil": "net.temurin.21.jdk"}]}, {"pkg": ["OpenJDK21U-jdk.pkg"]}, {"zap": []}]"#,
            // An app, and a program beside it in the Caskroom.
            #"[{"app": ["Foo.app"], "target": "/Applications/Foo.app"}, {"binary": ["foo/bin/foo"], "target": "/opt/homebrew/bin/foo"}]"#,
            // An app, and a link into another app's folder whose name it begins.
            #"[{"app": ["Foo.app"], "target": "/Applications/Foo.app"}, {"binary": ["/Applications/Foo.app.old/foo"], "target": "/opt/homebrew/bin/foo"}]"#,
            // An app and a postflight, which can put files anywhere.
            #"[{"app": ["Foo.app"], "target": "/Applications/Foo.app"}, {"postflight": null}]"#,
            // An app and a font.
            #"[{"app": ["Foo.app"], "target": "/Applications/Foo.app"}, {"font": ["Foo.otf"], "target": "/Users/x/Library/Fonts/Foo.otf"}]"#,
            // Nothing installed at all.
            #"[{"zap": []}]"#,
        ]
        for json in cases {
            #expect(!HomebrewRecord.canForget(artifacts: try artifacts(json), exists: everywhere), "\(json)")
        }
    }

    @Test("A cask whose app has gone cannot")
    func appGone() throws {
        let foo = try artifacts(#"[{"app": ["Foo.app"], "target": "/Applications/Foo.app"}]"#)
        #expect(!HomebrewRecord.canForget(artifacts: foo, exists: { _ in false }))
    }

    @Test("A renamed app is looked for under its new name")
    func renamedApp() throws {
        let foo = try artifacts(#"[{"app": ["Foo Beta.app", {"target": "Foo.app"}]}, {"binary": ["/Applications/Foo.app/Contents/MacOS/foo"]}]"#)
        #expect(HomebrewRecord.canForget(artifacts: foo, exists: { $0 == "/Applications/Foo.app" }))
    }

    @Test("Only installed casks are forgettable, by their short names")
    func forgettable() {
        let json = """
        {"formulae": [], "casks": [
          {"token": "calibre", "installed": "9.17.0",
           "artifacts": [{"app": ["calibre.app"], "target": "/Applications/calibre.app"}]},
          {"token": "temurin@21", "installed": "21.0.13,9",
           "artifacts": [{"pkg": ["OpenJDK21U-jdk.pkg"]}]},
          {"token": "someone/tap/foo", "installed": "1.0",
           "artifacts": [{"app": ["Foo.app"], "target": "/Applications/Foo.app"}]},
          {"token": "bar", "installed": null,
           "artifacts": [{"app": ["Bar.app"]}]}
        ]}
        """
        #expect(HomebrewRecord.forgettable(infoJSON: json, exists: everywhere) == ["calibre", "foo"])
        #expect(HomebrewRecord.forgettable(infoJSON: "Error: No available cask", exists: everywhere).isEmpty)
    }

    @Test("Names become folder names, and nothing else does")
    func names() {
        #expect(HomebrewRecord.shortName("calibre") == "calibre")
        #expect(HomebrewRecord.shortName("someone/tap/foo") == "foo")
        for name in ["calibre", "temurin@21", "4k-video-downloader+", "font-sf-mono", "python@3.13"] {
            #expect(HomebrewRecord.isFolderName(name), "\(name)")
        }
        for name in ["", ".", "..", ".metadata", "a/b", "-rf", "foo bar"] {
            #expect(!HomebrewRecord.isFolderName(name), "\(name)")
        }
    }

    @Test("Installed means Homebrew's folder is there")
    func installed() throws {
        try withScratchPrefix { prefix, _ in
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Cellar/wget/1.25.0"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/calibre/9.17.0"),
                                                    withIntermediateDirectories: true)
            #expect(HomebrewRecord.isInstalled(name: "wget", kind: .formula, prefix: prefix))
            #expect(HomebrewRecord.isInstalled(name: "calibre", kind: .cask, prefix: prefix))
            #expect(HomebrewRecord.isInstalled(name: "someone/tap/calibre", kind: .cask, prefix: prefix))
            #expect(!HomebrewRecord.isInstalled(name: "calibre", kind: .formula, prefix: prefix))
            #expect(!HomebrewRecord.isInstalled(name: "curl", kind: .formula, prefix: prefix))
            #expect(!HomebrewRecord.isInstalled(name: "homebrew/cask", kind: .tap, prefix: prefix))
            #expect(!HomebrewRecord.isInstalled(name: "..", kind: .cask, prefix: prefix))
        }
    }

    @Test("Forgetting deletes the record and keeps the app")
    func forgetKeepsTheApp() throws {
        try withScratchPrefix { prefix, applications in
            let fm = FileManager.default
            let app = applications.appendingPathComponent("calibre.app")
            let program = app.appendingPathComponent("Contents/MacOS/calibre")
            try fm.createDirectory(at: program.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
            // What Homebrew leaves: the cask file, and a link to the app it moved.
            let record = prefix.appendingPathComponent("Caskroom/calibre")
            try fm.createDirectory(at: record.appendingPathComponent(".metadata/9.17.0/20261024230900.000/Casks"),
                                   withIntermediateDirectories: true)
            try "{}".write(to: record.appendingPathComponent(".metadata/9.17.0/20261024230900.000/Casks/calibre.json"),
                           atomically: true, encoding: .utf8)
            try fm.createDirectory(at: record.appendingPathComponent("9.17.0"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: record.appendingPathComponent("9.17.0/calibre.app"), withDestinationURL: app)

            try HomebrewRecord.forget(cask: "calibre", caskroom: prefix.appendingPathComponent("Caskroom"))

            #expect(!fm.fileExists(atPath: record.path))
            #expect(fm.fileExists(atPath: program.path))
            #expect(!HomebrewRecord.isInstalled(name: "calibre", kind: .cask, prefix: prefix))
        }
    }

    @Test("A record that holds an app itself is left alone")
    func forgetRefusesARealApp() throws {
        try withScratchPrefix { prefix, _ in
            let fm = FileManager.default
            let record = prefix.appendingPathComponent("Caskroom/foo")
            let app = record.appendingPathComponent("1.0/Foo.app/Contents")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)

            #expect(throws: HomebrewRecord.ForgetError.holdsApp(cask: "foo", app: "Foo.app")) {
                try HomebrewRecord.forget(cask: "foo", caskroom: prefix.appendingPathComponent("Caskroom"))
            }
            #expect(fm.fileExists(atPath: app.path))
        }
    }

    @Test("A name with no record, or no folder name, is refused")
    func forgetRefusesBadNames() throws {
        try withScratchPrefix { prefix, _ in
            let caskroom = prefix.appendingPathComponent("Caskroom")
            #expect(throws: HomebrewRecord.ForgetError.notInstalled("foo")) {
                try HomebrewRecord.forget(cask: "foo", caskroom: caskroom)
            }
            #expect(throws: HomebrewRecord.ForgetError.badName("..")) {
                try HomebrewRecord.forget(cask: "..", caskroom: caskroom)
            }
            #expect(FileManager.default.fileExists(atPath: caskroom.path))
        }
    }
}
