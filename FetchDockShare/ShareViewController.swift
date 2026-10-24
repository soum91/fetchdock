import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var loaded = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !loaded else { return }; loaded = true
        Task { await loadLinks() }
    }
    private func loadLinks() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var links: [URL] = []
        for provider in providers {
            let type: String
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { type = UTType.url.identifier }
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { type = UTType.plainText.identifier }
            else { continue }
            let value: NSSecureCoding? = await withCheckedContinuation { continuation in
                provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in continuation.resume(returning: item) }
            }
            if let url = value as? URL, DownloadItem.canDownload(url), DownloadItem.parseURL(url.absoluteString) != nil { links.append(url) }
            else if let text = value as? String, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                for result in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let url = result.url, DownloadItem.canDownload(url), DownloadItem.parseURL(url.absoluteString) != nil { links.append(url) }
                }
            }
        }
        var seen = Set<String>()
        links = links.filter { seen.insert($0.absoluteString).inserted }
        let host = UIHostingController(rootView: ShareDownloadView(links: links, finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }))
        addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
    }
}

private struct ShareDownloadView: View {
    let links: [URL]
    let finish: () -> Void
    @State private var selected = Set<URL>()
    @State private var message: String?
    @State private var started = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(started ? "Downloads started" : "Download with FetchDock", systemImage: started ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.headline).foregroundStyle(.mint)
                    Text("Choose direct file links. Sharing a normal page downloads its HTML. Signed-in browser cookies aren't included.").font(.footnote).foregroundStyle(.secondary)
                }
                if links.isEmpty { Text("No HTTPS download links were shared. In your browser, long-press the file link and choose Share.") }
                ForEach(links, id: \.self) { url in
                    Button {
                        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(url) ? "checkmark.circle.fill" : "circle")
                            Text(url.absoluteString).font(.subheadline).lineLimit(3)
                        }
                    }.disabled(started)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(started ? Color.mint : Color.orange).textSelection(.enabled) }
                if started { Text("The system transfer continues after you close this sheet. Open FetchDock to see progress and start its Live Activity.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("FetchDock").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(started ? "Done" : "Cancel", action: finish) }
                if !started {
                    ToolbarItem(placement: .confirmationAction) { Button("Download") { start() }.disabled(selected.isEmpty) }
                }
            }
            .onAppear { selected = Set(links) }
        }.tint(.mint).preferredColorScheme(.dark)
    }
    private func start() {
        var count = 0
        do {
            for url in links where selected.contains(url) { try SharedTransferCoordinator.shared.start(url); count += 1 }
            started = true; message = "Started \(count) download(s)."
        } catch { message = (count > 0 ? "Started \(count). " : "") + error.localizedDescription }
    }
}
