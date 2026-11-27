// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit)
import CRenPlayBridge
import UIKit

final class GameOverlayWindow: UIWindow {
    private let overlayController: GameOverlayViewController

    init(windowScene: UIWindowScene, gameName: String, logDir: URL, opacity: Double) {
        let controller = GameOverlayViewController(gameName: gameName, logDir: logDir, opacity: opacity)
        self.overlayController = controller
        super.init(windowScene: windowScene)
        self.windowLevel = .statusBar + 10
        self.backgroundColor = .clear
        self.isOpaque = false
        self.rootViewController = controller
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // Never steal key-window status from SDL_uikitwindow while running a game.
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        overlayController.hitTestableView(at: point, with: event)
    }
}

private final class GameOverlayViewController: UIViewController {
    private let gameName: String
    private let logDir: URL
    private let overlayAlpha: CGFloat

    private let toggleButton = UIButton(type: .system)
    private let menuCard = UIView()
    private let menuStack = UIStackView()
    private let exitButton = UIButton(type: .system)
    private let confirmRow = UIStackView()
    private let confirmExitButton = UIButton(type: .system)
    private let cancelExitButton = UIButton(type: .system)

    private let logCard = UIView()
    private let logTitleLabel = UILabel()
    private let logTextView = UITextView()
    private var logRefreshButton = UIButton(type: .system)
    private var logBottomButton = UIButton(type: .system)
    private var logCopyButton = UIButton(type: .system)
    private var logCloseButton = UIButton(type: .system)

    private var buttonOrigin: CGPoint = CGPoint(x: 16, y: 54)
    private var panStartOrigin: CGPoint = .zero
    private var isMenuOpen = false
    private var isConfirmingExit = false

    init(gameName: String, logDir: URL, opacity: Double) {
        self.gameName = gameName
        self.logDir = logDir
        self.overlayAlpha = CGFloat(min(max(opacity, 0.35), 1.0))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        root.isOpaque = false
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupToggleButton()
        setupMenuCard()
        setupLogCard()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clampButtonOrigin()
        layoutOverlayFrames()
    }

    func hitTestableView(at point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isViewLoaded else { return nil }
        if !logCard.isHidden {
            let local = logCard.convert(point, from: view)
            if logCard.bounds.contains(local) {
                return logCard.hitTest(local, with: event) ?? logCard
            }
        }
        if !menuCard.isHidden {
            let local = menuCard.convert(point, from: view)
            if menuCard.bounds.contains(local) {
                return menuCard.hitTest(local, with: event) ?? menuCard
            }
        }
        let expandedToggleRect = toggleButton.frame.insetBy(dx: -6, dy: -6)
        if expandedToggleRect.contains(point) {
            return toggleButton
        }
        return nil
    }

    private func setupToggleButton() {
        toggleButton.frame = CGRect(origin: buttonOrigin, size: CGSize(width: 44, height: 44))
        toggleButton.backgroundColor = UIColor(white: 0.08, alpha: max(overlayAlpha, 0.6))
        toggleButton.tintColor = .white
        toggleButton.layer.cornerRadius = 22
        toggleButton.layer.borderWidth = 1
        toggleButton.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        updateToggleIcon()
        toggleButton.addAction(
            UIAction { [weak self] _ in
                self?.handleToggleTapped()
            },
            for: .touchUpInside
        )

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.cancelsTouchesInView = true
        toggleButton.addGestureRecognizer(pan)

        view.addSubview(toggleButton)
    }

    private func setupMenuCard() {
        menuCard.backgroundColor = UIColor(white: 0.10, alpha: max(overlayAlpha, 0.92))
        menuCard.layer.cornerRadius = 14
        menuCard.layer.borderWidth = 0.5
        menuCard.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        menuCard.clipsToBounds = true
        menuCard.isHidden = true

        menuStack.axis = .vertical
        menuStack.spacing = 4
        menuStack.alignment = .fill
        menuStack.translatesAutoresizingMaskIntoConstraints = false
        menuCard.addSubview(menuStack)

        NSLayoutConstraint.activate([
            menuStack.topAnchor.constraint(equalTo: menuCard.topAnchor, constant: 10),
            menuStack.bottomAnchor.constraint(equalTo: menuCard.bottomAnchor, constant: -10),
            menuStack.leadingAnchor.constraint(equalTo: menuCard.leadingAnchor, constant: 10),
            menuStack.trailingAnchor.constraint(equalTo: menuCard.trailingAnchor, constant: -10),
        ])

        let titleLabel = UILabel()
        titleLabel.text = gameName
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        menuStack.addArrangedSubview(titleLabel)

        let actions: [(String, String, Int32, Bool)] = [
            ("Game Menu", "line.3.horizontal", Int32(RENPLAY_CMD_GAME_MENU), true),
            ("Quick Save", "square.and.arrow.down", Int32(RENPLAY_CMD_QUICK_SAVE), true),
            ("Quick Load", "arrow.clockwise.circle", Int32(RENPLAY_CMD_QUICK_LOAD), true),
            ("Rollback", "arrow.uturn.backward", Int32(RENPLAY_CMD_ROLLBACK), true),
            ("Toggle Skip", "forward.fill", Int32(RENPLAY_CMD_TOGGLE_SKIP), true),
            ("Auto Forward", "play.circle", Int32(RENPLAY_CMD_AUTO_FORWARD), true),
            ("Hide Dialogue", "eye.slash", Int32(RENPLAY_CMD_HIDE_UI), true),
            ("Screenshot", "camera", Int32(RENPLAY_CMD_SCREENSHOT), true),
            ("Keyboard", "keyboard", Int32(RENPLAY_CMD_TOGGLE_KEYBOARD), false),
        ]

        for (title, symbol, command, shouldCollapse) in actions {
            let btn = makeMenuButton(title: title, symbolName: symbol, tint: .white) { [weak self] in
                renplay_request_command(command)
                if shouldCollapse {
                    self?.collapseMenu()
                }
            }
            menuStack.addArrangedSubview(btn)
        }

        let logsBtn = makeMenuButton(title: "Session Logs", symbolName: "doc.text", tint: .white) { [weak self] in
            self?.openLogViewer()
        }
        menuStack.addArrangedSubview(logsBtn)

        let divider = UIView()
        divider.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        menuStack.addArrangedSubview(divider)

        var exitConfig = UIButton.Configuration.plain()
        exitConfig.title = "Exit Game"
        exitConfig.image = UIImage(systemName: "power")
        exitConfig.imagePadding = 6
        exitConfig.baseForegroundColor = .systemRed
        exitConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        exitConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 13, weight: .semibold)
            return copy
        }
        exitButton.configuration = exitConfig
        exitButton.contentHorizontalAlignment = .leading
        exitButton.addAction(
            UIAction { [weak self] _ in
                self?.setConfirmingExit(true)
            },
            for: .touchUpInside
        )
        menuStack.addArrangedSubview(exitButton)

        confirmRow.axis = .horizontal
        confirmRow.spacing = 6
        confirmRow.distribution = .fillEqually
        confirmRow.isHidden = true

        var confirmConfig = UIButton.Configuration.filled()
        confirmConfig.title = "Confirm Exit"
        confirmConfig.baseBackgroundColor = .systemRed
        confirmConfig.baseForegroundColor = .white
        confirmConfig.background.cornerRadius = 8
        confirmConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        confirmConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 12, weight: .bold)
            return copy
        }
        confirmExitButton.configuration = confirmConfig
        confirmExitButton.addAction(
            UIAction { _ in
                renplay_request_command(Int32(RENPLAY_CMD_QUIT))
            },
            for: .touchUpInside
        )

        var cancelConfig = UIButton.Configuration.filled()
        cancelConfig.title = "Cancel"
        cancelConfig.baseBackgroundColor = UIColor.white.withAlphaComponent(0.16)
        cancelConfig.baseForegroundColor = .white
        cancelConfig.background.cornerRadius = 8
        cancelConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        cancelConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 12, weight: .medium)
            return copy
        }
        cancelExitButton.configuration = cancelConfig
        cancelExitButton.addAction(
            UIAction { [weak self] _ in
                self?.setConfirmingExit(false)
            },
            for: .touchUpInside
        )

        confirmRow.addArrangedSubview(confirmExitButton)
        confirmRow.addArrangedSubview(cancelExitButton)
        menuStack.addArrangedSubview(confirmRow)

        view.addSubview(menuCard)
    }

    private func setupLogCard() {
        logCard.backgroundColor = UIColor(white: 0.08, alpha: 0.96)
        logCard.layer.cornerRadius = 14
        logCard.layer.borderWidth = 0.75
        logCard.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        logCard.clipsToBounds = true
        logCard.isHidden = true

        let header = UIStackView()
        header.axis = .horizontal
        header.spacing = 8
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        logTitleLabel.text = "Session Logs"
        logTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        logTitleLabel.textColor = .white
        logTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        logRefreshButton = makeHeaderButton("Refresh") { [weak self] in
            self?.reloadLogContents()
        }
        logBottomButton = makeHeaderButton("Bottom") { [weak self] in
            self?.scrollLogToBottom()
        }
        logCopyButton = makeHeaderButton("Copy") { [weak self] in
            guard let self else { return }
            UIPasteboard.general.string = self.logTextView.text
            self.logCopyButton.setTitle("Copied", for: .normal)
        }
        logCloseButton = makeHeaderButton("Close") { [weak self] in
            self?.logCard.isHidden = true
        }

        header.addArrangedSubview(logTitleLabel)
        header.addArrangedSubview(logRefreshButton)
        header.addArrangedSubview(logBottomButton)
        header.addArrangedSubview(logCopyButton)
        header.addArrangedSubview(logCloseButton)

        logTextView.backgroundColor = UIColor(white: 0.04, alpha: 1.0)
        logTextView.textColor = UIColor(white: 0.92, alpha: 1.0)
        logTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.isEditable = false
        logTextView.isSelectable = false
        logTextView.layer.cornerRadius = 8
        logTextView.translatesAutoresizingMaskIntoConstraints = false

        logCard.addSubview(header)
        logCard.addSubview(logTextView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: logCard.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: logCard.trailingAnchor, constant: -12),
            logTextView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            logTextView.leadingAnchor.constraint(equalTo: logCard.leadingAnchor, constant: 10),
            logTextView.trailingAnchor.constraint(equalTo: logCard.trailingAnchor, constant: -10),
            logTextView.bottomAnchor.constraint(equalTo: logCard.bottomAnchor, constant: -10),
        ])

        view.addSubview(logCard)
    }

    private func makeMenuButton(title: String, symbolName: String, tint: UIColor, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbolName)
        config.imagePadding = 6
        config.baseForegroundColor = tint
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 4, bottom: 5, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 13, weight: .regular)
            return copy
        }
        btn.configuration = config
        btn.contentHorizontalAlignment = .leading
        btn.addAction(
            UIAction { _ in
                action()
            },
            for: .touchUpInside
        )
        return btn
    }

    private func makeHeaderButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.14)
        config.baseForegroundColor = .white
        config.background.cornerRadius = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 12, weight: .medium)
            return copy
        }
        btn.configuration = config
        btn.addAction(
            UIAction { _ in
                action()
            },
            for: .touchUpInside
        )
        return btn
    }

    private func handleToggleTapped() {
        isMenuOpen.toggle()
        if !isMenuOpen {
            setConfirmingExit(false)
        }
        menuCard.isHidden = !isMenuOpen
        updateToggleIcon()
        layoutOverlayFrames()
    }

    private func collapseMenu() {
        isMenuOpen = false
        setConfirmingExit(false)
        menuCard.isHidden = true
        updateToggleIcon()
    }

    private func setConfirmingExit(_ confirming: Bool) {
        isConfirmingExit = confirming
        exitButton.isHidden = confirming
        confirmRow.isHidden = !confirming
        layoutOverlayFrames()
    }

    private func updateToggleIcon() {
        let name = isMenuOpen ? "xmark" : "slider.horizontal.3"
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        toggleButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
    }

    private func openLogViewer() {
        collapseMenu()
        reloadLogContents()
        logCard.isHidden = false
        layoutOverlayFrames()
    }

    private func reloadLogContents() {
        logCopyButton.setTitle("Copy", for: .normal)
        let logURL = logDir.appendingPathComponent("renplay_session.log")
        if let content = try? String(contentsOf: logURL, encoding: .utf8), !content.isEmpty {
            logTextView.text = content
        } else {
            logTextView.text = "No session logs recorded yet."
        }
    }

    private func scrollLogToBottom() {
        let count = (logTextView.text as NSString).length
        if count > 0 {
            logTextView.scrollRangeToVisible(NSRange(location: count - 1, length: 1))
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panStartOrigin = buttonOrigin
        case .changed:
            let t = recognizer.translation(in: view)
            buttonOrigin = CGPoint(x: panStartOrigin.x + t.x, y: panStartOrigin.y + t.y)
            clampButtonOrigin()
            layoutOverlayFrames()
        default:
            break
        }
    }

    private func clampButtonOrigin() {
        let bounds = view.bounds
        guard bounds.width > 44, bounds.height > 44 else { return }
        let insets = view.safeAreaInsets
        let minX = insets.left + 8
        let maxX = max(minX, bounds.width - insets.right - 52)
        let minY = insets.top + 8
        let maxY = max(minY, bounds.height - insets.bottom - 52)
        buttonOrigin.x = min(max(buttonOrigin.x, minX), maxX)
        buttonOrigin.y = min(max(buttonOrigin.y, minY), maxY)
    }

    private func layoutOverlayFrames() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        toggleButton.frame = CGRect(origin: buttonOrigin, size: CGSize(width: 44, height: 44))

        let menuWidth: CGFloat = 200
        let fitSize = menuCard.systemLayoutSizeFitting(
            CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let menuHeight = min(fitSize.height, max(200, bounds.height - 24))
        var menuX = buttonOrigin.x
        if menuX + menuWidth > bounds.width - 8 {
            menuX = max(8, bounds.width - menuWidth - 8)
        }
        var menuY = toggleButton.frame.maxY + 8
        if menuY + menuHeight > bounds.height - 8 {
            let aboveY = buttonOrigin.y - menuHeight - 8
            menuY = max(8, aboveY >= 8 ? aboveY : bounds.height - menuHeight - 8)
        }
        menuCard.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)

        let logW = max(280, min(bounds.width - 32, 560))
        let logH = max(180, min(bounds.height - 100, 420))
        logCard.frame = CGRect(
            x: (bounds.width - logW) * 0.5,
            y: (bounds.height - logH) * 0.5,
            width: logW,
            height: logH
        )
    }
}
#endif
