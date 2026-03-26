import Foundation
import os.log

private let updateLog = Logger(subsystem: "io.github.sevmorris.Barkeep", category: "UpdateChecker")

struct AvailableUpdate: Sendable {
    let version: String
    let downloadURL: URL
}

actor UpdateChecker {
    static let shared = UpdateChecker()

    private let apiURL = URL(string: "https://api.github.com/repos/sevmorris/Barkeep/releases/latest")!
    private let releasesURL = URL(string: "https://github.com/sevmorris/Barkeep/releases")!

    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    func checkForUpdate() async -> AvailableUpdate? {
        do {
            guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
                updateLog.error("UpdateChecker: CFBundleShortVersionString missing from bundle")
                return nil
            }

            var request = URLRequest(url: apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, _) = try await urlSession.data(for: request)

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                updateLog.error("UpdateChecker: failed to parse JSON response")
                return nil
            }

            guard let tagName = json["tag_name"] as? String else {
                updateLog.error("UpdateChecker: tag_name missing from response")
                return nil
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            guard isNewer(remoteVersion, than: currentVersion) else { return nil }

            return AvailableUpdate(version: remoteVersion, downloadURL: releasesURL)
        } catch {
            updateLog.error("UpdateChecker: version check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
