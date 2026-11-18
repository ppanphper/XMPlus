import Flutter
import UIKit
import UniformTypeIdentifiers

/// Owns system resources for all Dart calls; no account credentials enter URLSession.
final class IosPlatformBridge: NSObject, UIDocumentPickerDelegate, URLSessionDownloadDelegate {
    static let shared = IosPlatformBridge()
    private var channel: FlutterMethodChannel?
    private var pickerResult: FlutterResult?
    private var choosingDirectory = false
    private var scopes: [String: URL] = [:]
    private var containerHomes: [String] = []
    private var work: [String: UIBackgroundTaskIdentifier] = [:]
    private var mediaSessions: [String: Int] = [:]
    private var waiting: [String: FlutterResult] = [:]
    private var completed: [String: [String: Any]] = [:]
    private var downloads: [String: URLSessionDownloadTask] = [:]
    var backgroundCompletion: (() -> Void)?
    private var eventsFinished = false
    private var cancelledTasks = Set<Int>()
    private let defaults = UserDefaults.standard
    private var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ios-transfers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return url
    }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(Bundle.main.bundleIdentifier!).audio-transfer")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    func register(_ messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "teikengstudio.xmplus/ios", binaryMessenger: messenger)
        channel?.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    }

    private func fail(_ result: FlutterResult, _ error: Error) {
        result(FlutterError(code: "ios_platform", message: error.localizedDescription, details: nil))
    }
    private func error(_ message: String) -> NSError {
        NSError(domain: "XMPlus", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private var presenter: UIViewController? {
        var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
    private func localURL(_ path: String?) throws -> URL {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { throw error("文件路径无效") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        do {
            switch call.method {
            case "initialize":
                let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
                let knownHomes = defaults.stringArray(forKey: "xmplus.containerHomes") ?? []
                containerHomes = Array(Set(knownHomes + [home.path, home.resolvingSymlinksInPath().path])).sorted { $0.count > $1.count }
                defaults.set(containerHomes, forKey: "xmplus.containerHomes")
                restoreScopes()
                if let data = try? Data(contentsOf: root.appendingPathComponent("completed.json")),
                   let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] { completed = records }
                for (id, record) in completed {
                    if Date().timeIntervalSince1970 - (record["savedAt"] as? Double ?? 0) > 86400 { releaseDownload(id) }
                }
                session.getAllTasks { [weak self] tasks in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        for task in tasks {
                            if let id = task.taskDescription, let download = task as? URLSessionDownloadTask { self.downloads[id] = download }
                        }
                        result(["currentHomes": [home.path, home.resolvingSymlinksInPath().path]])
                    }
                }
            case "resolvePath":
                let path = try localURL(args["path"] as? String).path
                let match = scopes.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
                if let match, let url = scopes[match] {
                    result(url.path + path.dropFirst(match.count))
                } else if let home = containerHomes.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    let current = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
                    result(current + path.dropFirst(home.count))
                } else { result(path) }
            case "pickDirectory":
                guard pickerResult == nil, let presenter else { throw error("请先关闭当前文件选择窗口") }
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                choosingDirectory = true; pickerResult = result; picker.delegate = self
                presenter.present(picker, animated: true)
            case "exportFile":
                guard pickerResult == nil, let presenter else { throw error("请先关闭当前文件选择窗口") }
                let url = try localURL(args["path"] as? String)
                guard FileManager.default.fileExists(atPath: url.path) else { throw error("文件已不存在") }
                let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                choosingDirectory = false; pickerResult = result; picker.delegate = self
                presenter.present(picker, animated: true)
            case "shareFile":
                guard let presenter else { throw error("请返回应用后重试") }
                let url = try localURL(args["path"] as? String)
                guard FileManager.default.fileExists(atPath: url.path) else { throw error("文件已不存在") }
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                    popover.permittedArrowDirections = []
                }
                activity.completionWithItemsHandler = { _, _, _, failure in
                    if let failure { self.fail(result, failure) } else { result(nil) }
                }
                presenter.present(activity, animated: true)
            case "commitFile":
                let source = try localURL(args["source"] as? String)
                let target = try localURL(args["target"] as? String)
                let overwrite = args["overwrite"] as? Bool ?? false
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try self.commitFile(source, target, overwrite: overwrite)
                        DispatchQueue.main.async { result(nil) }
                    } catch { DispatchQueue.main.async { self.fail(result, error) } }
                }
            case "availableBytes":
                let url = try localURL(args["path"] as? String)
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                if let capacity = values.volumeAvailableCapacityForImportantUsage { result(capacity) }
                else if let capacity = values.volumeAvailableCapacity { result(Int64(capacity)) }
                else {
                    let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
                    guard let capacity = attributes[.systemFreeSize] as? NSNumber else { throw error("无法查询可用空间") }
                    result(capacity.int64Value)
                }
            case "beginWork":
                guard let id = args["id"] as? String else { throw error("后台任务缺少标识") }
                beginWork(id); result(nil)
            case "bindMediaSession":
                if let id = args["id"] as? String, let session = args["session"] as? Int { mediaSessions[id] = session }; result(nil)
            case "endWork":
                if let id = args["id"] as? String { endWork(id) }; result(nil)
            case "download": try startDownload(args, result)
            case "cancelDownload":
                if let id = args["id"] as? String {
                    if let task = downloads.removeValue(forKey: id) {
                        cancelledTasks.insert(task.taskIdentifier)
                        task.cancel()
                    }
                    if let callback = waiting.removeValue(forKey: id) { callback(FlutterError(code: "cancelled", message: "下载已暂停", details: nil)) }
                    releaseDownload(id)
                }
                result(nil)
            case "releaseDownload":
                if let id = args["id"] as? String { releaseDownload(id) }; result(nil)
            default: result(FlutterMethodNotImplemented)
            }
        } catch { fail(result, error) }
    }

    private func commitFile(_ source: URL, _ target: URL, overwrite: Bool) throws {
        let files = FileManager.default
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else { throw error("源文件不是普通文件") }
        let sourceVolume = try files.attributesOfFileSystem(forPath: source.path)[.systemNumber] as? NSNumber
        let targetVolume = try files.attributesOfFileSystem(forPath: target.deletingLastPathComponent().path)[.systemNumber] as? NSNumber
        guard sourceVolume != nil, sourceVolume == targetVolume else { throw error("无法跨存储卷安全保存文件") }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forMoving,
            writingItemAt: target, options: .forReplacing, error: &coordinationError) { from, to in
            do {
                if files.fileExists(atPath: to.path) {
                    guard overwrite else { throw self.error("目标文件已存在，源缓存已保留") }
                    let values = try to.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw self.error("目标不是普通文件") }
                    let backupName = ".xmplus-replaced-" + UUID().uuidString
                    let backup = to.deletingLastPathComponent().appendingPathComponent(backupName)
                    do {
                        _ = try files.replaceItemAt(to, withItemAt: from, backupItemName: backupName,
                            options: [.withoutDeletingBackupItem])
                        guard files.fileExists(atPath: to.path) else { throw self.error("文件替换未完成") }
                        try? files.removeItem(at: backup)
                    } catch {
                        if !files.fileExists(atPath: to.path), files.fileExists(atPath: backup.path) {
                            try? files.moveItem(at: backup, to: to)
                        }
                        throw error
                    }
                } else {
                    // moveItem refuses an existing target and does not pre-delete it.
                    try files.moveItem(at: from, to: to)
                }
            } catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func restoreScopes() {
        let records = defaults.dictionary(forKey: "xmplus.directoryBookmarks") as? [String: Data] ?? [:]
        for (oldPath, bookmark) in records {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            if scopes[oldPath] == nil && url.startAccessingSecurityScopedResource() { scopes[oldPath] = url }
            if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                var updated = defaults.dictionary(forKey: "xmplus.directoryBookmarks") as? [String: Data] ?? [:]
                updated[oldPath] = fresh; defaults.set(updated, forKey: "xmplus.directoryBookmarks")
            }
        }
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let result = pickerResult; pickerResult = nil; result?(nil)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let result = pickerResult; pickerResult = nil
        guard let result, let url = urls.first else { result?(nil); return }
        do {
            if choosingDirectory {
                let accessed = url.startAccessingSecurityScopedResource()
                guard accessed || url.path.hasPrefix(NSHomeDirectory() + "/") else { throw error("所选目录未授予访问权限") }
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                if scopes[url.path] != nil && accessed { url.stopAccessingSecurityScopedResource() }
                scopes[url.path] = url
                var records = defaults.dictionary(forKey: "xmplus.directoryBookmarks") as? [String: Data] ?? [:]
                records[url.path] = bookmark; defaults.set(records, forKey: "xmplus.directoryBookmarks")
            }
            result(url.path)
        } catch { fail(result, error) }
    }
    private func beginWork(_ id: String) {
        guard work[id] == nil else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "XMPlus media") { [weak self] in
            self?.channel?.invokeMethod("backgroundWorkExpired", arguments: id)
            if let session = self?.mediaSessions[id] { FFmpegKit.cancel(session) }
            self?.endWork(id)
        }
        if task != .invalid { work[id] = task }
    }
    private func endWork(_ id: String) {
        mediaSessions.removeValue(forKey: id)
        if let task = work.removeValue(forKey: id) { UIApplication.shared.endBackgroundTask(task) }
    }
    private func startDownload(_ args: [String: Any], _ result: @escaping FlutterResult) throws {
        guard let id = args["id"] as? String, id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let text = args["url"] as? String, let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw error("下载请求无效") }
        guard waiting[id] == nil else { throw error("下载请求已在执行") }
        if let saved = completed[id], let path = saved["path"] as? String, FileManager.default.fileExists(atPath: path) { result(saved); return }
        waiting[id] = result
        if let task = downloads[id] { task.resume(); return }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        let allowed = Set(["user-agent", "accept", "accept-encoding", "range", "if-range"])
        for (key, value) in args["headers"] as? [String: String] ?? [:] where allowed.contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.downloadTask(with: request)
        task.taskDescription = id; downloads[id] = task; eventsFinished = false; task.resume()
    }
    private func saveCompleted() {
        // Persist only reusable successful bodies. Signed CDN URLs and response
        // cookies remain in memory, as in the Dart cache policy.
        var durable: [String: [String: Any]] = [:]
        for (id, value) in completed {
            guard let status = value["status"] as? Int, status == 200 || status == 206 else { continue }
            var record = value
            if let raw = record["url"] as? String, var url = URLComponents(string: raw) {
                url.query = nil; url.fragment = nil; record["url"] = url.string ?? ""
            }
            let allowed = Set(["content-type", "content-length", "content-range", "content-encoding", "etag", "last-modified"])
            record["headers"] = (record["headers"] as? [String: String] ?? [:]).filter { allowed.contains($0.key) }
            durable[id] = record
        }
        if let data = try? JSONSerialization.data(withJSONObject: durable) { try? data.write(to: root.appendingPathComponent("completed.json"), options: .atomic) }
    }
    private func releaseDownload(_ id: String) {
        if let record = completed.removeValue(forKey: id), let path = record["path"] as? String,
           URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
            try? FileManager.default.removeItem(atPath: path)
        }
        saveCompleted()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.endWork("download-" + id) }
        finishEventsIfReady()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Background sessions may follow redirects without invoking this delegate.
        // Dart also validates the final URL before consuming the downloaded body.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let response = downloadTask.response as? HTTPURLResponse else { return }
        guard !cancelledTasks.contains(downloadTask.taskIdentifier) else { return }
        // A cancelled request may finish after a retry using the same cache key.
        if let current = downloads[id], current.taskIdentifier != downloadTask.taskIdentifier { return }
        do {
            let target = root.appendingPathComponent(id + ".body")
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
            let record: [String: Any] = ["status": response.statusCode, "headers": headers, "path": target.path, "url": response.url?.absoluteString ?? "", "savedAt": Date().timeIntervalSince1970]
            completed[id] = record; saveCompleted(); beginWork("download-" + id)
            waiting.removeValue(forKey: id)?(record)
        } catch {
            if let callback = waiting.removeValue(forKey: id) { fail(callback, error) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        if cancelledTasks.remove(task.taskIdentifier) != nil {
            finishEventsIfReady()
            return
        }
        if let current = downloads[id], current.taskIdentifier != task.taskIdentifier { return }
        downloads.removeValue(forKey: id)
        if let error, let callback = waiting.removeValue(forKey: id) { fail(callback, error) }
        finishEventsIfReady()
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventsFinished = true; finishEventsIfReady()
    }
    private func finishEventsIfReady() {
        guard eventsFinished, waiting.isEmpty else { return }
        let callback = backgroundCompletion; backgroundCompletion = nil; callback?()
    }
}
