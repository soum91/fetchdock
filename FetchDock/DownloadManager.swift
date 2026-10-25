import Foundation
import Combine
import UIKit

@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static let sessionIdentifier = "com.soum91.fetchdock.transfers.v1"
    static let parallelSessionIdentifier = "com.soum91.fetchdock.parallel.v1"
    @Published private(set) var items: [DownloadItem] = []
    @Published var notice: String?
    @Published private(set) var restoring = true
    let live = LiveActivityController()
    var backgroundCompletion: (() -> Void)?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var lastSave = Date.distantPast
    private var reconciling = false
    private let configurationOverride: URLSessionConfiguration?
    private let root: URL
    private let downloads: URL
    private(set) var parallel: FetchDockTransferEngine!
    var connectionsPerFile: Int {
        let value = UserDefaults.standard.integer(forKey: "connectionsPerFile")
        return value == 0 ? 4 : min(8, max(1, value))
    }
    private lazy var session: URLSession = {
        let config = configurationOverride ?? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        // Cellular preference applies to each request, including after app relaunch.
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    var maxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: "concurrentDownloads")
        return value == 0 ? 3 : min(6, max(1, value))
    }
    var allowsCellular: Bool { UserDefaults.standard.object(forKey: "allowsCellular") as? Bool ?? true }
    var activeCount: Int { items.filter { $0.status == .running }.count }
    var totalSpeed: Double { items.reduce(0) { $0 + ($1.status == .running ? $1.speed : 0) } }

    override convenience init() {
        self.init(sessionConfiguration: nil, storageDirectory: nil, downloadsDirectory: nil)
    }
    // Dependency injection isolates integration tests from the host's background transfer daemon.
    // Normal app initialization always uses the background configuration above.
    init(sessionConfiguration: URLSessionConfiguration?, storageDirectory: URL?, downloadsDirectory: URL?) {
        configurationOverride = sessionConfiguration
        let fm = FileManager.default
        root = storageDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FetchDock", isDirectory: true)
        downloads = downloadsDirectory ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        super.init()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            if fm.fileExists(atPath: root.appendingPathComponent("downloads.json").path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: root.appendingPathComponent("downloads.json")))
            }
        } catch { notice = "Could not restore downloads: \(error.localizedDescription)" }
        parallel = FetchDockTransferEngine(identifier: Self.parallelSessionIdentifier, root: root.appendingPathComponent("Parallel"), output: root.appendingPathComponent("ParallelFiles"), configuration: sessionConfiguration == nil ? nil : .default)
        parallel.onChange = { [weak self] transfer in self?.importParallelTransfer(transfer) }
        for transfer in parallel.snapshots() { importParallelTransfer(transfer) }
        if configurationOverride == nil {
            SharedTransferCoordinator.shared.onChange = { [weak self] in self?.importSharedTransfers() }
        }
        reconcile()
    }

    func connect() { _ = session; parallel.connect() }
    func reconcile() {
        if configurationOverride == nil {
            importSharedTransfers()
            for record in SharedTransferCoordinator.shared.records() where record.status == .running {
                SharedTransferCoordinator.shared.adopt(record.sessionID)
            }
        }
        guard !reconciling else { return }
        reconciling = true
        session.getAllTasks { allTasks in
            DispatchQueue.main.async {
                self.tasks.removeAll()
                for task in allTasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let id = UUID(uuidString: task.taskDescription ?? ""),
                          let index = self.items.firstIndex(where: { $0.id == id }),
                          self.items[index].status != .completed else { task.cancel(); continue }
                    // A paused download must never restart simply because the app reopened.
                    if [.paused, .pausing].contains(self.items[index].status) {
                        self.tasks[id] = download
                        self.pause(id)
                        continue
                    }
                    self.tasks[id] = download
                    self.items[index].status = .running
                    self.items[index].received = max(0, download.countOfBytesReceived)
                    self.items[index].expected = max(0, download.countOfBytesExpectedToReceive)
                    if download.state == .suspended { download.resume() }
                }
                for index in self.items.indices where self.tasks[self.items[index].id] == nil && self.items[index].sharedSessionID == nil {
                    if self.items[index].usesParallelEngine == true { continue }
                    if self.items[index].status == .running { self.items[index].status = .queued }
                    if self.items[index].status == .pausing { self.items[index].status = .paused }
                }
                self.restoring = false
                self.reconciling = false
                self.schedule()
                self.save()
                self.live.refresh(self.items, force: true)
            }
        }
    }

    func addLinks(_ text: String) {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var invalid = 0
        for line in lines {
            if let url = DownloadItem.parseURL(line), DownloadItem.canDownload(url) { enqueue(url) } else { invalid += 1 }
        }
        if invalid > 0 { notice = "Skipped \(invalid) unsupported link(s). Use one full HTTPS download link per line." }
    }
    func enqueue(_ url: URL, headers: [String: String] = [:]) {
        guard DownloadItem.parseURL(url.absoluteString) != nil, DownloadItem.canDownload(url) else {
            notice = "Use an HTTPS link for remote file downloads. HTTP pages can still open in Browser."
            return
        }
        var item = DownloadItem(url: url, filename: DownloadItem.safeName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent), headers: headers)
        item.usesParallelEngine = true
        items.insert(item, at: 0)
        save()
        schedule()
        live.refresh(items, force: true)
    }
    func schedule() {
        guard !restoring else { return }
        var slots = maxConcurrent - tasks.count - items.filter { ($0.sharedSessionID != nil || $0.usesParallelEngine == true) && $0.status == .running }.count
        for index in items.indices.reversed() where slots > 0 && items[index].status == .queued {
            let item = items[index]
            if item.usesParallelEngine == true {
                items[index].status = .running
                if parallel.contains(item.id) { parallel.resume(item.id) }
                else { parallel.start(id: item.id, url: item.url, filename: item.filename, headers: item.headers, connections: connectionsPerFile, allowsCellular: allowsCellular) }
                slots -= 1
                continue
            }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: resumeURL(item.id)), !data.isEmpty {
                task = session.downloadTask(withResumeData: data)
            } else {
                var request = URLRequest(url: item.url)
                request.allowsCellularAccess = allowsCellular
                request.timeoutInterval = 60
                for (key, value) in item.headers { request.setValue(value, forHTTPHeaderField: key) }
                task = session.downloadTask(with: request)
            }
            task.taskDescription = item.id.uuidString
            tasks[item.id] = task
            items[index].status = .running
            items[index].error = nil
            items[index].speed = 0
            samples[item.id] = (Date(), items[index].received)
            slots -= 1
            task.resume()
        }
        live.refresh(items)
    }
    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].usesParallelEngine == true {
            if items[index].status == .queued { items[index].status = .paused; save(); live.refresh(items, force: true) }
            else { parallel.pause(id) }
            return
        }
        if items[index].sharedSessionID != nil { SharedTransferCoordinator.shared.pause(id); return }
        guard let task = tasks[id] else {
            if items[index].status == .queued { items[index].status = .paused; save(); live.refresh(items, force: true) }
            return
        }
        items[index].status = .pausing
        items[index].speed = 0
        save()
        task.cancel { data in
            DispatchQueue.main.async {
                guard let current = self.items.firstIndex(where: { $0.id == id }), self.items[current].status == .pausing else { return }
                if let data { self.persistResume(data, id: id) }
                else { self.removeResume(id); self.items[current].received = 0 }
                if self.tasks[id]?.taskIdentifier == task.taskIdentifier { self.tasks.removeValue(forKey: id) }
                self.items[current].status = .paused
                self.samples.removeValue(forKey: id)
                self.save()
                self.schedule()
                self.live.refresh(self.items, force: true)
            }
        }
    }
    func resume(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(items[index].status) else { return }
        if items[index].sharedSessionID != nil { SharedTransferCoordinator.shared.resume(id); return }
        items[index].status = .queued
        items[index].error = nil
        schedule()
        save()
        live.refresh(items, force: true)
    }
    func pauseAll() { for item in items where [.running, .queued].contains(item.status) { pause(item.id) } }
    func resumeAll() { for item in items where [.paused, .failed].contains(item.status) { resume(item.id) } }
    func remove(_ id: UUID) {
        if items.first(where: { $0.id == id })?.usesParallelEngine == true { parallel.remove(id) }
        if items.first(where: { $0.id == id })?.sharedSessionID != nil { SharedTransferCoordinator.shared.remove(id) }
        tasks.removeValue(forKey: id)?.cancel()
        if let item = items.first(where: { $0.id == id }), let file = fileURL(item) { try? FileManager.default.removeItem(at: file) }
        items.removeAll { $0.id == id }
        samples.removeValue(forKey: id)
        removeResume(id)
        save()
        schedule()
        live.refresh(items, force: true)
    }
    func fileURL(_ item: DownloadItem) -> URL? {
        guard let path = item.relativePath else { return nil }
        return downloads.appendingPathComponent((path as NSString).lastPathComponent)
    }
    @discardableResult
    func save() -> Bool {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: root.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSave = Date()
            return true
        } catch { notice = "Could not save the queue: \(error.localizedDescription)"; return false }
    }
    func settingsChanged() {
        UserDefaults(suiteName: ShareStore.groupID)?.set(allowsCellular, forKey: "allowsCellular")
        schedule(); live.refresh(items, force: true)
    }
    private func importParallelTransfer(_ transfer: FetchDockTransferEngine.Transfer) {
        guard let index = items.firstIndex(where: { $0.id == transfer.id }), items[index].usesParallelEngine == true else { return }
        if items[index].status == .completed { return }
        items[index].filename = transfer.filename
        items[index].received = transfer.received; items[index].expected = transfer.expected
        items[index].speed = transfer.speed; items[index].error = transfer.error
        items[index].connections = transfer.mode == .segmented ? transfer.parts.count : 1
        switch transfer.state {
        case .running: items[index].status = .running
        case .paused: items[index].status = .paused
        case .failed, .cancelled: items[index].status = .failed
        case .completed:
            do {
                let name = transfer.id.uuidString + "-" + DownloadItem.safeName(transfer.filename)
                let destination = downloads.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.copyItem(at: parallel.fileURL(transfer), to: destination)
                }
                items[index].relativePath = name; items[index].status = .completed; items[index].headers = [:]
                if save() { parallel.remove(transfer.id) }
            } catch { items[index].status = .failed; items[index].error = error.localizedDescription }
        }
        if Date().timeIntervalSince(lastSave) >= 3 || transfer.state != .running { save() }
        live.refresh(items, force: transfer.state != .running)
        if transfer.state != .running { schedule() }
    }
    func importSharedTransfers() {
        let coordinator = SharedTransferCoordinator.shared
        guard let sharedStore = try? coordinator.store() else { return }
        var finished: [UUID] = []
        let records = coordinator.records().sorted { $0.createdAt < $1.createdAt }
        guard !records.isEmpty else { return }
        for record in records {
            if !items.contains(where: { $0.id == record.id }) {
                var item = DownloadItem(url: record.url, filename: record.filename)
                item.id = record.id; item.createdAt = record.createdAt; item.sharedSessionID = record.sessionID
                items.insert(item, at: 0)
            }
            guard let index = items.firstIndex(where: { $0.id == record.id }) else { continue }
            if items[index].status == .completed, let existing = fileURL(items[index]), FileManager.default.fileExists(atPath: existing.path) {
                finished.append(record.id); continue
            }
            items[index].sharedSessionID = record.sessionID
            items[index].status = record.status; items[index].filename = record.filename
            items[index].received = record.received; items[index].expected = record.expected
            items[index].speed = record.speed; items[index].error = record.error
            if record.status == .completed, let file = record.file {
                let name = record.id.uuidString + "-" + DownloadItem.safeName(record.filename)
                let destination = downloads.appendingPathComponent(name)
                do {
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: sharedStore.fileURL(file), to: destination)
                    }
                    items[index].relativePath = name; items[index].sharedSessionID = nil
                    finished.append(record.id)
                } catch {
                    items[index].status = .failed; items[index].error = "Could not import shared file: \(error.localizedDescription)"
                }
            }
        }
        // Acknowledge only after the normal queue has durably recorded the imported file.
        if save() { finished.forEach { coordinator.forgetCompleted($0) } }
        schedule(); live.refresh(items, force: true)
    }
    private func resumeURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".resume") }
    private func persistResume(_ data: Data, id: UUID) {
        do { try data.write(to: resumeURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        catch { notice = "Could not save resume information: \(error.localizedDescription)" }
    }
    private func removeResume(_ id: UUID) { try? FileManager.default.removeItem(at: resumeURL(id)) }
    private func index(for task: URLSessionTask) -> Int? {
        guard let id = UUID(uuidString: task.taskDescription ?? "") else { return nil }
        // Background delegates may arrive before getAllTasks finishes on a cold launch.
        if tasks[id] == nil, restoring || reconciling, let download = task as? URLSessionDownloadTask {
            tasks[id] = download
        }
        guard tasks[id]?.taskIdentifier == task.taskIdentifier else { return nil }
        return items.firstIndex { $0.id == id }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = index(for: downloadTask), items[index].status == .running else { return }
        let id = items[index].id
        items[index].error = nil
        items[index].received = max(0, totalBytesWritten)
        items[index].expected = max(0, totalBytesExpectedToWrite)
        if let sample = samples[id] {
            let elapsed = Date().timeIntervalSince(sample.0)
            if elapsed >= 0.8 {
                let measured = max(0, Double(totalBytesWritten - sample.1) / elapsed)
                items[index].speed = items[index].speed == 0 ? measured : 0.3 * measured + 0.7 * items[index].speed
                samples[id] = (Date(), totalBytesWritten)
            }
        } else { samples[id] = (Date(), totalBytesWritten) }
        if let name = downloadTask.response?.suggestedFilename { items[index].filename = DownloadItem.safeName(name) }
        if Date().timeIntervalSince(lastSave) >= 3 { save() }
        live.refresh(items)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = index(for: downloadTask) else { return }
        let id = items[index].id
        if let response = downloadTask.response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            items[index].status = .failed
            items[index].error = "Server returned HTTP \(response.statusCode). Check the link or sign in using Browser."
            removeResume(id)
            items[index].received = 0
            items[index].expected = 0
            return
        }
        do {
            let name = DownloadItem.safeName(downloadTask.response?.suggestedFilename ?? items[index].filename)
            let path = String(id.uuidString.prefix(8)) + "-" + name
            let destination = downloads.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            // Move the temporary file before this delegate callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            items[index].filename = name
            items[index].relativePath = path
            items[index].status = .completed
            items[index].received = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? downloadTask.countOfBytesReceived
            items[index].expected = items[index].received
            items[index].speed = 0
            items[index].error = nil
            items[index].headers = [:]
            removeResume(id)
        } catch {
            items[index].status = .failed
            items[index].error = "Could not save file: \(error.localizedDescription)"
        }
        save()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = index(for: task) else { return }
        let id = items[index].id
        // Pause's completion owns the task until resume data has been written.
        if [.pausing, .paused].contains(items[index].status) { return }
        tasks.removeValue(forKey: id)
        samples.removeValue(forKey: id)
        items[index].speed = 0
        if let error = error as NSError?, items[index].status != .completed {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { persistResume(data, id: id) }
            else { removeResume(id); items[index].received = 0 }
            items[index].status = .failed
            items[index].error = error.localizedDescription
        }
        save()
        schedule()
        live.refresh(items, force: true)
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let index = index(for: task) else { return }
        items[index].error = "Waiting for a network connection"
        items[index].speed = 0
        live.refresh(items, force: true)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        save()
        live.refresh(items, force: true)
        let done = backgroundCompletion
        backgroundCompletion = nil
        // Keep the system's background execution grant until ActivityKit has accepted the update.
        Task { @MainActor in
            await live.finishPendingUpdates()
            done?()
        }
    }
}
