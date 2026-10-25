#if FETCHDOCK_APP || FETCHDOCK_WIDGET
import AppIntents
import Foundation

struct SetQueueRunningIntent: SetValueIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Run Download Queue"
    @Parameter(title: "Running") var value: Bool
    @MainActor func perform() async throws -> some IntentResult {
        #if FETCHDOCK_APP
        let manager = DownloadManager.shared
        if value { manager.resumeAll() } else { manager.pauseAll() }
        manager.save()
        await manager.live.finishPendingUpdates()
        #endif
        return .result()
    }
}
struct OpenFetchDockIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Downloads"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}
struct AddFetchDockIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Download"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        #if FETCHDOCK_APP
        DownloadManager.shared.showAddDownload = true
        #endif
        return .result()
    }
}
#endif
