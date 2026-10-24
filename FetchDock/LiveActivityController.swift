import ActivityKit
import UIKit

@MainActor
final class LiveActivityController {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var pendingUpdate: Task<Void, Never>?
    var error: String?
    var enabled: Bool { UserDefaults.standard.object(forKey: "liveActivities") as? Bool ?? true }

    func finishPendingUpdates() async { await pendingUpdate?.value }

    func refresh(_ items: [DownloadItem], force: Bool = false) {
        let active = items.filter { [.running, .queued, .pausing, .paused].contains($0.status) }
        activity = activity ?? Activity<DownloadActivityAttributes>.activities.first
        // Clean up duplicate activities left by interrupted launches.
        for extra in Activity<DownloadActivityAttributes>.activities where extra.id != activity?.id {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        guard enabled, !active.isEmpty else {
            if let old = activity {
                activity = nil
                pendingUpdate = Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let item = active.first(where: { $0.status == .running }) ?? active[0]
        let running = active.filter { $0.status == .running }
        let state = DownloadActivityAttributes.ContentState(filename: item.filename, received: item.received,
            expected: item.expected, bytesPerSecond: item.speed, activeCount: running.count,
            status: running.isEmpty ? (active.allSatisfy { $0.status == .paused } ? "Paused" : "Queued") : "Downloading",
            updatedAt: Date())
        if activity == nil {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                error = "Live Activities are disabled in iOS Settings for FetchDock."
                return
            }
            guard UIApplication.shared.applicationState == .active else { return }
            do {
                activity = try Activity.request(attributes: DownloadActivityAttributes(), content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(20)), pushType: nil)
                error = nil
            } catch { self.error = error.localizedDescription }
        } else if force || Date().timeIntervalSince(lastUpdate) >= 2 {
            lastUpdate = Date()
            if let current = activity { pendingUpdate = Task { await current.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(20))) } }
        }
    }
}
