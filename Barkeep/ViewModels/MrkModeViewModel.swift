import SwiftUI

/// mrk mode for the open Brewfile: the drift sync reports, and the one place
/// Barkeep runs mrk's scripts from.
///
/// Every run goes through one queue, in order, so two scripts never edit the
/// Brewfile or the description table at once. While sync is rewriting the
/// Brewfile, `isWritingBrewfile` is set and BrewfileViewModel holds its own
/// writes back, because a save from Barkeep's copy of the file made before
/// sync ran would put back what sync just changed.
@Observable
@MainActor
final class MrkMode {
    private(set) var checkout: MrkCheckout?
    private(set) var candidates: [MrkCandidate] = []
    private(set) var isChecking = false
    private(set) var isBusy = false
    private(set) var isWritingBrewfile = false
    /// Why the last check failed, shown in place of the Untracked list.
    private(set) var checkError: String?

    /// Reloads Barkeep's copy of the Brewfile. Called when a command that
    /// can rewrite it finishes, before `isWritingBrewfile` is cleared, so no
    /// write from the old copy can slip in between.
    @ObservationIgnored var onBrewfileWritten: (@MainActor () -> Void)? = nil

    var isActive: Bool { checkout != nil }
    var additions: [MrkCandidate] { candidates.filter { $0.action == .add } }
    var prunes: [MrkCandidate] { candidates.filter { $0.action == .prune } }

    private let runner: MrkRunner
    private var tail: Task<Void, Never>?
    private var fixQueued = false

    init(runner: MrkRunner = MrkRunner()) {
        self.runner = runner
    }

    /// Turns mrk mode on for a Brewfile in an mrk checkout, and off for any
    /// other. The drift is read again by the next `refresh()`.
    func open(brewfile: URL?) {
        let next = brewfile.flatMap { MrkCheckout.containing(brewfile: $0) }
        guard next != checkout else { return }
        checkout = next
        candidates = []
        checkError = nil
    }

    func candidate(_ action: MrkCandidate.Action, name: String, kind: PackageKind) -> MrkCandidate? {
        candidates.first { $0.action == action && $0.name == name && $0.kind == kind }
    }

    /// Reads the drift again with `sync --check --details`.
    func refresh() async {
        await enqueue { await self.check() }
    }

    /// Runs one decision — add, ignore or prune — with its output in the
    /// console, then reads the drift again. Returns the error sync gave, or
    /// nil when it did what it was asked.
    @discardableResult
    func perform(_ command: MrkCommand, log: ProcessingLog) async -> Error? {
        var failure: Error?
        await enqueue {
            failure = await self.execute(command, log: log)
            await self.check()
        }
        return failure
    }

    /// After an edit Barkeep made to the Brewfile itself: describe what has
    /// no description, delete what no entry uses. A run already waiting in the
    /// queue covers every edit before it starts, so a burst of edits queues
    /// one run, not one each.
    func fixDescriptions(log: ProcessingLog) {
        guard isActive, !fixQueued else { return }
        fixQueued = true
        schedule {
            self.fixQueued = false
            _ = await self.execute(.fixDescriptions, log: log)
        }
    }

    /// Stops the script that is running.
    func cancel() {
        Task { await runner.cancel() }
    }

    /// Waits until every queued run is done.
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { break }
        }
    }

    // MARK: - Private

    /// Puts an operation at the end of the queue, at once: it starts when
    /// everything queued before it is done.
    @discardableResult
    private func schedule(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        await schedule(operation).value
    }

    private func check() async {
        guard let checkout else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            candidates = try await runner.check(checkout)
            checkError = nil
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func execute(_ command: MrkCommand, log: ProcessingLog) async -> Error? {
        guard let checkout else { return nil }
        isBusy = true
        isWritingBrewfile = command.writesBrewfile
        defer {
            if command.writesBrewfile { onBrewfileWritten?() }
            isBusy = false
            isWritingBrewfile = false
        }
        log.append(command.displayLine(in: checkout))

        // The lines arrive on the pipes' threads. A stream keeps them in the
        // order they came, and is drained before the outcome is logged.
        let (lines, sink) = AsyncStream.makeStream(of: (String, Bool).self)
        let console = Task { @MainActor in
            for await (line, fromStderr) in lines {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let level: LogLevel = text.hasPrefix("✗") ? .error : (fromStderr ? .verbose : .info)
                log.append(text, level: level)
            }
        }
        var failure: Error?
        do {
            try await runner.run(command, in: checkout) { line, fromStderr in
                sink.yield((line, fromStderr))
            }
        } catch {
            failure = error
        }
        sink.finish()
        await console.value

        if let failure {
            log.append("Error: \(failure.localizedDescription)", level: .error)
        } else {
            log.append("Done.")
        }
        return failure
    }
}
