import SwiftUI

private enum Keys {
    static let brewfileBookmark = "bk_brewfileBookmark"
    static let legacyPath = "BrewfilePath"
}

@Observable
@MainActor
final class AppState {
    var showBrewfilePicker = false
    var availableUpdate: AvailableUpdate? = nil

    var brewfilePath: URL? {
        didSet {
            let ud = UserDefaults.standard
            if let url = brewfilePath {
                // App isn't sandboxed — plain bookmarks are enough to
                // remember the path across launches.
                if let bookmark = try? url.bookmarkData() {
                    ud.set(bookmark, forKey: Keys.brewfileBookmark)
                } else {
                    ud.removeObject(forKey: Keys.brewfileBookmark)
                }
            } else {
                ud.removeObject(forKey: Keys.brewfileBookmark)
            }
            ud.removeObject(forKey: Keys.legacyPath)
        }
    }

    /// Set to true if a saved bookmark was stale or unresolvable at launch.
    private(set) var brewfileBookmarkWasReset = false

    init() {
        let ud = UserDefaults.standard

        if let bookmark = ud.data(forKey: Keys.brewfileBookmark) {
            var isStale = false
            // Accept both formats — earlier builds saved security-scoped
            // bookmarks even though the app isn't sandboxed. Try plain
            // first, fall back to security-scoped for upgraders.
            let url = (try? URL(resolvingBookmarkData: bookmark,
                                relativeTo: nil,
                                bookmarkDataIsStale: &isStale))
                ?? (try? URL(resolvingBookmarkData: bookmark,
                             options: .withSecurityScope,
                             relativeTo: nil,
                             bookmarkDataIsStale: &isStale))
            if let url, !isStale {
                brewfilePath = url
            } else {
                ud.removeObject(forKey: Keys.brewfileBookmark)
                brewfileBookmarkWasReset = true
            }
        } else if let saved = ud.string(forKey: Keys.legacyPath) {
            // Migrate plain-path key to bookmark storage.
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.path) {
                brewfilePath = url  // didSet saves bookmark and removes legacyPath key
            } else {
                ud.removeObject(forKey: Keys.legacyPath)
            }
        }

        // Fallback: default mrk location
        if brewfilePath == nil {
            let def = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("mrk/Brewfile")
            if FileManager.default.fileExists(atPath: def.path) {
                brewfilePath = def
            }
        }
    }
}
