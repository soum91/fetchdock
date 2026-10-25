import Foundation
import WidgetKit

struct QueueWidgetSnapshot: Codable {
    var filename: String
    var active: Int
    var paused: Int
    var received: Int64
    var expected: Int64
    var speed: Double
    var updatedAt: Date
    static let kind = "FetchDockQueue"
    static func load() -> QueueWidgetSnapshot? {
        guard let d = UserDefaults(suiteName: ShareStore.groupID)?.data(forKey: "queue.widget") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: d)
    }
    static func publish(_ items: [DownloadItem]) {
        let pending = items.filter { [.running, .queued, .pausing, .paused].contains($0.status) }
        let first = pending.first { $0.status == .running } ?? pending.first
        let snapshot = Self(filename: first?.filename ?? "No active downloads",
                            active: pending.filter { [.running, .queued, .pausing].contains($0.status) }.count,
                            paused: pending.filter { $0.status == .paused }.count,
                            received: first?.received ?? 0, expected: first?.expected ?? 0,
                            speed: first?.speed ?? 0, updatedAt: .now)
        let old = load()
        if let data = try? JSONEncoder().encode(snapshot) { UserDefaults(suiteName: ShareStore.groupID)?.set(data, forKey: "queue.widget") }
        let defaults = UserDefaults(suiteName: ShareStore.groupID)
        let reloadedAt = defaults?.object(forKey: "queue.widgetReloadAt") as? Date ?? .distantPast
        if let old, snapshot.updatedAt.timeIntervalSince(reloadedAt) < 15, snapshot.active == old.active, snapshot.paused == old.paused { return }
        defaults?.set(snapshot.updatedAt, forKey: "queue.widgetReloadAt")
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
    }
}
