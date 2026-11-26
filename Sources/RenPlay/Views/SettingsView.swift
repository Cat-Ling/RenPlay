// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import RenPlayCore
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var cacheSizeBytes: Int64 = 0
    @State private var showLicenseSheet = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default Engine Selection", selection: $appState.appSettings.defaultEngineStrategy) {
                        Text("Accurate Match").tag(EngineSelectionStrategy.accurate)
                        Text("Latest in Major Branch").tag(EngineSelectionStrategy.latest)
                    }
                    Toggle("Allow Network by Default", isOn: $appState.appSettings.globalAllowNetwork)
                } header: {
                    Text("Engine Behavior")
                }

                Section {
                    Stepper(
                        "Rolling Save Backups: \(appState.appSettings.autoBackupCount)",
                        value: $appState.appSettings.autoBackupCount,
                        in: 0...20
                    )
                    Toggle("Show In-Game Overlay", isOn: $appState.appSettings.showOverlayByDefault)
                    VStack(alignment: .leading) {
                        Text("Overlay Opacity: \(Int(appState.appSettings.overlayOpacity * 100))%")
                            .font(.subheadline)
                        Slider(value: $appState.appSettings.overlayOpacity, in: 0.35...1.0, step: 0.05)
                    }
                } header: {
                    Text("Saves & Overlay")
                }

                Section {
                    if appState.engines.isEmpty {
                        Text("No engine frameworks detected in app bundle.")
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
                } header: {
                    Text("Bundled Engines (\(appState.engines.count))")
                }

                Section {
                    HStack {
                        Text("Unpacked Engine Cache")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear Engine Cache", role: .destructive) {
                        try? appState.launcher.clearEngineCache()
                        cacheSizeBytes = appState.launcher.engineCacheSizeBytes()
                    }
                } header: {
                    Text("Storage")
                }

                Section {
                    Button("Install Built-in Demo Game") {
                        appState.installDemoGame()
                    }
                    Button("License & Legal Info") {
                        showLicenseSheet = true
                    }
                } header: {
                    Text("About RenPlay")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                cacheSizeBytes = appState.launcher.engineCacheSizeBytes()
            }
            .onChange(of: appState.appSettings) {
                appState.saveAppSettings()
            }
            .sheet(isPresented: $showLicenseSheet) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RenPlay")
                                .font(.title2.bold())
                            Text("Copyright (C) 2026 RenPlay Contributors")
                            Text("This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.")
                            Text("This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.")
                            Text("RenPlay is an independent open-source project and is not affiliated with or endorsed by Ren'Py.")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .navigationTitle("License")
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
#endif
