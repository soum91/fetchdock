import SwiftUI
import QuickLook
import ActivityKit

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var adding = false
    @State private var query = ""
    @State private var filter = 0
    @State private var selectedTab = 0
    @State private var preview: PreviewFile?
    @State private var sharing: PreviewFile?
    @State private var deleting: DownloadItem?
    private let ink = Color(red: 0.04, green: 0.08, blue: 0.12)
    private var filtered: [DownloadItem] {
        manager.items.filter { item in
            (filter == 0 || (filter == 1 && item.status != .completed) || (filter == 2 && item.status == .completed)) &&
            (query.isEmpty || item.filename.localizedCaseInsensitiveContains(query) || (item.url.host ?? "").localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        summary
                        Picker("Show downloads", selection: $filter) {
                            Text("All").tag(0); Text("Transfers").tag(1); Text("Files").tag(2)
                        }.pickerStyle(.segmented)
                        if manager.restoring {
                            ProgressView("Reconnecting to downloads…").frame(maxWidth: .infinity).padding(50)
                        } else if filtered.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filtered) { item in
                                    DownloadRow(item: item,
                                        pause: { manager.pause(item.id) }, resume: { manager.resume(item.id) },
                                        open: { if let url = manager.fileURL(item) { preview = PreviewFile(url: url) } },
                                        share: { if let url = manager.fileURL(item) { sharing = PreviewFile(url: url) } },
                                        delete: { deleting = item })
                                }
                            }
                        }
                    }.padding(20)
                }
                .background(ink.ignoresSafeArea())
                .navigationTitle("FetchDock")
                .searchable(text: $query, prompt: "Find files or hosts")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button("Pause all", systemImage: "pause.fill", action: manager.pauseAll)
                            Button("Resume all", systemImage: "play.fill", action: manager.resumeAll)
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { adding = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                            .accessibilityLabel("Add download")
                    }
                }
            }.tabItem { Label("Downloads", systemImage: "arrow.down.circle") }.tag(0)
            UploadView().tabItem { Label("Uploads", systemImage: "arrow.up.circle") }.tag(1)
            BrowserView().tabItem { Label("Browser", systemImage: "globe") }.tag(2)
            SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .onOpenURL { url in
            guard url.scheme == "fetchdock" else { return }
            selectedTab = 0
            if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value {
                manager.addLinks(value)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $adding) { AddDownloadView() }
        .onReceive(manager.$showAddDownload) { requested in
            if requested { adding = true; manager.showAddDownload = false }
        }
        .sheet(item: $preview) { file in FilePreview(url: file.url).ignoresSafeArea() }
        .sheet(item: $sharing) { file in ShareSheet(url: file.url) }
        .confirmationDialog("Delete \(deleting?.filename ?? "download")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete download and file", role: .destructive) {
                if let deleting { manager.remove(deleting.id) }; deleting = nil
            }
        }
        .alert("FetchDock", isPresented: Binding(get: { manager.notice != nil }, set: { if !$0 { manager.notice = nil } })) {
            Button("OK") { manager.notice = nil }
        } message: { Text(manager.notice ?? "") }
    }
    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(manager.activeCount == 0 ? "READY WHEN YOU ARE" : "DOWNLOADS IN MOTION", systemImage: "arrow.down.to.line.compact")
                    .font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.mint)
                Spacer()
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.mint.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(manager.totalSpeed > 0 ? ByteCountFormatter.string(fromByteCount: Int64(manager.totalSpeed), countStyle: .file) : "Let's fetch.")
                    .font(.system(size: 35, weight: .bold, design: .rounded)).contentTransition(.numericText())
                if manager.totalSpeed > 0 { Text("/s").font(.title3).foregroundStyle(.secondary) }
            }
            HStack(spacing: 20) {
                Label("\(manager.activeCount) active", systemImage: "arrow.down")
                Label("\(manager.items.filter { $0.status == .completed }.count) saved", systemImage: "checkmark.circle")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.mint.opacity(0.13), Color.cyan.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.mint.opacity(0.18)))
    }
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == 2 ? "folder" : "tray.and.arrow.down").font(.system(size: 48, weight: .light)).foregroundStyle(.mint)
            Text(query.isEmpty ? (filter == 2 ? "Your files land here" : "Your next download starts here") : "No matching downloads")
                .font(.headline)
            Text("Paste a direct file link or use the browser. Follow your transfers from the Lock Screen.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { adding = true } label: { Label("Add download", systemImage: "plus").padding(.horizontal, 14).padding(.vertical, 5) }
                .buttonStyle(.borderedProminent).foregroundStyle(.black)
        }.padding(.vertical, 48).frame(maxWidth: .infinity)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let pause: () -> Void
    let resume: () -> Void
    let open: () -> Void
    let share: () -> Void
    let delete: () -> Void
    private var symbol: String {
        switch item.url.pathExtension.lowercased() {
        case "mp4", "mkv", "mov", "webm": return "film"
        case "mp3", "flac", "m4a", "wav": return "waveform"
        case "zip", "rar", "7z", "ipa", "apk": return "shippingbox"
        case "png", "jpg", "jpeg", "heic": return "photo"
        default: return "doc"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.mint)
                    .frame(width: 44, height: 48).background(.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.filename).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(item.url.host ?? "Download").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let count = item.connections, count > 1 {
                        Text("FetchDock • \(count) connections").font(.caption2).foregroundStyle(.mint)
                    }
                }
                Spacer(minLength: 2)
                if item.status == .running || item.status == .queued {
                    Button(action: pause) { Image(systemName: "pause.fill").frame(width: 32, height: 36) }.accessibilityLabel("Pause \(item.filename)")
                } else if item.status == .paused || item.status == .failed {
                    Button(action: resume) { Image(systemName: "play.fill").frame(width: 32, height: 36) }.accessibilityLabel("Resume \(item.filename)")
                } else if item.status == .completed {
                    Button(action: open) { Image(systemName: "arrow.up.right").frame(width: 32, height: 36) }.accessibilityLabel("Open \(item.filename)")
                } else { ProgressView() }
            }
            if item.status != .completed {
                if item.expected > 0 { ProgressView(value: item.progress).tint(item.status == .failed ? .orange : .mint) }
                else if item.status == .running { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                Text(item.status == .running && item.speed > 0 ? ByteCountFormatter.string(fromByteCount: Int64(item.speed), countStyle: .file) + "/s" : item.status.title)
                    .foregroundStyle(item.status == .failed ? .orange : .mint)
                Spacer(minLength: 5)
                if let remaining = item.remaining, item.status == .running { Text(remaining) }
                Text(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file) + (item.expected > 0 && item.status != .completed ? " / " + ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file) : ""))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(16).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            if item.status == .completed { Button("Open", systemImage: "doc", action: open); Button("Share / Save to Files", systemImage: "square.and.arrow.up", action: share) }
            if [.running, .queued].contains(item.status) { Button("Pause", systemImage: "pause", action: pause) }
            if [.paused, .failed].contains(item.status) { Button("Resume", systemImage: "play", action: resume) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = item.url }
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

private struct AddDownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var links = ""
    private var valid: Bool {
        let values = links.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !values.isEmpty && values.allSatisfy { value in DownloadItem.parseURL(value).map { DownloadItem.canDownload($0) } ?? false }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Download links") {
                    TextEditor(text: $links).frame(minHeight: 150).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Paste links", systemImage: "doc.on.clipboard") { links = UIPasteboard.general.string ?? "" }
                }
                Section {
                    Text("One HTTPS link per line. For sites requiring sign-in, use Browser and tap the site's download link.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New download").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Download") { manager.addLinks(links); dismiss() }.disabled(!valid) }
            }
        }
    }
}

struct PreviewFile: Identifiable { let id = UUID(); let url: URL }
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct FilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage("liveActivities") private var liveActivities = true
    @AppStorage("allowsCellular") private var cellular = true
    @AppStorage("concurrentDownloads") private var concurrent = 3
    @AppStorage("connectionsPerFile") private var connections = 4
    var body: some View {
        NavigationStack {
            Form {
                Section("Transfers") {
                    Stepper("Simultaneous downloads: \(concurrent)", value: $concurrent, in: 1...6)
                    Stepper("Connections per file: \(connections)", value: $connections, in: 1...8)
                    Text("Splits supported files into parallel segments. Servers must support byte ranges and provide a strong file validator; otherwise FetchDock uses one connection.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Allow cellular for new downloads", isOn: $cellular)
                    Text("Pause and retry a transfer to apply a new cellular preference. Resume data may retain the original network policy.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Live Activity") {
                    Toggle("Lock Screen & Dynamic Island", isOn: $liveActivities)
                    Label(ActivityAuthorizationInfo().areActivitiesEnabled ? "Allowed by iOS" : "Disabled in iOS Settings", systemImage: "livephoto")
                    if let error = manager.live.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Text("Shows the current file, progress and speed. iOS controls updates while FetchDock is suspended, so the display may temporarily show older progress. Tap it to return to Downloads.").font(.caption).foregroundStyle(.secondary)
                    Button("Open iOS Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Section("Browser integration") {
                    Label("Safari Companion extension included", systemImage: "safari")
                    Text("Enable FetchDock Companion in iOS Settings > Apps > Safari > Extensions. Allow it on the sites you want to use. Its menu lists file links and can catch download links on sites you enable.").font(.caption).foregroundStyle(.secondary)
                    Label("Download with FetchDock share extension", systemImage: "square.and.arrow.up")
                    Text("In Safari, Chrome or Reynard, share a file link and choose Download with FetchDock. Shared downloads need compatible App Group signing. Open FetchDock to start its Live Activity.").font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Shared storage", value: (try? ShareStore.appGroup()) != nil ? "Available" : "Check signing")
                }
                Section("Files & privacy") {
                    Text("Downloads are saved on this iPhone under Files > On My iPhone > FetchDock > Downloads. Long-press a completed file to share it or save it elsewhere.")
                    Text("Links and browser download cookies stay on this device. No FetchDock account, analytics or server. Remote file downloads require HTTPS; the browser can still open HTTP pages.")
                }.font(.footnote)
                Section("FetchDock") {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                    Text("Background transfers use iOS URLSession. Force-quitting FetchDock cancels background transfers until you reopen it. Segmented transfers keep completed chunks when paused; unfinished chunks restart on resume. Share-sheet transfers currently use one connection.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings")
                .onChange(of: liveActivities) { _ in manager.settingsChanged() }
                .onChange(of: concurrent) { _ in manager.settingsChanged() }
                .onChange(of: cellular) { _ in manager.settingsChanged() }
        }
    }
}
