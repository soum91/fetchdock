import SwiftUI
import WebKit

struct BrowserView: View {
    @EnvironmentObject private var manager: DownloadManager
    @StateObject private var model = BrowserModel()
    @State private var address = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.mint)
                    TextField("Search or enter website", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                        .submitLabel(.go).onSubmit { model.navigate(address) }
                    Button { model.navigate(address) } label: { Image(systemName: "arrow.right.circle.fill").font(.title2) }.accessibilityLabel("Go")
                }.padding(13).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15)).padding(.horizontal).padding(.bottom, 10)
                ZStack {
                    WebSurface(model: model)
                    if model.webView.url == nil {
                        VStack(spacing: 18) {
                            Image(systemName: "globe.americas.fill").font(.system(size: 55)).foregroundStyle(.mint)
                            Text("Browse. Tap. Fetch.").font(.title2.bold())
                            Text("Open a website and tap a download link. FetchDock catches file downloads automatically.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Text("For a direct file URL, use the download button below.").font(.caption).foregroundStyle(.secondary)
                        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
                    }
                    if model.loading { ProgressView().padding(15).background(.regularMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .top).padding(.top, 12) }
                }
                HStack {
                    Button { model.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canGoBack).accessibilityLabel("Back")
                    Spacer()
                    Button { model.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canGoForward).accessibilityLabel("Forward")
                    Spacer()
                    Button { model.downloadCurrentPage() } label: { Image(systemName: "arrow.down.to.line") }.disabled(model.webView.url == nil).accessibilityLabel("Download current URL")
                    Spacer()
                    Button { model.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                }.font(.title3).padding(.horizontal, 30).padding(.vertical, 15).background(.bar)
            }
            .navigationTitle("Browser").navigationBarTitleDisplayMode(.inline)
            .onAppear { model.onDownload = { url, headers in manager.enqueue(url, headers: headers) } }
            .onChange(of: model.address) { address = $0 }
            .alert("Browser", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
        }
    }
}

private struct WebSurface: UIViewRepresentable {
    @ObservedObject var model: BrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var address = ""
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var message: String?
    var onDownload: ((URL, [String: String]) -> Void)?
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
    }
    func navigate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = DownloadItem.parseURL(trimmed) { webView.load(URLRequest(url: url)) }
        else if !trimmed.contains(" "), trimmed.contains("."), let url = DownloadItem.parseURL("https://" + trimmed) { webView.load(URLRequest(url: url)) }
        else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components.url { webView.load(URLRequest(url: url)) }
        }
    }
    func downloadCurrentPage() { if let url = webView.url { capture(url) } }
    private func capture(_ url: URL, requestHeaders: [String: String] = [:]) {
        guard DownloadItem.parseURL(url.absoluteString) != nil else {
            message = "This link is not a direct HTTP download. Blob links and protected media streams need the website's own export option."
            return
        }
        guard DownloadItem.canDownload(url) else {
            message = "Use the site's HTTPS download link. FetchDock can browse HTTP pages, but remote file transfers require HTTPS."
            return
        }
        let referrer = webView.url?.absoluteString
        webView.evaluateJavaScript("navigator.userAgent") { userAgent, _ in
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let host = url.host?.lowercased() ?? ""
                let path = url.path.isEmpty ? "/" : url.path
                let applicable = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased()
                    let domainMatches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
                    let cookiePath = cookie.path
                    let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
                    return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
                }
                var headers = requestHeaders.filter { ["accept", "accept-language", "referer", "user-agent"].contains($0.key.lowercased()) }
                if !applicable.isEmpty { headers["Cookie"] = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] }
                if let referrer { headers["Referer"] = referrer }
                if let userAgent = userAgent as? String { headers["User-Agent"] = userAgent }
                self.onDownload?(url, headers)
                self.message = "Added to Downloads."
            }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            capture(url, requestHeaders: navigationAction.request.allHTTPHeaderFields ?? [:]); decisionHandler(.cancel)
        } else if ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") { decisionHandler(.allow) }
        else { decisionHandler(.cancel); message = "This link uses an unsupported URL scheme. Use a direct file download link." }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
        if navigationResponse.isForMainFrame && (!navigationResponse.canShowMIMEType || attachment), let url = navigationResponse.response.url {
            capture(url); decisionHandler(.cancel); loading = false
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; address = webView.url?.absoluteString ?? ""; canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false
        if (error as NSError).code != NSURLErrorCancelled { message = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }; return nil
    }
}
