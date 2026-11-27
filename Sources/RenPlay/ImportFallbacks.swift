// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Darwin
import Foundation
import Observation
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

private final class UploadSocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false

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
    var uploadedCount: Int = 0
    var errorMessage: String?

    private let socketHolder = UploadSocketHolder()
    private var onUploadedFile: ((URL) -> Void)?

    func start(onUploadedFile: @escaping (URL) -> Void) {
        stop()
        self.onUploadedFile = onUploadedFile
        self.errorMessage = nil
        self.statusText = "Starting local server..."

        let holder = socketHolder
        let ip = Self.localIPv4Address() ?? "127.0.0.1"
        let weakRef = WeakUploadServerRef(self)

        DispatchQueue.global(qos: .userInitiated).async {
            let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard listenFD >= 0 else {
                Task { @MainActor in
                    weakRef.server?.errorMessage = "Could not create TCP socket."
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
                        weakRef.server?.errorMessage = "Could not bind a local port for Wi-Fi upload."
                    }
                    return
                }
            }

            guard Darwin.listen(listenFD, 8) == 0 else {
                Darwin.close(listenFD)
                Task { @MainActor in
                    weakRef.server?.errorMessage = "Could not listen on local port \(boundPort)."
                }
                return
            }

            holder.set(listenFD)
            let urlStr = "http://\(ip):\(boundPort)"
            Task { @MainActor in
                weakRef.server?.serverURLString = urlStr
                weakRef.server?.statusText = "Ready for upload"
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
                    Self.handleClient(clientFD) { status in
                        Task { @MainActor in
                            weakRef.server?.statusText = status
                        }
                    } onComplete: { uploadedURL in
                        Task { @MainActor in
                            guard let server = weakRef.server else { return }
                            server.uploadedCount += 1
                            server.statusText = "Received \(uploadedURL.lastPathComponent)"
                            server.onUploadedFile?(uploadedURL)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        socketHolder.stop()
        serverURLString = nil
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
        onStatus: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (URL) -> Void
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
            sendHTTP(fd, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(uploadHTML.utf8))
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

        let encodedName = String(rawTarget.dropFirst("/upload/".count)).components(separatedBy: "?").first ?? "upload.zip"
        let decodedName = encodedName.removingPercentEncoding ?? encodedName
        let safeName = sanitizeUploadFilename(decodedName)
        let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent("renplay-wifi-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            let destURL = stageDir.appendingPathComponent(safeName)
            FileManager.default.createFile(atPath: destURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: destURL)
            defer { try? fileHandle.close() }

            onStatus("Receiving \(safeName)...")
            let initialBody = headerData[headerEndRange.upperBound...]
            var remaining = contentLength
            if !initialBody.isEmpty {
                let toWrite = Int(min(Int64(initialBody.count), remaining))
                if toWrite > 0 {
                    let slice = Data(initialBody.prefix(toWrite))
                    try fileHandle.write(contentsOf: slice)
                    remaining -= Int64(toWrite)
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
            }

            sendHTTP(fd, status: "200 OK", contentType: "application/json", body: Data("{\"ok\":true}".utf8))
            onComplete(destURL)
        } catch {
            try? FileManager.default.removeItem(at: stageDir)
            sendHTTP(fd, status: "500 Internal Server Error", contentType: "text/plain", body: Data(error.localizedDescription.utf8))
        }
    }

    nonisolated private static func sendHTTP(_ fd: Int32, status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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
      <title>RenPlay Wi-Fi Upload</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; max-width: 560px; margin: 40px auto; padding: 0 16px; background: #111; color: #f5f5f5; }
        .box { border: 2px dashed #555; border-radius: 12px; padding: 24px; text-align: center; background: #1b1b1e; }
        input[type=file] { margin: 16px 0; }
        button { background: #0a84ff; color: #fff; border: 0; border-radius: 8px; padding: 10px 18px; font-size: 15px; cursor: pointer; }
        progress { width: 100%; height: 18px; margin-top: 14px; display: none; }
        #status { margin-top: 12px; font-size: 14px; color: #b5b5bd; }
      </style>
    </head>
    <body>
      <h2>RenPlay Wi-Fi Upload</h2>
      <p>Upload a Ren'Py game archive (<code>.zip</code>, <code>.apk</code>, <code>.tar.gz</code>) directly into RenPlay.</p>
      <div class="box">
        <input id="file" type="file" multiple>
        <br>
        <button id="btn">Upload Selected Files</button>
        <progress id="prog" max="100" value="0"></progress>
        <div id="status">Idle</div>
      </div>
      <script>
        const fileEl = document.getElementById('file');
        const btn = document.getElementById('btn');
        const prog = document.getElementById('prog');
        const statusEl = document.getElementById('status');
        btn.onclick = async () => {
          if (!fileEl.files.length) return;
          btn.disabled = true;
          prog.style.display = 'block';
          for (const f of fileEl.files) {
            statusEl.textContent = 'Uploading ' + f.name + '...';
            await new Promise((resolve, reject) => {
              const xhr = new XMLHttpRequest();
              xhr.open('PUT', '/upload/' + encodeURIComponent(f.name));
              xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) prog.value = Math.round((e.loaded / e.total) * 100);
              };
              xhr.onload = () => xhr.status < 300 ? resolve() : reject(new Error(xhr.responseText || ('HTTP ' + xhr.status)));
              xhr.onerror = () => reject(new Error('Network error'));
              xhr.send(f);
            }).catch(err => { statusEl.textContent = 'Error: ' + err.message; throw err; });
          }
          prog.value = 100;
          statusEl.textContent = 'Upload finished. RenPlay is importing...';
          btn.disabled = false;
        };
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
            Form {
                Section {
                    if let url = server.serverURLString {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(url)
                                .font(.title3.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                            Button(copiedAddress ? "Copied" : "Copy Server URL") {
                                UIPasteboard.general.string = url
                                copiedAddress = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    } else if let err = server.errorMessage {
                        Text(err)
                            .foregroundStyle(.red)
                    } else {
                        ProgressView(server.statusText)
                    }
                } header: {
                    Text("Open in Desktop or Device Browser")
                } footer: {
                    Text("Keep this screen open until the upload finishes. Uploaded archives import automatically.")
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(server.statusText)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Files Received")
                        Spacer()
                        Text("\(server.uploadedCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Wi-Fi Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                server.start { tempURL in
                    appState.importFiles([tempURL], deleteSourceAfterImport: true)
                }
            }
            .onDisappear {
                server.stop()
            }
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
                    Text("Direct Archive URL")
                } footer: {
                    Text("Supports direct http/https links to .zip, .apk, .tar, or .tar.gz archives.")
                }

                Section {
                    Button("Download and Import") {
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
#endif
