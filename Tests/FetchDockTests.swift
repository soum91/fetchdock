import XCTest
@testable import FetchDock

final class FetchDockTests: XCTestCase {
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
