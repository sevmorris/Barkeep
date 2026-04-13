import Foundation

enum LogLevel {
    case info
    case verbose
    case error
}

struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    let level: LogLevel
}

@MainActor @Observable
final class ProcessingLog {
    var entries: [LogEntry] = []

    /// Filtered view: command lines, brew step headers, warnings, errors, and final status.
    var statusEntries: [LogEntry] {
        entries.filter { isStatusLine($0.message) }
    }

    func append(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(message: message, level: level))
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 900)
        }
    }

    func clear() {
        entries = []
    }

    // MARK: - Private

    private func isStatusLine(_ message: String) -> Bool {
        let m = message.trimmingCharacters(in: .whitespaces)
        return m.hasPrefix("$")            // command echo
            || m.hasPrefix("==>")          // brew step headers
            || m.hasPrefix("Error:")       // errors
            || m.hasPrefix("Warning:")     // warnings
            || m.hasPrefix("Already ")     // "Already installed."
            || m.contains("Successfully")  // success summaries
            || m == "Done."
    }
}
