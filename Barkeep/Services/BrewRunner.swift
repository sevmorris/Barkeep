import Foundation
import os.log

private let brewLog = Logger(subsystem: "io.github.sevmorris.Barkeep", category: "BrewRunner")

enum BrewError: LocalizedError {
    case notFound
    case failed(Int32)
    case failedWithMessage(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Homebrew not found. Install from https://brew.sh"
        case .failed(let code):
            return "brew exited with status \(code)"
        case .failedWithMessage(let msg):
            return msg.isEmpty ? "brew command failed" : msg
        }
    }
}

private final class ResumeGuard {
    private var resumed = false
    func tryResume() -> Bool {
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

/// Lock-protected `Data` buffer — readability handlers and termination
/// handlers run on background queues independently, so the byte buffer
/// that aggregates them needs synchronization.
private final class CaptureBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

actor BrewRunner {
    static let shared = BrewRunner()

    private var runningProcess: Process?

    // MARK: - Info cache

    private var infoCache: [String: (BrewPackage, Date)] = [:]
    private let infoCacheTTL: TimeInterval = 300  // 5 minutes

    private func cachedInfo(name: String, kind: PackageKind) -> BrewPackage? {
        let key = "\(kind):\(name)"
        guard let entry = infoCache[key] else { return nil }
        guard Date().timeIntervalSince(entry.1) < infoCacheTTL else {
            infoCache.removeValue(forKey: key)
            return nil
        }
        return entry.0
    }

    private func cacheInfo(_ pkg: BrewPackage) {
        let key = "\(pkg.kind):\(pkg.name)"
        infoCache[key] = (pkg, Date())
    }

    /// Drop cached info for the given names so the next `info(...)` call
    /// refetches from `brew info`. Call after any install/uninstall/upgrade.
    func invalidateCache(names: [String]) {
        for name in names {
            infoCache.removeValue(forKey: "\(PackageKind.formula):\(name)")
            infoCache.removeValue(forKey: "\(PackageKind.cask):\(name)")
        }
    }

    /// Drop every cached info entry — use when we don't know which packages
    /// were affected (e.g. after `brew bundle install`).
    func invalidateAllCache() {
        infoCache.removeAll()
    }

    // MARK: - Executable

    private nonisolated func brewExecutable() throws -> URL {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw BrewError.notFound
    }

    /// Homebrew's prefix, /opt/homebrew or /usr/local: the folder above the
    /// bin that holds brew. Its Cellar and Caskroom are in it.
    nonisolated func prefix() throws -> URL {
        try brewExecutable().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func brewEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["HOME"] = NSHomeDirectory()
        return env
    }

    // MARK: - Run (streaming)

    /// Run brew with streaming output. Each output line is passed to `onOutput` on the main actor.
    func run(
        _ args: [String],
        onOutput: @MainActor @Sendable @escaping (String, LogLevel) -> Void
    ) async throws {
        let brew = try brewExecutable()
        defer { runningProcess = nil }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = brew
            process.arguments = args
            process.environment = Self.brewEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let guard_ = ResumeGuard()

            @Sendable func emit(_ text: String, level: LogLevel) {
                for line in text.components(separatedBy: "\n") {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        Task { await onOutput(t, level) }
                    }
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                if let s = String(data: handle.availableData, encoding: .utf8) { emit(s, level: .verbose) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                if let s = String(data: handle.availableData, encoding: .utf8) { emit(s, level: .verbose) }
            }

            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard guard_.tryResume() else { return }
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: BrewError.failed(p.terminationStatus))
                }
            }

            do {
                runningProcess = process
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard guard_.tryResume() else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        guard let process = runningProcess else { return }
        process.terminate()
        runningProcess = nil
    }

    // MARK: - Capture (non-streaming)

    func capture(_ args: [String]) async throws -> String {
        let brew = try brewExecutable()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = brew
            process.arguments = args
            process.environment = Self.brewEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let guard_ = ResumeGuard()
            // Read stdout/stderr incrementally to avoid pipe-buffer deadlock
            // on large outputs (e.g. `brew search --cask ""` returns >64KB).
            // The buffers are mutated from background queues — both the
            // readability handlers and the termination handler — so they
            // need a lock. CaptureBuffer provides that.
            let stdoutBuffer = CaptureBuffer()
            let stderrBuffer = CaptureBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutBuffer.append(handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrBuffer.append(handle.availableData)
            }

            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain any remaining data after detaching handlers
                stdoutBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                guard guard_.tryResume() else { return }
                let stdoutData = stdoutBuffer.snapshot()
                let stderrData = stderrBuffer.snapshot()
                if p.terminationStatus == 0 {
                    if !stderrData.isEmpty,
                       let msg = String(data: stderrData, encoding: .utf8),
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        brewLog.debug("[brew stderr] \(msg, privacy: .public)")
                    }
                    let result = String(data: stdoutData, encoding: .utf8)
                        ?? String(decoding: stdoutData, as: UTF8.self)
                    continuation.resume(returning: result)
                } else {
                    let msg = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: BrewError.failedWithMessage(msg))
                }
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard guard_.tryResume() else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Convenience queries

    func listFormulae() async throws -> [String] {
        let out = try await capture(["list", "--formula", "--full-name"])
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Active taps from `brew tap`.
    func listTaps() async throws -> Set<String> {
        let out = try await capture(["tap"])
        let taps = out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(taps)
    }

    /// Only formulae the user explicitly installed — drops transitive
    /// dependencies that were pulled in automatically.
    func listRequestedFormulae() async throws -> [String] {
        let out = try await capture(["list", "--formula", "--full-name", "--installed-on-request"])
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    func listCasks() async throws -> [String] {
        let out = try await capture(["list", "--cask"])
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// The casks among `names` that Homebrew can forget while their apps
    /// stay where they are (HomebrewRecord.canForget), by their short names.
    /// Empty when brew cannot describe them.
    func forgettableCasks(_ names: [String]) async -> Set<String> {
        guard !names.isEmpty,
              let json = try? await capture(["info", "--json=v2", "--cask"] + names)
        else { return [] }
        return HomebrewRecord.forgettable(infoJSON: json)
    }

    /// Fetch detailed info for one or more packages via `brew info --json=v2`.
    func info(names: [String], kind: PackageKind) async throws -> [BrewPackage] {
        guard !names.isEmpty else { return [] }

        // Check cache for single-name lookups
        if names.count == 1, let cached = cachedInfo(name: names[0], kind: kind) {
            return [cached]
        }

        let flag = kind == .cask ? "--cask" : "--formula"
        let json = try await capture(["info", "--json=v2", flag] + names)
        let packages = parseInfoJSON(json, kind: kind)

        for pkg in packages {
            cacheInfo(pkg)
        }

        return packages
    }

    private func parseInfoJSON(_ json: String, kind: PackageKind) -> [BrewPackage] {
        guard
            let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var packages: [BrewPackage] = []

        if kind == .formula, let formulae = root["formulae"] as? [[String: Any]] {
            for f in formulae {
                let name    = f["name"]     as? String ?? ""
                let desc    = f["desc"]     as? String ?? ""
                let home    = f["homepage"] as? String ?? ""
                let version = (f["versions"] as? [String: Any])?["stable"] as? String ?? ""
                let license = f["license"]  as? String ?? ""
                let tap     = f["tap"]      as? String ?? ""
                let deps    = f["dependencies"]       as? [String] ?? []
                let buildDeps = f["build_dependencies"] as? [String] ?? []
                let caveats = f["caveats"]  as? String ?? ""
                let outdated  = f["outdated"] as? Bool ?? false
                let conflicts = f["conflicts_with"] as? [String] ?? []
                let installTime = (f["installed"] as? [[String: Any]])?.first?["time"] as? TimeInterval

                var pkg = BrewPackage(name: name, kind: .formula,
                                      description: desc, version: version, homepage: home,
                                      isInstalled: true,
                                      isBrewManaged: true)
                pkg.license          = license
                pkg.tap              = tap
                pkg.dependencies     = deps
                pkg.buildDependencies = buildDeps
                pkg.caveats          = caveats.trimmingCharacters(in: .whitespacesAndNewlines)
                pkg.outdated         = outdated
                pkg.conflicts        = conflicts
                pkg.installDate      = installTime.map { Date(timeIntervalSince1970: $0) }
                packages.append(pkg)
            }
        } else if kind == .cask, let casks = root["casks"] as? [[String: Any]] {
            for c in casks {
                let token   = c["token"]    as? String ?? ""
                let desc    = c["desc"]     as? String ?? ""
                let home    = c["homepage"] as? String ?? ""
                let version = c["version"]  as? String ?? ""
                let tap     = c["tap"]      as? String ?? ""
                let caveats = c["caveats"]  as? String ?? ""
                let outdated = c["outdated"] as? Bool ?? false
                let conflicts = (c["conflicts_with"] as? [String: Any])?["cask"] as? [String] ?? []
                let installTime = c["installed_time"] as? TimeInterval
                let brewInstalled = c["installed"] as? String != nil

                // Check if the app exists in /Applications even if not brew-managed
                // (handles migrated / manually-installed apps)
                let appInApplications: Bool = {
                    guard !brewInstalled,
                          let artifacts = c["artifacts"] as? [[String: Any]] else { return false }
                    for artifact in artifacts {
                        if let apps = artifact["app"] as? [String] {
                            for app in apps {
                                if FileManager.default.fileExists(atPath: "/Applications/\(app)") {
                                    return true
                                }
                            }
                        }
                    }
                    return false
                }()

                var pkg = BrewPackage(name: token, kind: .cask,
                                      description: desc, version: version, homepage: home,
                                      isInstalled: brewInstalled || appInApplications,
                                      isBrewManaged: brewInstalled)
                pkg.tap         = tap
                pkg.caveats     = caveats.trimmingCharacters(in: .whitespacesAndNewlines)
                pkg.outdated    = outdated
                pkg.conflicts   = conflicts
                pkg.installDate = installTime.map { Date(timeIntervalSince1970: $0) }
                packages.append(pkg)
            }
        }

        return packages
    }

    // MARK: - Outdated

    /// Returns the names of all outdated formulae and casks.
    func outdatedNames() async -> Set<String> {
        guard let json = try? await capture(["outdated", "--json"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var names = Set<String>()
        if let formulae = root["formulae"] as? [[String: Any]] {
            formulae.compactMap { $0["name"] as? String }.forEach { names.insert($0) }
        }
        if let casks = root["casks"] as? [[String: Any]] {
            casks.compactMap { $0["name"] as? String }.forEach { names.insert($0) }
        }
        return names
    }


    // MARK: - Man page

    /// Fetches and parses the man page for a formula, returning key sections.
    /// Returns empty array for casks or when no man page exists.
    func manPage(for name: String) async -> [ManSection] {
        // Validate name matches valid formula/cask token characters before passing to shell
        guard name.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9@+.\-]*$"#, options: .regularExpression) != nil else {
            return []
        }
        guard let raw = try? await captureRaw("/bin/bash",
            args: ["-c", "MANPAGER=cat man -- \"$1\" 2>/dev/null | col -b", "bash", name]),
              !raw.isEmpty
        else { return [] }
        return parseManPage(raw)
    }

    private func parseManPage(_ raw: String) -> [ManSection] {
        // Sections we care about, in display order
        let wantedTitles = ["NAME", "SYNOPSIS", "DESCRIPTION"]
        // Cap each section. SwiftUI's Text with .fixedSize lays out the full
        // intrinsic height on the main thread; tools like rclone have ~3MB
        // man pages that beachball the UI. 8 KB is more than any reader
        // wants in the detail panel — they can `man <name>` for the full text.
        let perSectionCap = 8_000

        var sections: [(title: String, lines: [String])] = []
        var currentTitle = ""
        var currentLines: [String] = []

        for line in raw.components(separatedBy: "\n") {
            // Section headers: unindented ALL-CAPS words (optionally with spaces/parens)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeader = !line.hasPrefix(" ") && !line.hasPrefix("\t")
                && !trimmed.isEmpty
                && trimmed == trimmed.uppercased()
                && trimmed.range(of: #"^[A-Z][A-Z\s\(\)]+$"#, options: .regularExpression) != nil

            if isHeader {
                if !currentTitle.isEmpty && !currentLines.isEmpty {
                    sections.append((title: currentTitle, lines: currentLines))
                }
                currentTitle = trimmed
                currentLines = []
            } else if !currentTitle.isEmpty {
                currentLines.append(line)
            }
        }
        if !currentTitle.isEmpty && !currentLines.isEmpty {
            sections.append((title: currentTitle, lines: currentLines))
        }

        return sections
            .filter { wantedTitles.contains($0.title) }
            .compactMap { s -> ManSection? in
                let full = s.lines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !full.isEmpty else { return nil }
                let content = full.count > perSectionCap
                    ? String(full.prefix(perSectionCap)) + "\n…\n(truncated — run `man \(processName(from: s.lines))` for the full page)"
                    : full
                return ManSection(title: s.title, content: content)
            }
    }

    /// Best-effort extraction of the page name from a man-page section's
    /// raw lines, just so the truncation hint can suggest the exact command.
    private func processName(from lines: [String]) -> String {
        // NAME section line typically reads: "       toolname - one-line desc"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let dashIdx = trimmed.firstIndex(of: "-") {
                let head = trimmed[..<dashIdx].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return head }
            }
        }
        return ""
    }

    // MARK: - Reverse dependencies

    /// Returns installed packages that depend on the given formula.
    func uses(for name: String) async -> [String] {
        let out = (try? await capture(["uses", "--installed", name])) ?? ""
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    // MARK: - tldr

    /// Fetch and parse tldr examples for a package. Returns empty arrays
    /// if tldr isn't installed or no page exists.
    func tldr(for name: String) async -> (summary: String, examples: [TldrExample]) {
        // Locate tldr via PATH — `brewEnvironment()` puts Homebrew on PATH,
        // so this covers /opt/homebrew/bin/tldr, /usr/local/bin/tldr, and
        // any custom install.
        guard let path = (try? await captureRaw("/usr/bin/which", args: ["tldr"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return ("", []) }

        guard let raw = try? await captureRaw(path, args: ["--raw", name]) else { return ("", []) }

        return parseTldr(raw)
    }

    private func captureRaw(_ executable: String, args: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = Self.brewEnvironment()

            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe() // discard

            // Incremental reads — `readDataToEndOfFile()` alone deadlocks on
            // outputs larger than the pipe buffer (e.g. a long man page).
            let buffer = CaptureBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                buffer.append(handle.availableData)
            }

            let guard_ = ResumeGuard()
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                buffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                guard guard_.tryResume() else { return }
                let data = buffer.snapshot()
                if p.terminationStatus == 0 {
                    let result = String(data: data, encoding: .utf8)
                        ?? String(decoding: data, as: UTF8.self)
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: BrewError.failed(p.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                guard guard_.tryResume() else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    private func parseTldr(_ raw: String) -> (summary: String, examples: [TldrExample]) {
        var summaryLines: [String] = []
        var examples: [TldrExample] = []
        var pendingDescription = ""

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("> ") {
                // Summary / description line
                let text = String(line.dropFirst(2))
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !text.hasPrefix("More information:") {
                    summaryLines.append(text)
                }
            } else if line.hasPrefix("- ") {
                // Example description
                pendingDescription = String(line.dropFirst(2))
                    .trimmingCharacters(in: .init(charactersIn: ": "))
            } else if line.hasPrefix("`") && line.hasSuffix("`") && !pendingDescription.isEmpty {
                // Command — strip surrounding backticks and {{placeholder}} braces
                var cmd = String(line.dropFirst().dropLast())
                cmd = cmd.replacingOccurrences(of: "{{", with: "")
                cmd = cmd.replacingOccurrences(of: "}}", with: "")
                examples.append(TldrExample(description: pendingDescription, command: cmd))
                pendingDescription = ""
            }
        }

        let summary = summaryLines
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (summary, examples)
    }
}

// MARK: - Homebrew's records

/// What Homebrew keeps of an installed package, read and changed without
/// running brew: a formula's folder in the Cellar and a cask's in the
/// Caskroom, both in Homebrew's prefix.
///
/// Removing a package from the Brewfile leaves it installed, so Homebrew goes
/// on upgrading it. When its app is updated by hand instead, Homebrew's
/// record falls behind, and `brew outdated` offers the version that is
/// already there: Calibre on 2026-11-06, updated to 9.18.0 while the
/// Caskroom still said 9.17.0. Barkeep's Remove asks what happens to an
/// installed package, and one answer is to keep the app and have Homebrew
/// forget the cask (`forget`). That is the reverse of `brew install --adopt`,
/// which Adopt runs, and Homebrew has no command for it.
enum HomebrewRecord {
    enum ForgetError: LocalizedError, Equatable {
        case badName(String)
        case notInstalled(String)
        /// The cask's folder holds an app itself, not a link to one.
        case holdsApp(cask: String, app: String)

        var errorDescription: String? {
            switch self {
            case .badName(let name):
                return "“\(name)” is not a name Homebrew gives a cask."
            case .notInstalled(let name):
                return "Homebrew has no record of \(name) in its Caskroom."
            case .holdsApp(let cask, let app):
                return "Homebrew's folder for \(cask) holds \(app) itself, not a link to it, so Barkeep leaves it alone."
            }
        }
    }

    /// The stanzas of a cask that install nothing: what uninstall and zap
    /// delete. A preflight or postflight can put files anywhere, the
    /// Caskroom included, so a cask with one is never forgotten.
    static let inertStanzas: Set<String> = ["uninstall", "zap", "uninstall_preflight", "uninstall_postflight"]

    /// A Brewfile name as Homebrew names the folder: `user/tap/foo` is `foo`.
    static func shortName(_ name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    /// A name that can only be a folder directly in the Cellar or the
    /// Caskroom: no slash, and nothing that starts with a dot.
    static func isFolderName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9@+._-]*$"#, options: .regularExpression) != nil
    }

    /// The folder Homebrew keeps for an installed `name`, or nil for a tap
    /// or a name no folder has. A formula named by an alias (`python` for
    /// `python@3.13`) is not found, so Remove treats it as not installed.
    static func folder(name: String, kind: PackageKind, prefix: URL) -> URL? {
        let short = shortName(name)
        guard isFolderName(short) else { return nil }
        switch kind {
        case .formula: return prefix.appendingPathComponent("Cellar", isDirectory: true)
            .appendingPathComponent(short, isDirectory: true)
        case .cask: return prefix.appendingPathComponent("Caskroom", isDirectory: true)
            .appendingPathComponent(short, isDirectory: true)
        case .tap: return nil
        }
    }

    /// Whether Homebrew has `name` installed: its folder is there.
    static func isInstalled(name: String, kind: PackageKind, prefix: URL,
                            fileManager: FileManager = .default) -> Bool {
        guard let folder = folder(name: name, kind: kind, prefix: prefix) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Whether Homebrew can forget a cask, from its `brew info --json=v2`
    /// artifacts, and leave everything it installed working. Each artifact
    /// that installs something must be an app, which Homebrew moved into the
    /// Applications folder, or a link to a program inside one of those apps,
    /// as Calibre's `ebook-convert` is. Those links stay, and work while the
    /// app does; `brew cleanup` prunes them once they are broken. A pkg, an
    /// installer, a binary in the Caskroom (android-platform-tools), a font
    /// and the rest are Homebrew's to remove.
    ///
    /// An installed cask's artifact carries `target`, where it went; `exists`
    /// says whether each app is still there.
    static func canForget(artifacts: [[String: Any]],
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        var apps: [String] = []
        var binaries: [String] = []
        for artifact in artifacts {
            for (stanza, value) in artifact where stanza != "target" {
                if inertStanzas.contains(stanza) { continue }
                guard let values = value as? [Any], let source = values.first as? String else { return false }
                switch stanza {
                case "app":
                    let renamed = (values.dropFirst().first as? [String: Any])?["target"] as? String
                    let path = artifact["target"] as? String ?? "/Applications/" + (renamed ?? source)
                    guard path.hasPrefix("/") else { return false }
                    apps.append(path)
                case "binary":
                    binaries.append(source)
                default:
                    return false
                }
            }
        }
        guard !apps.isEmpty, apps.allSatisfy(exists) else { return false }
        return binaries.allSatisfy { source in apps.contains { source.hasPrefix($0 + "/") } }
    }

    /// The short names of the casks in a `brew info --json=v2 --cask`
    /// document that Homebrew has installed and can forget.
    static func forgettable(infoJSON: String,
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String> {
        guard let data = infoJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]]
        else { return [] }
        var names = Set<String>()
        for cask in casks {
            guard let token = cask["token"] as? String, cask["installed"] is String,
                  let artifacts = cask["artifacts"] as? [[String: Any]],
                  canForget(artifacts: artifacts, exists: exists)
            else { continue }
            names.insert(shortName(token))
        }
        return names
    }

    /// Makes Homebrew forget the cask `name` by deleting its folder in
    /// `caskroom`, and leaves its app where it is. The folder holds the cask
    /// file Homebrew installed from, and a link to each app it moved; the
    /// links are deleted, not what they point to. A folder that holds an app
    /// itself is refused, and nothing is deleted.
    static func forget(cask name: String, caskroom: URL, fileManager: FileManager = .default) throws {
        let short = shortName(name)
        guard isFolderName(short) else { throw ForgetError.badName(name) }
        let folder = caskroom.appendingPathComponent(short, isDirectory: true)
        let attributes = try? fileManager.attributesOfItem(atPath: folder.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else {
            throw ForgetError.notInstalled(short)
        }
        // The enumerator does not follow links, so it never reaches into
        // the apps they point to.
        let keys: [URLResourceKey] = [.isSymbolicLinkKey]
        if let items = fileManager.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let item as URL in items {
                if item.lastPathComponent == ".metadata" {
                    items.skipDescendants()
                    continue
                }
                let isLink = (try? item.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true
                if item.pathExtension == "app", !isLink {
                    throw ForgetError.holdsApp(cask: short, app: item.lastPathComponent)
                }
            }
        }
        try fileManager.removeItem(at: folder)
    }
}
