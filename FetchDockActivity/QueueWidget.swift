import SwiftUI
import WidgetKit
import AppIntents
struct QueueEntry: TimelineEntry { var date: Date; var snapshot: QueueWidgetSnapshot? }
struct QueueProvider: TimelineProvider {
    func placeholder(in context: Context) -> QueueEntry { .init(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (QueueEntry) -> Void) { completion(.init(date: .now, snapshot: .load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QueueEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, snapshot: .load())], policy: .after(.now.addingTimeInterval(900))))
    }
}
struct FetchDockQueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: QueueWidgetSnapshot.kind, provider: QueueProvider()) { entry in
            QueueWidgetView(entry: entry).containerBackground(for: .widget) { Color.clear }
        }.configurationDisplayName("Download queue").description("Latest queue status. Use the Live Activity for ongoing progress.")
            .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct QueueWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: QueueEntry
    var body: some View {
        Group {
            if let s = entry.snapshot {
                if family == .accessoryInline { Text("FetchDock · \(s.active) active · \(s.paused) paused") }
                else if family == .accessoryCircular {
                    ZStack { AccessoryWidgetBackground(); VStack { Image(systemName: "arrow.down"); Text("\(s.active)").font(.headline) } }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.filename).font(.headline).lineLimit(1)
                        Text("\(s.active) active · \(s.paused) paused").font(.caption)
                        if s.expected > 0 { ProgressView(value: min(1, max(0, Double(s.received) / Double(s.expected)))) }
                        if family == .systemSmall {
                            Button(intent: queueIntent(s.active == 0)) { Label(s.active > 0 ? "Pause queue" : "Resume queue", systemImage: s.active > 0 ? "pause.fill" : "play.fill") }.buttonStyle(.bordered)
                        }
                        Text("Updated \(s.updatedAt, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else { Label("Open FetchDock", systemImage: "arrow.down.circle").font(.caption) }
        }.widgetURL(URL(string: "fetchdock://downloads"))
    }
    func queueIntent(_ value: Bool) -> SetQueueRunningIntent { var i = SetQueueRunningIntent(); i.value = value; return i }
}
struct QueueControlProvider: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { (QueueWidgetSnapshot.load()?.active ?? 0) > 0 }
}
struct FetchDockQueueControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.fetchdock.queue", provider: QueueControlProvider()) { on in
            ControlWidgetToggle("Download queue", isOn: on, action: SetQueueRunningIntent()) { Label($0 ? "Running" : "Paused", systemImage: $0 ? "arrow.down.circle.fill" : "pause.circle") }
        }.displayName("Pause/resume downloads").description("Pause active transfers or resume paused and failed transfers.")
    }
}
struct FetchDockOpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.soum91.fetchdock.open") {
            ControlWidgetButton(action: OpenFetchDockIntent()) { Label("Downloads", systemImage: "arrow.down.circle") }
        }.displayName("Open downloads").description("Open FetchDock to add links or manage downloads.")
    }
}
