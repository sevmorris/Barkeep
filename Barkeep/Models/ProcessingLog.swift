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

    func append(_ message: String, level: LogLevel = .info) {
        entries.append(LogEntry(message: message, level: level))
        if entries.count > 1000 {
            entries.removeFirst(entries.count - 900)
        }
    }

    func clear() {
        entries = []
    }
}
