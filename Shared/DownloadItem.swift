import Foundation

enum DownloadStatus: String, Codable {
    case queued, running, pausing, paused, failed, completed
    var title: String { rawValue.capitalized }
}

struct DownloadItem: Codable, Identifiable {
    var id = UUID()
    var url: URL
    var filename: String
    var createdAt = Date()
    var status: DownloadStatus = .queued
    var received: Int64 = 0
    var expected: Int64 = 0
    var relativePath: String?
    var sharedSessionID: String?
    var error: String?
    var headers: [String: String] = [:]
    // Ephemeral values deliberately excluded from persistence.
    var speed: Double = 0
    var progress: Double { expected > 0 ? min(1, max(0, Double(received) / Double(expected))) : 0 }
    var remaining: String? {
        guard speed > 0, expected > received else { return nil }
        let seconds = Double(expected - received) / speed
        guard seconds.isFinite, seconds < 86400 * 365 else { return nil }
        let value = Int(seconds)
        return value >= 3600 ? "\(value / 3600)h \(value % 3600 / 60)m left" : value >= 60 ? "\(value / 60)m \(value % 60)s left" : "\(value)s left"
    }
    enum CodingKeys: String, CodingKey {
        case id, url, filename, createdAt, status, received, expected, relativePath, sharedSessionID, error, headers
    }
    static func safeName(_ proposed: String) -> String {
        let clean = proposed.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "Download" : String(clean.prefix(180))
    }
    static func canDownload(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        // Loopback is useful for local tools and integration tests; other remote files require TLS.
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
    static func parseURL(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
