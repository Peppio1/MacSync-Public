import Foundation

/// Stable-only discovery. The GitHub API is an informational channel,
/// NOT a trust root for installing executable code.
public struct StableUpdateRelease: Decodable, Equatable, Sendable {
    public let tagName: String
    public let prerelease: Bool
    public let draft: Bool
    public let body: String?
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", prerelease, draft, body
    }
    public var pageURL: URL? {
        guard Self.version(tagName) != nil else { return nil }
        return URL(string: "https://github.com/Peppio1/MacSync-Public/releases/tag/\(tagName)")
    }

    /// Only three-component numeric versions are accepted. No suffix,
    /// downgrade, leading zero, path separator, or unbounded integer.
    public static func version(_ raw: String) -> [Int]? {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0",
                  let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    public func isNewer(than installed: String) -> Bool {
        guard !draft, !prerelease, let candidate = Self.version(tagName),
              let current = Self.version(installed) else { return false }
        return current.lexicographicallyPrecedes(candidate)
    }
}

public enum UpdateCheckResult: Equatable, Sendable {
    case noStableRelease
    case current
    case available(StableUpdateRelease)
}

public enum StableUpdateDiscovery {
    public enum DiscoveryError: LocalizedError {
        case unexpectedResponse, invalidRelease, serviceUnavailable(Int), tooLarge
        public var errorDescription: String? {
            switch self {
            case .unexpectedResponse: return "Risposta del servizio aggiornamenti non valida."
            case .invalidRelease: return "Metadati della versione non validi."
            case .serviceUnavailable(let status): return "Servizio aggiornamenti non disponibile (HTTP \(status))."
            case .tooLarge: return "Risposta del servizio aggiornamenti troppo grande."
            }
        }
    }
    public static let endpoint = URL(string: "https://api.github.com/repos/Peppio1/MacSync-Public/releases/latest")!
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= interval
    }

    public static func interpret(status: Int, data: Data, installed: String) throws -> UpdateCheckResult {
        // GitHub returns 404 when a public repo has no stable release.
        // This is not evidence that the installed version is up to date.
        if status == 404 { return .noStableRelease }
        guard status == 200 else { throw DiscoveryError.serviceUnavailable(status) }
        guard data.count <= 512 * 1024 else { throw DiscoveryError.tooLarge }
        let release = try JSONDecoder().decode(StableUpdateRelease.self, from: data)
        guard StableUpdateRelease.version(installed) != nil,
              StableUpdateRelease.version(release.tagName) != nil,
              !release.draft, !release.prerelease else { throw DiscoveryError.invalidRelease }
        return release.isNewer(than: installed) ? .available(release) : .current
    }

    public static func check(installed: String) async throws -> UpdateCheckResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacSync/updates", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.url == endpoint else { throw DiscoveryError.unexpectedResponse }
        return try interpret(status: response.statusCode, data: data, installed: installed)
    }
}
