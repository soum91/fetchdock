import SwiftUI
import UIKit
import AppIntents

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == DownloadManager.parallelSessionIdentifier {
            DownloadManager.shared.parallel.backgroundCompletion = {
                Task { @MainActor in
                    await DownloadManager.shared.live.finishPendingUpdates()
                    completionHandler()
                }
            }
            DownloadManager.shared.parallel.connect()
            return
        }
        if identifier.hasPrefix(ShareStore.sessionPrefix) {
            _ = DownloadManager.shared
            SharedTransferCoordinator.shared.adopt(identifier) {
                Task { @MainActor in
                    DownloadManager.shared.importSharedTransfers()
                    await DownloadManager.shared.live.finishPendingUpdates()
                    completionHandler()
                }
            }
            return
        }
        guard identifier == DownloadManager.sessionIdentifier else { completionHandler(); return }
        DownloadManager.shared.backgroundCompletion = completionHandler
        DownloadManager.shared.connect()
    }
}

@main
struct FetchDockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var manager = DownloadManager.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(manager).tint(.mint)
                .onChange(of: scenePhase) { phase in
                    if phase == .active { manager.reconcile() }
                    else { manager.save() }
                }
        }
    }
}


/// App-only queue toggle for Apple's visible Control Center Shortcut control.
struct ToggleDownloadQueueShortcutIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Download Queue"

    @MainActor
    func perform() async throws -> some IntentResult {
        let manager = DownloadManager.shared
        let active = manager.items.contains { $0.status == .running || $0.status == .queued }
        if active { manager.pauseAll() } else { manager.resumeAll() }
        manager.save()
        await manager.live.finishPendingUpdates()
        return .result()
    }
}
struct FetchDockShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .teal

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDownloadQueueShortcutIntent(), phrases: [
            "Toggle downloads in \(.applicationName)",
        ], shortTitle: "Downloads", systemImageName: "arrow.down.circle.fill")
        AppShortcut(intent: AddFetchDockIntent(), phrases: [
            "Add a download in \(.applicationName)",
        ], shortTitle: "Add Download", systemImageName: "plus.circle.fill")
    }
}
