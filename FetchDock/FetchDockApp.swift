import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
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
