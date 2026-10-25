import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 18.0, *)
struct FetchDockAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.fetchdock.FetchDockAddControl") {
            ControlWidgetButton(action: AddFetchDockIntent()) { Label("Add download", systemImage: "plus.circle") }
        }.displayName("Add download").description("Add download")
    }
}
