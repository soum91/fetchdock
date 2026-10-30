import Foundation

@MainActor
final class FetchDockUploadEngine: NSObject, ObservableObject, URLSessionDataDelegate {
    static let sessionIdentifier = "com.soum91.fetchdock.uploads.v1"
    enum State: String, Codable { case queued, running, paused, failed, completed, cancelled }
    struct Upload: Codable, Identifiable {
        var id: UUID
        var fileName: String
        var filePath: String
        var destination: URL
        var method: String
        var headers: [String: String]
        var createdAt: Date
        var state: State
        var sent: Int64
        var expected: Int64
        var error: String?
        var responseStatus: Int?
        var speed: Double
        var progress: Double { expected > 0 ? min(1, max(0, Double(sent) / Double(expected))) : 0 }
    }
    @Published private(set) var items: [Upload] = []
    var backgroundCompletion: (() -> Void)?
    var onChange: ((Upload) -> Void)?
    private let root: URL
    private let configurationOverride: URLSessionConfiguration?
    private var tasks: [UUID: URLSessionUploadTask] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var sessions: [String: URLSession] = [:]
    private var connected = false

    init(root: URL, configuration: URLSessionConfiguration? = nil) {
        self.root = root; configurationOverride = configuration; super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: ledgerURL) { items = try JSONDecoder().decode([Upload].self, from: data) }
        } catch { }
    }
    private var filesRoot: URL { root.appendingPathComponent("Files", isDirectory: true) }
    private var ledgerURL: URL { root.appendingPathComponent("uploads.json") }

    func connect() {
        guard !connected else { return }; connected = true
        session(for: Self.sessionIdentifier).getAllTasks { [weak self] all in
            Task { @MainActor in
                guard let self else { return }
                for task in all {
                    guard let upload = task as? URLSessionUploadTask,
                          let id = UUID(uuidString: task.taskDescription ?? "") else { continue }
                    self.tasks[id] = upload
                    if let index = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[index].state = .running; self.emit(self.items[index])
                    }
                }
                self.save()
            }
        }
    }

    func start(file: URL, destination: URL, method: String = "POST",
               headers: [String: String] = [:]) throws -> UUID {
        guard destination.scheme?.lowercased() == "https" else {
            throw NSError(domain: "FetchDock.Upload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Upload destinations must use HTTPS."])
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "FetchDock.Upload", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected file is no longer available."])
        }
        let id = UUID(); let safe = Self.safeName(file.lastPathComponent)
        let relative = "Files/\(id.uuidString)-\(safe)"; let local = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: local)
        let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = URLRequest(url: destination); request.httpMethod = method.uppercased(); request.timeoutInterval = 7 * 24 * 3600
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "Content-Length") == nil { request.setValue(String(size), forHTTPHeaderField: "Content-Length") }
        let item = Upload(id: id, fileName: safe, filePath: relative, destination: destination, method: request.httpMethod ?? "POST", headers: headers, createdAt: Date(), state: .running, sent: 0, expected: size, error: nil, responseStatus: nil, speed: 0)
        items.insert(item, at: 0); save()
        let task = session(for: Self.sessionIdentifier).uploadTask(with: request, fromFile: local)
        task.taskDescription = id.uuidString; tasks[id] = task; task.resume(); emit(item)
        return id
    }

    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        tasks[id]?.cancel(); tasks.removeValue(forKey: id); samples.removeValue(forKey: id)
        items[index].state = .paused; items[index].speed = 0
        items[index].error = "Paused. Resume restarts the upload unless the server supports resumable uploads."
        save(); emit(items[index])
    }
    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(items[index].state) else { return }
        let item = items[index]; let local = root.appendingPathComponent(item.filePath)
        guard FileManager.default.fileExists(atPath: local.path) else { items[index].state = .failed; items[index].error = "The staged upload file is missing."; save(); emit(items[index]); return }
        var request = URLRequest(url: item.destination); request.httpMethod = item.method; request.timeoutInterval = 7 * 24 * 3600
        for (key, value) in item.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(String(item.expected), forHTTPHeaderField: "Content-Length")
        items[index].state = .running; items[index].sent = 0; items[index].error = nil
        let task = session(for: Self.sessionIdentifier).uploadTask(with: request, fromFile: local)
        task.taskDescription = id.uuidString; tasks[id] = task; save(); emit(items[index]); task.resume()
    }
    func cancel(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel(); samples.removeValue(forKey: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]; try? FileManager.default.removeItem(at: root.appendingPathComponent(item.filePath))
        items.remove(at: index); save()
    }
    func save() { if let data = try? JSONEncoder().encode(items) { try? data.write(to: ledgerURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) } }
    private func session(for identifier: String) -> URLSession {
        if let existing = sessions[identifier] { return existing }
        let config = configurationOverride ?? URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true; config.waitsForConnectivity = true; config.timeoutIntervalForResource = 7 * 24 * 3600
        let result = URLSession(configuration: config, delegate: self, delegateQueue: .main); sessions[identifier] = result; return result
    }
    private func emit(_ item: Upload) { onChange?(item) }
    private static func safeName(_ name: String) -> String {
        let value = name.removingPercentEncoding ?? name
        let cleaned = value.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "upload.bin" : String(cleaned.prefix(180))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = UUID(uuidString: task.taskDescription ?? ""), let index = items.firstIndex(where: { $0.id == id }) else { return }
        let now = Date(); var speed = 0.0
        if let sample = samples[id] { speed = max(0, Double(totalBytesSent - sample.1) / max(0.1, now.timeIntervalSince(sample.0))) }
        samples[id] = (now, totalBytesSent); items[index].sent = totalBytesSent
        if totalBytesExpectedToSend > 0 { items[index].expected = totalBytesExpectedToSend }
        items[index].speed = speed; items[index].state = .running; emit(items[index]); save()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = UUID(uuidString: task.taskDescription ?? ""), let index = items.firstIndex(where: { $0.id == id }) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode; items[index].responseStatus = status; items[index].speed = 0
        if let error { items[index].state = .failed; items[index].error = error.localizedDescription }
        else if let status, !(200...299).contains(status) { items[index].state = .failed; items[index].error = "Server returned HTTP \(status)." }
        else { items[index].state = .completed; items[index].sent = items[index].expected; items[index].error = nil; try? FileManager.default.removeItem(at: root.appendingPathComponent(items[index].filePath)) }
        tasks.removeValue(forKey: id); samples.removeValue(forKey: id); save(); emit(items[index])
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = backgroundCompletion; backgroundCompletion = nil; DispatchQueue.main.async { done?() }
    }
}
