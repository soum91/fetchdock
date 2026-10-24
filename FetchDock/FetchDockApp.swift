import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
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
