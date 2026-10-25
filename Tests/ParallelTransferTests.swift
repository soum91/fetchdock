import XCTest
@testable import FetchDock

final class ParallelTransferTests: XCTestCase {
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
    func testBackgroundSessionKeepsRedirectAuthenticationScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = FetchDockTransferEngine(identifier: "com.soum91.fetchdock.tests.\(UUID().uuidString)", root: root, output: root.appendingPathComponent("Files"))
        let id = engine.start(url: URL(string: "http://127.0.0.1:8765/redirect-other-host")!, filename: "file", headers: ["Cookie": "user_session=fixture-session"])
        let item = try await terminal(engine, id)
        XCTAssertEqual(item.state, .completed, item.error ?? "")
        XCTAssertEqual(try Data(contentsOf: engine.fileURL(item)), Data(repeating: 70, count: 524288))
        engine.remove(id)
    }
}
