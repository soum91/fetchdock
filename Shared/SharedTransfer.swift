import Foundation

/// A separate, atomic ledger per transfer avoids cross-process queue-file races.
struct SharedTransfer: Codable, Identifiable {
    var id: UUID
    var url: URL
    var filename: String
    var sessionID: String
    var createdAt = Date()
    var status: DownloadStatus = .running
    var received: Int64 = 0
    var expected: Int64 = 0
    var speed: Double = 0
    var file: String?
    var error: String?
}

struct ShareStore {
    static let groupID = "group.com.soum91.fetchdock"
    static let sessionPrefix = "com.soum91.fetchdock.share."
    let root: URL
    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    static func appGroup() throws -> ShareStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw NSError(domain: "FetchDock.Share", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared storage is unavailable. Keep FetchDock's App Group entitlement when signing the app and Share extension."])
        }
        return try ShareStore(root: container.appendingPathComponent("Transfers", isDirectory: true))
    }
    func records() throws -> [SharedTransfer] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SharedTransfer.self, from: Data(contentsOf: $0)) }
    }
    func record(_ id: UUID) throws -> SharedTransfer {
        try JSONDecoder().decode(SharedTransfer.self, from: Data(contentsOf: recordURL(id)))
    }
    func write(_ transfer: SharedTransfer) throws {
        try JSONEncoder().encode(transfer).write(to: recordURL(transfer.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func recordURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    func resumeURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".resume") }
    func fileURL(_ name: String) -> URL { root.appendingPathComponent((name as NSString).lastPathComponent) }
    func remove(_ id: UUID) throws {
        if let record = try? record(id), let file = record.file { try? FileManager.default.removeItem(at: fileURL(file)) }
        try? FileManager.default.removeItem(at: resumeURL(id))
        if FileManager.default.fileExists(atPath: recordURL(id).path) { try FileManager.default.removeItem(at: recordURL(id)) }
    }
}

/// Only the process owning a session writes its ledger. The containing app adopts
/// extension sessions when iOS delivers their background events.
@MainActor
final class SharedTransferCoordinator: NSObject, URLSessionDownloadDelegate {
    static let shared = SharedTransferCoordinator()
    var onChange: (() -> Void)?
    private var sessions: [String: URLSession] = [:]
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var completions: [String: () -> Void] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var lastWrites: [UUID: Date] = [:]
    private let storeOverride: ShareStore?
    private let configurationOverride: URLSessionConfiguration?
    override convenience init() { self.init(store: nil, configuration: nil) }
    init(store: ShareStore?, configuration: URLSessionConfiguration?) {
        storeOverride = store; configurationOverride = configuration; super.init()
    }
    func store() throws -> ShareStore { try storeOverride ?? ShareStore.appGroup() }
    func records() -> [SharedTransfer] { (try? store().records()) ?? [] }
    private func session(_ identifier: String) -> URLSession {
        if let existing = sessions[identifier] { return existing }
        let config = configurationOverride ?? URLSessionConfiguration.background(withIdentifier: identifier)
        if configurationOverride == nil { config.sharedContainerIdentifier = ShareStore.groupID }
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 3600
        let result = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        sessions[identifier] = result
        return result
    }
    @discardableResult
    func start(_ url: URL) throws -> UUID {
        guard DownloadItem.parseURL(url.absoluteString) != nil, DownloadItem.canDownload(url) else {
            throw NSError(domain: "FetchDock.Share", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use an HTTPS file download link."])
        }
        let store = try store()
        let id = UUID()
        let identifier = ShareStore.sessionPrefix + id.uuidString
        let transfer = SharedTransfer(id: id, url: url, filename: DownloadItem.safeName(url.lastPathComponent), sessionID: identifier)
        try store.write(transfer)
        var request = URLRequest(url: url)
        request.allowsCellularAccess = UserDefaults(suiteName: ShareStore.groupID)?.object(forKey: "allowsCellular") as? Bool ?? true
        let task = session(identifier).downloadTask(with: request)
        task.taskDescription = id.uuidString
        tasks[id] = task
        task.resume()
        onChange?()
        return id
    }
    func adopt(_ identifier: String, completion: (() -> Void)? = nil) {
        guard identifier.hasPrefix(ShareStore.sessionPrefix) else { completion?(); return }
        if let completion { completions[identifier] = completion }
        else if sessions[identifier] != nil { return }
        let connection = session(identifier)
        connection.getAllTasks { all in
            DispatchQueue.main.async {
                for task in all {
                    if let id = UUID(uuidString: task.taskDescription ?? ""), let task = task as? URLSessionDownloadTask { self.tasks[id] = task }
                }
                self.onChange?()
            }
        }
    }
    func pause(_ id: UUID) {
        guard let store = try? store(), var record = try? store.record(id) else { return }
        if tasks[id] == nil {
            // Resume app ownership first; do not pretend the transfer was paused.
            adopt(record.sessionID)
            record.error = "Connecting to the shared transfer. Try Pause again in a moment."
            try? store.write(record); onChange?(); return
        }
        guard record.status == .running, let task = tasks[id] else { return }
        record.status = .pausing; record.speed = 0
        try? store.write(record); onChange?()
        task.cancel { data in
            DispatchQueue.main.async {
                guard var record = try? store.record(id), record.status == .pausing else { return }
                if let data { try? data.write(to: store.resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                else { record.received = 0 }
                record.status = .paused; record.error = nil
                try? store.write(record)
                self.tasks.removeValue(forKey: id); self.onChange?()
            }
        }
    }
    func resume(_ id: UUID) {
        guard let store = try? store(), var record = try? store.record(id), [.paused, .failed].contains(record.status) else { return }
        let connection = session(record.sessionID)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: store.resumeURL(id)), !data.isEmpty { task = connection.downloadTask(withResumeData: data) }
        else { task = connection.downloadTask(with: record.url); record.received = 0 }
        task.taskDescription = id.uuidString; tasks[id] = task
        record.status = .running; record.error = nil
        try? store.write(record); task.resume(); onChange?()
    }
    func remove(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        if let store = try? store(), let record = try? store.record(id) {
            // Cancel daemon-owned work even when no task callback has reached this process yet.
            session(record.sessionID).getAllTasks { $0.forEach { $0.cancel() } }
            try? store.remove(id)
        }
        onChange?()
    }
    func forgetCompleted(_ id: UUID) { try? store().remove(id) }
    func invalidate() { sessions.values.forEach { $0.invalidateAndCancel() }; sessions.removeAll() }
    private func record(for task: URLSessionTask) -> (ShareStore, SharedTransfer)? {
        guard let id = UUID(uuidString: task.taskDescription ?? ""), let store = try? store(), let record = try? store.record(id) else { return nil }
        if let active = tasks[id], active.taskIdentifier != task.taskIdentifier { return nil }
        return (store, record)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let (store, existing) = record(for: downloadTask), existing.status == .running else { return }
        let now = Date(), id = existing.id
        guard now.timeIntervalSince(lastWrites[id] ?? .distantPast) >= 1 else { return }
        var record = existing
        if let sample = samples[id] { record.speed = max(0, Double(totalBytesWritten - sample.1) / max(0.1, now.timeIntervalSince(sample.0))) }
        samples[id] = (now, totalBytesWritten); lastWrites[id] = now
        record.received = max(0, totalBytesWritten); record.expected = max(0, totalBytesExpectedToWrite); record.error = nil
        if let name = downloadTask.response?.suggestedFilename { record.filename = DownloadItem.safeName(name) }
        try? store.write(record); onChange?()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let (store, existing) = record(for: downloadTask) else { return }
        var record = existing
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "FetchDock.Share", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode). For sign-in-only links, use FetchDock's browser."])
            }
            record.filename = DownloadItem.safeName(downloadTask.response?.suggestedFilename ?? record.filename)
            let name = record.id.uuidString + "-" + record.filename
            let destination = store.fileURL(name)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            record.file = name; record.status = .completed; record.speed = 0
            record.received = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            record.expected = record.received
            try store.write(record)
        } catch { record.status = .failed; record.error = error.localizedDescription; record.speed = 0; try? store.write(record) }
        onChange?()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (store, existing) = record(for: task) else { return }
        if [.pausing, .paused].contains(existing.status) { return }
        var record = existing
        if let error = error as NSError?, record.status != .completed {
            record.status = .failed; record.error = error.localizedDescription; record.speed = 0
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: store.resumeURL(record.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            else { try? FileManager.default.removeItem(at: store.resumeURL(record.id)) }
            try? store.write(record)
        }
        tasks.removeValue(forKey: record.id); samples.removeValue(forKey: record.id); onChange?()
        // Ordinary foreground completions do not get didFinishEvents callbacks.
        if completions[record.sessionID] == nil { session.finishTasksAndInvalidate(); sessions.removeValue(forKey: record.sessionID) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        onChange?()
        let done = completions.removeValue(forKey: identifier)
        // App observers may have scheduled an ActivityKit update.
        DispatchQueue.main.async { done?() }
        session.finishTasksAndInvalidate(); sessions.removeValue(forKey: identifier)
    }
}
