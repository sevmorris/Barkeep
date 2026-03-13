import Foundation

struct AvailableUpdate: Sendable {
    let version: String
    let downloadURL: URL
}

actor UpdateChecker {
    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/sevmorris/Barkeep/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/sevmorris/Barkeep/releases")!

    func checkForUpdate() async -> AvailableUpdate? {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        else { return nil }

        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
        else { return nil }

        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard isNewer(remoteVersion, than: currentVersion) else { return nil }

        return AvailableUpdate(version: remoteVersion, downloadURL: releasesURL)
    }

    private func isNewer(_ remote: String, than current: String) -> Bool {
        let toInts = { (v: String) in v.split(separator: ".").compactMap { Int($0) } }
        let r = toInts(remote)
        let c = toInts(current)
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv != cv { return rv > cv }
        }
        return false
    }
}
