import Testing
import Foundation
@testable import Barkeep

// mrk mode, against throwaway checkouts: a temporary folder with a Brewfile,
// a description table, and stub scripts/sync and scripts/check-picker-desc
// that record how they were run. No test reaches the real ~/mrk, the real
// login shell or the real defaults: the runner gets its environment from the
// test, never from zsh.

/// A temporary mrk checkout, deleted when the test is done.
private final class StubCheckout {
    let root: URL
    var calls: URL { root.appendingPathComponent("calls.log") }
    var brewfile: URL { root.appendingPathComponent("Brewfile") }

    /// The stub sync answers --check from `checkOutput`, appends a line to
    /// the Brewfile for --add, refuses --ignore of "taken" as sync does, and
    /// sleeps through --prune of "slow". Each run records its arguments, its
    /// directory, the variable the test set, and whether stdin was a terminal
    /// or held anything.
    init(checkOutput: String = "", syncExecutable: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkeep-mrk-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("tools/picker"), withIntermediateDirectories: true)
        try "## Repo essentials\nbrew \"jq\"\n".write(to: brewfile, atomically: true, encoding: .utf8)
        try "# table\njq\tJSON processor\n".write(
            to: root.appendingPathComponent("tools/picker/descriptions.tsv"), atomically: true, encoding: .utf8)
        try checkOutput.write(to: root.appendingPathComponent("check.out"), atomically: true, encoding: .utf8)

        let record = """
        here="$(cd "$(dirname "$0")/.." && pwd)"
        {
          printf 'run %s %s\\n' "$(basename "$0")" "$*"
          printf 'cwd %s\\n' "$(pwd -P)"
          printf 'mark %s\\n' "${MRK_TEST_MARK:-}"
          [ -t 0 ] && echo 'stdin tty'
          IFS= read -r _ && echo 'stdin data'
        } >> "$here/calls.log"
        """
        let sync = """
        #!/bin/bash
        \(record)
        case "$1" in
          --check)  echo "  ▸ Scanning installed Homebrew packages..." >&2
                    cat "$here/check.out" ;;
          --add)    echo "  ▸ Reading Homebrew's descriptions for 1 package(s)..." >&2
                    printf 'brew "%s"\\n' "$2" >> "$here/Brewfile"
                    echo "Added 1 entry to Brewfile."
                    echo "  ✓ Described 1 package(s)" >&2 ;;
          --ignore) if [ "$2" = taken ]; then echo "  ✗ taken is already in the Brewfile." >&2; exit 1; fi
                    echo "  ▸ Added $2 to ~/.mrk/sync-ignore" >&2 ;;
          --prune)  if [ "$2" = slow ]; then sleep 10; fi ;;
        esac
        """
        let fix = "#!/bin/bash\n\(record)\necho 'check-picker-desc: OK'\n"
        try write(sync, to: "scripts/sync", executable: syncExecutable)
        try write(fix, to: "scripts/check-picker-desc", executable: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to path: String, executable: Bool) throws {
        let url = root.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: url.path)
    }

    var checkout: MrkCheckout { MrkCheckout(root: root) }

    func runner(timeout: Duration = .seconds(30)) -> MrkRunner {
        MrkRunner(environment: { ["PATH": "/usr/bin:/bin", "MRK_TEST_MARK": "from-the-test"] },
                  timeout: timeout)
    }

    func recorded() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    func runs() -> [String] { recorded().filter { $0.hasPrefix("run ") } }
}

private let checkOutput = [
    "add\tformula\tzq-tool\t\t\tZq command-line tool",
    "add\tcask\tzq-chess\tCasks - Games\tZq Chess.app declares public.app-category.board-games\tChess against the clock",
    "prune\tcask\tzq-gone\tCasks - Utilities\t\tGone app",
].joined(separator: "\n") + "\n"

// MARK: - Detection

@Suite("mrk checkout")
struct MrkCheckoutTests {

    @Test("A Brewfile with sync, check-picker-desc and the table beside it is an mrk checkout")
    func detectsCheckout() throws {
        let stub = try StubCheckout()
        #expect(MrkCheckout.containing(brewfile: stub.brewfile)?.root.standardizedFileURL
                == stub.root.standardizedFileURL)
    }

    @Test("Any other Brewfile is not")
    func otherBrewfiles() throws {
        let stub = try StubCheckout()
        // sync works on the file named Brewfile, so a copy under another name is not its checkout.
        #expect(MrkCheckout.containing(brewfile: stub.root.appendingPathComponent("Brewfile.backup")) == nil)

        let noExec = try StubCheckout(syncExecutable: false)
        #expect(MrkCheckout.containing(brewfile: noExec.brewfile) == nil)

        let noTable = try StubCheckout()
        try FileManager.default.removeItem(at: noTable.root.appendingPathComponent("tools/picker/descriptions.tsv"))
        #expect(MrkCheckout.containing(brewfile: noTable.brewfile) == nil)

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("Brewfile-\(UUID().uuidString)")
        #expect(MrkCheckout.containing(brewfile: plain) == nil)
    }

    @Test("Formula sections are the ## sections but Taps and the cask sections")
    func formulaSections() {
        let nodes = BrewfileParser.parse(string: """
        ## Taps
        # None.

        ## CLI Tools - Media
        # A comment, not a section.
        brew "yt-dlp"

        ## Repo essentials
        brew "jq"
        # Casks are filed by category.
        ## Casks - Audio
        cask "audacity", greedy: true
        """)
        #expect(MrkCheckout.formulaSections(in: nodes) == ["CLI Tools - Media", "Repo essentials"])
    }
}

// MARK: - What sync says, and what Barkeep asks

@Suite("sync --check output")
struct MrkCandidateParseTests {

    @Test("Reads the six fields of --details")
    func detailsLines() {
        let all = MrkCandidate.parse(checkOutput)
        #expect(all.count == 3)
        #expect(all[0] == MrkCandidate(action: .add, kind: .formula, name: "zq-tool",
                                       section: "", reason: "", description: "Zq command-line tool"))
        #expect(all[1].section == "Casks - Games")
        #expect(all[1].reason == "Zq Chess.app declares public.app-category.board-games")
        #expect(all[2].action == .prune && all[2].kind == .cask && all[2].description == "Gone app")
    }

    @Test("Reads the three fields mrk-status reads, and ignores fields added later")
    func threeAndSevenFields() {
        let all = MrkCandidate.parse("add\tcask\tzq-a\nprune\tformula\tzq-b\tSec\t\tDesc\tfuture\n")
        #expect(all.count == 2)
        #expect(all[0].name == "zq-a" && all[0].section.isEmpty && all[0].description.isEmpty)
        #expect(all[1].description == "Desc")
    }

    @Test("Skips a line it cannot read")
    func malformed() {
        let text = "add\tcask\nremove\tcask\tx\nadd\ttap\tx\nadd\tcask\t\nnot a line\nadd\tcask\tok\n"
        #expect(MrkCandidate.parse(text).map(\.name) == ["ok"])
    }
}

@Suite("mrk commands")
struct MrkCommandTests {

    @Test("Each command passes the kind, and a formula its section as its ## line")
    func arguments() {
        #expect(MrkCommand.check.arguments == ["--check", "--details"])
        #expect(MrkCommand.add(name: "zq", kind: .formula, section: "Repo essentials").arguments
                == ["--add", "zq", "--formula", "--section", "## Repo essentials"])
        #expect(MrkCommand.add(name: "zq", kind: .cask, section: "ignored").arguments
                == ["--add", "zq", "--cask"])
        #expect(MrkCommand.ignore(name: "zq", kind: .cask).arguments == ["--ignore", "zq", "--cask"])
        #expect(MrkCommand.prune(name: "zq", kind: .formula).arguments == ["--prune", "zq", "--formula"])
        #expect(MrkCommand.fixDescriptions.arguments == ["--fix"])
    }

    @Test("check-picker-desc runs the fix; sync runs the rest")
    func executables() {
        let checkout = MrkCheckout(root: URL(fileURLWithPath: "/tmp/mrk"))
        #expect(MrkCommand.fixDescriptions.executable(in: checkout).path == "/tmp/mrk/scripts/check-picker-desc")
        #expect(MrkCommand.check.executable(in: checkout).path == "/tmp/mrk/scripts/sync")
        #expect(MrkCommand.add(name: "zq", kind: .formula, section: "Repo essentials").displayLine(in: checkout)
                == "$ scripts/sync --add zq --formula --section \"## Repo essentials\"")
    }

    @Test("Only add and prune rewrite the Brewfile")
    func writesBrewfile() {
        #expect(MrkCommand.add(name: "zq", kind: .cask, section: nil).writesBrewfile)
        #expect(MrkCommand.prune(name: "zq", kind: .cask).writesBrewfile)
        #expect(!MrkCommand.ignore(name: "zq", kind: .cask).writesBrewfile)
        #expect(!MrkCommand.check.writesBrewfile)
        #expect(!MrkCommand.fixDescriptions.writesBrewfile)
    }
}

// MARK: - The login shell's environment

@Suite("Shell environment")
struct ShellEnvironmentTests {

    @Test("Reads the variables between the markers, past what .zshrc prints")
    func parse() {
        var data = Data("Welcome back\n".utf8)
        data += Data(ShellEnvironment.startMarker.utf8)
        data += Data("PATH=/opt/homebrew/bin:/usr/bin\0MULTI=one\ntwo\0=nokey\0".utf8)
        data += Data(ShellEnvironment.endMarker.utf8)
        data += Data("goodbye".utf8)
        let env = ShellEnvironment.parse(data)
        #expect(env == ["PATH": "/opt/homebrew/bin:/usr/bin", "MULTI": "one\ntwo"])
    }

    @Test("No markers, no environment")
    func noMarkers() {
        #expect(ShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8)) == nil)
        #expect(ShellEnvironment.parse(Data(ShellEnvironment.startMarker.utf8)) == nil)
    }

    @Test("Asks the shell as a login, interactive shell, with stdin from /dev/null")
    func capture() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkeep-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let args = folder.appendingPathComponent("args")
        let shell = folder.appendingPathComponent("zsh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        [ -t 0 ] && echo tty >> '\(args.path)'
        echo 'the zshrc says hello'
        printf '\(ShellEnvironment.startMarker)PATH=/stub/bin\\000HOME=/stub/home\\000\(ShellEnvironment.endMarker)'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)

        let env = await ShellEnvironment.capture(shell: shell, timeout: .seconds(10))
        #expect(env == ["PATH": "/stub/bin", "HOME": "/stub/home"])
        let passed = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(passed == ["-i", "-l", "-c", ShellEnvironment.script])
    }

    @Test("A shell that hangs gives no environment, so the fallback is used")
    func captureTimesOut() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("barkeep-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shell = folder.appendingPathComponent("zsh")
        try "#!/bin/sh\nexec sleep 30\n".write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        #expect(await ShellEnvironment.capture(shell: shell, timeout: .milliseconds(300)) == nil)

        let fallback = ShellEnvironment.fallback(base: ["KEEP": "1"], home: "/Users/someone")
        #expect(fallback["KEEP"] == "1")
        #expect(fallback["PATH"]?.hasPrefix("/Users/someone/bin:/opt/homebrew/bin:") == true)
    }
}

// MARK: - Running the scripts

@Suite("mrk runner")
struct MrkRunnerTests {

    @Test("--check runs in the checkout, with the given environment and no stdin, and is parsed")
    func check() async throws {
        let stub = try StubCheckout(checkOutput: checkOutput)
        let candidates = try await stub.runner().check(stub.checkout)
        #expect(candidates.map(\.name) == ["zq-tool", "zq-chess", "zq-gone"])
        let log = stub.recorded()
        #expect(log.contains("run sync --check --details"))
        // pwd -P says /private/var, Foundation says /var: resolve both alike.
        let cwd = log.first { $0.hasPrefix("cwd ") }.map { String($0.dropFirst(4)) }
        #expect(cwd.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == stub.root.resolvingSymlinksInPath().path)
        #expect(log.contains("mark from-the-test"))
        #expect(!log.contains("stdin tty") && !log.contains("stdin data"))
    }

    @Test("Each line reaches the console as it comes, stdout and stderr both")
    func streams() async throws {
        let stub = try StubCheckout()
        let lines = LockedLines()
        try await stub.runner().run(.add(name: "zq-tool", kind: .formula, section: "Repo essentials"),
                                    in: stub.checkout) { line, fromStderr in
            lines.append("\(fromStderr ? "err" : "out") \(line)")
        }
        let got = lines.all
        #expect(got.contains("err   ▸ Reading Homebrew's descriptions for 1 package(s)..."))
        #expect(got.contains("out Added 1 entry to Brewfile."))
        #expect(got.contains("err   ✓ Described 1 package(s)"))
        #expect(stub.runs() == ["run sync --add zq-tool --formula --section ## Repo essentials"])
        #expect(try String(contentsOf: stub.brewfile, encoding: .utf8).hasSuffix("brew \"zq-tool\"\n"))
    }

    @Test("A refusal throws with sync's own reason")
    func refusal() async throws {
        let stub = try StubCheckout()
        do {
            try await stub.runner().run(.ignore(name: "taken", kind: .cask), in: stub.checkout)
            Issue.record("the refusal did not throw")
        } catch let error as MrkError {
            #expect(error.localizedDescription == "taken is already in the Brewfile.")
        }
    }

    @Test("A script that does not finish is stopped")
    func timeout() async throws {
        let stub = try StubCheckout()
        do {
            try await stub.runner(timeout: .milliseconds(500)).run(.prune(name: "slow", kind: .cask), in: stub.checkout)
            Issue.record("the hung script did not time out")
        } catch let error as MrkError {
            guard case .timedOut = error else { Issue.record("wrong error: \(error)"); return }
        }
    }
}

@Suite("Script process")
struct ScriptProcessTests {

    @Test("A child left holding the pipes does not keep Barkeep waiting")
    func orphanHoldsPipes() async throws {
        let started = ContinuousClock.now
        let result = try await ScriptProcess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 10 & echo partial; exit 3"],
            timeout: .seconds(30),
            drainGrace: .milliseconds(300))
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(result.status == 3)
        #expect(!result.timedOut)
        #expect(result.stdoutText == "partial\n")
    }

    @Test("A line split across reads arrives whole, and a last line with no newline arrives too")
    func lineCollector() {
        let lines = LockedLines()
        let collector = LineCollector { lines.append($0) }
        collector.append(Data("one\ntw".utf8))
        collector.append(Data("o\nthree".utf8))
        collector.finish()
        #expect(lines.all == ["one", "two", "three"])
        #expect(collector.data == Data("one\ntwo\nthree".utf8))
    }
}

/// Lines collected from the pipes' threads.
private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

// MARK: - mrk mode

@Suite("mrk mode")
@MainActor
struct MrkModeTests {

    private func mode(_ stub: StubCheckout) -> MrkMode {
        let mrk = MrkMode(runner: stub.runner())
        mrk.open(brewfile: stub.brewfile)
        return mrk
    }

    @Test("On for a Brewfile in an mrk checkout, off for any other")
    func openAndClose() throws {
        let stub = try StubCheckout()
        let mrk = mode(stub)
        #expect(mrk.isActive)
        mrk.open(brewfile: stub.root.appendingPathComponent("Other.Brewfile"))
        #expect(!mrk.isActive)
        mrk.open(brewfile: nil)
        #expect(!mrk.isActive)
    }

    @Test("refresh reads the drift: additions and prunes")
    func refresh() async throws {
        let stub = try StubCheckout(checkOutput: checkOutput)
        let mrk = mode(stub)
        await mrk.refresh()
        #expect(mrk.additions.map(\.name) == ["zq-tool", "zq-chess"])
        #expect(mrk.prunes.map(\.name) == ["zq-gone"])
        #expect(mrk.candidate(.prune, name: "zq-gone", kind: .cask) != nil)
        #expect(mrk.candidate(.prune, name: "zq-gone", kind: .formula) == nil)
        #expect(mrk.checkError == nil)
    }

    @Test("A decision is logged in order, reloads the Brewfile while writes are held, then reads the drift again")
    func perform() async throws {
        let stub = try StubCheckout(checkOutput: checkOutput)
        let mrk = mode(stub)
        let log = ProcessingLog()
        var heldDuringReload: Bool?
        mrk.onBrewfileWritten = { heldDuringReload = mrk.isWritingBrewfile }

        let error = await mrk.perform(.add(name: "zq-tool", kind: .formula, section: "Repo essentials"), log: log)
        #expect(error == nil)
        let messages = log.entries.map(\.message)
        #expect(messages.first == "$ scripts/sync --add zq-tool --formula --section \"## Repo essentials\"")
        #expect(messages.last == "Done.")
        #expect(messages.contains("Added 1 entry to Brewfile."))
        #expect(log.statusEntries.map(\.message).contains("✓ Described 1 package(s)"))
        #expect(heldDuringReload == true)
        #expect(!mrk.isWritingBrewfile && !mrk.isBusy)
        #expect(stub.runs() == ["run sync --add zq-tool --formula --section ## Repo essentials",
                                "run sync --check --details"])
    }

    @Test("A refusal comes back as an error and is logged")
    func refused() async throws {
        let stub = try StubCheckout()
        let mrk = mode(stub)
        let log = ProcessingLog()
        var reloaded = false
        mrk.onBrewfileWritten = { reloaded = true }
        let error = await mrk.perform(.ignore(name: "taken", kind: .cask), log: log)
        #expect(error?.localizedDescription == "taken is already in the Brewfile.")
        #expect(log.entries.last?.message == "Error: taken is already in the Brewfile.")
        #expect(log.entries.contains { $0.level == .error && $0.message.hasPrefix("✗") })
        #expect(!reloaded, "an ignore does not rewrite the Brewfile")
    }

    @Test("A burst of Barkeep edits runs check-picker-desc --fix once")
    func fixCoalesces() async throws {
        let stub = try StubCheckout()
        let mrk = mode(stub)
        let log = ProcessingLog()
        mrk.fixDescriptions(log: log)
        mrk.fixDescriptions(log: log)
        mrk.fixDescriptions(log: log)
        await mrk.settle()
        #expect(stub.runs() == ["run check-picker-desc --fix"])
        mrk.fixDescriptions(log: log)
        await mrk.settle()
        #expect(stub.runs().count == 2)
    }

    @Test("Outside mrk mode nothing runs")
    func inactive() async throws {
        let stub = try StubCheckout()
        let mrk = MrkMode(runner: stub.runner())
        mrk.fixDescriptions(log: ProcessingLog())
        await mrk.refresh()
        await mrk.settle()
        #expect(stub.runs().isEmpty)
    }

    @Test("A Barkeep edit in mrk mode is followed by --fix, and is held back while sync writes")
    func barkeepEdits() async throws {
        let stub = try StubCheckout()
        let mrk = mode(stub)
        let log = ProcessingLog()
        let vm = BrewfileViewModel()
        vm.nodes = try BrewfileParser.parse(url: stub.brewfile)
        vm.onSave = { mrk.fixDescriptions(log: log) }

        vm.add(name: "zq-new", kind: .formula, section: "# Repo essentials", brewfileURL: stub.brewfile)
        await mrk.settle()
        #expect(try String(contentsOf: stub.brewfile, encoding: .utf8).contains("brew \"zq-new\""))
        #expect(stub.runs() == ["run check-picker-desc --fix"])

        let before = try String(contentsOf: stub.brewfile, encoding: .utf8)
        vm.writeGuard = { "held" }
        vm.add(name: "zq-held", kind: .formula, section: "# Repo essentials", brewfileURL: stub.brewfile)
        #expect(try String(contentsOf: stub.brewfile, encoding: .utf8) == before)
        #expect(!vm.contains(name: "zq-held", kind: .formula))
        #expect(vm.error == "held")
        await mrk.settle()
        #expect(stub.runs().count == 1, "a held-back edit wrote nothing, so there is nothing to fix")
    }

    @Test("The Untracked lists come from the drift, with each cask's section")
    func untrackedLists() {
        let vm = UntrackedViewModel()
        vm.selectedPackageIDs = ["zq-chess:cask", "vanished:formula"]
        vm.load(candidates: MrkCandidate.parse(checkOutput))
        #expect(vm.formulae.map(\.name) == ["zq-tool"])
        #expect(vm.casks.map(\.name) == ["zq-chess"])
        #expect(vm.casks.first?.mrkSection == "Casks - Games")
        #expect(vm.casks.first?.description == "Chess against the clock")
        #expect(vm.formulae.first?.mrkSection == nil)
        #expect(vm.notInstalled.map(\.name) == ["zq-gone"])
        #expect(vm.notInstalled.first?.isInBrewfile == true)
        #expect(vm.untrackedCount == 2)
        #expect(vm.selectedPackageIDs == ["zq-chess:cask"])
        #expect(vm.selectedPackages.map(\.name) == ["zq-chess"])
        vm.clearMrk()
        #expect(vm.notInstalled.isEmpty)
    }
}

// MARK: - Against a real scratch checkout (opt-in)

/// Runs mrk mode end to end: the real login zsh, the real sync and
/// check-picker-desc of an mrk clone, and the real Homebrew, which is only
/// read. Off unless BARKEEP_MRK_SCRATCH names a scratch home holding a
/// `.zprofile` that puts Homebrew on PATH and an `mrk` clone whose Brewfile
/// differs from what is installed: at least one cask and one formula to add,
/// one more package to ignore, and one entry to prune. Everything it writes
/// is in that folder: the zsh runs with HOME set to it, so sync's ignore list
/// is the scratch one. Run it with
///
///     TEST_RUNNER_BARKEEP_MRK_SCRATCH=/path/to/scratchhome xcodebuild … test
///
/// (in xcodebuild's environment: it hands TEST_RUNNER_ variables to the tests
/// without the prefix; given as an argument it would be a build setting).
/// The console of the run is written to barkeep-e2e-console.txt beside it.
@Suite("mrk mode against a scratch checkout",
       .enabled(if: ProcessInfo.processInfo.environment["BARKEEP_MRK_SCRATCH"] != nil))
@MainActor
struct MrkModeScratchCheckoutTests {

    @Test("Untracked, add, ignore, prune and --fix all go through mrk's scripts")
    func endToEnd() async throws {
        let home = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BARKEEP_MRK_SCRATCH"]))
        let brewfile = home.appendingPathComponent("mrk/Brewfile")
        let checkout = try #require(MrkCheckout.containing(brewfile: brewfile))
        let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        // The "## " section a line is in, by mrk's rule. Barkeep's own view
        // starts a section at any comment, and mrk's Brewfile has comments
        // inside sections.
        let mrkSection = { (line: String) -> String? in
            var current: String?
            for l in read(brewfile).components(separatedBy: "\n") {
                if l.hasPrefix("## ") { current = String(l.dropFirst(3)) }
                if l == line { return current }
            }
            return nil
        }

        // The app's own capture, with the scratch home in place of the real one.
        let shell = home.appendingPathComponent("zsh-with-scratch-home")
        try "#!/bin/sh\nexec /usr/bin/env HOME='\(home.path)' /bin/zsh \"$@\"\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shell.path)
        let env = try #require(await ShellEnvironment.capture(shell: shell))
        #expect(env["HOME"] == home.path)
        #expect(env["PATH"]?.contains("/opt/homebrew/bin") == true)

        let mrk = MrkMode(runner: MrkRunner(environment: { env }))
        let log = ProcessingLog()
        let vm = BrewfileViewModel()
        vm.nodes = try BrewfileParser.parse(url: brewfile)
        vm.writeGuard = { mrk.isWritingBrewfile ? "held" : nil }
        vm.onSave = { mrk.fixDescriptions(log: log) }
        mrk.onBrewfileWritten = { vm.nodes = (try? BrewfileParser.parse(url: brewfile)) ?? vm.nodes }
        defer {
            let text = log.entries.map(\.message).joined(separator: "\n") + "\n"
            try? text.write(to: home.appendingPathComponent("barkeep-e2e-console.txt"), atomically: true, encoding: .utf8)
        }

        mrk.open(brewfile: brewfile)
        #expect(mrk.isActive)
        await mrk.refresh()
        #expect(mrk.checkError == nil)
        let untracked = UntrackedViewModel()
        untracked.load(candidates: mrk.candidates)

        // A cask, filed where --details said it would go.
        let cask = try #require(untracked.casks.first)
        let section = try #require(cask.mrkSection)
        #expect(await mrk.perform(.add(name: cask.name, kind: .cask, section: nil), log: log) == nil)
        let caskLine = "cask \"\(cask.name)\", greedy: true"
        #expect(mrkSection(caskLine) == section)
        #expect(read(checkout.descriptions).contains("\n\(cask.name)\t"))

        // A formula, into the first formula section.
        let formula = try #require(untracked.formulae.first)
        let formulaSection = try #require(MrkCheckout.formulaSections(in: vm.nodes).first)
        #expect(await mrk.perform(.add(name: formula.name, kind: .formula, section: formulaSection), log: log) == nil)
        #expect(mrkSection("brew \"\(formula.name)\"") == formulaSection)

        // Adding it again is refused, with sync's reason, and changes nothing.
        let before = read(brewfile)
        let again = await mrk.perform(.add(name: formula.name, kind: .formula, section: formulaSection), log: log)
        #expect(again?.localizedDescription.contains("already in the Brewfile") == true)
        #expect(read(brewfile) == before)

        // Ignore the next candidate: it leaves the drift, into the scratch list.
        let next = try #require(mrk.additions.first)
        #expect(await mrk.perform(.ignore(name: next.name, kind: next.kind), log: log) == nil)
        #expect(read(home.appendingPathComponent(".mrk/sync-ignore")).contains("\n\(next.name)\n"))
        #expect(!mrk.additions.contains { $0.name == next.name })

        // Prune an entry whose package is not installed, and its description.
        let stale = try #require(mrk.prunes.first)
        #expect(await mrk.perform(.prune(name: stale.name, kind: stale.kind), log: log) == nil)
        #expect(!BrewfileParser.entries(from: vm.nodes).contains { $0.name == stale.name && $0.kind == stale.kind })
        #expect(!read(checkout.descriptions).contains("\n\(stale.name)\t"))

        // Barkeep's own edits: remove an entry, and add one the way Barkeep
        // does outside sync. The --fix after each save settles the table.
        let removed = try #require(BrewfileParser.entries(from: vm.nodes).first { $0.kind == .formula && $0.name != formula.name })
        vm.remove(entry: removed, brewfileURL: brewfile)
        vm.add(name: next.name, kind: next.kind, section: "# \(formulaSection)", brewfileURL: brewfile)
        await mrk.settle()
        #expect(!read(checkout.descriptions).contains("\n\(removed.name)\t"))
        #expect(read(checkout.descriptions).contains("\n\(next.name)\t"))

        // And mrk's own gate agrees.
        let verdict = try await ScriptProcess.run(checkout.checkPickerDesc, environment: env,
                                                  currentDirectory: checkout.root, timeout: .seconds(60))
        #expect(verdict.status == 0, "\(verdict.stdoutText)\(verdict.stderrText)")
    }
}
