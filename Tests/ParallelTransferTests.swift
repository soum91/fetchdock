import XCTest
@testable import FetchDock

final class ParallelTransferTests: XCTestCase {
    func testRangeValidationAndLargePartitionArithmetic() throws {
        for value in ["bytes -0-0/100", "bytes 0-100/100", "bytes 0-0/*", "bytes 0-0/999999999999999999999999", "bytes +0-0/100"] {
            let response = HTTPURLResponse(url: URL(string: "https://example.com/file")!, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": value])!
            XCTAssertNil(FetchDockTransferEngine.contentRange(response), value)
        }
        let parts = FetchDockTransferEngine.partitions(total: Int64.max, count: 8)
        XCTAssertEqual(parts.count, 8)
        XCTAssertEqual(parts.first?.first, 0)
        XCTAssertEqual(parts.last?.last, Int64.max - 1)
        for index in 1..<parts.count { XCTAssertEqual(parts[index].first, parts[index - 1].last + 1) }
        XCTAssertEqual(parts.reduce(Int64(0)) { $0 + ($1.last - $1.first + 1) }, Int64.max)
    }
    func testReconstructedCookiesRemainHostOnlyAndSecure() throws {
        let url = URL(string: "https://files.example.com/protected/download")!
        let cookies = FetchDockTransferEngine.scopedCookies("session=fixture==; __Host-login=fixture", for: url)
        XCTAssertEqual(cookies.count, 2)
        let storage = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        cookies.forEach(storage.setCookie)
        XCTAssertEqual(storage.cookies(for: url)?.count, 2)
        XCTAssertTrue((storage.cookies(for: URL(string: "https://child.files.example.com/protected/download")!) ?? []).isEmpty)
        XCTAssertTrue((storage.cookies(for: URL(string: "http://files.example.com/protected/download")!) ?? []).isEmpty)
        XCTAssertEqual(cookies.first(where: { $0.name == "session" })?.value, "fixture==")
    }
    private func makeEngine(root: URL? = nil) -> FetchDockTransferEngine {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return FetchDockTransferEngine(identifier: UUID().uuidString, root: root, output: root.appendingPathComponent("Files"), configuration: .ephemeral)
    }
    private func expectedBytes() -> Data { Data((0..<2097152).map { UInt8($0 % 251) }) }
    private func terminal(_ engine: FetchDockTransferEngine, _ id: UUID) async throws -> FetchDockTransferEngine.Transfer {
        for _ in 0..<400 {
            if let item = engine.snapshots().first(where: { $0.id == id }), [.completed, .failed].contains(item.state) { return item }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Transfer timed out")
        return try XCTUnwrap(engine.snapshots().first(where: { $0.id == id }))
    }
    func testSegmentsOverlapAndAssembleExactFile() async throws {
        let engine = makeEngine()
        let id = engine.start(url: URL(string: "http://127.0.0.1:8765/segments")!, filename: "file", connections: 4)
        let item = try await terminal(engine, id)
        XCTAssertEqual(item.state, .completed, item.error ?? "")
        XCTAssertEqual(item.mode, .segmented)
        XCTAssertEqual(item.parts.count, 4)
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(item)), expectedBytes())
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8765/segment-stats")!)
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Int]])
        XCTAssertGreaterThanOrEqual(stats["/segments"]?["peak"] ?? 0, 2, "There must be real overlapping range requests")
        engine.remove(id)
    }
    func testUnsafeOrUnsupportedRangesFallBackWithoutCorruptingFile() async throws {
        for endpoint in ["ignore-ranges", "bad-range", "changing-etag", "no-validator"] {
            let engine = makeEngine()
            let id = engine.start(url: URL(string: "http://127.0.0.1:8765/\(endpoint)")!, filename: "file", connections: 4)
            let item = try await terminal(engine, id)
            XCTAssertEqual(item.state, .completed, "\(endpoint): \(item.error ?? "")")
            XCTAssertEqual(item.mode, .single, endpoint)
            XCTAssertEqual(try Data(contentsOf: engine.fileURL(item)), expectedBytes(), endpoint)
            engine.remove(id)
        }
    }
    func testPauseRestoreAndResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = makeEngine(root: root)
        let id = engine.start(url: URL(string: "http://127.0.0.1:8765/segments-slow")!, filename: "file", connections: 4)
        for _ in 0..<150 {
            if (engine.snapshots().first(where: { $0.id == id })?.received ?? 0) > 1000 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        engine.pause(id)
        XCTAssertEqual(engine.snapshots().first?.state, .paused)
        try await Task.sleep(nanoseconds: 300_000_000)
        let restored = makeEngine(root: root)
        XCTAssertEqual(restored.snapshots().first?.id, id)
        XCTAssertEqual(restored.snapshots().first?.state, .paused)
        restored.resume(id)
        let item = try await terminal(restored, id)
        XCTAssertEqual(item.state, .completed, item.error ?? "")
        XCTAssertEqual(try Data(contentsOf: restored.fileURL(item)), expectedBytes())
        restored.remove(id)
    }
    func testHTTPFailureAndCancellationDoNotProduceCompletedFiles() async throws {
        let engine = makeEngine()
        let id = engine.start(url: URL(string: "http://127.0.0.1:8765/missing")!, filename: "file")
        let failed = try await terminal(engine, id)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.fileURL(failed).path))
        let slow = engine.start(url: URL(string: "http://127.0.0.1:8765/segments-slow")!, filename: "file")
        engine.cancel(slow)
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = try XCTUnwrap(engine.snapshots().first(where: { $0.id == slow }))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.fileURL(cancelled).path))
        engine.remove(id); engine.remove(slow)
    }
    func testRedirectAuthenticationRemainsScoped() async throws {
        // Unsigned simulator hosts cannot talk to nsurlsessiond. Exercise the
        // exact request/redirect path with an isolated foreground transport.
        let engine = makeEngine()
        let id = engine.start(url: URL(string: "http://127.0.0.1:8765/redirect-other-host")!, filename: "file", headers: ["Cookie": "user_session=fixture-session"])
        let item = try await terminal(engine, id)
        XCTAssertEqual(item.state, .completed, item.error ?? "")
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(item)), Data(repeating: 70, count: 524288))
        engine.remove(id)
    }
}
