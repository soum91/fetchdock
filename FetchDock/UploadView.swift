import SwiftUI
import UniformTypeIdentifiers

struct UploadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @State private var importing = false
    @State private var fileURL: URL?
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            List {
                Section("New upload") {
                    Button {
                        importing = true
                    } label: {
                        Label(fileURL?.lastPathComponent ?? "Choose a file", systemImage: "doc.badge.plus")
                    }
                    TextField("HTTPS upload endpoint", text: $destination)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Start background upload", systemImage: "arrow.up.circle.fill") {
                        guard let fileURL, let url = URL(string: destination),
                              url.scheme?.lowercased() == "https" else {
                            manager.notice = "Enter an HTTPS upload endpoint."
                            return
                        }
                        manager.startUpload(file: fileURL, destination: url)
                        self.fileURL = nil
                    }
                    .disabled(fileURL == nil || destination.isEmpty)
                    Text("FetchDock stages the file locally, then iOS continues the file-backed upload while the app is suspended. The server must accept the request method and body format.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Uploads") {
                    if manager.uploadItems.isEmpty {
                        Text("No uploads yet. Choose a file and an HTTPS endpoint.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.uploadItems) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: item.state == .completed ? "checkmark.circle.fill" : "arrow.up.circle")
                                    .foregroundStyle(item.state == .failed ? .orange : .mint)
                                VStack(alignment: .leading) {
                                    Text(item.fileName).font(.subheadline.weight(.semibold))
                                    Text(item.destination.host ?? item.destination.absoluteString)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if [.running, .paused, .failed].contains(item.state) {
                                    Button {
                                        if item.state == .running { manager.pauseUpload(item.id) }
                                        else { manager.resumeUpload(item.id) }
                                    } label: {
                                        Image(systemName: item.state == .running ? "pause.fill" : "play.fill")
                                    }
                                }
                            }
                            if item.expected > 0 {
                                ProgressView(value: item.progress)
                            }
                            HStack {
                                Text(item.state.rawValue.capitalized)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.sent, countStyle: .file) +
                                     (item.expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: item.expected, countStyle: .file) : ""))
                            }.font(.caption2).foregroundStyle(.secondary)
                            if let error = item.error {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .swipeActions {
                            Button("Cancel", role: .destructive) { manager.cancelUpload(item.id) }
                        }
                    }
                }
            }
            .navigationTitle("Uploads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { fileURL = urls.first }
            }
        }
    }
}
