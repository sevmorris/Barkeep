import Foundation

// mrk mode: when the open Brewfile is the one in an mrk checkout, Barkeep has
// mrk's own scripts make the decisions sync makes — which packages count as
// untracked, where a new entry goes, what its picker description says, what
// may be pruned — instead of making them itself. mrk's bash carries the safety
// checks (sync-ignore, never pruning when `brew list` fails, never guessing a
// formula's section), and a second copy of them here would drift.

/// An mrk checkout around a Brewfile: the folder holds `scripts/sync`,
/// `scripts/check-picker-desc` and `tools/picker/descriptions.tsv` beside the
/// Brewfile, as ~/mrk does.
struct MrkCheckout: Equatable, Sendable {
    let root: URL

    var brewfile: URL        { root.appendingPathComponent("Brewfile") }
    var sync: URL            { root.appendingPathComponent("scripts/sync") }
    var checkPickerDesc: URL { root.appendingPathComponent("scripts/check-picker-desc") }
    var descriptions: URL    { root.appendingPathComponent("tools/picker/descriptions.tsv") }

    /// The checkout the Brewfile is in, or nil when it is in none. sync works
    /// on the file named Brewfile beside it, so any other name is no checkout
    /// of the file Barkeep shows.
    static func containing(brewfile url: URL, fileManager: FileManager = .default) -> MrkCheckout? {
        guard url.lastPathComponent == "Brewfile" else { return nil }
        let checkout = MrkCheckout(root: url.deletingLastPathComponent())
        guard fileManager.isExecutableFile(atPath: checkout.sync.path),
              fileManager.isExecutableFile(atPath: checkout.checkPickerDesc.path),
              fileManager.fileExists(atPath: checkout.descriptions.path)
        else { return nil }
        return checkout
    }

    /// The sections sync accepts for a formula, as their `## ` lines name
    /// them: every one but Taps and the cask sections. These are the names
    /// sync's own prompt offers; sync checks the one it is given in any case.
    static func formulaSections(in nodes: [BrewfileNode]) -> [String] {
        var names: [String] = []
        for case .comment(let raw) in nodes {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("## ") else { continue }
            let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "Taps", !name.hasPrefix("Casks"),
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }
}

/// One line of `sync --check --details`: a package sync would offer to add,
/// or a Brewfile entry it would offer to prune.
struct MrkCandidate: Identifiable, Hashable, Sendable {
    enum Action: String, Sendable { case add, prune }

    let action: Action
    let kind: PackageKind
    let name: String
    /// For an add, the section sync files a cask under (empty for a formula,
    /// whose section sync asks for). For a prune, the entry's section.
    let section: String
    /// Why a cask goes to its section.
    let reason: String
    /// The words the description table holds after an add, or holds now for
    /// a prune. Empty when there are none.
    let description: String

    var id: String { "\(action.rawValue):\(kind.rawValue):\(name)" }

    /// Parses the output of `sync --check` with or without `--details`: tab
    /// separated, three fields, then section, reason and description. A line
    /// that is not one of these is skipped, and a field added after the six
    /// is ignored, so a later sync can add one without breaking this.
    static func parse(_ output: String) -> [MrkCandidate] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3,
                  let action = Action(rawValue: fields[0]),
                  !fields[2].isEmpty
            else { return nil }
            let kind: PackageKind
            switch fields[1] {
            case "formula": kind = .formula
            case "cask":    kind = .cask
            default:        return nil
            }
            func field(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
            return MrkCandidate(action: action, kind: kind, name: fields[2],
                                section: field(3), reason: field(4), description: field(5))
        }
    }
}

/// What Barkeep asks mrk to do. Each case is one run of one script.
enum MrkCommand: Equatable, Sendable {
    /// The drift, with each cask's section and each description.
    case check
    /// Add a package; a formula needs the section it goes in.
    case add(name: String, kind: PackageKind, section: String?)
    /// Add a name to ~/.mrk/sync-ignore.
    case ignore(name: String, kind: PackageKind)
    /// Delete the entry of a package that is not installed.
    case prune(name: String, kind: PackageKind)
    /// Describe each undescribed package and delete each orphaned description.
    case fixDescriptions

    /// Whether the command can rewrite the Brewfile. Barkeep holds its own
    /// writes back while one runs, so neither undoes the other.
    var writesBrewfile: Bool {
        switch self {
        case .add, .prune: return true
        case .check, .ignore, .fixDescriptions: return false
        }
    }

    func executable(in checkout: MrkCheckout) -> URL {
        self == .fixDescriptions ? checkout.checkPickerDesc : checkout.sync
    }

    /// The arguments, with the kind always given, so a name that is both a
    /// formula and a cask is never left to sync to refuse.
    var arguments: [String] {
        switch self {
        case .check:
            return ["--check", "--details"]
        case .add(let name, let kind, let section):
            var args = ["--add", name, Self.kindFlag(kind)]
            if kind == .formula, let section { args += ["--section", "## \(section)"] }
            return args
        case .ignore(let name, let kind):
            return ["--ignore", name, Self.kindFlag(kind)]
        case .prune(let name, let kind):
            return ["--prune", name, Self.kindFlag(kind)]
        case .fixDescriptions:
            return ["--fix"]
        }
    }

    /// The command as the console shows it.
    func displayLine(in checkout: MrkCheckout) -> String {
        let script = self == .fixDescriptions ? "scripts/check-picker-desc" : "scripts/sync"
        let args = arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
        return "$ " + ([script] + args).joined(separator: " ")
    }

    private static func kindFlag(_ kind: PackageKind) -> String {
        kind == .cask ? "--cask" : "--formula"
    }
}

enum MrkError: LocalizedError {
    case failed(command: String, status: Int32, message: String)
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let message):
            return message.isEmpty ? "\(command) exited with status \(status)." : message
        case .timedOut(let command):
            return "\(command) did not finish, and Barkeep stopped it."
        }
    }
}

/// Runs mrk's scripts with the environment of an interactive login zsh,
/// asked for once and kept.
actor MrkRunner {
    typealias EnvironmentProvider = @Sendable () async -> [String: String]

    /// What a terminal window on this Mac has, or Barkeep's own environment
    /// with the usual PATH when the shell cannot be asked.
    static let loginShellEnvironment: EnvironmentProvider = {
        let home = NSHomeDirectory()
        return await ShellEnvironment.capture()
            ?? ShellEnvironment.fallback(base: ProcessInfo.processInfo.environment, home: home)
    }

    private let environmentProvider: EnvironmentProvider
    private let timeout: Duration
    private var environment: [String: String]?
    private var runningPID: Int32?

    init(environment: @escaping EnvironmentProvider = MrkRunner.loginShellEnvironment,
         timeout: Duration = .seconds(300)) {
        self.environmentProvider = environment
        self.timeout = timeout
    }

    /// Runs the command in the checkout, handing each line of its output to
    /// `onLine` as it arrives. Throws when the script exits non-zero, with the
    /// last line it wrote to stderr — where sync says why it refused.
    @discardableResult
    func run(
        _ command: MrkCommand,
        in checkout: MrkCheckout,
        onLine: @escaping @Sendable (String, _ fromStderr: Bool) -> Void = { _, _ in }
    ) async throws -> ScriptResult {
        let env = await resolvedEnvironment()
        let result = try await ScriptProcess.run(
            command.executable(in: checkout),
            arguments: command.arguments,
            environment: env,
            currentDirectory: checkout.root,
            timeout: timeout,
            onStart: { pid in Task { await self.started(pid) } },
            onLine: { line, fromStderr in onLine(Self.plain(line), fromStderr) }
        )
        runningPID = nil
        let name = command.displayLine(in: checkout).dropFirst(2)
        if result.timedOut { throw MrkError.timedOut(command: String(name)) }
        guard result.status == 0 else {
            let message = result.stderrText.split(separator: "\n")
                .map { Self.plain(String($0)).trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? ""
            throw MrkError.failed(command: String(name), status: result.status,
                                  message: Self.withoutMark(message))
        }
        return result
    }

    /// The drift sync sees, with the details Barkeep shows.
    func check(_ checkout: MrkCheckout) async throws -> [MrkCandidate] {
        let result = try await run(.check, in: checkout)
        return MrkCandidate.parse(result.stdoutText)
    }

    /// Stops the script that is running, if one is.
    func cancel() {
        if let pid = runningPID { kill(pid, SIGTERM) }
        runningPID = nil
    }

    private func started(_ pid: Int32) { runningPID = pid }

    private func resolvedEnvironment() async -> [String: String] {
        if let environment { return environment }
        let env = await environmentProvider()
        environment = env
        return env
    }

    /// The line without terminal colour codes. mrk's scripts write none to a
    /// pipe, but brew and git, which they run, may.
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: #"\u{1B}\[[0-9;]*[A-Za-z]"#, with: "", options: .regularExpression)
    }

    /// sync's `err` marks its lines with ✗; the alert says it in words.
    static func withoutMark(_ message: String) -> String {
        var text = message
        for mark in ["✗", "⚠", "▸", "✓"] where text.hasPrefix(mark) {
            text = String(text.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}
