import Foundation

struct MigratableApp: Identifiable, Hashable {
    var id: String { caskToken }
    let appName: String      // e.g. "Google Chrome"
    let caskToken: String    // e.g. "google-chrome"
    var selected: Bool = true

    static func == (lhs: MigratableApp, rhs: MigratableApp) -> Bool {
        lhs.caskToken == rhs.caskToken
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(caskToken)
    }
}
