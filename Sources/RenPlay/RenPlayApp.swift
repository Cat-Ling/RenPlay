// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import CRenPlayBridge
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    @objc var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        renplay_install_sdl_scene_bridge()
        return true
    }
}

@main
struct RenPlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
    }
}

struct ContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        TabView {
            LibraryView(appState: appState)
                .tabItem {
                    Label("Library", systemImage: "books.vertical.fill")
                }

            GlobalSavesView(appState: appState)
                .tabItem {
                    Label("Saves", systemImage: "externaldrive.fill")
                }

            SettingsView(appState: appState)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .alert(
            "RenPlay Notice",
            isPresented: Binding(
                get: { appState.activeError != nil },
                set: { if !$0 { appState.activeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.activeError = nil
            }
        } message: {
            Text(appState.activeError ?? "")
        }
        .onOpenURL { url in
            appState.importFiles([url])
        }
    }
}
#endif
