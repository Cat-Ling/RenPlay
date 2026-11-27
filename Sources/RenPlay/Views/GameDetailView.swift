// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI

struct GameDetailView: View {
    @Bindable var appState: AppState
    let gameID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var saveSlots: [SaveSlot] = []
    @State private var showSettingsSheet = false
    @State private var showSaveLinkSheet = false
    @State private var pendingDelete: GameEntry?
    @State private var showRenameTitleAlert = false
    @State private var showRenameFolderAlert = false
    @State private var showVersionAlert = false
    @State private var draftInput = ""

    private var game: GameEntry? {
        appState.games.first(where: { $0.id == gameID })
    }

    var body: some View {
        Group {
            if let game {
                detailScroll(for: game)
            } else {
                ContentUnavailableView("Game Not Found", systemImage: "questionmark.folder")
            }
        }
        .onAppear {
            reloadSaves()
        }
        .onChange(of: showSaveLinkSheet) { _, isPresented in
            if !isPresented {
                reloadSaves()
            }
        }
        .onChange(of: game?.saveIdentifier) { _, _ in
            reloadSaves()
        }
    }

    private func detailScroll(for game: GameEntry) -> some View {
        let resolved = appState.resolvedEngine(for: game)
        let gameBinding = Binding<GameEntry>(
            get: { appState.games.first(where: { $0.id == gameID }) ?? game },
            set: { appState.updateGame($0) }
        )

        return ScrollView {
            VStack(spacing: 20) {
                heroSection(for: game)

                playButton(for: game, resolved: resolved)
                    .padding(.horizontal)

                quickActionsRow(for: game, gameBinding: gameBinding)
                    .padding(.horizontal)

                savesStripSection(for: game)

                detailsCardsSection(for: game)

                engineSection(for: game, gameBinding: gameBinding, resolved: resolved)
                    .padding(.horizontal)

                if let remote = game.remoteSource {
                    networkSourceSection(for: game, remote: remote)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 32)
        }
        .navigationTitle(game.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") {
                    showSettingsSheet = true
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            GameSettingsSheet(appState: appState, gameID: gameID)
        }
        .sheet(isPresented: $showSaveLinkSheet) {
            SaveFolderLinkSheet(appState: appState, gameID: gameID)
        }
        .alert("Rename Game", isPresented: $showRenameTitleAlert) {
            TextField("Title", text: $draftInput)
            Button("Save") {
                let clean = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    var copy = game
                    copy.displayName = clean
                    appState.updateGame(copy)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Folder", isPresented: $showRenameFolderAlert) {
            TextField("Folder name", text: $draftInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") {
                appState.renameGameDirectory(game, to: draftInput)
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Game Version", isPresented: $showVersionAlert) {
            TextField("Version (e.g. 1.0.0)", text: $draftInput)
                .textInputAutocapitalization(.never)
            Button("Save") {
                var copy = game
                let clean = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
                copy.gameVersion = clean.isEmpty ? nil : clean
                appState.updateGame(copy)
            }
            Button("Cancel", role: .cancel) {}
        }
        .gameDeletionDialog(pending: $pendingDelete, appState: appState) {
            dismiss()
        }
    }

    @ViewBuilder
    private func heroSection(for game: GameEntry) -> some View {
        let heroImage = loadArtwork(relPath: game.customHeroPath ?? game.customCoverPath ?? game.coverRelativePath, game: game)
        let accent = Color(category: game.category)

        ZStack(alignment: .bottom) {
            Group {
                if let heroImage {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 230)
                        .overlay {
                            Image(uiImage: heroImage)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .overlay {
                            LinearGradient(
                                colors: [.clear, Color(.systemBackground).opacity(0.65), Color(.systemBackground)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                } else {
                    LinearGradient(
                        colors: [accent.opacity(0.35), Color(.systemBackground)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 170)
                    .overlay {
                        Image(systemName: "books.vertical.fill")
                            .font(.system(size: 52))
                            .foregroundStyle(.white.opacity(0.3))
                            .offset(y: -18)
                    }
                }
            }

            if game.settings.showTitleWithArtwork || heroImage == nil {
                VStack(spacing: 4) {
                    Text(game.displayName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if !subtitleLine(for: game).isEmpty {
                        Text(subtitleLine(for: game))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func subtitleLine(for game: GameEntry) -> String {
        var items: [String] = []
        if let ver = game.gameVersion, !ver.isEmpty {
            items.append(ver)
        }
        if let size = game.sizeBytes, size > 0 {
            items.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if game.remoteSource != nil {
            items.append("Network Share")
        }
        return items.joined(separator: " • ")
    }

    private func playButton(for game: GameEntry, resolved: EngineInfo?) -> some View {
        let resumeSlot = saveSlots.filter { $0.renpySlotName != nil }.max(by: { $0.modifiedAt < $1.modifiedAt })
        let pctLabel = game.dialogueProgressFraction.map { " • \(Int(($0 * 100).rounded()))%" } ?? ""
        let tintColor = Color(category: game.category)

        return Group {
            if let resumeSlot, let slotName = resumeSlot.renpySlotName {
                HStack(spacing: 10) {
                    Button {
                        appState.launch(game: game, autoloadSlot: slotName)
                    } label: {
                        Label("Resume\(pctLabel)", systemImage: "play.fill")
                            .font(.headline)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tintColor)
                    .controlSize(.large)
                    .clipShape(.capsule)
                    .disabled(resolved == nil || appState.isLaunching)

                    Button {
                        appState.launch(game: game, autoloadSlot: nil)
                    } label: {
                        Label("Main Menu", systemImage: "house")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(tintColor)
                    .controlSize(.large)
                    .clipShape(.capsule)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(resolved == nil || appState.isLaunching)
                }
            } else {
                Button {
                    appState.launch(game: game, autoloadSlot: nil)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(tintColor)
                .controlSize(.large)
                .clipShape(.capsule)
                .disabled(resolved == nil || appState.isLaunching)
            }
        }
    }

    private func quickActionsRow(for game: GameEntry, gameBinding: Binding<GameEntry>) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                GameSaveManagerView(appState: appState, game: game)
            } label: {
                quickActionCircle(title: "Saves", systemImage: "externaldrive")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            NavigationLink {
                AssetGalleryView(
                    gameDir: appState.libraryStore.gameDirectory(for: game),
                    screenshotsDir: appState.libraryStore.screenshotDirectory(for: game, documentsDir: appState.documentsDir),
                    remoteSource: game.remoteSource,
                    remotePassword: game.remoteSource.map { appState.libraryStore.smbPassword(for: $0.serverID) } ?? ""
                )
            } label: {
                quickActionCircle(title: "Gallery", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                showSettingsSheet = true
            } label: {
                quickActionCircle(title: "Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            NavigationLink {
                SessionLogViewer(appState: appState, game: game)
            } label: {
                quickActionCircle(title: "Logs", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Menu {
                if game.remoteSource == nil {
                    Button("Rename Folder...", systemImage: "folder") {
                        draftInput = game.folderName
                        showRenameFolderAlert = true
                    }
                } else {
                    Button("Sync Scripts", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await appState.refreshRemoteSMBGame(game) }
                    }
                }
                Button("Rename Game...", systemImage: "pencil") {
                    draftInput = game.displayName
                    showRenameTitleAlert = true
                }
                Button("Edit Version...", systemImage: "number") {
                    draftInput = game.gameVersion ?? ""
                    showVersionAlert = true
                }
                AIHelpButton(appState: appState, game: game)
                Menu("Category", systemImage: "tag") {
                    Button("None") {
                        var copy = game
                        copy.category = nil
                        appState.updateGame(copy)
                    }
                    ForEach(GameCategory.allCases, id: \.self) { cat in
                        Button {
                            var copy = game
                            copy.category = cat
                            appState.updateGame(copy)
                        } label: {
                            if game.category == cat {
                                Label(cat.displayName, systemImage: "checkmark")
                            } else {
                                Text(cat.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button(game.remoteSource != nil ? "Remove from Library" : "Delete Game", systemImage: "trash", role: .destructive) {
                    pendingDelete = game
                }
            } label: {
                quickActionCircle(title: "More", systemImage: "ellipsis")
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func quickActionCircle(title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(.circle)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func savesStripSection(for game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saves")
                    .font(.headline)
                Text("\(saveSlots.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                NavigationLink {
                    GameSaveManagerView(appState: appState, game: game)
                } label: {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            if saveSlots.isEmpty {
                Text("No saves yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(saveSlots.prefix(10)) { slot in
                            if let slotName = slot.renpySlotName {
                                Button {
                                    appState.launch(game: game, autoloadSlot: slotName)
                                } label: {
                                    saveStripCardBody(slot, showPlayBadge: true)
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.resolvedEngine(for: game) == nil || appState.isLaunching)
                                .contextMenu {
                                    Button("Load Save & Play", systemImage: "play.fill") {
                                        appState.launch(game: game, autoloadSlot: slotName)
                                    }
                                    .disabled(appState.resolvedEngine(for: game) == nil || appState.isLaunching)
                                }
                            } else {
                                NavigationLink {
                                    GameSaveManagerView(appState: appState, game: game)
                                } label: {
                                    saveStripCardBody(slot, showPlayBadge: false)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    private func saveStripCardBody(_ slot: SaveSlot, showPlayBadge: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .frame(width: 148, height: 84)
                .overlay {
                    if let data = slot.screenshotData, let img = UIImage(data: data) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(.tertiarySystemGroupedBackground)
                            .overlay {
                                Image(systemName: slot.kind == .persistent ? "gearshape.2" : "photo")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if showPlayBadge {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.55))
                            .clipShape(.circle)
                            .padding(5)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))

            Text(slot.slotLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(slot.modifiedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 148, alignment: .leading)
    }

    private func detailsCardsSection(for game: GameEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    statCard(title: "Play Time", value: formatPlayTime(game.playTimeSeconds))
                    statCard(
                        title: "Last Played",
                        value: game.lastPlayedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Never"
                    )
                    Button {
                        showSaveLinkSheet = true
                    } label: {
                        statCard(
                            title: "Save Folder",
                            value: game.saveIdentifier ?? String(game.id.uuidString.prefix(8)),
                            icon: "folder"
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
        }
    }

    private func statCard(title: String, value: String, icon: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func engineSection(for game: GameEntry, gameBinding: Binding<GameEntry>, resolved: EngineInfo?) -> some View {
        let collapsedLabel: String = switch gameBinding.wrappedValue.settings.engineMode {
        case .auto:
            "Auto • \(resolved?.version ?? "—")"
        case .pinned(let id):
            resolved?.version ?? id
        }

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Engine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 8)
                Menu {
                    Button {
                        engineSelectionBinding(for: gameBinding).wrappedValue = "auto"
                    } label: {
                        let autoTitle = "Auto (\(resolved?.version ?? "Unavailable"))"
                        if case .auto = gameBinding.wrappedValue.settings.engineMode {
                            Label(autoTitle, systemImage: "checkmark")
                        } else {
                            Text(autoTitle)
                        }
                    }
                    Divider()
                    ForEach(appState.engines) { eng in
                        Button {
                            engineSelectionBinding(for: gameBinding).wrappedValue = eng.id
                        } label: {
                            let rowTitle = "Ren'Py \(eng.version) (\(eng.sdlVersion))"
                            if case .pinned(let id) = gameBinding.wrappedValue.settings.engineMode, id == eng.id {
                                Label(rowTitle, systemImage: "checkmark")
                            } else {
                                Text(rowTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(collapsedLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().padding(.leading, 14)

            HStack {
                Text("Ren'Py Version")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(game.detectedEngineVersion ?? "Unknown")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func networkSourceSection(for game: GameEntry, remote: SMBGameSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("smb://\(remote.host)/\(remote.share)/\(remote.remotePath)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text("Synced \(remote.lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Sync") {
                    Task { await appState.refreshRemoteSMBGame(game) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isImporting)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func reloadSaves() {
        guard let game else { return }
        saveSlots = appState.saveManager.listSaves(in: appState.libraryStore.saveDirectory(for: game))
    }

    private func loadArtwork(relPath: String?, game: GameEntry) -> UIImage? {
        guard let relPath else { return nil }
        let url = appState.libraryStore.gameDirectory(for: game).appendingPathComponent(relPath)
        return UIImage(contentsOfFile: url.path)
    }

    private func formatPlayTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        let rem = mins % 60
        return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
    }

    private func engineSelectionBinding(for game: Binding<GameEntry>) -> Binding<String> {
        Binding<String>(
            get: {
                switch game.wrappedValue.settings.engineMode {
                case .auto: return "auto"
                case .pinned(let id): return id
                }
            },
            set: { newValue in
                var copy = game.wrappedValue
                copy.settings.engineMode = (newValue == "auto") ? .auto : .pinned(newValue)
                game.wrappedValue = copy
            }
        )
    }
}

struct GameSettingsSheet: View {
    @Bindable var appState: AppState
    let gameID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showVariantPicker = false

    private var game: GameEntry? {
        appState.games.first(where: { $0.id == gameID })
    }

    var body: some View {
        NavigationStack {
            if let game {
                let binding = Binding<GameEntry>(
                    get: { appState.games.first(where: { $0.id == gameID }) ?? game },
                    set: { appState.updateGame($0) }
                )
                Form {
                    Section("General") {
                        Toggle("Safe Mode", isOn: binding.settings.safeMode)
                        Picker("Engine", selection: engineModeBinding(binding)) {
                            Text("Auto").tag("auto")
                            ForEach(appState.engines) { eng in
                                Text("Ren'Py \(eng.version) (\(eng.sdlVersion))").tag(eng.id)
                            }
                        }
                        Picker("Screen Rotation", selection: binding.settings.screenRotation) {
                            ForEach(ScreenRotationPreference.allCases, id: \.self) { pref in
                                Text(pref.displayName).tag(pref)
                            }
                        }
                    }

                    Section("Appearance") {
                        Picker("Category", selection: categoryBinding(binding)) {
                            Text("None").tag(Optional<GameCategory>.none)
                            ForEach(GameCategory.allCases, id: \.self) { cat in
                                Text(cat.displayName).tag(Optional(cat))
                            }
                        }
                        Toggle("Show Title With Artwork", isOn: binding.settings.showTitleWithArtwork)
                        ArtworkPhotoPicker(
                            title: "Set Cover Image...",
                            hasCustomImage: game.customCoverPath != nil,
                            onSelectData: { data in appState.setCustomArtwork(data: data, kind: .cover, for: game) },
                            onReset: { appState.clearCustomArtwork(kind: .cover, for: game) }
                        )
                        ArtworkPhotoPicker(
                            title: "Set Hero Image...",
                            hasCustomImage: game.customHeroPath != nil,
                            onSelectData: { data in appState.setCustomArtwork(data: data, kind: .hero, for: game) },
                            onReset: { appState.clearCustomArtwork(kind: .hero, for: game) }
                        )
                    }

                    Section("Ren'Py Options") {
                        Toggle("Use Global Settings", isOn: binding.settings.useGlobalSettings)

                        Group {
                            Toggle("Developer Mode", isOn: runtimeBoolBinding(binding, \.developerMode, global: appState.appSettings.globalDeveloperMode))
                            Toggle("Enable Console", isOn: runtimeBoolBinding(binding, \.enableConsole, global: appState.appSettings.globalEnableConsole))
                            Toggle("Use Less Memory", isOn: runtimeBoolBinding(binding, \.lowMemoryMode, global: appState.appSettings.globalLowMemory))
                            Toggle("Less Screen Updates", isOn: runtimeBoolBinding(binding, \.lessScreenUpdates, global: appState.appSettings.globalLessUpdates))
                            Toggle("Force Rollback", isOn: runtimeBoolBinding(binding, \.forceRollback, global: appState.appSettings.globalForceRollback))
                            Toggle("Force Skip", isOn: runtimeBoolBinding(binding, \.forceSkip, global: appState.appSettings.globalForceSkip))
                            Toggle("Skip Unseen Text", isOn: runtimeBoolBinding(binding, \.forceUnseenSkip, global: appState.appSettings.globalForceUnseenSkip))
                            Toggle("Transparent Textboxes", isOn: runtimeBoolBinding(binding, \.transparentTextboxes, global: appState.appSettings.globalTransparentTextboxes))
                            Toggle("Allow Network Access", isOn: binding.settings.allowNetwork)
                            Toggle("Compatibility Patches", isOn: runtimeBoolBinding(binding, \.compatibilityPatches, global: appState.appSettings.globalCompatibilityPatches))
                            Toggle("Override Device Variant", isOn: runtimeBoolBinding(binding, \.overrideDeviceVariant, global: appState.appSettings.globalOverrideVariant))
                        }
                        .disabled(binding.wrappedValue.settings.useGlobalSettings)

                        Button("Select Variants") {
                            showVariantPicker = true
                        }
                        .disabled(binding.wrappedValue.settings.useGlobalSettings || !binding.wrappedValue.settings.overrideDeviceVariant)
                    }
                }
                .navigationTitle("Game Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .sheet(isPresented: $showVariantPicker) {
                    VariantSelectionSheet(selectedVariants: binding.settings.selectedVariants)
                }
            }
        }
    }

    private func engineModeBinding(_ game: Binding<GameEntry>) -> Binding<String> {
        Binding<String>(
            get: {
                switch game.wrappedValue.settings.engineMode {
                case .auto: return "auto"
                case .pinned(let id): return id
                }
            },
            set: { val in
                var copy = game.wrappedValue
                copy.settings.engineMode = (val == "auto") ? .auto : .pinned(val)
                game.wrappedValue = copy
            }
        )
    }

    private func categoryBinding(_ game: Binding<GameEntry>) -> Binding<GameCategory?> {
        Binding<GameCategory?>(
            get: { game.wrappedValue.category },
            set: { val in
                var copy = game.wrappedValue
                copy.category = val
                game.wrappedValue = copy
            }
        )
    }

    private func runtimeBoolBinding(
        _ game: Binding<GameEntry>,
        _ keyPath: WritableKeyPath<GameSettings, Bool>,
        global: Bool
    ) -> Binding<Bool> {
        Binding<Bool>(
            get: { game.wrappedValue.settings.useGlobalSettings ? global : game.wrappedValue.settings[keyPath: keyPath] },
            set: { val in
                var copy = game.wrappedValue
                copy.settings[keyPath: keyPath] = val
                game.wrappedValue = copy
            }
        )
    }
}

struct VariantSelectionSheet: View {
    @Binding var selectedVariants: [String]
    @Environment(\.dismiss) private var dismiss

    private static let allVariants = [
        "pc", "large", "medium",
        "small", "tablet", "phone",
        "touch", "tv", "android",
        "ios", "mobile", "web",
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(Self.allVariants, id: \.self) { variant in
                    Button {
                        if let idx = selectedVariants.firstIndex(of: variant) {
                            selectedVariants.remove(at: idx)
                        } else {
                            selectedVariants.append(variant)
                        }
                    } label: {
                        HStack {
                            Text(variant)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedVariants.contains(variant) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Device Variants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct SessionLogViewer: View {
    let appState: AppState
    let game: GameEntry
    @State private var logText = ""

    private var logDir: URL {
        appState.libraryStore.logDirectory(for: game)
    }

    var body: some View {
        ScrollView {
            Text(logText.isEmpty ? "No session logs recorded yet." : logText)
                .font(.caption.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Session Logs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                AIHelpButton(appState: appState, game: game, label: "Share for AI", systemImage: "square.and.arrow.up")
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = logText
                }
                .disabled(logText.isEmpty)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    loadLogs()
                }
            }
        }
        .onAppear { loadLogs() }
    }

    private func loadLogs() {
        let logURL = logDir.appendingPathComponent("renplay_session.log")
        if let content = try? String(contentsOf: logURL, encoding: .utf8) {
            logText = content
        } else {
            logText = ""
        }
    }
}
#endif
