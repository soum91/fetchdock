import WidgetKit
import SwiftUI
import ActivityKit

@main
struct FetchDockActivityBundle: WidgetBundle {
    var body: some Widget { FetchDockActivity() }
}
struct FetchDockActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("FetchDock", systemImage: "arrow.down.circle.fill").font(.subheadline.bold()).foregroundStyle(.mint)
                    Spacer()
                    Text(context.state.status).font(.caption).foregroundStyle(.secondary)
                    if context.state.activeCount > 1 { Text("+\(context.state.activeCount - 1)").font(.caption.bold()).foregroundStyle(.mint) }
                }
                Text(context.state.filename).font(.headline).lineLimit(1)
                if context.state.expected > 0 { ProgressView(value: context.state.progress).tint(.mint) }
                HStack {
                    Text(context.state.sizeText)
                    Spacer()
                    if context.isStale { Text("Open to refresh") }
                    else { Text(context.state.status == "Downloading" ? context.state.speedText : context.state.status) }
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(17).activityBackgroundTint(Color(red: 0.035, green: 0.08, blue: 0.1))
            .activitySystemActionForegroundColor(.mint)
            .widgetURL(URL(string: "fetchdock://downloads"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("FetchDock", systemImage: "arrow.down.circle.fill").font(.caption.bold()).foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status == "Downloading" ? context.state.speedText : context.state.status).font(.caption.monospacedDigit()).foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.filename).font(.subheadline.weight(.medium)).lineLimit(1)
                        if context.state.expected > 0 { ProgressView(value: context.state.progress).tint(.mint) }
                        HStack {
                            Text(context.state.sizeText)
                            Spacer()
                            if context.state.activeCount > 1 { Text("\(context.state.activeCount) active") }
                            else if context.state.expected > 0 { Text("\(Int(context.state.progress * 100))%") }
                        }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.status == "Paused" ? "pause.fill" : "arrow.down").foregroundStyle(.mint)
            } compactTrailing: {
                Text(context.state.expected > 0 ? "\(Int(context.state.progress * 100))%" : "DL").font(.caption2.monospacedDigit()).foregroundStyle(.mint)
            } minimal: {
                if context.state.expected > 0 { ProgressView(value: context.state.progress).progressViewStyle(.circular).tint(.mint) }
                else { Image(systemName: "arrow.down").foregroundStyle(.mint) }
            }
            .keylineTint(.mint).widgetURL(URL(string: "fetchdock://downloads"))
        }
    }
}
