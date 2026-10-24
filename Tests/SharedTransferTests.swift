import XCTest
@testable import FetchDock

final class SharedTransferTests: XCTestCase {
    func testSeparateLedgersKeepMultipleSharesAndSanitizeFilePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ShareStore(root: root)
        let first = SharedTransfer(id: UUID(), url: URL(string: "https://example.com/a.zip")!, filename: "a.zip", sessionID: "test.first")
        let second = SharedTransfer(id: UUID(), url: URL(string: "https://example.com/b.zip")!, filename: "b.zip", sessionID: "test.second")
        try store.write(first); try store.write(second)
        XCTAssertEqual(Set(try store.records().map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(store.fileURL("../../secret.bin").deletingLastPathComponent().path, root.path)
        try store.remove(first.id)
        XCTAssertEqual(try store.records().map(\.id), [second.id])
    }
    @MainActor
    func testSharedTransferProducesRecoverableFileLedger() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ShareStore(root: root)
        let coordinator = SharedTransferCoordinator(store: store, configuration: .default)
        defer { coordinator.invalidate(); try? FileManager.default.removeItem(at: root) }
        let id = try coordinator.start(URL(string: "http://127.0.0.1:8765/file")!)
        for _ in 0..<200 {
            if try store.record(id).status == .completed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let completed = try store.record(id)
        XCTAssertEqual(completed.status, .completed, completed.error ?? "Shared download did not finish")
        let file = try XCTUnwrap(completed.file)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(file)), Data(repeating: 70, count: 524288))
        XCTAssertTrue(completed.sessionID.hasPrefix(ShareStore.sessionPrefix))
        // A new process can discover the finished file without sharing in-memory state.
        XCTAssertEqual(try ShareStore(root: root).record(id).file, completed.file)
    }
    @MainActor
    func testSharedTransferRejectsInsecureRemoteLinksAndHTTPFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try ShareStore(root: root)
        let coordinator = SharedTransferCoordinator(store: store, configuration: .default)
        defer { coordinator.invalidate(); try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try coordinator.start(URL(string: "http://example.com/file")!))
        let id = try coordinator.start(URL(string: "http://127.0.0.1:8765/missing")!)
        for _ in 0..<150 {
            if try store.record(id).status == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let failed = try store.record(id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("404") == true)
        XCTAssertNil(failed.file)
    }
}
