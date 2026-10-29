// Shared verbatim across the sibling app repos (Dipstick, Barkeep). Keep the
// copies byte-identical: scripts/check-shared.sh compares them and a release
// preflight fails when they drift. Anything one app needs on its own belongs
// in that app's files, not here.

import Foundation

/// The rules mrk's lists share, as BIN-1 documents them.
///
/// The five --check modes (defaults.sh, dock-setup, sync, sync-login-items
/// and snapshot-prefs) print their lines by one contract, mrk's
/// mrk_check_line: one tab between two fields, and each field escaped. A
/// later mrk may add fields at the end of a line, and new words to a field
/// that has a fixed set of them; it never removes or reorders a field. So a
/// reader takes a line with at least the fields it knows, and passes over a
/// line whose word it does not know. mrk keeps the contract as data in
/// tests/fixtures/check-lines.json, and each app's tests read a copy.
///
/// Everything here works by Unicode scalar, not by Character. As Characters,
/// a carriage return and the newline after it are one, and so are an escape
/// and a combining mark after it: a reader by Character joined two lines at
/// a carriage return, which mrk does not escape, and passed over a field with
/// a tab or a backslash before an accent (sevmorris/mrk audit 22, Z-4, Z-5).
enum MrkText {
    /// A field of config/defaults.tsv, docs/defaults/descriptions.tsv or a
    /// line of any of the five --check modes, with its escapes undone: \t is
    /// a tab, \n a newline and \\ a backslash. nil for a backslash before
    /// anything else, which mrk never writes.
    static func unescape(_ field: Substring) -> String? {
        guard field.unicodeScalars.contains("\\") else { return String(field) }
        var out = String.UnicodeScalarView()
        var it = field.unicodeScalars.makeIterator()
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

    /// The fields of one line, split at every tab, each with its escapes
    /// undone. Two tabs in a row are an empty field. nil when a field has a
    /// bad escape.
    static func fields(_ line: Substring) -> [String]? {
        var fields: [String] = []
        for field in line.unicodeScalars.split(separator: "\t", omittingEmptySubsequences: false) {
            guard let text = unescape(Substring(field)) else { return nil }
            fields.append(text)
        }
        return fields
    }

    /// Whether a line of a list in config/ is an entry, by mrk_config_entries'
    /// rule: every line but one that starts with # and one that is empty or
    /// only white space. The line is taken as it stands, with nothing trimmed.
    static func isEntry(_ line: Substring) -> Bool {
        !line.hasPrefix("#") && !line.allSatisfy(\.isWhitespace)
    }

    /// The lines of a file's text, or of a check's output, without the
    /// newline that ends the last. It splits at every newline scalar.
    static func lines(_ text: String) -> [Substring] {
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(Substring.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Whether a check printed anything: a line with text in it. A check that
    /// did, and of which the app read no line, printed what this build of
    /// the app does not know. The app says so, and does not show an empty
    /// list, which would read as nothing to do.
    static func hasLines(_ text: String) -> Bool {
        lines(text).contains { !$0.isEmpty }
    }
}
