// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Darwin
import Foundation
import Observation
import PhotosUI
import RenPlayCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct PickedImportItem: @unchecked Sendable {
    public let url: URL
    public let deleteAfterImport: Bool
    public let stopSecurityScope: (@Sendable () -> Void)?

    public init(url: URL, deleteAfterImport: Bool, stopSecurityScope: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.deleteAfterImport = deleteAfterImport
        self.stopSecurityScope = stopSecurityScope
    }
}

public enum SideloadPickerMode: String, Identifiable, Sendable {
    case archiveCopy
    case archiveInPlace
    case folder

    public var id: String { rawValue }
}

struct SideloadDocumentPicker: UIViewControllerRepresentable {
    let mode: SideloadPickerMode
    let onPick: @MainActor ([PickedImportItem]) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(mode: mode, onPick: onPick, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        switch mode {
        case .archiveCopy:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            controller.allowsMultipleSelection = true
        case .archiveInPlace:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
            controller.allowsMultipleSelection = true
        case .folder:
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            controller.allowsMultipleSelection = false
        }
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let mode: SideloadPickerMode
        let onPick: @MainActor ([PickedImportItem]) -> Void
        let onError: @MainActor (String) -> Void

        init(
            mode: SideloadPickerMode,
            onPick: @escaping @MainActor ([PickedImportItem]) -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.mode = mode
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            switch mode {
            case .archiveCopy:
                let items = urls.map { PickedImportItem(url: $0, deleteAfterImport: false) }
                onPick(items)

            case .folder:
                var items: [PickedImportItem] = []
                for url in urls {
                    let granted = url.startAccessingSecurityScopedResource()
                    let cleanup: (@Sendable () -> Void)?
                    if granted {
                        cleanup = { url.stopAccessingSecurityScopedResource() }
                    } else {
                        cleanup = nil
                    }
                    items.append(PickedImportItem(url: url, deleteAfterImport: false, stopSecurityScope: cleanup))
                }
                onPick(items)

            case .archiveInPlace:
                let pickedURLs = urls
                let onPickCallback = onPick
                let onErrorCallback = onError
                DispatchQueue.global(qos: .userInitiated).async {
                    var stagedItems: [PickedImportItem] = []
                    var firstError: String?
                    for srcURL in pickedURLs {
                        let granted = srcURL.startAccessingSecurityScopedResource()
                        defer {
                            if granted { srcURL.stopAccessingSecurityScopedResource() }
                        }
                        do {
                            let stagedURL = try Self.stageCoordinatedCopy(from: srcURL)
                            stagedItems.append(PickedImportItem(url: stagedURL, deleteAfterImport: true))
                        } catch {
                            if firstError == nil {
                                firstError = "\(srcURL.lastPathComponent): \(error.localizedDescription)"
                            }
                        }
                    }
                    let itemsSnapshot = stagedItems
                    let errorSnapshot = firstError
                    Task { @MainActor in
                        if !itemsSnapshot.isEmpty {
                            onPickCallback(itemsSnapshot)
                        } else if let errorSnapshot {
                            onErrorCallback("In-place file copy failed: \(errorSnapshot)")
                        }
                    }
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}

        nonisolated private static func stageCoordinatedCopy(from url: URL) throws -> URL {
            let fm = FileManager.default
            let stageDir = fm.temporaryDirectory.appendingPathComponent("renplay-picked-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let dest = stageDir.appendingPathComponent(url.lastPathComponent)

            let coordinator = NSFileCoordinator()
            var coordError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordError) { readURL in
                do {
                    try fm.copyItem(at: readURL, to: dest)
                } catch {
                    copyError = error
                }
            }
            if let coordError {
                throw coordError
            }
            if copyError != nil {
                // Fall back to mapped Data read if FileProvider refuses copyItem metadata.
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try data.write(to: dest, options: .atomic)
            }
            return dest
        }
    }
}

struct WiFiTransferJob: Identifiable, Sendable, Codable, Equatable {
    enum Phase: String, Sendable, Codable {
        case receiving
        case importing
        case completed
        case failed
    }

    let id: String
    let filename: String
    var totalBytes: Int64
    var receivedBytes: Int64
    var phase: Phase
    var progress: Double
    var message: String
    var gameTitle: String?
    var engineVersion: String?
}

private final class UploadSocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private var snapshotJSON = Data("{\"jobs\":[]}".utf8)

    func set(_ newFD: Int32) {
        lock.lock()
        fd = newFD
        stopped = false
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        let cur = fd
        fd = -1
        lock.unlock()
        if cur >= 0 {
            Darwin.shutdown(cur, SHUT_RDWR)
            Darwin.close(cur)
        }
    }

    func isStopped() -> Bool {
        lock.lock()
        let v = stopped
        lock.unlock()
        return v
    }

    func setStatusSnapshot(_ data: Data) {
        lock.lock()
        snapshotJSON = data
        lock.unlock()
    }

    func getStatusSnapshot() -> Data {
        lock.lock()
        let data = snapshotJSON
        lock.unlock()
        return data
    }
}

private final class WeakUploadServerRef: @unchecked Sendable {
    weak var server: LocalWiFiUploadServer?
    init(_ server: LocalWiFiUploadServer) {
        self.server = server
    }
}

@MainActor
@Observable
final class LocalWiFiUploadServer {
    var serverURLString: String?
    var statusText: String = "Starting server..."
    var jobs: [WiFiTransferJob] = []
    var errorMessage: String?

    private let socketHolder = UploadSocketHolder()
    private var onImportUpload: ((URL, @escaping @Sendable (Double, String) -> Void) async -> Result<GameEntry, Error>)?

    func start(
        onImportUpload: @escaping (URL, @escaping @Sendable (Double, String) -> Void) async -> Result<GameEntry, Error>
    ) {
        stop()
        self.onImportUpload = onImportUpload
        self.errorMessage = nil
        self.statusText = "Starting server..."
        self.jobs = []
        syncStatusSnapshot()

        let holder = socketHolder
        let ip = Self.localIPv4Address() ?? "127.0.0.1"
        let weakRef = WeakUploadServerRef(self)

        DispatchQueue.global(qos: .userInitiated).async {
            let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard listenFD >= 0 else {
                Task { @MainActor in
                    weakRef.server?.errorMessage = "Could not create local socket."
                }
                return
            }

            var reuse: Int32 = 1
            setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var boundPort: UInt16 = 8080
            if !Self.bindSocket(listenFD, port: 8080) {
                if Self.bindSocket(listenFD, port: 0) {
                    boundPort = Self.assignedPort(of: listenFD) ?? 0
                } else {
                    Darwin.close(listenFD)
                    Task { @MainActor in
                        weakRef.server?.errorMessage = "Could not bind a local port."
                    }
                    return
                }
            }

            guard Darwin.listen(listenFD, 8) == 0 else {
                Darwin.close(listenFD)
                Task { @MainActor in
                    weakRef.server?.errorMessage = "Could not listen on port \(boundPort)."
                }
                return
            }

            holder.set(listenFD)
            let urlStr = "http://\(ip):\(boundPort)"
            Task { @MainActor in
                weakRef.server?.serverURLString = urlStr
                weakRef.server?.statusText = "Waiting for files"
            }

            while !holder.isStopped() {
                var addr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(listenFD, sockPtr, &addrLen)
                    }
                }
                if clientFD < 0 {
                    if errno == EINTR && !holder.isStopped() {
                        continue
                    }
                    break
                }
                DispatchQueue.global(qos: .utility).async {
                    Self.handleClient(
                        clientFD,
                        statusSnapshotProvider: { holder.getStatusSnapshot() },
                        onReceiveStart: { jobID, filename, total in
                            Task { @MainActor in
                                weakRef.server?.recordReceiveStart(id: jobID, filename: filename, totalBytes: total)
                            }
                        },
                        onReceiveProgress: { jobID, received, total in
                            Task { @MainActor in
                                weakRef.server?.recordReceiveProgress(id: jobID, receivedBytes: received, totalBytes: total)
                            }
                        },
                        onReceiveFailed: { jobID, reason in
                            Task { @MainActor in
                                weakRef.server?.recordFailure(id: jobID, message: reason)
                            }
                        },
                        onComplete: { jobID, uploadedURL in
                            Task { @MainActor in
                                await weakRef.server?.handleUploadedFile(id: jobID, tempURL: uploadedURL)
                            }
                        }
                    )
                }
            }
        }
    }

    func stop() {
        socketHolder.stop()
        serverURLString = nil
    }

    private func recordReceiveStart(id: String, filename: String, totalBytes: Int64) {
        let job = WiFiTransferJob(
            id: id,
            filename: filename,
            totalBytes: totalBytes,
            receivedBytes: 0,
            phase: .receiving,
            progress: 0,
            message: "Uploading..."
        )
        jobs.insert(job, at: 0)
        statusText = "Receiving \(filename)"
        syncStatusSnapshot()
    }

    private func recordReceiveProgress(id: String, receivedBytes: Int64, totalBytes: Int64) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].receivedBytes = receivedBytes
        jobs[idx].progress = totalBytes > 0 ? min(1.0, Double(receivedBytes) / Double(totalBytes)) : 0
        syncStatusSnapshot()
    }

    private func recordFailure(id: String, message: String) {
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].phase = .failed
            jobs[idx].message = message
        }
        statusText = "Transfer failed"
        syncStatusSnapshot()
    }

    private func handleUploadedFile(id: String, tempURL: URL) async {
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs[idx].phase = .importing
            jobs[idx].progress = 0.02
            jobs[idx].receivedBytes = jobs[idx].totalBytes
            jobs[idx].message = "Extracting archive..."
        }
        statusText = "Importing \(tempURL.lastPathComponent)..."
        syncStatusSnapshot()

        guard let onImportUpload else { return }
        let weakRef = WeakUploadServerRef(self)
        let result = await onImportUpload(tempURL) { frac, msg in
            Task { @MainActor in
                guard let server = weakRef.server,
                      let idx = server.jobs.firstIndex(where: { $0.id == id }) else { return }
                server.jobs[idx].phase = .importing
                server.jobs[idx].progress = frac
                server.jobs[idx].message = msg
                server.syncStatusSnapshot()
            }
        }

        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let entry):
            jobs[idx].phase = .completed
            jobs[idx].progress = 1.0
            jobs[idx].gameTitle = entry.displayName
            jobs[idx].engineVersion = entry.detectedEngineVersion
            jobs[idx].message = "Added to Library"
            statusText = "Added \(entry.displayName)"
        case .failure(let error):
            jobs[idx].phase = .failed
            jobs[idx].message = error.localizedDescription
            statusText = "Import failed"
        }
        syncStatusSnapshot()
    }

    private func syncStatusSnapshot() {
        let payload = ["jobs": jobs]
        if let data = try? JSONEncoder().encode(payload) {
            socketHolder.setStatusSnapshot(data)
        }
    }

    nonisolated private static func bindSocket(_ fd: Int32, port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    nonisolated private static func assignedPort(of fd: Int32) -> UInt16? {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &len)
            }
        }
        guard rc == 0 else { return nil }
        return UInt16(bigEndian: addr.sin_port)
    }

    nonisolated private static func handleClient(
        _ fd: Int32,
        statusSnapshotProvider: () -> Data,
        onReceiveStart: @escaping @Sendable (String, String, Int64) -> Void,
        onReceiveProgress: @escaping @Sendable (String, Int64, Int64) -> Void,
        onReceiveFailed: @escaping @Sendable (String, String) -> Void,
        onComplete: @escaping @Sendable (String, URL) -> Void
    ) {
        defer { Darwin.close(fd) }

        var headerData = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var headerEndRange: Range<Data.Index>?
        let separator = Data("\r\n\r\n".utf8)

        while headerData.count < 65536 {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            headerData.append(contentsOf: chunk[..<n])
            if let r = headerData.range(of: separator) {
                headerEndRange = r
                break
            }
        }

        guard let headerEndRange else {
            sendHTTP(fd, status: "400 Bad Request", contentType: "text/plain", body: Data("Malformed HTTP request".utf8))
            return
        }

        let headerText = String(decoding: headerData[..<headerEndRange.lowerBound], as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        if method == "GET" {
            let pathOnly = rawTarget.components(separatedBy: "?").first ?? rawTarget
            if pathOnly == "/status" {
                sendHTTP(fd, status: "200 OK", contentType: "application/json", body: statusSnapshotProvider())
            } else {
                sendHTTP(fd, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(uploadHTML.utf8))
            }
            return
        }

        guard method == "PUT", rawTarget.hasPrefix("/upload/") else {
            sendHTTP(fd, status: "404 Not Found", contentType: "text/plain", body: Data("Not Found".utf8))
            return
        }

        var contentLength: Int64 = -1
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "content-length" {
                    let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    contentLength = Int64(val) ?? -1
                }
            }
        }

        guard contentLength >= 0 else {
            sendHTTP(fd, status: "411 Length Required", contentType: "text/plain", body: Data("Content-Length required".utf8))
            return
        }

        let pathAndQuery = String(rawTarget.dropFirst("/upload/".count)).components(separatedBy: "?")
        let encodedName = pathAndQuery.first ?? "upload.zip"
        let decodedName = encodedName.removingPercentEncoding ?? encodedName
        let safeName = sanitizeUploadFilename(decodedName)
        let jobID = extractQueryParam(name: "id", from: pathAndQuery.dropFirst().first ?? "") ?? UUID().uuidString

        let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent("renplay-wifi-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let destURL = stageDir.appendingPathComponent(safeName)
            FileManager.default.createFile(atPath: destURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destURL)
            defer { try? fileHandle.close() }

            onReceiveStart(jobID, safeName, contentLength)
            let initialBody = headerData[headerEndRange.upperBound...]
            var received: Int64 = 0
            var remaining = contentLength
            var lastProgressEmit = CFAbsoluteTimeGetCurrent()

            if !initialBody.isEmpty {
                let toWrite = Int(min(Int64(initialBody.count), remaining))
                if toWrite > 0 {
                    let slice = Data(initialBody.prefix(toWrite))
                    try fileHandle.write(contentsOf: slice)
                    remaining -= Int64(toWrite)
                    received += Int64(toWrite)
                }
            }

            var buf = [UInt8](repeating: 0, count: 65536)
            while remaining > 0 {
                let want = Int(min(Int64(buf.count), remaining))
                let n = Darwin.recv(fd, &buf, want, 0)
                if n <= 0 {
                    throw NSError(domain: "RenPlayUpload", code: -1, userInfo: [NSLocalizedDescriptionKey: "Upload stream interrupted"])
                }
                try fileHandle.write(contentsOf: buf[..<n])
                remaining -= Int64(n)
                received += Int64(n)
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastProgressEmit >= 0.15 {
                    lastProgressEmit = now
                    onReceiveProgress(jobID, received, contentLength)
                }
            }

            let okBody = (try? JSONEncoder().encode(["id": jobID])) ?? Data("{\"ok\":true}".utf8)
            sendHTTP(fd, status: "200 OK", contentType: "application/json", body: okBody)
            onComplete(jobID, destURL)
        } catch {
            try? FileManager.default.removeItem(at: stageDir)
            onReceiveFailed(jobID, error.localizedDescription)
            sendHTTP(fd, status: "500 Internal Server Error", contentType: "text/plain", body: Data(error.localizedDescription.utf8))
        }
    }

    nonisolated private static func extractQueryParam(name: String, from query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == name {
                let raw = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                return raw.isEmpty ? nil : raw
            }
        }
        return nil
    }

    nonisolated private static func sendHTTP(_ fd: Int32, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        payload.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < payload.count {
                let n = Darwin.send(fd, base.advanced(by: sent), payload.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    nonisolated private static func sanitizeUploadFilename(_ raw: String) -> String {
        let leaf = (raw as NSString).lastPathComponent
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = leaf.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "game.zip" : cleaned
    }

    nonisolated private static func localIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(firstAddr) }

        var fallback: String?
        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sa,
                socklen_t(sa.pointee.sa_len),
                &hostBuf,
                socklen_t(hostBuf.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }
            let ipBytes = hostBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            let ip = String(decoding: ipBytes, as: UTF8.self)
            let ifName = String(decoding: Data(bytes: current.pointee.ifa_name, count: Int(strlen(current.pointee.ifa_name))), as: UTF8.self)
            if ifName == "en0" {
                return ip
            }
            if fallback == nil {
                fallback = ip
            }
        }
        return fallback
    }

    nonisolated private static let uploadHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>RenPlay Wi-Fi Transfer</title>
      <style>
        :root { color-scheme: dark; }
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 600px; margin: 36px auto; padding: 0 16px; background: #0d0e12; color: #f5f5f7; }
        h2 { margin: 0 0 6px; font-size: 22px; }
        p { margin: 0 0 18px; color: #9a9aa6; font-size: 14px; }
        .drop { border: 1.5px dashed #3a3f4b; border-radius: 14px; padding: 26px 18px; text-align: center; background: #161821; transition: border-color .15s, background .15s; }
        .drop.over { border-color: #0a84ff; background: #162133; }
        .actions { display: flex; gap: 10px; justify-content: center; flex-wrap: wrap; margin-top: 12px; }
        button { background: #0a84ff; color: #fff; border: 0; border-radius: 10px; padding: 10px 18px; font-size: 14px; font-weight: 600; cursor: pointer; }
        button.secondary { background: #262936; }
        button:disabled { opacity: .5; cursor: default; }
        #jobs { margin-top: 20px; display: flex; flex-direction: column; gap: 10px; }
        .job { background: #161821; border: 1px solid #242734; border-radius: 12px; padding: 12px 14px; }
        .row { display: flex; justify-content: space-between; align-items: center; gap: 10px; font-size: 14px; }
        .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .pill { font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 999px; background: #252836; color: #b5b8c5; white-space: nowrap; }
        .pill.ok { background: rgba(48,209,88,.18); color: #30d158; }
        .pill.err { background: rgba(255,69,58,.18); color: #ff453a; }
        .pill.work { background: rgba(10,132,255,.18); color: #409cff; }
        progress { width: 100%; height: 6px; margin-top: 10px; border-radius: 999px; overflow: hidden; accent-color: #0a84ff; }
        .sub { margin-top: 6px; font-size: 12px; color: #9a9aa6; }
      </style>
    </head>
    <body>
      <h2>RenPlay Wi-Fi Transfer</h2>
      <p>Supports .zip, .apk, .7z, .rar, .tar.xz, .tar.zst, and .tar.bz2 archives.</p>
      <div id="drop" class="drop">
        <div>Drop game archives here or choose files</div>
        <input id="file" type="file" multiple hidden>
        <div class="actions">
          <button id="pick" type="button" class="secondary">Choose Files</button>
          <button id="btn" type="button">Upload</button>
        </div>
      </div>
      <div id="jobs"></div>
      <script>
        const fileEl = document.getElementById('file');
        const pickBtn = document.getElementById('pick');
        const btn = document.getElementById('btn');
        const drop = document.getElementById('drop');
        const jobsEl = document.getElementById('jobs');
        let pendingFiles = [];
        let pollTimer = null;

        pickBtn.onclick = () => fileEl.click();
        fileEl.onchange = () => { pendingFiles = Array.from(fileEl.files || []); btn.textContent = pendingFiles.length ? 'Upload (' + pendingFiles.length + ')' : 'Upload'; };
        drop.ondragover = (e) => { e.preventDefault(); drop.classList.add('over'); };
        drop.ondragleave = () => drop.classList.remove('over');
        drop.ondrop = (e) => { e.preventDefault(); drop.classList.remove('over'); pendingFiles = Array.from(e.dataTransfer.files || []); btn.textContent = pendingFiles.length ? 'Upload (' + pendingFiles.length + ')' : 'Upload'; };

        function fmtBytes(b) {
          if (!b) return '0 B';
          const u = ['B','KB','MB','GB'];
          const i = Math.min(3, Math.floor(Math.log(b) / Math.log(1024)));
          return (b / Math.pow(1024, i)).toFixed(i ? 1 : 0) + ' ' + u[i];
        }

        function esc(s) {
          return String(s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        }

        async function refreshStatus() {
          try {
            const res = await fetch('/status', { cache: 'no-store' });
            if (!res.ok) return;
            const data = await res.json();
            const list = data.jobs || [];
            jobsEl.innerHTML = list.map(j => {
              const pct = Math.round((j.progress || 0) * 100);
              let cls = 'work';
              let badge = (j.phase === 'importing' ? 'Importing ' : 'Uploading ') + pct + '%';
              if (j.phase === 'completed') { cls = 'ok'; badge = 'Added'; }
              if (j.phase === 'failed') { cls = 'err'; badge = 'Failed'; }
              const title = j.gameTitle ? j.gameTitle + (j.engineVersion ? ' • v' + j.engineVersion : '') : j.message;
              const bar = (j.phase === 'receiving' || j.phase === 'importing') ? '<progress max="100" value="' + pct + '"></progress>' : '';
              return '<div class="job"><div class="row"><div class="name">' + esc(j.filename) + '</div><div class="pill ' + cls + '">' + esc(badge) + '</div></div>' + bar + '<div class="sub">' + fmtBytes(j.totalBytes) + ' • ' + esc(title) + '</div></div>';
            }).join('');
            const active = list.some(j => j.phase === 'receiving' || j.phase === 'importing');
            if (!active && pollTimer) { clearInterval(pollTimer); pollTimer = null; }
          } catch (_) {}
        }

        function ensurePolling() {
          if (!pollTimer) pollTimer = setInterval(refreshStatus, 400);
        }

        btn.onclick = async () => {
          if (!pendingFiles.length) { fileEl.click(); return; }
          btn.disabled = true;
          ensurePolling();
          for (const f of pendingFiles) {
            const id = (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
            await new Promise((resolve) => {
              const xhr = new XMLHttpRequest();
              xhr.open('PUT', '/upload/' + encodeURIComponent(f.name) + '?id=' + encodeURIComponent(id));
              xhr.onload = () => { refreshStatus(); resolve(); };
              xhr.onerror = () => { refreshStatus(); resolve(); };
              xhr.send(f);
            });
          }
          pendingFiles = [];
          fileEl.value = '';
          btn.textContent = 'Upload';
          btn.disabled = false;
          refreshStatus();
        };
        refreshStatus();
      </script>
    </body>
    </html>
    """
}

struct WiFiUploadSheetView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var server = LocalWiFiUploadServer()
    @State private var copiedAddress = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let url = server.serverURLString {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url)
                                    .font(.headline.monospaced())
                                    .textSelection(.enabled)
                                Text(server.statusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(copiedAddress ? "Copied" : "Copy") {
                                UIPasteboard.general.string = url
                                copiedAddress = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    } else if let err = server.errorMessage {
                        Text(err)
                            .foregroundStyle(.red)
                    } else {
                        ProgressView(server.statusText)
                    }
                } header: {
                    Text("Browser Address")
                } footer: {
                    Text("Keep this sheet open while transferring files. Imports start automatically once uploaded.")
                }

                Section("Transfers") {
                    if server.jobs.isEmpty {
                        Text("No transfers yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(server.jobs) { job in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(job.filename)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    phaseBadge(for: job)
                                }
                                if job.phase == .receiving || job.phase == .importing {
                                    ProgressView(value: job.progress)
                                }
                                HStack {
                                    Text(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))
                                    Text("•")
                                    Text(jobSubtitle(for: job))
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .foregroundStyle(job.phase == .failed ? .red : .secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Wi-Fi Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                server.start { tempURL, progress in
                    await appState.importUploadedArchive(at: tempURL, progress: progress)
                }
            }
            .onDisappear {
                server.stop()
            }
        }
    }

    @ViewBuilder
    private func phaseBadge(for job: WiFiTransferJob) -> some View {
        switch job.phase {
        case .receiving:
            Text("Uploading \(Int(job.progress * 100))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.blue)
        case .importing:
            Text("Importing \(Int(job.progress * 100))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.blue)
        case .completed:
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private func jobSubtitle(for job: WiFiTransferJob) -> String {
        switch job.phase {
        case .completed:
            let title = job.gameTitle ?? job.filename
            if let ver = job.engineVersion {
                return "\(title) • Ren'Py \(ver)"
            }
            return title
        default:
            return job.message
        }
    }
}

struct URLDownloadSheetView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/game.zip", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Archive URL")
                } footer: {
                    Text("Supports direct links to .zip, .7z, .rar, .apk, .tar.xz, .tar.zst, and .tar.gz files.")
                }

                Section {
                    Button("Download & Import") {
                        let value = urlText
                        dismiss()
                        appState.downloadAndImport(urlString: value)
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Download Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ArtworkPhotoPicker: View {
    let title: String
    let hasCustomImage: Bool
    let onSelectData: (Data) -> Void
    let onReset: () -> Void

    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        HStack {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Label(title, systemImage: "photo")
            }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        onSelectData(data)
                    }
                    selectedItem = nil
                }
            }

            if hasCustomImage {
                Spacer()
                Button("Reset", role: .destructive, action: onReset)
                    .buttonStyle(.borderless)
            }
        }
    }
}
#endif
