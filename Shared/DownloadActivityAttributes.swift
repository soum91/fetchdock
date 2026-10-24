import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var filename: String
        var received: Int64
        var expected: Int64
        var bytesPerSecond: Double
        var activeCount: Int
        var status: String
        var updatedAt: Date
        var progress: Double { expected > 0 ? min(1, max(0, Double(received) / Double(expected))) : 0 }
        var sizeText: String {
            let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
            guard expected > 0 else { return done }
            return done + " / " + ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        }
        var speedText: String {
            guard bytesPerSecond > 0, bytesPerSecond.isFinite else { return "Waiting" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        }
    }
    var title: String = "FetchDock"
}
