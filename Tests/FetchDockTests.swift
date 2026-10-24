import XCTest
import WebKit
@testable import FetchDock

final class FetchDockTests: XCTestCase {
    @MainActor
    func testTypedExtensionlessDownloadUsesSavedHTTPOnlySession() async throws {
        let model = BrowserModel(websiteDataStore: .nonPersistent())
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "user_session", .value: "fixture-session",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE"
        ]))
        await model.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let captured = expectation(description: "Authenticated redirect reaches the queue")
        model.onDownload = { url, headers in
            XCTAssertEqual(url.path, "/file")
            XCTAssertTrue(headers["Cookie"]?.contains("user_session=fixture-session") == true)
            captured.fulfill()
        }
        // No host rule and no filename extension: the response identifies a file.
        model.navigate("http://127.0.0.1:8765/private-release")
        await fulfillment(of: [captured], timeout: 45)
    }
    @MainActor
    func testBrowserRedirectDoesNotLeakCookieToAnotherHost() async throws {
        let model = BrowserModel(websiteDataStore: .nonPersistent())
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "user_session", .value: "fixture-session"
        ]))
        await model.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let captured = expectation(description: "Cross-host redirect keeps cookies scoped")
        model.onDownload = { url, headers in
            XCTAssertEqual(url.host, "localhost")
            XCTAssertEqual(url.path, "/no-cookies")
            XCTAssertNil(headers["Cookie"])
            captured.fulfill()
        }
        // The destination returns 403 if the source's Cookie header is forwarded.
        model.navigate("http://127.0.0.1:8765/redirect-other-host")
        await fulfillment(of: [captured], timeout: 45)
        print("Cross-host browser result:", model.webView.url?.absoluteString ?? "none", model.message ?? "no browser error")
    }
    @MainActor
    func testSessionCookiesStayWithinTheirScopes() throws {
        let url = URL(string: "https://files.example.com/account/download")!
        func cookie(_ name: String, _ domain: String, _ path: String, secure: Bool = true, expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "fixture", .domain: domain, .path: path]
            if secure { properties[.secure] = "TRUE" }
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let cookies = try [cookie("session", ".example.com", "/"), cookie("wrongSite", "another.example", "/"),
                           cookie("wrongPath", "files.example.com", "/accounts"), cookie("rightPath", "files.example.com", "/account"),
                           cookie("expired", "files.example.com", "/", expires: Date(timeIntervalSinceNow: -3600))]
        let headers = BrowserModel.sessionHeaders(for: url, cookies: cookies, requestHeaders: ["Cookie": "untrusted", "Authorization": "untrusted"])
        let header = try XCTUnwrap(headers["Cookie"])
        XCTAssertTrue(header.contains("session=fixture"))
        XCTAssertTrue(header.contains("rightPath=fixture"))
        XCTAssertFalse(header.contains("wrong"))
        XCTAssertFalse(header.contains("expired"))
        XCTAssertFalse(header.contains("untrusted"))
        XCTAssertNil(headers["Authorization"])
        for link in ["https://cdn.other.example/file", "https://files.example.com.evil.test/file", "http://files.example.com/file"] {
            XCTAssertNil(BrowserModel.sessionHeaders(for: URL(string: link)!, cookies: cookies)["Cookie"])
        }
    }
    @MainActor
    func testBrowserCookieAuthenticatesTransferAndRedirect() async throws {
        let manager = makeManager()
        defer { for item in manager.items { manager.remove(item.id) } }
        for _ in 0..<100 where manager.restoring { try await Task.sleep(nanoseconds: 100_000_000) }
        let url = URL(string: "http://127.0.0.1:8765/private-release")!
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "user_session", .value: "fixture-session"]))
        manager.enqueue(url, headers: BrowserModel.sessionHeaders(for: url, cookies: [cookie]))
        let id = try XCTUnwrap(manager.items.first?.id)
        for _ in 0..<150 {
            if let item = manager.items.first(where: { $0.id == id }), [.completed, .failed].contains(item.status) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let item = try XCTUnwrap(manager.items.first(where: { $0.id == id }))
        XCTAssertEqual(item.status, .completed, item.error ?? "Authenticated transfer failed")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(manager.fileURL(item))), Data(repeating: 70, count: 524288))
        XCTAssertTrue(item.headers.isEmpty, "Discard session headers after completion")
    }
    @MainActor
    private func makeManager() -> DownloadManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DownloadManager(sessionConfiguration: .default, storageDirectory: root.appendingPathComponent("State"), downloadsDirectory: root.appendingPathComponent("Downloads"))
    }
    func testOnlyHTTPLinksCanBecomeDownloads() {
        XCTAssertNotNil(DownloadItem.parseURL("https://example.com/archive.zip?token=abc"))
        XCTAssertNotNil(DownloadItem.parseURL(" http://localhost:8765/file \n"))
        for link in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/file", "blob:https://example.com/id", "https://", "not a url"] {
            XCTAssertNil(DownloadItem.parseURL(link), link)
        }
    }
    func testRemoteDownloadsRequireTLS() {
        XCTAssertTrue(DownloadItem.canDownload(URL(string: "https://example.com/file")!))
        XCTAssertTrue(DownloadItem.canDownload(URL(string: "http://127.0.0.1:8765/file")!))
        XCTAssertFalse(DownloadItem.canDownload(URL(string: "http://example.com/file")!))
        XCTAssertFalse(DownloadItem.canDownload(URL(string: "http://localhost.example.com/file")!))
    }
    func testServerFilenameCannotEscapeDownloadDirectory() {
        for name in ["../../secret", "../..", "/tmp/file", "..\\..\\file", "\n", ".", "..", ""] {
            let safe = DownloadItem.safeName(name)
            XCTAssertFalse(safe.contains("/"))
            XCTAssertFalse(safe.contains("\\"))
            XCTAssertFalse(safe.contains("\n"))
            XCTAssertFalse(["", ".", ".."].contains(safe))
        }
        XCTAssertEqual(DownloadItem.safeName("Movie (2026).mp4"), "Movie (2026).mp4")
    }
    func testPersistenceKeepsIdentityAndDropsTransientSpeed() throws {
        var item = DownloadItem(url: URL(string: "https://example.com/file.zip")!, filename: "file.zip")
        item.status = .paused; item.received = 123; item.expected = 456; item.speed = 900
        item.headers = ["Cookie": "session=test"]
        let restored = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.received, 123)
        XCTAssertEqual(restored.headers, item.headers)
        XCTAssertEqual(restored.speed, 0)
    }
    @MainActor
    func testDownloadSavesFileAndHTTPFailureDoesNot() async throws {
        let manager = makeManager()
        for _ in 0..<100 where manager.restoring { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(manager.restoring)
        for item in manager.items { manager.remove(item.id) }
        manager.enqueue(URL(string: "http://127.0.0.1:8765/file")!)
        let id = try XCTUnwrap(manager.items.first?.id)
        for _ in 0..<200 {
            if manager.items.first(where: { $0.id == id })?.status == .completed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let saved = try XCTUnwrap(manager.items.first(where: { $0.id == id }))
        XCTAssertEqual(saved.status, .completed, saved.error ?? "Download did not finish")
        let file = try XCTUnwrap(manager.fileURL(saved))
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 70, count: 524288))
        manager.remove(id)
        manager.enqueue(URL(string: "http://127.0.0.1:8765/missing")!)
        let badID = try XCTUnwrap(manager.items.first?.id)
        for _ in 0..<150 {
            if manager.items.first(where: { $0.id == badID })?.status == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let failed = try XCTUnwrap(manager.items.first(where: { $0.id == badID }))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("404") == true)
        XCTAssertNil(manager.fileURL(failed))
        manager.remove(badID)
    }
    @MainActor
    func testPauseLeavesTransferPausedUntilExplicitResume() async throws {
        let manager = makeManager()
        for _ in 0..<100 where manager.restoring { try await Task.sleep(nanoseconds: 100_000_000) }
        manager.enqueue(URL(string: "http://127.0.0.1:8765/slow")!)
        let id = try XCTUnwrap(manager.items.first?.id)
        for _ in 0..<100 {
            if (manager.items.first(where: { $0.id == id })?.received ?? 0) > 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        manager.pause(id)
        for _ in 0..<100 {
            if manager.items.first(where: { $0.id == id })?.status == .paused { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(manager.items.first(where: { $0.id == id })?.status, .paused)
        manager.reconcile()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(manager.items.first(where: { $0.id == id })?.status, .paused)
        manager.resume(id)
        for _ in 0..<200 {
            if manager.items.first(where: { $0.id == id })?.status == .completed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let saved = try XCTUnwrap(manager.items.first(where: { $0.id == id }))
        XCTAssertEqual(saved.status, .completed, saved.error ?? "Resumed transfer did not finish")
        if let file = manager.fileURL(saved) { XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 70, count: 2097152)) }
        manager.remove(id)
    }
}
