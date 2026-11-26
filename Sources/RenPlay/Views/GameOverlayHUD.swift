// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit) && canImport(SwiftUI)
import CRenPlayBridge
import SwiftUI
import UIKit

final class GameOverlayWindow: UIWindow {
    private let passthroughController: UIViewController

    init(windowScene: UIWindowScene, gameName: String, logDir: URL, opacity: Double) {
        let rootView = GameOverlayHUDView(gameName: gameName, logDir: logDir, opacity: opacity)
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        self.passthroughController = host
        super.init(windowScene: windowScene)
        self.windowLevel = .statusBar + 1
        self.backgroundColor = .clear
        self.rootViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Forward touches outside the compact HUD controls directly to the underlying SDL game window.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self || hit === passthroughController.view {
            return nil
        }
        return hit
    }
}

private struct GameOverlayHUDView: View {
    let gameName: String
    let logDir: URL
    let opacity: Double

    @State private var isExpanded = false
    @State private var showLogs = false
    @State private var showExitConfirm = false
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    // SDL scancodes and keycodes (consistent across SDL2 and SDL3 for ASCII / navigation keys).
    private enum SDLKey {
        static let escape: (Int32, Int32) = (27, 41)
        static let pageUp: (Int32, Int32) = (0x4000_004B, 75)
        static let tab: (Int32, Int32) = (9, 43)
        static let keyA: (Int32, Int32) = (97, 4)
        static let keyH: (Int32, Int32) = (104, 11)
        static let keyS: (Int32, Int32) = (115, 22)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "xmark.circle.fill" : "slider.horizontal.3")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.ultraThinMaterial.opacity(opacity))
                        .clipShape(.circle)
                        .shadow(radius: 4)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(gameName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.bottom, 2)

                        hudButton("Game Menu", systemImage: "line.3.horizontal") {
                            renplay_send_key_press(SDLKey.escape.0, SDLKey.escape.1)
                        }
                        hudButton("Rollback", systemImage: "arrow.uturn.backward") {
                            renplay_send_key_press(SDLKey.pageUp.0, SDLKey.pageUp.1)
                        }
                        hudButton("Toggle Skip", systemImage: "forward.fill") {
                            renplay_send_key_press(SDLKey.tab.0, SDLKey.tab.1)
                        }
                        hudButton("Auto Forward", systemImage: "play.circle") {
                            renplay_send_key_press(SDLKey.keyA.0, SDLKey.keyA.1)
                        }
                        hudButton("Hide Dialogue", systemImage: "eye.slash") {
                            renplay_send_key_press(SDLKey.keyH.0, SDLKey.keyH.1)
                        }
                        hudButton("Screenshot", systemImage: "camera") {
                            renplay_send_key_press(SDLKey.keyS.0, SDLKey.keyS.1)
                        }
                        hudButton("Keyboard", systemImage: "keyboard") {
                            renplay_toggle_text_input()
                        }
                        hudButton("Logs", systemImage: "doc.text") {
                            showLogs = true
                        }
                        Divider()
                        Button(role: .destructive) {
                            showExitConfirm = true
                        } label: {
                            Label("Exit Game", systemImage: "power")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .frame(width: 175)
                    .background(.regularMaterial.opacity(max(opacity, 0.85)))
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(radius: 8)
                }
            }
            .padding(.top, 54)
            .padding(.leading, 16)
            .offset(x: offset.width + dragTranslation.width, y: offset.height + dragTranslation.height)
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }
            )
        }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                SessionLogViewer(logDir: logDir)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Close") { showLogs = false }
                        }
                    }
            }
        }
        .confirmationDialog("Exit \(gameName)?", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Quit to Library", role: .destructive) {
                renplay_send_sdl_quit()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func hudButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        }
    }
}
#endif
