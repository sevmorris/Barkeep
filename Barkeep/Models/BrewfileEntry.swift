import Foundation

// Lossless representation of a single line in the Brewfile
enum BrewfileNode {
    case comment(String)      // # Section header
    case blank                // empty line
    case entry(BrewfileEntry) // brew/cask/tap line
    case unknown(String)      // unrecognised line (mas, etc.) — preserved verbatim

    var rawLine: String {
        switch self {
        case .comment(let s): return s
        case .blank:          return ""
        case .entry(let e):   return e.rawLine
        case .unknown(let s): return s
        }
    }
}

struct BrewfileEntry: Identifiable, Hashable {
    /// Stable across reparse so SwiftUI selection survives a refresh.
    /// A Brewfile with two `brew "git"` lines is malformed; `add()` blocks
    /// duplicates and the parser only ever produces one entry per kind+name.
    var id: String { "\(kind.rawValue):\(name)" }

    var name: String
    var kind: PackageKind
    var section: String    // the comment header in effect when this entry was parsed
    var rawLine: String    // original text — used for write-back

    init(name: String, kind: PackageKind, section: String, rawLine: String) {
        self.name    = name
        self.kind    = kind
        self.section = section
        self.rawLine = rawLine
    }

    // Generate a canonical Brewfile line for new entries. `greedy` adds
    // `, greedy: true` to a cask line and is ignored for anything else.
    static func canonicalLine(name: String, kind: PackageKind, greedy: Bool = false) -> String {
        switch kind {
        case .formula: return #"brew "\#(name)""#
        case .cask:    return greedy ? #"cask "\#(name)", greedy: true"# : #"cask "\#(name)""#
        case .tap:     return #"tap "\#(name)""#
        }
    }

    /// True when the line carries `greedy: true`, so `brew upgrade` updates
    /// the cask even though the app updates itself.
    var isGreedy: Bool {
        rawLine.range(of: #",\s*greedy:\s*true\b"#, options: .regularExpression) != nil
    }
}
