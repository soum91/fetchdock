import Foundation

/// Shared by FetchDock and Reynard. All mutable state lives on `queue`.
final class FetchDockTransferEngine: NSObject, URLSessionDownloadDelegate {
    enum State: String, Codable { case running, paused, failed, cancelled, completed }
    enum Mode: String, Codable { case probe, segmented, single }
    struct Part: Codable { var first: Int64; var last: Int64; var complete = false }
    struct Transfer: Codable {
        var id: UUID; var url: URL; var resolvedURL: URL?; var filename: String
        var headers: [String: String]; var created = Date(); var state = State.running
        var generation = UUID(); var mode = Mode.probe; var connections: Int
        var expected: Int64 = 0; var received: Int64 = 0; var speed: Double = 0
        var validator: String?; var parts: [Part] = []; var error: String?
        var allowsCellular = true
    }
    var onChange: ((Transfer) -> Void)?
    var backgroundCompletion: (() -> Void)?
    let identifier: String
    private let root: URL
    private let output: URL
    private let configuration: URLSessionConfiguration?
    private let queue = DispatchQueue(label: "FetchDock.TransferEngine", qos: .utility)
    private var records: [UUID: Transfer] = [:]
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var ready = false
    private var connecting = false
    private lazy var session: URLSession = {
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForResource = 7 * 86400
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegates = OperationQueue()
        delegates.maxConcurrentOperationCount = 1
        delegates.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: delegates)
    }()

    init(identifier: String, root: URL, output: URL, configuration: URLSessionConfiguration? = nil) {
        self.identifier = identifier; self.root = root; self.output = output; self.configuration = configuration
        super.init()
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                if let data = try? Data(contentsOf: root.appendingPathComponent("transfers.json")) {
                    let restored = try JSONDecoder().decode([Transfer].self, from: data)
                    records = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
                }
            } catch { /* Storage errors are surfaced by the next durable mutation. */ }
        }
        connect()
    }
    func connect() {
        queue.async {
            guard !self.connecting && !self.ready else { return }
            self.connecting = true
            self.session.getAllTasks { restored in
                self.queue.async {
                    self.tasks.removeAll()
                    for case let task as URLSessionDownloadTask in restored {
                        guard let (id, generation, _) = self.tag(task), let record = self.records[id],
                              record.generation == generation, record.state == .running else { task.cancel(); continue }
                        self.tasks[task.taskIdentifier] = task
                        task.resume()
                    }
                    self.ready = true
                    self.connecting = false
                    for id in Array(self.records.keys) {
                        if self.records[id]?.state == .running { self.schedule(id) }
                        self.emit(id)
                    }
                }
            }
        }
    }
    func snapshots() -> [Transfer] { queue.sync { Array(records.values) } }
    func contains(_ id: UUID) -> Bool { queue.sync { records[id] != nil } }
    func fileURL(_ transfer: Transfer) -> URL {
        output.appendingPathComponent(transfer.id.uuidString + "-" + Self.safeName(transfer.filename))
    }
    @discardableResult
    func start(id: UUID = UUID(), url: URL, filename: String, headers: [String: String] = [:], connections: Int = 4, allowsCellular: Bool = true) -> UUID {
        queue.sync {
            guard records[id] == nil else { return }
            var transfer = Transfer(id: id, url: url, filename: Self.safeName(filename), headers: headers, connections: min(8, max(1, connections)))
            transfer.allowsCellular = allowsCellular
            if !Self.allowed(url) { transfer.state = .failed; transfer.error = "Remote downloads require HTTPS." }
            if transfer.connections == 1 { transfer.mode = .single }
            records[id] = transfer
            do { try save(); schedule(id); emit(id) }
            catch { fail(id, error.localizedDescription) }
        }
        return id
    }
    func pause(_ id: UUID) { queue.sync {
        guard var t = records[id], t.state == .running else { return }
        t.state = .paused; t.generation = UUID(); t.speed = 0; records[id] = t
        cancelTasks(id); samples.removeValue(forKey: id); try? save(); emit(id)
    } }
    func resume(_ id: UUID) { queue.sync {
        guard var t = records[id], [.paused, .failed].contains(t.state) else { return }
        t.state = .running; t.generation = UUID(); t.error = nil; t.speed = 0; records[id] = t
        samples.removeValue(forKey: id)
        do { try save(); schedule(id); emit(id) } catch { fail(id, error.localizedDescription) }
    } }
    func cancel(_ id: UUID) { queue.sync {
        guard var t = records[id], t.state != .completed else { return }
        t.state = .cancelled; t.generation = UUID(); t.headers = [:]; t.speed = 0; records[id] = t
        cancelTasks(id); try? FileManager.default.removeItem(at: directory(id)); try? save(); emit(id)
    } }
    func remove(_ id: UUID) { queue.sync {
        cancelTasks(id)
        if let t = records.removeValue(forKey: id) { try? FileManager.default.removeItem(at: fileURL(t)) }
        try? FileManager.default.removeItem(at: directory(id)); samples.removeValue(forKey: id); try? save()
    } }
    private static func allowed(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""))
    }
    static func safeName(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\r\n\0")).joined(separator: "_")
        return safe.isEmpty || safe == "." || safe == ".." ? "Download" : String(safe.prefix(180))
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func partURL(_ id: UUID, _ index: Int) -> URL { directory(id).appendingPathComponent("part-\(index)") }
    private func save() throws {
        let data = try JSONEncoder().encode(Array(records.values))
        #if os(iOS)
        try data.write(to: root.appendingPathComponent("transfers.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: root.appendingPathComponent("transfers.json"), options: .atomic)
        #endif
    }
    private func emit(_ id: UUID) {
        guard let transfer = records[id] else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(transfer) }
    }
    private func tag(_ task: URLSessionTask) -> (UUID, UUID, Int)? {
        let parts = (task.taskDescription ?? "").split(separator: "|")
        guard parts.count == 3, let id = UUID(uuidString: String(parts[0])),
              let generation = UUID(uuidString: String(parts[1])), let index = Int(parts[2]) else { return nil }
        return (id, generation, index)
    }
    private func cancelTasks(_ id: UUID) {
        for (key, task) in Array(tasks) where tag(task)?.0 == id { tasks.removeValue(forKey: key); task.cancel() }
    }
    private func request(_ transfer: Transfer, index: Int) -> URLRequest {
        let target = transfer.resolvedURL ?? transfer.url
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.allowsCellularAccess = transfer.allowsCellular
        for (name, value) in transfer.headers {
            let key = name.lowercased()
            if ["range", "if-range", "accept-encoding", "host", "content-length"].contains(key) { continue }
            if ["cookie", "authorization", "referer"].contains(key) && (target.scheme != transfer.url.scheme || target.host != transfer.url.host || target.port != transfer.url.port) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if index == -2 { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
        if index >= 0 {
            let part = transfer.parts[index]
            request.setValue("bytes=\(part.first)-\(part.last)", forHTTPHeaderField: "Range")
            request.setValue(transfer.validator, forHTTPHeaderField: "If-Range")
        }
        return request
    }
    private func schedule(_ id: UUID) {
        guard ready, var t = records[id], t.state == .running else { return }
        do { try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true) }
        catch { fail(id, error.localizedDescription); return }
        for i in t.parts.indices where t.parts[i].complete && !FileManager.default.fileExists(atPath: partURL(id, i).path) { t.parts[i].complete = false }
        records[id] = t
        if t.mode == .segmented && t.parts.allSatisfy({ $0.complete }) { assemble(id); return }
        let indices = t.mode == .segmented ? t.parts.indices.filter { !t.parts[$0].complete } : [t.mode == .probe ? -2 : -1]
        for index in indices {
            if tasks.values.contains(where: { let value = tag($0); return value?.0 == id && value?.1 == t.generation && value?.2 == index }) { continue }
            let task = session.downloadTask(with: request(t, index: index))
            task.taskDescription = "\(id.uuidString)|\(t.generation.uuidString)|\(index)"
            tasks[task.taskIdentifier] = task; task.resume()
        }
    }
    private func fallback(_ id: UUID) {
        guard var t = records[id] else { return }
        cancelTasks(id)
        t.generation = UUID(); t.mode = .single; t.parts = []; t.validator = nil; t.received = 0; t.speed = 0
        records[id] = t; samples.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: directory(id))
        do { try save(); schedule(id); emit(id) } catch { fail(id, error.localizedDescription) }
    }
    private func fail(_ id: UUID, _ message: String) {
        guard var t = records[id] else { return }
        cancelTasks(id); t.generation = UUID(); t.state = .failed; t.error = message; t.speed = 0
        records[id] = t; try? save(); emit(id)
    }
    private func finish(_ id: UUID, location: URL) throws {
        guard var t = records[id] else { return }
        let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        let destination = fileURL(t)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: location, to: destination)
        t.state = .completed; t.received = size; t.expected = size; t.speed = 0; t.headers = [:]; t.error = nil
        records[id] = t; try save(); try? FileManager.default.removeItem(at: directory(id)); emit(id)
    }
    private func assemble(_ id: UUID) {
        guard let t = records[id], t.state == .running else { return }
        let merged = directory(id).appendingPathComponent("merged")
        do {
            guard let writer = OutputStream(url: merged, append: false) else { throw URLError(.cannotWriteToFile) }
            writer.open()
            defer { writer.close() }
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            for index in t.parts.indices {
                let file = partURL(id, index)
                let expected = t.parts[index].last - t.parts[index].first + 1
                guard (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == expected else { throw URLError(.cannotDecodeContentData) }
                guard let reader = InputStream(url: file) else { throw URLError(.cannotOpenFile) }
                reader.open()
                defer { reader.close() }
                while true {
                    let count = reader.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw reader.streamError ?? URLError(.cannotOpenFile) }
                    if count == 0 { break }
                    try buffer.withUnsafeBufferPointer { bytes in
                        var offset = 0
                        while offset < count {
                            let written = writer.write(bytes.baseAddress!.advanced(by: offset), maxLength: count - offset)
                            if written <= 0 { throw writer.streamError ?? URLError(.cannotWriteToFile) }
                            offset += written
                        }
                    }
                }
            }
            writer.close()
            guard (try FileManager.default.attributesOfItem(atPath: merged.path)[.size] as? NSNumber)?.int64Value == t.expected else { throw URLError(.cannotDecodeContentData) }
            try finish(id, location: merged)
        } catch { fail(id, "Could not join download segments: \(error.localizedDescription)") }
    }
    static func contentRange(_ response: HTTPURLResponse) -> (Int64, Int64, Int64)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else { return nil }
        let fields = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        let values = [bounds[0], bounds[1], fields[1]]
        guard values.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ "0123456789".contains($0) }) }) else { return nil }
        guard values.count == 3, let start = Int64(values[0]), let end = Int64(values[1]), let total = Int64(values[2]), start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }
    static func partitions(total: Int64, count: Int) -> [Part] {
        guard total > 0, count >= 1, count <= 8, total >= Int64(count) else { return [] }
        let width = total / Int64(count), remainder = total % Int64(count)
        return (0..<count).map { index in
            let i = Int64(index)
            let first = i * width + min(i, remainder)
            return Part(first: first, last: first + width - 1 + (i < remainder ? 1 : 0))
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (id, generation, index) = tag(downloadTask), var t = records[id], t.generation == generation, t.state == .running else { return }
        tasks.removeValue(forKey: downloadTask.taskIdentifier)
        guard let response = downloadTask.response as? HTTPURLResponse else { fail(id, "No HTTP response."); return }
        do {
            if let name = response.suggestedFilename, index < 0 { t.filename = Self.safeName(name) }
            if response.statusCode == 200 {
                if index >= 0 { fallback(id); return }
                t.mode = .single; t.connections = 1
                records[id] = t; try finish(id, location: location); return
            }
            guard response.statusCode == 206, let range = Self.contentRange(response) else {
                if index >= 0 && [412, 416].contains(response.statusCode) { fallback(id) }
                else { fail(id, "Server returned HTTP \(response.statusCode).") }
                return
            }
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            if index == -2 {
                guard range.0 == 0, range.1 == 0, size == 1, range.2 >= 1024 * 1024,
                      encoding == nil || encoding == "identity",
                      let etag = response.value(forHTTPHeaderField: "ETag"), etag.hasPrefix("\""), etag.hasSuffix("\"") else { fallback(id); return }
                guard let target = response.url, Self.allowed(target) else { fail(id, "Unsupported download redirect."); return }
                t.resolvedURL = target; t.expected = range.2; t.validator = etag; t.mode = .segmented
                t.parts = Self.partitions(total: range.2, count: t.connections)
                t.received = 0; records[id] = t; try save(); schedule(id); emit(id); return
            }
            guard index >= 0 else { fail(id, "Server returned an unexpected partial response."); return }
            let part = t.parts[index]
            guard range.0 == part.first, range.1 == part.last, range.2 == t.expected,
                  size == part.last - part.first + 1, response.value(forHTTPHeaderField: "ETag") == t.validator,
                  encoding == nil || encoding == "identity" else { fallback(id); return }
            if FileManager.default.fileExists(atPath: partURL(id, index).path) { try FileManager.default.removeItem(at: partURL(id, index)) }
            try FileManager.default.moveItem(at: location, to: partURL(id, index))
            t.parts[index].complete = true; records[id] = t; try save(); updateProgress(id); schedule(id)
        } catch { fail(id, error.localizedDescription) }
    }
    private func updateProgress(_ id: UUID) {
        guard var t = records[id] else { return }
        let completed = t.parts.filter { $0.complete }.reduce(Int64(0)) { $0 + ($1.last - $1.first + 1) }
        let active = tasks.values.filter { tag($0)?.0 == id }.reduce(Int64(0)) { $0 + max(0, $1.countOfBytesReceived) }
        t.received = completed + active
        if let sample = samples[id], Date().timeIntervalSince(sample.0) >= 0.8 {
            t.speed = max(0, Double(t.received - sample.1) / Date().timeIntervalSince(sample.0)); samples[id] = (Date(), t.received)
        } else if samples[id] == nil { samples[id] = (Date(), t.received) }
        records[id] = t; emit(id)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (id, generation, _) = tag(downloadTask), var t = records[id], t.generation == generation, t.state == .running else { return }
        if t.mode != .segmented && totalBytesExpectedToWrite > 1 { t.expected = totalBytesExpectedToWrite; records[id] = t }
        updateProgress(id)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (id, generation, _) = tag(task), let t = records[id], t.generation == generation, t.state == .running else { return }
        tasks.removeValue(forKey: task.taskIdentifier)
        if let error { fail(id, error.localizedDescription) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        try? save()
        DispatchQueue.main.async { [weak self] in let done = self?.backgroundCompletion; self?.backgroundCompletion = nil; done?() }
    }
}
