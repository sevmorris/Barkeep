import Foundation

struct MigratableApp: Identifiable {
    let id = UUID()
    let appName: String      // e.g. "Google Chrome"
    let caskToken: String    // e.g. "google-chrome"
    var selected: Bool = true
}
