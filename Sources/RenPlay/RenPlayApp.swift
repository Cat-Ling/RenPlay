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

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        switch renplay_get_preferred_orientation() {
        case 1: return .landscapeLeft
        case 2: return .landscapeRight
        case 3: return [.portrait, .portraitUpsideDown]
        case 4: return .landscape
        default: return .allButUpsideDown
        }
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
            appState.activeErrorTitle,
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
