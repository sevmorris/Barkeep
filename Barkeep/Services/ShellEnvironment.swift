import Foundation

/// The environment a new terminal window has, which is what mrk's scripts
/// expect to run in.
///
/// An app started from Finder or at login gets launchd's bare PATH. mrk's
/// sync run with that finds no Homebrew bash, and its scripts look for gum,
/// python3 and brew on PATH. So Barkeep asks an interactive login zsh what it
/// sets up from ~/.zprofile and ~/.zshrc, and runs the scripts with that.
/// Dipstick does the same for mrk-status, and this is its approach.
enum ShellEnvironment {
    static let startMarker = "__BARKEEP_ENV_START__"
    static let endMarker = "__BARKEEP_ENV_END__"

    /// .zshrc can print to stdout as it loads, so the dump sits between two
    /// markers. `env -0` ends each entry with a NUL, so a value that holds a
    /// newline survives. stdin is /dev/null, so anything .zshrc runs that
    /// waits for a terminal finds none.
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

    /// Barkeep's own environment with the fallback PATH.
    static func fallback(base: [String: String], home: String) -> [String: String] {
        var env = base
        env["PATH"] = fallbackPath(home: home)
        env["HOME"] = home
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

    /// Asks the shell, or returns nil when it fails, hangs past `timeout`, or
    /// prints no markers.
    static func capture(
        shell: URL = URL(fileURLWithPath: "/bin/zsh"),
        timeout: Duration = .seconds(15)
    ) async -> [String: String]? {
        guard let result = try? await ScriptProcess.run(
            shell,
            arguments: ["-i", "-l", "-c", script],
            timeout: timeout
        ), !result.timedOut else { return nil }
        return parse(result.stdout)
    }
}
