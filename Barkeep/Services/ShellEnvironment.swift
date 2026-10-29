// Shared verbatim across the sibling app repos (Dipstick, Barkeep). Keep the
// copies byte-identical: scripts/check-shared.sh compares them and a release
// preflight fails when they drift. Anything one app needs on its own belongs
// in that app's files, not here.

import Foundation

/// The environment a new terminal window has, which is what mrk's scripts
/// expect to run in.
///
/// An app started from Finder or at login gets launchd's bare PATH. mrk's
/// scripts run with that find no Homebrew on PATH: sync falls back to the
/// system bash, the scripts look for gum, python3 and brew and do not find
/// them, and mrk-status reports ~/bin as missing from PATH when it is only
/// missing from the app's. So the app asks an interactive login zsh what it
/// sets up from ~/.zprofile and ~/.zshrc, and runs mrk's scripts with that.
///
/// Each app asks with its own process runner, in a `capture` of its own
/// beside that runner; what is here is the part that does not run anything.
enum ShellEnvironment {
    static let startMarker = "__MRK_SHELL_ENV_START__"
    static let endMarker = "__MRK_SHELL_ENV_END__"

    /// .zshrc can print to stdout as it loads (about 1.9 KB on the owner's
    /// Mac), so the dump sits between two markers. `env -0` ends each entry
    /// with a NUL, so a value that holds a newline survives. stdin is
    /// /dev/null, so anything .zshrc runs that waits for a terminal finds
    /// none: mrk's scripts/check-updates, which .zshrc runs, exits at once.
    static let script =
        "print -rn -- \(startMarker); /usr/bin/env -0; print -rn -- \(endMarker)"

    /// The directories a terminal on this Mac puts first, for when the shell
    /// cannot be asked.
    static func fallbackPath(home: String) -> String {
        [
            "\(home)/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
    }

    /// The app's own environment with the fallback PATH, and HOME.
    static func fallback(base: [String: String], home: String) -> [String: String] {
        var env = base
        env["HOME"] = home
        env["PATH"] = fallbackPath(home: home)
        return env
    }

    /// The variables between the markers, or nil when either marker is missing.
    static func parse(_ output: Data) -> [String: String]? {
        guard
            let start = output.range(of: Data(startMarker.utf8)),
            let end = output.range(of: Data(endMarker.utf8), in: start.upperBound..<output.endIndex)
        else { return nil }

        var env: [String: String] = [:]
        for entry in output[start.upperBound..<end.lowerBound].split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                  let eq = text.firstIndex(of: "="), eq != text.startIndex
            else { continue }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}
