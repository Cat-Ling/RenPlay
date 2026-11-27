// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    var showDoneButton = false
    @Environment(\.dismiss) private var dismiss

    @State private var cacheSizeBytes: Int64 = 0
    @State private var showLicenseSheet = false
    @State private var showSMBBrowser = false
    @State private var copiedDocsPath = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine & Playback") {
                    Picker("Engine Matching", selection: $appState.appSettings.defaultEngineStrategy) {
                        Text("Closest Version").tag(EngineSelectionStrategy.accurate)
                        Text("Latest in Branch").tag(EngineSelectionStrategy.latest)
                    }
                    Picker("Default Rotation", selection: $appState.appSettings.defaultRotation) {
                        Text("Auto").tag(GameOrientation.auto)
                        Text("Landscape").tag(GameOrientation.landscape)
                        Text("Portrait").tag(GameOrientation.portrait)
                    }
                    Toggle("Allow Network by Default", isOn: $appState.appSettings.globalAllowNetwork)
                    NavigationLink("Advanced Ren'Py Settings") {
                        AdvancedRenPySettingsView(appState: appState)
                    }
                }

                Section("Overlay & Saves") {
                    Toggle("Show In-Game Overlay", isOn: $appState.appSettings.showOverlayByDefault)
                    Toggle("Show Quick Bar", isOn: $appState.appSettings.showQuickBar)
                    Toggle("Show FPS Counter", isOn: $appState.appSettings.showFPSOverlay)
                    VStack(alignment: .leading) {
                        Text("Overlay Opacity • \(Int(appState.appSettings.overlayOpacity * 100))%")
                            .font(.subheadline)
                        Slider(value: $appState.appSettings.overlayOpacity, in: 0.35...1.0, step: 0.05)
                    }
                    Stepper(
                        "Backups Kept: \(appState.appSettings.autoBackupCount)",
                        value: $appState.appSettings.autoBackupCount,
                        in: 0...20
                    )
                }

                Section("Storage & Files") {
                    NavigationLink {
                        StorageManagerView(appState: appState)
                    } label: {
                        HStack {
                            Text("Storage Manager")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Documents Path")
                            .font(.subheadline)
                        Text(appState.documentsDir.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button(copiedDocsPath ? "Copied" : "Copy Path") {
                        UIPasteboard.general.string = appState.documentsDir.path
                        copiedDocsPath = true
                    }
                    Button("Network Shares (SMB)") {
                        showSMBBrowser = true
                    }
                    Button("Scan Import Folder") {
                        appState.scanDropzones(silentIfEmpty: false)
                    }
                }

                Section("Bundled Engines (\(appState.engines.count))") {
                    if appState.engines.isEmpty {
                        Text("No engine runtimes bundled.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.engines) { engine in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ren'Py \(engine.version)")
                                        .font(.subheadline.weight(.medium))
                                    Text("Python \(engine.pythonVersion) • \(engine.sdlVersion)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(engine.frameworkName)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Section("About") {
                    Button("Install Demo Game") {
                        appState.installDemoGame()
                    }
                    Button("Licenses") {
                        showLicenseSheet = true
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                if showDoneButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .onAppear {
                cacheSizeBytes = appState.launcher.engineCacheSizeBytes()
            }
            .onChange(of: appState.appSettings) {
                appState.saveAppSettings()
            }
            .sheet(isPresented: $showSMBBrowser) {
                SMBBrowserView(appState: appState)
            }
            .sheet(isPresented: $showLicenseSheet) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RenPlay")
                                .font(.title2.bold())
                            Text("Copyright (C) 2026 RenPlay Contributors")
                            Text("This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.")
                            Text("Includes libsmb2 (LGPL-2.1-or-later) and Zstandard (BSD-3-Clause).")
                                .font(.footnote)
                            Text("RenPlay is an independent open-source project and is not affiliated with Ren'Py.")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .navigationTitle("Licenses")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") { showLicenseSheet = false }
                        }
                    }
                }
            }
        }
    }
}

struct AdvancedRenPySettingsView: View {
    @Bindable var appState: AppState
    @State private var showVariantPicker = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $appState.appSettings.renpyMasterVolume, in: 0...1, step: 0.05)
                    Text("\(Int(appState.appSettings.renpyMasterVolume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } header: {
                Text("Volume")
            }

            Section("Global Ren'Py Options") {
                Toggle("Developer Mode", isOn: $appState.appSettings.globalDeveloperMode)
                Toggle("Enable Console", isOn: $appState.appSettings.globalEnableConsole)
                Toggle("Use Less Memory", isOn: $appState.appSettings.globalLowMemory)
                Toggle("Less Screen Updates", isOn: $appState.appSettings.globalLessUpdates)
                Toggle("Force Rollback", isOn: $appState.appSettings.globalForceRollback)
                Toggle("Force Skip", isOn: $appState.appSettings.globalForceSkip)
                Toggle("Skip Unseen Text", isOn: $appState.appSettings.globalForceUnseenSkip)
                Toggle("Transparent Textboxes", isOn: $appState.appSettings.globalTransparentTextboxes)
                Toggle("Allow Network Access", isOn: $appState.appSettings.globalAllowNetwork)
                Toggle("Compatibility Patches", isOn: $appState.appSettings.globalCompatibilityPatches)
                Toggle("Override Device Variant", isOn: $appState.appSettings.globalOverrideVariant)
                Button("Select Variants") {
                    showVariantPicker = true
                }
                .disabled(!appState.appSettings.globalOverrideVariant)
            }
        }
        .navigationTitle("Advanced Ren'Py")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showVariantPicker) {
            VariantSelectionSheet(selectedVariants: $appState.appSettings.globalSelectedVariants)
        }
    }
}

struct StorageManagerView: View {
    @Bindable var appState: AppState
    @State private var breakdown: StorageBreakdown?

    var body: some View {
        List {
            if let breakdown {
                Section("Summary") {
                    storageBar(breakdown)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    usageRow(title: "Total Used", bytes: breakdown.totalBytes, bold: true)
                    usageRow(title: "Games", bytes: breakdown.totalGamesBytes)
                    usageRow(title: "Saves", bytes: breakdown.savesBytes)
                    usageRow(title: "Backups", bytes: breakdown.backupsBytes)
                    usageRow(title: "Exports", bytes: breakdown.exportsBytes)
                    usageRow(title: "Engine Cache", bytes: breakdown.engineCacheBytes)
                }

                Section("Games") {
                    if breakdown.games.isEmpty {
                        Text("No games installed")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(breakdown.games) { item in
                            HStack {
                                Text(item.title)
                                    .lineLimit(1)
                                if item.isRemote {
                                    Text("LAN")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.teal.opacity(0.2))
                                        .foregroundStyle(.teal)
                                        .clipShape(.rect(cornerRadius: 4))
                                }
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Cleanup") {
                    Button("Clear Engine Cache", role: .destructive) {
                        try? appState.launcher.clearEngineCache()
                        reload()
                    }
                    Button("Clear Exported Archives", role: .destructive) {
                        try? appState.libraryStore.clearExports()
                        reload()
                    }
                }
            } else {
                ProgressView("Calculating...")
            }
        }
        .navigationTitle("Storage Manager")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
    }

    private func storageBar(_ b: StorageBreakdown) -> some View {
        let total = max(1, b.totalBytes)
        return GeometryReader { geo in
            HStack(spacing: 2) {
                barSlice(color: .blue, fraction: Double(b.totalGamesBytes) / Double(total), width: geo.size.width)
                barSlice(color: .green, fraction: Double(b.savesBytes + b.backupsBytes) / Double(total), width: geo.size.width)
                barSlice(color: .orange, fraction: Double(b.engineCacheBytes) / Double(total), width: geo.size.width)
                barSlice(color: .purple, fraction: Double(b.exportsBytes) / Double(total), width: geo.size.width)
            }
            .frame(height: 12)
            .background(Color(.tertiarySystemFill))
            .clipShape(.capsule)
        }
        .frame(height: 12)
    }

    @ViewBuilder
    private func barSlice(color: Color, fraction: Double, width: CGFloat) -> some View {
        if fraction > 0.005 {
            Rectangle()
                .fill(color)
                .frame(width: max(4, width * fraction))
        }
    }

    private func usageRow(title: String, bytes: Int64, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .fontWeight(bold ? .semibold : .regular)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func reload() {
        let cache = appState.launcher.engineCacheSizeBytes()
        breakdown = appState.libraryStore.computeStorageBreakdown(engineCacheBytes: cache)
    }
}
#endif
