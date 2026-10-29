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

/// The line contract of mrk's `--check` modes, as BIN-1 documents it: mrk's
/// `mrk_check_line` puts one tab between two fields and escapes each field,
/// a tab as `\t`, a newline as `\n` and a backslash as `\\`. mrk keeps the
/// contract as data in tests/fixtures/check-lines.json, and
/// BarkeepTests/Fixtures holds a copy that the tests read.
///
/// Both functions work by Unicode scalar, not by Character. As Characters, a
/// carriage return and the newline after it are one, and so are an escape and
/// a combining mark after it. mrk does not escape a carriage return, so in
/// Barkeep 1.15 a description that ended in one joined two lines, and every
/// escape showed as it came (sevmorris/mrk audit 22, Z-4).
enum MrkLine {
    /// The lines of an output: split at every newline, with no empty line.
    static func lines(_ output: String) -> [Substring] {
        output.unicodeScalars.split(separator: "\n").map(Substring.init)
    }

    /// The fields of one line, split at every tab, each with its escapes
    /// undone. Two tabs in a row are an empty field. nil when a field has a
    /// backslash before anything but t, n or another backslash, which mrk
    /// never writes.
    static func fields(_ line: Substring) -> [String]? {
        var fields: [String] = []
        for field in line.unicodeScalars.split(separator: "\t", omittingEmptySubsequences: false) {
            guard let text = unescape(field) else { return nil }
            fields.append(text)
        }
        return fields
    }

    private static func unescape(_ field: Substring.UnicodeScalarView.SubSequence) -> String? {
        var out = String.UnicodeScalarView()
        var it = field.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "\\": out.append("\\")
            default: return nil
            }
        }
        return String(out)
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
    /// separated, three fields, then section, reason and description, each
    /// field escaped as `MrkLine` undoes. A line that is not one of these is
    /// skipped, and a field added after the six is ignored, so a later sync
    /// can add one without breaking this.
    static func parse(_ output: String) -> [MrkCandidate] {
        MrkLine.lines(output).compactMap { line in
            guard let fields = MrkLine.fields(line),
                  fields.count >= 3,
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

/// What the scripts of an mrk checkout take from a program, as the checkout's
/// `scripts/mrk-contract` says it (mrk's BIN-1, mrk-contract). MrkRunner reads
/// it once for each checkout, and again when the file changes, and passes an
/// option only when the script takes it. So an exit 2 from sync means that it
/// refuses the command line, for the reason that it gives (sevmorris/mrk
/// audit 22, O-2). An mrk from before 2026-10-29 has no mrk-contract, and then
/// Barkeep runs the command and shows the reason sync gives.
///
/// Barkeep reads the options alone: MrkCandidate reads the fields of the
/// --check lines by the line contract.
struct MrkContract: Decodable, Equatable, Sendable {
    /// The version this build reads. mrk raises it when it deletes an option,
    /// a field or a key, moves a field, or gives a word or a key a new
    /// meaning. A new script, option, field, word or key keeps it.
    static let supportedVersion = 1

    let contract: Int
    /// Each script, by its path in the checkout, such as scripts/sync.
    let scripts: [String: Script]

    struct Script: Decodable, Equatable, Sendable {
        /// Every option the script takes, each short form apart.
        let options: [String]
    }

    static func decode(_ data: Data) throws -> MrkContract {
        try JSONDecoder().decode(MrkContract.self, from: data)
    }

    /// Whether this mrk is newer than the contract this build reads.
    var isNewer: Bool { contract > Self.supportedVersion }

    /// The options of COMMAND that its script does not take. Empty when it
    /// takes them all, and nil when the contract does not name the script.
    func missing(_ command: MrkCommand) -> [String]? {
        guard let script = scripts[command.script] else { return nil }
        return command.options.filter { !script.options.contains($0) }
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

    /// The script, by its path in the checkout, as mrk-contract names it.
    var script: String {
        self == .fixDescriptions ? "scripts/check-picker-desc" : "scripts/sync"
    }

    /// The options the command gives, by name, as mrk-contract lists them.
    var options: [String] {
        arguments.filter { $0.hasPrefix("-") }
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
    /// The checkout's mrk-contract does not list an option of the command,
    /// so Barkeep did not run it.
    case notTaken(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let status, let message):
            return message.isEmpty ? "\(command) exited with status \(status)." : message
        case .timedOut(let command):
            return "\(command) did not finish, and Barkeep stopped it."
        case .notTaken(_, let message):
            return message
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
    /// The contract of each checkout, by its root's path, with the
    /// modification date that scripts/mrk-contract had when it was read. A
    /// pull that changes the file changes the date, and the next run reads it
    /// again. A nil contract is a checkout with none, or one that could not
    /// be read.
    private var contracts: [String: (stamp: Date?, contract: MrkContract?)] = [:]

    init(environment: @escaping EnvironmentProvider = MrkRunner.loginShellEnvironment,
         timeout: Duration = .seconds(300)) {
        self.environmentProvider = environment
        self.timeout = timeout
    }

    /// The checkout's mrk-contract, run once and kept until the file changes,
    /// or nil when the checkout has none or it did not answer with a document
    /// Barkeep can read.
    func contract(for checkout: MrkCheckout) async -> MrkContract? {
        let url = checkout.root.appendingPathComponent("scripts/mrk-contract")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let kept = contracts[checkout.root.path], kept.stamp == stamp { return kept.contract }
        var contract: MrkContract?
        if stamp != nil, FileManager.default.isExecutableFile(atPath: url.path),
           let result = try? await ScriptProcess.run(url, environment: await resolvedEnvironment(),
                                                     currentDirectory: checkout.root, timeout: .seconds(30)),
           !result.timedOut, result.status == 0 {
            contract = try? MrkContract.decode(result.stdout)
        }
        contracts[checkout.root.path] = (stamp, contract)
        return contract
    }

    /// Runs the command in the checkout, handing each line of its output to
    /// `onLine` as it arrives. Throws when the script exits non-zero, with
    /// the reason it wrote to stderr: the last line it marked ✗, or else its
    /// last line. Throws without running it when the checkout's mrk-contract
    /// does not list one of its options.
    @discardableResult
    func run(
        _ command: MrkCommand,
        in checkout: MrkCheckout,
        onLine: @escaping @Sendable (String, _ fromStderr: Bool) -> Void = { _, _ in }
    ) async throws -> ScriptResult {
        let name = String(command.displayLine(in: checkout).dropFirst(2))
        if let contract = await contract(for: checkout), let missing = contract.missing(command), !missing.isEmpty {
            let options = missing.joined(separator: " ")
            throw MrkError.notTaken(command: name, message: contract.isNewer
                ? "\(command.script) does not take \(options): this Barkeep is older than mrk. Choose Check for Updates… in the Barkeep menu."
                : "\(command.script) does not take \(options): this mrk is older than Barkeep. Run make pull in \(checkout.root.path).")
        }
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
        if result.timedOut { throw MrkError.timedOut(command: name) }
        guard result.status == 0 else {
            throw MrkError.failed(command: name, status: result.status,
                                  message: Self.reason(in: result.stderrText))
        }
        return result
    }

    /// Why a script refused: the last line that mrk's err marked ✗, which
    /// comes before the hints that info adds below it, such as sync's "Run
    /// sync --help for the options.", or else the last line. Without its mark.
    static func reason(in stderr: String) -> String {
        let lines = stderr.split(separator: "\n")
            .map { plain(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return withoutMark(lines.last { $0.hasPrefix("✗") } ?? lines.last ?? "")
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
