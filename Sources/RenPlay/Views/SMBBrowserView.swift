// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import Foundation
import Network
import Observation
import RenPlayCore
import SwiftUI

struct DiscoveredSMBHost: Identifiable, Hashable {
    var id: String { "\(domain)|\(name)" }
    let name: String
    let type: String
    let domain: String
}

@MainActor
@Observable
final class SMBBonjourScanner {
    var discoveredHosts: [DiscoveredSMBHost] = []
    var isSearching = false

    private var browser: NWBrowser?
    private var activeResolver: SMBNetServiceResolver?

    func start() {
        stop()
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let nwBrowser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: nil), using: params)
        nwBrowser.stateUpdateHandler = { [weak self] state in
            let searching: Bool
            switch state {
            case .ready:
                searching = true
            case .failed, .cancelled:
                searching = false
            default:
                return
            }
            Task { @MainActor [weak self] in
                self?.isSearching = searching
            }
        }
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            var hosts: [DiscoveredSMBHost] = []
            for result in results {
                if case .service(let name, let type, let domain, _) = result.endpoint {
                    hosts.append(DiscoveredSMBHost(name: name, type: type, domain: domain))
                }
            }
            hosts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor [weak self] in
                self?.discoveredHosts = hosts
            }
        }
        nwBrowser.start(queue: .main)
        browser = nwBrowser
        isSearching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        activeResolver?.cancel()
        activeResolver = nil
        isSearching = false
    }

    func resolve(host: DiscoveredSMBHost) async -> (hostname: String, port: Int) {
        let resolved: (String, Int) = await withCheckedContinuation { continuation in
            let resolver = SMBNetServiceResolver(host: host) { result in
                continuation.resume(returning: result)
            }
            self.activeResolver = resolver
            resolver.start()
        }
        activeResolver = nil
        return resolved
    }
}

private final class SMBNetServiceResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService
    private let completion: @Sendable ((String, Int)) -> Void
    private var completed = false
    private let lock = NSLock()

    init(host: DiscoveredSMBHost, completion: @escaping @Sendable ((String, Int)) -> Void) {
        self.service = NetService(domain: host.domain, type: host.type, name: host.name)
        self.completion = completion
        super.init()
        self.service.delegate = self
    }

    func start() {
        service.resolve(withTimeout: 4.0)
    }

    func cancel() {
        service.stop()
        finish((sanitizeFallbackHost(service.name), 445))
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? sanitizeFallbackHost(sender.name)
        let port = sender.port > 0 ? sender.port : 445
        finish((host, port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = errorDict
        finish((sanitizeFallbackHost(sender.name), 445))
    }

    private func finish(_ value: (String, Int)) {
        lock.lock()
        let shouldFire = !completed
        completed = true
        lock.unlock()
        if shouldFire {
            service.stop()
            completion(value)
        }
    }

    private func sanitizeFallbackHost(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: " ", with: "-")
        return cleaned.hasSuffix(".local") ? cleaned : "\(cleaned).local"
    }
}

struct SMBBrowserView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scanner = SMBBonjourScanner()
    @State private var editorTarget: SMBServerEditorSeed?
    @State private var resolvingName: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if appState.smbServers.isEmpty {
                        Text("No saved SMB servers yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.smbServers) { server in
                            NavigationLink {
                                SMBShareListView(
                                    appState: appState,
                                    server: server,
                                    password: appState.libraryStore.smbPassword(for: server.id),
                                    onDone: { dismiss() }
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(server.displayName)
                                        .font(.headline)
                                    Text("\(server.host):\(server.port) • \(server.isGuest ? "Guest" : server.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) {
                                    appState.deleteSMBServer(server)
                                }
                                Button("Edit") {
                                    editorTarget = SMBServerEditorSeed(
                                        existing: server,
                                        initialPassword: appState.libraryStore.smbPassword(for: server.id)
                                    )
                                }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    Text("Saved Servers")
                }

                Section {
                    if scanner.discoveredHosts.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching local network...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(scanner.discoveredHosts) { host in
                            Button {
                                resolvingName = host.name
                                Task {
                                    let resolved = await scanner.resolve(host: host)
                                    resolvingName = nil
                                    editorTarget = SMBServerEditorSeed(
                                        displayName: host.name,
                                        host: resolved.hostname,
                                        port: resolved.port
                                    )
                                }
                            } label: {
                                HStack {
                                    Label(host.name, systemImage: "externaldrive.connected.to.line.below")
                                    Spacer()
                                    if resolvingName == host.name {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Discovered on LAN")
                }
            }
            .navigationTitle("Network Shares")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Server", systemImage: "plus") {
                        editorTarget = SMBServerEditorSeed()
                    }
                }
            }
            .sheet(item: $editorTarget) { seed in
                SMBServerEditorSheet(appState: appState, seed: seed)
            }
            .onAppear {
                scanner.start()
            }
            .onDisappear {
                scanner.stop()
            }
        }
    }
}

private struct SMBServerEditorSeed: Identifiable {
    let id = UUID()
    let existing: SMBServerProfile?
    let displayName: String
    let host: String
    let port: Int
    let username: String
    let domain: String
    let isGuest: Bool
    let password: String

    init(
        existing: SMBServerProfile? = nil,
        initialPassword: String = "",
        displayName: String? = nil,
        host: String = "",
        port: Int = 445
    ) {
        self.existing = existing
        self.displayName = displayName ?? existing?.displayName ?? ""
        self.host = existing?.host ?? host
        self.port = existing?.port ?? port
        self.username = existing?.username ?? ""
        self.domain = existing?.domain ?? ""
        self.isGuest = existing?.isGuest ?? true
        self.password = initialPassword
    }
}

private struct SMBServerEditorSheet: View {
    @Bindable var appState: AppState
    let seed: SMBServerEditorSeed
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var host = ""
    @State private var portText = "445"
    @State private var isGuest = true
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var isTesting = false
    @State private var testError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Address") {
                    TextField("Display Name (optional)", text: $displayName)
                    TextField("Host or IP (e.g. 192.168.1.50)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                }

                Section("Authentication") {
                    Toggle("Guest / Anonymous Login", isOn: $isGuest)
                    if !isGuest {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        TextField("Workgroup / Domain (optional)", text: $domain)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let testError {
                    Section {
                        Text(testError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        testAndSave(verifyFirst: true)
                    } label: {
                        if isTesting {
                            HStack {
                                ProgressView()
                                Text("Connecting...")
                            }
                        } else {
                            Text("Connect & Save")
                        }
                    }
                    .disabled(trimmedHost.isEmpty || isTesting)

                    Button("Save Offline") {
                        testAndSave(verifyFirst: false)
                    }
                    .disabled(trimmedHost.isEmpty || isTesting)
                }
            }
            .navigationTitle(seed.existing == nil ? "Add SMB Server" : "Edit SMB Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                displayName = seed.displayName
                host = seed.host
                portText = String(seed.port)
                isGuest = seed.isGuest
                username = seed.username
                password = seed.password
                domain = seed.domain
            }
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildProfile() -> SMBServerProfile {
        let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 445
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return SMBServerProfile(
            id: seed.existing?.id ?? UUID(),
            displayName: cleanName.isEmpty ? trimmedHost : cleanName,
            host: trimmedHost,
            port: (port > 0 && port <= 65535) ? port : 445,
            username: isGuest ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: isGuest ? "" : domain.trimmingCharacters(in: .whitespacesAndNewlines),
            isGuest: isGuest,
            createdAt: seed.existing?.createdAt ?? Date()
        )
    }

    private func testAndSave(verifyFirst: Bool) {
        let profile = buildProfile()
        let secret = isGuest ? "" : password
        testError = nil
        if !verifyFirst {
            appState.saveSMBServer(profile, password: secret)
            dismiss()
            return
        }

        isTesting = true
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SMBClient.listShares(server: profile, password: secret)
                }.value
                isTesting = false
                appState.saveSMBServer(profile, password: secret)
                dismiss()
            } catch {
                isTesting = false
                testError = error.localizedDescription
            }
        }
    }
}

private struct SMBShareListView: View {
    @Bindable var appState: AppState
    let server: SMBServerProfile
    let password: String
    let onDone: () -> Void

    @State private var shares: [SMBShareInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showHiddenShares = false
    @State private var showManualShareAlert = false
    @State private var manualShareName = ""
    @State private var manualShareTarget: String?

    private var visibleShares: [SMBShareInfo] {
        showHiddenShares ? shares : shares.filter { !$0.isHidden }
    }

    var body: some View {
        List {
            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading shares on \(server.host)...")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    HStack {
                        Button("Retry") {
                            Task { await loadShares() }
                        }
                        .buttonStyle(.bordered)
                        Button("Open Share Manually") {
                            manualShareName = ""
                            showManualShareAlert = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if visibleShares.isEmpty {
                ContentUnavailableView(
                    "No Visible Shares",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("You can toggle hidden shares or enter a share name manually.")
                )
            } else {
                ForEach(visibleShares) { share in
                    NavigationLink {
                        SMBFolderBrowserView(
                            appState: appState,
                            server: server,
                            password: password,
                            share: share.name,
                            path: "",
                            onDone: onDone
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(share.name, systemImage: "externaldrive.fill")
                                .font(.body.weight(.medium))
                            if !share.remark.isEmpty {
                                Text(share.remark)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(server.displayName)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(showHiddenShares ? "Hide $" : "Show $") {
                    showHiddenShares.toggle()
                }
                Button("Enter Share", systemImage: "folder.badge.plus") {
                    manualShareName = ""
                    showManualShareAlert = true
                }
            }
        }
        .navigationDestination(item: $manualShareTarget) { shareName in
            SMBFolderBrowserView(
                appState: appState,
                server: server,
                password: password,
                share: shareName,
                path: "",
                onDone: onDone
            )
        }
        .alert("Open Share by Name", isPresented: $showManualShareAlert) {
            TextField("Share name (e.g. Games)", text: $manualShareName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open") {
                let clean = manualShareName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    manualShareTarget = clean
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await loadShares()
        }
    }

    private func loadShares() async {
        isLoading = true
        errorMessage = nil
        do {
            shares = try await Task.detached(priority: .userInitiated) {
                try SMBClient.listShares(server: server, password: password)
            }.value
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct SMBFolderBrowserView: View {
    @Bindable var appState: AppState
    let server: SMBServerProfile
    let password: String
    let share: String
    let path: String
    let onDone: () -> Void

    @State private var items: [SMBRemoteItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var looksLikeGameHere: Bool {
        SMBClient.looksLikeRenPyGame(items: items)
    }

    private var folderTitle: String {
        if path.isEmpty { return share }
        return path.split(separator: "/").last.map(String.init) ?? share
    }

    private var existingLibraryGame: GameEntry? {
        let normalized = SMBClient.normalizeRelativePath(path)
        return appState.games.first {
            $0.remoteSource?.host == server.host
                && $0.remoteSource?.share == share
                && $0.remoteSource?.remotePath == normalized
        }
    }

    var body: some View {
        List {
            if !isLoading && looksLikeGameHere {
                Section {
                    if let existing = existingLibraryGame {
                        HStack {
                            Label("Added to Library", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Sync Scripts") {
                                Task { await appState.refreshRemoteSMBGame(existing) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(appState.isImporting)
                        }
                    } else {
                        Button {
                            streamFolder(remotePath: path, preferredName: folderTitle)
                        } label: {
                            Label("Add to Library", systemImage: "plus.circle.fill")
                                .font(.headline)
                        }
                        .disabled(appState.isImporting)
                    }
                }
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await loadDirectory() }
                    }
                    .buttonStyle(.bordered)
                }
            } else if items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                Section(path.isEmpty ? "/\(share)" : "/\(share)/\(path)") {
                    ForEach(items) { item in
                        if item.isDirectory {
                            NavigationLink {
                                SMBFolderBrowserView(
                                    appState: appState,
                                    server: server,
                                    password: password,
                                    share: share,
                                    path: item.relativePath,
                                    onDone: onDone
                                )
                            } label: {
                                Label(item.name, systemImage: "folder.fill")
                            }
                            .contextMenu {
                                Button("Add to Library", systemImage: "plus.circle") {
                                    streamFolder(remotePath: item.relativePath, preferredName: item.name)
                                }
                            }
                        } else {
                            HStack {
                                Label(item.name, systemImage: "doc")
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if appState.isImporting {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: appState.importProgress)
                            .progressViewStyle(.linear)
                        Text("Adding to Library")
                            .font(.headline)
                        Text(appState.importStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(20)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial)
                    .clipShape(.rect(cornerRadius: 16))
                }
            }
        }
        .task {
            await loadDirectory()
        }
    }

    private func loadDirectory() async {
        isLoading = true
        errorMessage = nil
        do {
            items = try await Task.detached(priority: .userInitiated) {
                try SMBClient.listDirectory(server: server, password: password, share: share, path: path)
            }.value
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func streamFolder(remotePath: String, preferredName: String) {
        Task {
            let ok = await appState.importRemoteSMBGame(
                server: server,
                password: password,
                share: share,
                remotePath: remotePath,
                preferredName: preferredName
            )
            if ok {
                onDone()
            }
        }
    }
}
#endif
