// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(UIKit)
import CRenPlayBridge
import RenPlayCore
import UIKit

final class GameOverlayWindow: UIWindow {
    private let overlayController: GameOverlayViewController

    init(
        windowScene: UIWindowScene,
        gameID: UUID,
        gameName: String,
        logDir: URL,
        opacity: Double,
        initialVolume: Double,
        showFloatingButton: Bool,
        showFPS: Bool,
        showQuickBar: Bool,
        mouseSpeed: Double,
        initialTransparentTextboxes: Bool,
        initialVariants: [String],
        screenshotDestMode: Int,
        initialGestures: GestureProfile,
        isSafeMode: Bool,
        onPersistSettings: ((Double, Bool, Bool, Double, Int) -> Void)?,
        onPersistGestures: ((GestureProfile) -> Void)?
    ) {
        let controller = GameOverlayViewController(
            gameID: gameID,
            gameName: gameName,
            logDir: logDir,
            opacity: opacity,
            initialVolume: initialVolume,
            showFloatingButton: showFloatingButton,
            showFPS: showFPS,
            showQuickBar: showQuickBar,
            mouseSpeed: mouseSpeed,
            initialTransparentTextboxes: initialTransparentTextboxes,
            initialVariants: initialVariants,
            screenshotDestMode: screenshotDestMode,
            initialGestures: initialGestures,
            isSafeMode: isSafeMode,
            onPersistSettings: onPersistSettings,
            onPersistGestures: onPersistGestures
        )
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

private struct HudVarItem {
    let name: String
    let kind: String
    var value: String
    let editable: Bool
    var frozen: Bool
}

private enum HudModalKind {
    case variants
    case gallery
    case progress
    case variables
    case settings
    case gestures
    case tools
    case exitConfirm
    case logs
}

private final class GameOverlayViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let gameID: UUID
    private let gameName: String
    private let logDir: URL

    private var overlayAlpha: CGFloat
    private var volumeValue: Float
    private let showFloatingButton: Bool
    private var showFPS: Bool
    private var showQuickBar: Bool
    private var mouseSpeed: CGFloat

    private let toggleButton = UIButton(type: .system)
    private let quickBarView = UIView()
    private let keyboardPillButton = UIButton(type: .system)
    private let fpsBadgeLabel = UILabel()

    private let expandedBackdrop = UIView()
    private let toolGridContainer = UIView()
    private let variantsBtn = UIButton(type: .system)
    private let galleryBtn = UIButton(type: .system)
    private let progressBtn = UIButton(type: .system)
    private let progressRingLayer = CAShapeLayer()
    private let progressLabel = UILabel()
    private let variablesBtn = UIButton(type: .system)

    private let volumePill = UIView()
    private let volumeSlider = UISlider()
    private let mouseToggleButton = UIButton(type: .system)

    private let bottomDock = UIView()
    private let modalContainer = UIView()
    private let modalHeaderIcon = UIImageView()
    private let modalTitleLabel = UILabel()
    private let modalBody = UIStackView()

    // Virtual mouse overlay
    private let mouseTrackpadView = UIView()
    private let cursorView = UIImageView()
    private var cursorNormPoint = CGPoint(x: 0.5, y: 0.5)
    private var isMouseEnabled = false
    private var mousePanStart = CGPoint.zero

    // State synced from engine
    private var seenDialogue = 0
    private var totalDialogue = 0
    private var isHUDExpanded = false
    private var activeModal: HudModalKind?
    private var transparentTextboxes: Bool
    private var selectedVariants: Set<String>
    private var screenshotDestMode: Int
    private var gestures: GestureProfile
    private let isSafeMode: Bool
    private let onPersistSettings: ((Double, Bool, Bool, Double, Int) -> Void)?
    private let onPersistGestures: ((GestureProfile) -> Void)?
    private var selectedRotationMode: Int = Int(renplay_get_preferred_orientation())

    // Dynamic modal views updated on RPC reply
    private weak var galleryStatusLabel: UILabel?
    private var varScope = "store"
    private var varBrowseMode = 0
    private var varItems: [HudVarItem] = []
    private var varSearchQuery = ""
    private var savedVarNames: Set<String>
    private weak var varTableView: UITableView?
    private weak var varScopeButton: UIButton?
    private weak var varSearchField: UITextField?
    private weak var logTextView: UITextView?

    private var buttonOrigin = CGPoint(x: 16, y: 20)
    private var panStartOrigin = CGPoint.zero
    nonisolated(unsafe) private var pollTimer: Timer?
    nonisolated(unsafe) private var displayLink: CADisplayLink?
    private var fpsFrameCount = 0
    private var fpsLastStamp: CFTimeInterval = 0
    private var lastVolumeSentAt: CFTimeInterval = 0

    private static let allVariants = [
        "pc", "large", "medium",
        "small", "tablet", "phone",
        "touch", "tv", "android",
        "ios", "mobile", "web",
    ]

    init(
        gameID: UUID,
        gameName: String,
        logDir: URL,
        opacity: Double,
        initialVolume: Double,
        showFloatingButton: Bool,
        showFPS: Bool,
        showQuickBar: Bool,
        mouseSpeed: Double,
        initialTransparentTextboxes: Bool,
        initialVariants: [String],
        screenshotDestMode: Int,
        initialGestures: GestureProfile,
        isSafeMode: Bool,
        onPersistSettings: ((Double, Bool, Bool, Double, Int) -> Void)?,
        onPersistGestures: ((GestureProfile) -> Void)?
    ) {
        self.gameID = gameID
        self.gameName = gameName
        self.logDir = logDir
        self.overlayAlpha = CGFloat(min(max(opacity, 0.35), 1.0))
        self.volumeValue = Float(min(max(initialVolume, 0.0), 1.0))
        self.showFloatingButton = showFloatingButton
        self.showFPS = showFPS
        self.showQuickBar = showQuickBar
        self.mouseSpeed = CGFloat(min(max(mouseSpeed, 0.4), 2.5))
        self.transparentTextboxes = initialTransparentTextboxes
        if initialVariants.isEmpty {
            self.selectedVariants = UIDevice.current.userInterfaceIdiom == .pad
                ? ["tablet", "touch", "ios"]
                : ["phone", "touch", "ios"]
        } else {
            self.selectedVariants = Set(initialVariants)
        }
        self.screenshotDestMode = screenshotDestMode
        self.gestures = initialGestures
        self.isSafeMode = isSafeMode
        self.onPersistSettings = onPersistSettings
        self.onPersistGestures = onPersistGestures
        let saved = UserDefaults.standard.stringArray(forKey: "renplay.savedVars.\(gameID.uuidString)") ?? []
        self.savedVarNames = Set(saved)
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
        setupMouseTrackpad()
        setupExpandedBackdrop()
        setupToggleAndQuickBar()
        setupFPSBadge()
        setupKeyboardPillButton()
        setupToolCluster()
        setupRightControls()
        setupBottomDock()
        setupModalContainer()
        startTimers()
        updateVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    deinit {
        pollTimer?.invalidate()
        displayLink?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        clampButtonOrigin()
        layoutAllFrames()
    }

    func hitTestableView(at point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isViewLoaded else { return nil }

        if activeModal != nil {
            let local = modalContainer.convert(point, from: view)
            if modalContainer.bounds.contains(local) {
                return modalContainer.hitTest(local, with: event) ?? modalContainer
            }
            return expandedBackdrop
        }

        if !toggleButton.isHidden && toggleButton.frame.insetBy(dx: -6, dy: -6).contains(point) {
            return toggleButton
        }
        if !keyboardPillButton.isHidden && keyboardPillButton.frame.insetBy(dx: -4, dy: -4).contains(point) {
            return keyboardPillButton
        }

        if isHUDExpanded {
            for container in [toolGridContainer, volumePill, mouseToggleButton, bottomDock] where !container.isHidden {
                let local = container.convert(point, from: view)
                if container.bounds.contains(local) {
                    return container.hitTest(local, with: event) ?? container
                }
            }
            return expandedBackdrop
        }

        if !quickBarView.isHidden {
            let local = quickBarView.convert(point, from: view)
            if quickBarView.bounds.contains(local) {
                return quickBarView.hitTest(local, with: event) ?? quickBarView
            }
        }

        if isMouseEnabled {
            let local = mouseToggleButton.convert(point, from: view)
            if mouseToggleButton.bounds.contains(local) {
                return mouseToggleButton
            }
            return mouseTrackpadView
        }

        return nil
    }

    // MARK: - Setup

    private func setupMouseTrackpad() {
        mouseTrackpadView.backgroundColor = .clear
        mouseTrackpadView.isHidden = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMousePan(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMouseLeftClick(_:)))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(handleMouseRightClick(_:)))
        rightTap.numberOfTouchesRequired = 2
        tap.require(toFail: rightTap)
        mouseTrackpadView.addGestureRecognizer(pan)
        mouseTrackpadView.addGestureRecognizer(tap)
        mouseTrackpadView.addGestureRecognizer(rightTap)
        view.addSubview(mouseTrackpadView)

        cursorView.image = Self.makeCursorArrowImage()
        cursorView.contentMode = .topLeft
        cursorView.frame = CGRect(x: 0, y: 0, width: 16, height: 22)
        cursorView.isHidden = true
        cursorView.isUserInteractionEnabled = false
        view.addSubview(cursorView)
    }

    private static func makeCursorArrowImage() -> UIImage {
        let size = CGSize(width: 16, height: 22)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1.5, y: 1.5))
            path.addLine(to: CGPoint(x: 1.5, y: 16.5))
            path.addLine(to: CGPoint(x: 5.3, y: 13.0))
            path.addLine(to: CGPoint(x: 8.0, y: 19.2))
            path.addLine(to: CGPoint(x: 10.2, y: 18.2))
            path.addLine(to: CGPoint(x: 7.5, y: 12.1))
            path.addLine(to: CGPoint(x: 12.5, y: 12.1))
            path.close()
            path.lineJoinStyle = .round

            let cg = ctx.cgContext
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0.5, height: 1.0), blur: 1.5, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            UIColor.white.setFill()
            path.fill()
            cg.restoreGState()

            UIColor.black.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }

    private func setupExpandedBackdrop() {
        expandedBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        expandedBackdrop.isHidden = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap))
        expandedBackdrop.addGestureRecognizer(tap)
        view.addSubview(expandedBackdrop)
    }

    private func setupToggleAndQuickBar() {
        toggleButton.backgroundColor = UIColor(white: 0.12, alpha: max(overlayAlpha, 0.68))
        toggleButton.tintColor = .white
        toggleButton.layer.cornerRadius = 20
        toggleButton.layer.borderWidth = 0.75
        toggleButton.layer.borderColor = UIColor.white.withAlphaComponent(0.26).cgColor
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        toggleButton.setImage(UIImage(systemName: "command", withConfiguration: cfg), for: .normal)
        toggleButton.addAction(UIAction { [weak self] _ in
            self?.toggleHUD()
        }, for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTogglePan(_:)))
        pan.delaysTouchesBegan = false
        pan.cancelsTouchesInView = true
        toggleButton.addGestureRecognizer(pan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleToggleLongPress(_:)))
        longPress.minimumPressDuration = 0.42
        toggleButton.addGestureRecognizer(longPress)
        view.addSubview(toggleButton)

        quickBarView.backgroundColor = UIColor(white: 0.12, alpha: max(overlayAlpha, 0.72))
        quickBarView.layer.cornerRadius = 20
        quickBarView.layer.borderWidth = 0.75
        quickBarView.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        let quickSpecs: [(String, Int32)] = [
            ("backward.fill", Int32(RENPLAY_CMD_ROLLBACK)),
            ("keyboard", Int32(RENPLAY_CMD_TOGGLE_KEYBOARD)),
            ("forward.fill", Int32(RENPLAY_CMD_TOGGLE_SKIP)),
            ("square.and.arrow.down", Int32(RENPLAY_CMD_QUICK_SAVE)),
        ]
        for (sym, cmd) in quickSpecs {
            let b = UIButton(type: .system)
            b.tintColor = .white
            b.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 36).isActive = true
            b.heightAnchor.constraint(equalToConstant: 34).isActive = true
            b.addAction(UIAction { _ in renplay_request_command(cmd) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        quickBarView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: quickBarView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: quickBarView.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: quickBarView.centerYAnchor),
        ])
        view.addSubview(quickBarView)
    }

    private func setupFPSBadge() {
        fpsBadgeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        fpsBadgeLabel.textColor = .white
        fpsBadgeLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        fpsBadgeLabel.layer.cornerRadius = 6
        fpsBadgeLabel.clipsToBounds = true
        fpsBadgeLabel.textAlignment = .center
        fpsBadgeLabel.text = "60 fps"
        fpsBadgeLabel.isHidden = !showFPS
        view.addSubview(fpsBadgeLabel)
    }

    private func setupKeyboardPillButton() {
        var config = UIButton.Configuration.filled()
        config.title = "Keyboard"
        config.image = UIImage(systemName: "keyboard")
        config.imagePadding = 6
        config.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.88)
        config.baseForegroundColor = .white
        config.background.cornerRadius = 17
        config.background.strokeColor = UIColor.white.withAlphaComponent(0.25)
        config.background.strokeWidth = 0.75
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 12, weight: .semibold)
            return copy
        }
        keyboardPillButton.configuration = config
        keyboardPillButton.isHidden = true
        keyboardPillButton.addAction(UIAction { _ in
            renplay_show_keyboard_from_ui()
        }, for: .touchUpInside)
        view.addSubview(keyboardPillButton)
    }

    private func setupToolCluster() {
        toolGridContainer.isHidden = true

        styleCircleButton(variantsBtn, symbol: "rectangle.3.group")
        variantsBtn.addAction(UIAction { [weak self] _ in self?.openModal(.variants) }, for: .touchUpInside)

        styleCircleButton(galleryBtn, symbol: "photo.on.rectangle.angled")
        galleryBtn.addAction(UIAction { [weak self] _ in self?.openModal(.gallery) }, for: .touchUpInside)

        progressBtn.backgroundColor = UIColor(white: 0.12, alpha: 0.86)
        progressBtn.layer.cornerRadius = 24
        progressBtn.layer.borderWidth = 0.75
        progressBtn.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor

        let track = CAShapeLayer()
        let ringPath = UIBezierPath(arcCenter: CGPoint(x: 24, y: 24), radius: 20, startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        track.path = ringPath.cgPath
        track.strokeColor = UIColor.white.withAlphaComponent(0.18).cgColor
        track.fillColor = UIColor.clear.cgColor
        track.lineWidth = 3.2
        progressBtn.layer.addSublayer(track)

        progressRingLayer.path = ringPath.cgPath
        progressRingLayer.strokeColor = UIColor.systemBlue.cgColor
        progressRingLayer.fillColor = UIColor.clear.cgColor
        progressRingLayer.lineWidth = 3.2
        progressRingLayer.lineCap = .round
        progressRingLayer.strokeEnd = 0
        progressBtn.layer.addSublayer(progressRingLayer)

        progressLabel.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        progressLabel.textAlignment = .center
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        progressLabel.textColor = .white
        progressLabel.text = "0%"
        progressLabel.isUserInteractionEnabled = false
        progressBtn.addSubview(progressLabel)
        progressBtn.addAction(UIAction { [weak self] _ in self?.openModal(.progress) }, for: .touchUpInside)

        styleCircleButton(variablesBtn, symbol: "wrench.and.screwdriver")
        variablesBtn.addAction(UIAction { [weak self] _ in self?.openModal(.variables) }, for: .touchUpInside)

        for b in [variantsBtn, galleryBtn, progressBtn, variablesBtn] {
            toolGridContainer.addSubview(b)
        }
        view.addSubview(toolGridContainer)
    }

    private func styleCircleButton(_ btn: UIButton, symbol: String, tint: UIColor = .white) {
        btn.backgroundColor = UIColor(white: 0.12, alpha: 0.86)
        btn.tintColor = tint
        btn.layer.cornerRadius = 24
        btn.layer.borderWidth = 0.75
        btn.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
    }

    private func setupRightControls() {
        volumePill.backgroundColor = UIColor(white: 0.12, alpha: 0.86)
        volumePill.layer.cornerRadius = 22
        volumePill.layer.borderWidth = 0.75
        volumePill.layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor
        volumePill.isHidden = true

        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 1
        volumeSlider.value = volumeValue
        volumeSlider.minimumTrackTintColor = .systemBlue
        volumeSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        volumeSlider.addTarget(self, action: #selector(handleVolumeChanged), for: .valueChanged)

        let speakerIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        speakerIcon.tintColor = .white
        speakerIcon.contentMode = .scaleAspectFit
        speakerIcon.translatesAutoresizingMaskIntoConstraints = false
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false
        volumePill.addSubview(volumeSlider)
        volumePill.addSubview(speakerIcon)
        NSLayoutConstraint.activate([
            volumeSlider.leadingAnchor.constraint(equalTo: volumePill.leadingAnchor, constant: 14),
            volumeSlider.centerYAnchor.constraint(equalTo: volumePill.centerYAnchor),
            speakerIcon.leadingAnchor.constraint(equalTo: volumeSlider.trailingAnchor, constant: 10),
            speakerIcon.trailingAnchor.constraint(equalTo: volumePill.trailingAnchor, constant: -14),
            speakerIcon.centerYAnchor.constraint(equalTo: volumePill.centerYAnchor),
            speakerIcon.widthAnchor.constraint(equalToConstant: 20),
            speakerIcon.heightAnchor.constraint(equalToConstant: 20),
        ])
        view.addSubview(volumePill)

        styleCircleButton(mouseToggleButton, symbol: "computermouse", tint: .white)
        mouseToggleButton.isHidden = true
        mouseToggleButton.addAction(UIAction { [weak self] _ in self?.toggleVirtualMouse() }, for: .touchUpInside)
        view.addSubview(mouseToggleButton)
    }

    private func setupBottomDock() {
        bottomDock.backgroundColor = UIColor(white: 0.08, alpha: 0.94)
        bottomDock.layer.cornerRadius = 16
        bottomDock.layer.borderWidth = 0.75
        bottomDock.layer.borderColor = UIColor.white.withAlphaComponent(0.20).cgColor
        bottomDock.isHidden = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        let items: [(String?, String?, UIColor, () -> Void)] = [
            ("xmark", nil, .systemRed, { [weak self] in self?.openModal(.exitConfirm) }),
            ("gearshape.fill", nil, .white, { [weak self] in self?.openModal(.settings) }),
            (nil, "Aa", .white, { [weak self] in self?.openModal(.tools) }),
            ("arrow.clockwise", nil, .white, { [weak self] in self?.triggerReloadScript() }),
        ]
        for (sym, txt, tint, action) in items {
            let btn = UIButton(type: .system)
            btn.tintColor = tint
            if let sym {
                btn.setImage(UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
            } else if let txt {
                btn.setTitle(txt, for: .normal)
                btn.setTitleColor(tint, for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 19, weight: .medium)
            }
            btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
            stack.addArrangedSubview(btn)
        }
        bottomDock.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bottomDock.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomDock.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bottomDock.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: bottomDock.trailingAnchor, constant: -6),
        ])
        view.addSubview(bottomDock)
    }

    private func setupModalContainer() {
        modalContainer.backgroundColor = UIColor(white: 0.09, alpha: 0.96)
        modalContainer.layer.cornerRadius = 16
        modalContainer.layer.borderWidth = 0.75
        modalContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        modalContainer.clipsToBounds = true
        modalContainer.isHidden = true

        let header = UIView()
        header.backgroundColor = UIColor(white: 0.13, alpha: 1.0)
        header.translatesAutoresizingMaskIntoConstraints = false

        modalHeaderIcon.tintColor = .white
        modalHeaderIcon.contentMode = .scaleAspectFit
        modalHeaderIcon.translatesAutoresizingMaskIntoConstraints = false

        modalTitleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        modalTitleLabel.textColor = .white
        modalTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = UIButton(type: .system)
        closeBtn.tintColor = .systemRed
        closeBtn.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addAction(UIAction { [weak self] _ in self?.closeModal() }, for: .touchUpInside)

        header.addSubview(modalHeaderIcon)
        header.addSubview(modalTitleLabel)
        header.addSubview(closeBtn)

        let hairline = UIView()
        hairline.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        hairline.translatesAutoresizingMaskIntoConstraints = false

        modalBody.axis = .vertical
        modalBody.spacing = 12
        modalBody.alignment = .fill
        modalBody.translatesAutoresizingMaskIntoConstraints = false

        modalContainer.addSubview(header)
        modalContainer.addSubview(hairline)
        modalContainer.addSubview(modalBody)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: modalContainer.topAnchor),
            header.leadingAnchor.constraint(equalTo: modalContainer.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: modalContainer.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            modalHeaderIcon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            modalHeaderIcon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modalHeaderIcon.widthAnchor.constraint(equalToConstant: 20),
            modalHeaderIcon.heightAnchor.constraint(equalToConstant: 20),

            modalTitleLabel.leadingAnchor.constraint(equalTo: modalHeaderIcon.trailingAnchor, constant: 10),
            modalTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeBtn.leadingAnchor, constant: -8),
            modalTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 32),
            closeBtn.heightAnchor.constraint(equalToConstant: 32),

            hairline.topAnchor.constraint(equalTo: header.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: modalContainer.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: modalContainer.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            modalBody.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 14),
            modalBody.leadingAnchor.constraint(equalTo: modalContainer.leadingAnchor, constant: 14),
            modalBody.trailingAnchor.constraint(equalTo: modalContainer.trailingAnchor, constant: -14),
            modalBody.bottomAnchor.constraint(equalTo: modalContainer.bottomAnchor, constant: -14),
        ])
        view.addSubview(modalContainer)
    }

    // MARK: - Actions & Modals

    private func toggleHUD() {
        if activeModal != nil {
            closeModal()
            return
        }
        isHUDExpanded.toggle()
        updateVisibility()
        layoutAllFrames()
    }

    @objc private func handleBackdropTap() {
        if activeModal != nil {
            closeModal()
        } else if isHUDExpanded {
            isHUDExpanded = false
            updateVisibility()
            layoutAllFrames()
        }
    }

    private func closeModal() {
        activeModal = nil
        modalContainer.isHidden = true
        updateVisibility()
        layoutAllFrames()
    }

    private func updateVisibility() {
        let modalOpen = activeModal != nil
        toggleButton.isHidden = !showFloatingButton && !isHUDExpanded && !modalOpen
        expandedBackdrop.isHidden = !isHUDExpanded && !modalOpen
        quickBarView.isHidden = isHUDExpanded || modalOpen || !showQuickBar || !showFloatingButton
        toolGridContainer.isHidden = !isHUDExpanded || modalOpen
        volumePill.isHidden = !isHUDExpanded || modalOpen
        mouseToggleButton.isHidden = !(isHUDExpanded || isMouseEnabled) || modalOpen
        bottomDock.isHidden = !isHUDExpanded || modalOpen
        mouseTrackpadView.isHidden = !isMouseEnabled || isHUDExpanded || modalOpen
        cursorView.isHidden = !isMouseEnabled
        mouseToggleButton.tintColor = isMouseEnabled ? .systemGreen : .white
        fpsBadgeLabel.isHidden = !showFPS
    }

    private func openModal(_ kind: HudModalKind) {
        activeModal = kind
        isHUDExpanded = true
        for sub in modalBody.arrangedSubviews {
            modalBody.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        switch kind {
        case .variants:
            buildVariantsModal()
        case .gallery:
            buildGalleryModal()
        case .progress:
            buildProgressModal()
        case .variables:
            buildVariablesModal()
        case .settings:
            buildSettingsModal()
        case .gestures:
            buildGesturesModal()
        case .tools:
            buildToolsModal()
        case .exitConfirm:
            buildExitConfirmModal()
        case .logs:
            buildLogsModal()
        }

        modalContainer.isHidden = false
        updateVisibility()
        layoutAllFrames()
    }

    private func buildVariantsModal() {
        modalHeaderIcon.image = UIImage(systemName: "rectangle.3.group")
        modalTitleLabel.text = "Device Variants"

        let sub = UILabel()
        sub.text = "Select display variants to apply in Ren'Py"
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabel
        sub.textAlignment = .center
        modalBody.addArrangedSubview(sub)

        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        for rowStart in stride(from: 0, to: Self.allVariants.count, by: 3) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for idx in rowStart..<min(rowStart + 3, Self.allVariants.count) {
                let name = Self.allVariants[idx]
                let btn = makeVariantChip(name)
                row.addArrangedSubview(btn)
            }
            grid.addArrangedSubview(row)
        }
        modalBody.addArrangedSubview(grid)

        let applyBtn = makePrimaryButton("Apply") { [weak self] in
            guard let self, !self.selectedVariants.isEmpty else { return }
            self.sendRPC(["op": "set_variants", "variants": Array(self.selectedVariants).sorted()])
            self.closeModal()
        }
        modalBody.addArrangedSubview(applyBtn)
    }

    private func makeVariantChip(_ name: String) -> UIButton {
        let btn = UIButton(type: .system)
        func syncChip() {
            let on = selectedVariants.contains(name)
            var cfg = UIButton.Configuration.filled()
            cfg.title = name
            cfg.image = UIImage(systemName: on ? "checkmark.circle.fill" : "circle")
            cfg.imagePadding = 6
            cfg.baseBackgroundColor = on ? UIColor.systemBlue.withAlphaComponent(0.28) : UIColor(white: 0.14, alpha: 1.0)
            cfg.baseForegroundColor = .white
            cfg.background.cornerRadius = 8
            cfg.background.strokeColor = on ? .systemBlue : UIColor.white.withAlphaComponent(0.20)
            cfg.background.strokeWidth = 1
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 6, bottom: 7, trailing: 6)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var copy = incoming
                copy.font = .systemFont(ofSize: 12, weight: .medium)
                return copy
            }
            btn.configuration = cfg
        }
        syncChip()
        btn.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.selectedVariants.contains(name) {
                if self.selectedVariants.count > 1 { self.selectedVariants.remove(name) }
            } else {
                self.selectedVariants.insert(name)
            }
            syncChip()
        }, for: .touchUpInside)
        return btn
    }

    private func buildGalleryModal() {
        modalHeaderIcon.image = UIImage(systemName: "photo.on.rectangle.angled")
        modalTitleLabel.text = "Gallery Unlocker"

        let desc = UILabel()
        desc.text = "Unlock photos, scenes, and gallery entries for the current title. Compatibility varies by game."
        desc.font = .systemFont(ofSize: 13)
        desc.textColor = .lightGray
        desc.textAlignment = .center
        desc.numberOfLines = 0
        modalBody.addArrangedSubview(desc)

        let status = UILabel()
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .systemGreen
        status.textAlignment = .center
        status.text = ""
        status.isHidden = true
        self.galleryStatusLabel = status
        modalBody.addArrangedSubview(status)

        let unlockBtn = makePrimaryButton("Unlock All") { [weak self] in
            self?.sendRPC(["op": "unlock_gallery"])
        }
        modalBody.addArrangedSubview(unlockBtn)
    }

    private func buildProgressModal() {
        modalHeaderIcon.image = UIImage(systemName: "book")
        let pct = totalDialogue > 0 ? Int(min(100, (seenDialogue * 100) / max(1, totalDialogue))) : 0
        modalTitleLabel.text = "Dialogue Progress • \(pct)%"

        let info = UILabel()
        info.text = "Dialogue Seen: \(seenDialogue)\nTotal Dialogue Blocks: \(totalDialogue)"
        info.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        info.textColor = .white
        info.textAlignment = .center
        info.numberOfLines = 0
        modalBody.addArrangedSubview(info)

        modalBody.addArrangedSubview(makePrimaryButton("Close") { [weak self] in
            self?.closeModal()
        })
    }

    private func buildVariablesModal() {
        modalHeaderIcon.image = UIImage(systemName: "safari")
        modalTitleLabel.text = "Variable Editor"

        let topRow = UIStackView()
        topRow.axis = .horizontal
        topRow.spacing = 8
        topRow.alignment = .center

        let scopeBtn = UIButton(type: .system)
        var sCfg = UIButton.Configuration.filled()
        sCfg.title = varScope
        sCfg.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.24)
        sCfg.baseForegroundColor = .systemBlue
        sCfg.background.cornerRadius = 8
        sCfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        scopeBtn.configuration = sCfg
        scopeBtn.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.varScope = (self.varScope == "store") ? "persistent" : "store"
            var copy = self.varScopeButton?.configuration
            copy?.title = self.varScope
            self.varScopeButton?.configuration = copy
            self.requestVariablesList()
        }, for: .touchUpInside)
        self.varScopeButton = scopeBtn

        let search = UITextField()
        search.placeholder = "Search variables"
        search.text = varSearchQuery
        search.textColor = .white
        search.backgroundColor = UIColor(white: 0.16, alpha: 1.0)
        search.layer.cornerRadius = 8
        search.font = .systemFont(ofSize: 13)
        search.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        search.leftViewMode = .always
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.returnKeyType = .search
        search.delegate = self
        search.addTarget(self, action: #selector(handleVarSearchChanged), for: .editingChanged)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.heightAnchor.constraint(equalToConstant: 32).isActive = true
        self.varSearchField = search

        let refreshBtn = UIButton(type: .system)
        refreshBtn.tintColor = .systemBlue
        refreshBtn.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshBtn.addAction(UIAction { [weak self] _ in self?.requestVariablesList() }, for: .touchUpInside)

        topRow.addArrangedSubview(scopeBtn)
        topRow.addArrangedSubview(search)
        topRow.addArrangedSubview(refreshBtn)
        modalBody.addArrangedSubview(topRow)

        let modeSeg = UISegmentedControl(items: ["Browse", "Saved"])
        modeSeg.selectedSegmentIndex = varBrowseMode
        modeSeg.addAction(UIAction { [weak self, weak modeSeg] _ in
            guard let self, let modeSeg else { return }
            self.varBrowseMode = modeSeg.selectedSegmentIndex
            self.varTableView?.reloadData()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(modeSeg)

        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = UIColor(white: 0.06, alpha: 1.0)
        table.separatorColor = UIColor.white.withAlphaComponent(0.12)
        table.layer.cornerRadius = 8
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        let tableHeight = min(280, max(160, view.bounds.height - 230))
        table.heightAnchor.constraint(equalToConstant: tableHeight).isActive = true
        self.varTableView = table
        modalBody.addArrangedSubview(table)

        requestVariablesList()
    }

    private func persistOverlaySettings() {
        onPersistSettings?(Double(overlayAlpha), showFPS, showQuickBar, Double(mouseSpeed), screenshotDestMode)
    }

    private func buildSettingsModal() {
        modalHeaderIcon.image = UIImage(systemName: "gearshape.fill")
        modalTitleLabel.text = "Overlay Settings"

        let opacitySlider = UISlider()
        opacitySlider.minimumValue = 0.35
        opacitySlider.maximumValue = 1.0
        opacitySlider.value = Float(overlayAlpha)
        opacitySlider.addAction(UIAction { [weak self, weak opacitySlider] _ in
            guard let self, let opacitySlider else { return }
            self.overlayAlpha = CGFloat(opacitySlider.value)
            self.toggleButton.backgroundColor = UIColor(white: 0.12, alpha: max(self.overlayAlpha, 0.55))
            self.quickBarView.backgroundColor = UIColor(white: 0.12, alpha: max(self.overlayAlpha, 0.55))
            self.persistOverlaySettings()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Opacity", control: opacitySlider))

        let rotSeg = UISegmentedControl(items: ["All", "Left", "Right", "Portrait"])
        let mapToSeg = [0: 0, 1: 1, 2: 2, 3: 3, 4: 0]
        rotSeg.selectedSegmentIndex = mapToSeg[selectedRotationMode] ?? 0
        rotSeg.addAction(UIAction { [weak self, weak rotSeg] _ in
            guard let self, let rotSeg else { return }
            let idx = rotSeg.selectedSegmentIndex
            self.selectedRotationMode = idx
            renplay_set_preferred_orientation(Int32(idx))
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Rotation", control: rotSeg))

        let fpsSwitch = UISwitch()
        fpsSwitch.isOn = showFPS
        fpsSwitch.addAction(UIAction { [weak self, weak fpsSwitch] _ in
            guard let self, let fpsSwitch else { return }
            self.showFPS = fpsSwitch.isOn
            self.updateVisibility()
            self.persistOverlaySettings()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("FPS Counter", control: fpsSwitch))

        let barSwitch = UISwitch()
        barSwitch.isOn = showQuickBar
        barSwitch.addAction(UIAction { [weak self, weak barSwitch] _ in
            guard let self, let barSwitch else { return }
            self.showQuickBar = barSwitch.isOn
            self.updateVisibility()
            self.persistOverlaySettings()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Quick Bar", control: barSwitch))

        let speedSlider = UISlider()
        speedSlider.minimumValue = 0.4
        speedSlider.maximumValue = 2.5
        speedSlider.value = Float(mouseSpeed)
        speedSlider.addAction(UIAction { [weak self, weak speedSlider] _ in
            guard let self, let speedSlider else { return }
            self.mouseSpeed = CGFloat(speedSlider.value)
            self.persistOverlaySettings()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Mouse Speed", control: speedSlider))

        let shotSeg = UISegmentedControl(items: ["Files", "Photos", "Both"])
        shotSeg.selectedSegmentIndex = min(max(screenshotDestMode, 0), 2)
        shotSeg.addAction(UIAction { [weak self, weak shotSeg] _ in
            guard let self, let shotSeg else { return }
            let mode = shotSeg.selectedSegmentIndex
            self.screenshotDestMode = mode
            renplay_set_screenshot_destination(Int32(mode))
            self.persistOverlaySettings()
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Screenshots", control: shotSeg))

        modalBody.addArrangedSubview(makeSecondaryButton("Configure Touch Gestures...") { [weak self] in
            self?.openModal(.gestures)
        })
    }

    private func buildGesturesModal() {
        modalHeaderIcon.image = UIImage(systemName: "hand.draw")
        modalTitleLabel.text = "Touch Gestures"

        if isSafeMode {
            let notice = UILabel()
            notice.text = "Safe Mode is active for this game. Multi-touch gestures are inactive for this session."
            notice.font = .systemFont(ofSize: 12, weight: .medium)
            notice.textColor = .systemOrange
            notice.numberOfLines = 0
            modalBody.addArrangedSubview(notice)
        }

        let enableSwitch = UISwitch()
        enableSwitch.isOn = gestures.isEnabled
        enableSwitch.addAction(UIAction { [weak self, weak enableSwitch] _ in
            guard let self, let enableSwitch else { return }
            self.gestures.isEnabled = enableSwitch.isOn
            self.onPersistGestures?(self.gestures)
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Enable Gestures", control: enableSwitch))

        let specs: [(String, WritableKeyPath<GestureProfile, GestureAction>)] = [
            ("Two-Finger Tap", \.twoFingerTap),
            ("Three-Finger Tap", \.threeFingerTap),
            ("2-Finger Swipe Left", \.twoFingerSwipeLeft),
            ("2-Finger Swipe Right", \.twoFingerSwipeRight),
            ("2-Finger Swipe Up", \.twoFingerSwipeUp),
            ("2-Finger Swipe Down", \.twoFingerSwipeDown),
        ]

        for (title, keyPath) in specs {
            let btn = UIButton(type: .system)
            var cfg = UIButton.Configuration.filled()
            cfg.title = gestures[keyPath: keyPath].displayName
            cfg.baseBackgroundColor = UIColor(white: 0.17, alpha: 1.0)
            cfg.baseForegroundColor = .systemBlue
            cfg.cornerStyle = .medium
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var copy = incoming
                copy.font = .systemFont(ofSize: 12, weight: .semibold)
                return copy
            }
            btn.configuration = cfg
            btn.addAction(UIAction { [weak self, weak btn] _ in
                guard let self, let btn else { return }
                let sheet = UIAlertController(title: title, message: "Choose action", preferredStyle: .actionSheet)
                for action in GestureAction.allCases {
                    let prefix = self.gestures[keyPath: keyPath] == action ? "✓ " : ""
                    sheet.addAction(UIAlertAction(title: "\(prefix)\(action.displayName)", style: .default) { [weak self, weak btn] _ in
                        guard let self else { return }
                        self.gestures[keyPath: keyPath] = action
                        var updatedCfg = btn?.configuration
                        updatedCfg?.title = action.displayName
                        btn?.configuration = updatedCfg
                        self.onPersistGestures?(self.gestures)
                    })
                }
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                if let pop = sheet.popoverPresentationController {
                    pop.sourceView = btn
                    pop.sourceRect = btn.bounds
                }
                self.present(sheet, animated: true)
            }, for: .touchUpInside)
            modalBody.addArrangedSubview(makeLabeledRow(title, control: btn))
        }

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.addArrangedSubview(makeSecondaryButton("Reset Defaults") { [weak self] in
            guard let self else { return }
            self.gestures = GestureProfile()
            self.onPersistGestures?(self.gestures)
            self.openModal(.gestures)
        })
        row.addArrangedSubview(makePrimaryButton("Back") { [weak self] in
            self?.openModal(.settings)
        })
        modalBody.addArrangedSubview(row)
    }

    private func buildToolsModal() {
        modalHeaderIcon.image = UIImage(systemName: "slider.horizontal.3")
        modalTitleLabel.text = "Display & Actions"

        let textboxSwitch = UISwitch()
        textboxSwitch.isOn = transparentTextboxes
        textboxSwitch.addAction(UIAction { [weak self, weak textboxSwitch] _ in
            guard let self, let textboxSwitch else { return }
            self.transparentTextboxes = textboxSwitch.isOn
            self.sendRPC(["op": "set_transparent_textbox", "enabled": textboxSwitch.isOn])
        }, for: .valueChanged)
        modalBody.addArrangedSubview(makeLabeledRow("Transparent Textbox", control: textboxSwitch))

        let buttonSpecs: [(String, () -> Void)] = [
            ("Game Menu", { renplay_request_command(Int32(RENPLAY_CMD_GAME_MENU)) }),
            ("Quick Save", { renplay_request_command(Int32(RENPLAY_CMD_QUICK_SAVE)) }),
            ("Quick Load", { renplay_request_command(Int32(RENPLAY_CMD_QUICK_LOAD)) }),
            ("Hide Dialogue", { renplay_request_command(Int32(RENPLAY_CMD_HIDE_UI)) }),
            ("Screenshot", { renplay_request_command(Int32(RENPLAY_CMD_SCREENSHOT)) }),
            ("Keyboard", { renplay_request_command(Int32(RENPLAY_CMD_TOGGLE_KEYBOARD)) }),
            ("Developer Console", { [weak self] in self?.sendRPC(["op": "open_console"]) }),
            ("Session Logs", { [weak self] in self?.openModal(.logs) }),
        ]

        for rowIdx in stride(from: 0, to: buttonSpecs.count, by: 2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for i in rowIdx..<min(rowIdx + 2, buttonSpecs.count) {
                let spec = buttonSpecs[i]
                let b = makeSecondaryButton(spec.0) { [weak self] in
                    spec.1()
                    if spec.0 != "Session Logs" {
                        self?.closeModal()
                        self?.isHUDExpanded = false
                        self?.updateVisibility()
                    }
                }
                row.addArrangedSubview(b)
            }
            modalBody.addArrangedSubview(row)
        }
    }

    private func buildExitConfirmModal() {
        modalHeaderIcon.image = UIImage(systemName: "power")
        modalTitleLabel.text = "Exit Game"

        let msg = UILabel()
        msg.text = "Close \(gameName) and return to the RenPlay library?"
        msg.font = .systemFont(ofSize: 13)
        msg.textColor = .lightGray
        msg.textAlignment = .center
        msg.numberOfLines = 0
        modalBody.addArrangedSubview(msg)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually

        let cancelBtn = makeSecondaryButton("Cancel") { [weak self] in
            self?.closeModal()
        }
        let quitBtn = makePrimaryButton("Exit to Library", color: .systemRed) {
            renplay_request_command(Int32(RENPLAY_CMD_QUIT))
        }
        row.addArrangedSubview(cancelBtn)
        row.addArrangedSubview(quitBtn)
        modalBody.addArrangedSubview(row)
    }

    private func buildLogsModal() {
        modalHeaderIcon.image = UIImage(systemName: "doc.text")
        modalTitleLabel.text = "Session Logs"

        let tv = UITextView()
        tv.backgroundColor = UIColor(white: 0.04, alpha: 1.0)
        tv.textColor = UIColor(white: 0.92, alpha: 1.0)
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isEditable = false
        tv.layer.cornerRadius = 8
        tv.translatesAutoresizingMaskIntoConstraints = false
        let h = min(280, max(160, view.bounds.height - 200))
        tv.heightAnchor.constraint(equalToConstant: h).isActive = true
        self.logTextView = tv
        reloadLogsText()
        modalBody.addArrangedSubview(tv)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.distribution = .fillEqually
        row.addArrangedSubview(makeSecondaryButton("Refresh") { [weak self] in self?.reloadLogsText() })
        row.addArrangedSubview(makeSecondaryButton("Copy") { [weak self] in
            UIPasteboard.general.string = self?.logTextView?.text ?? ""
        })
        modalBody.addArrangedSubview(row)
    }

    private func reloadLogsText() {
        let logURL = logDir.appendingPathComponent("renplay_session.log")
        if let content = try? String(contentsOf: logURL, encoding: .utf8), !content.isEmpty {
            logTextView?.text = content
        } else {
            logTextView?.text = "No session logs recorded yet."
        }
    }

    private func triggerReloadScript() {
        sendRPC(["op": "reload_script"])
        isHUDExpanded = false
        updateVisibility()
        layoutAllFrames()
    }

    private func toggleVirtualMouse() {
        isMouseEnabled.toggle()
        if isMouseEnabled && isHUDExpanded {
            isHUDExpanded = false
        }
        updateVisibility()
        layoutAllFrames()
    }

    // MARK: - Helpers & RPC

    private func makeLabeledRow(_ title: String, control: UIView) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        let lbl = UILabel()
        lbl.text = title
        lbl.font = .systemFont(ofSize: 14, weight: .medium)
        lbl.textColor = .white
        lbl.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(control)
        return row
    }

    private func makePrimaryButton(_ title: String, color: UIColor = .systemBlue, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = color
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 14, weight: .semibold)
            return copy
        }
        btn.configuration = cfg
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }

    private func makeSecondaryButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .system)
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        cfg.baseBackgroundColor = UIColor(white: 0.17, alpha: 1.0)
        cfg.baseForegroundColor = .white
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var copy = incoming
            copy.font = .systemFont(ofSize: 13, weight: .medium)
            return copy
        }
        btn.configuration = cfg
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }

    private func sendRPC(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }
        jsonStr.withCString { cStr in
            renplay_enqueue_rpc(cStr)
        }
    }

    private func requestVariablesList() {
        sendRPC(["op": "list_vars", "scope": varScope, "query": varSearchQuery])
    }

    @objc private func handleVolumeChanged() {
        volumeValue = volumeSlider.value
        let now = CACurrentMediaTime()
        if now - lastVolumeSentAt >= 0.08 {
            lastVolumeSentAt = now
            sendRPC(["op": "set_volume", "value": Double(volumeValue)])
        }
    }

    @objc private func handleVarSearchChanged() {
        varSearchQuery = varSearchField?.text ?? ""
        requestVariablesList()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        requestVariablesList()
        return true
    }

    // MARK: - Variable TableView

    private var displayedVars: [HudVarItem] {
        if varBrowseMode == 1 {
            return varItems.filter { savedVarNames.contains($0.name) }
        }
        return varItems
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedVars.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellID = "HudVarCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: cellID) ?? UITableViewCell(style: .value1, reuseIdentifier: cellID)
        let item = displayedVars[indexPath.row]
        cell.backgroundColor = .clear
        cell.textLabel?.text = item.name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        cell.detailTextLabel?.text = (item.frozen ? "❄ " : "") + (savedVarNames.contains(item.name) ? "★ " : "") + item.value
        cell.detailTextLabel?.textColor = .lightGray
        cell.detailTextLabel?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.accessoryType = item.editable ? .disclosureIndicator : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = displayedVars[indexPath.row]
        let alert = UIAlertController(title: item.name, message: "Type: \(item.kind)", preferredStyle: .alert)
        if item.editable {
            alert.addTextField { tf in
                tf.text = item.value
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }
            alert.addAction(UIAlertAction(title: "Save Value", style: .default) { [weak self] _ in
                guard let self, let val = alert.textFields?.first?.text else { return }
                self.sendRPC([
                    "op": "set_var",
                    "scope": self.varScope,
                    "name": item.name,
                    "kind": item.kind,
                    "value": val,
                    "freeze": item.frozen,
                ])
                self.requestVariablesList()
            })
        }
        alert.addAction(UIAlertAction(title: item.frozen ? "Unfreeze" : "Freeze", style: .default) { [weak self] _ in
            guard let self else { return }
            self.sendRPC(["op": "toggle_freeze", "scope": self.varScope, "name": item.name])
            self.requestVariablesList()
        })
        let isSaved = savedVarNames.contains(item.name)
        alert.addAction(UIAlertAction(title: isSaved ? "Remove Saved" : "Pin to Saved", style: .default) { [weak self] _ in
            guard let self else { return }
            if isSaved { self.savedVarNames.remove(item.name) } else { self.savedVarNames.insert(item.name) }
            UserDefaults.standard.set(Array(self.savedVarNames).sorted(), forKey: "renplay.savedVars.\(self.gameID.uuidString)")
            self.varTableView?.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Gestures & Timers

    @objc private func handleTogglePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panStartOrigin = buttonOrigin
        case .changed:
            let t = recognizer.translation(in: view)
            buttonOrigin = CGPoint(x: panStartOrigin.x + t.x, y: panStartOrigin.y + t.y)
            clampButtonOrigin()
            layoutAllFrames()
        default:
            break
        }
    }

    @objc private func handleToggleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if activeModal != nil {
            closeModal()
        }
        isHUDExpanded = false
        showQuickBar.toggle()
        persistOverlaySettings()
        updateVisibility()
        layoutAllFrames()
    }

    @objc private func handleMousePan(_ recognizer: UIPanGestureRecognizer) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch recognizer.state {
        case .began:
            mousePanStart = CGPoint(x: cursorNormPoint.x * bounds.width, y: cursorNormPoint.y * bounds.height)
        case .changed:
            let t = recognizer.translation(in: view)
            let nx = min(max((mousePanStart.x + t.x * mouseSpeed) / bounds.width, 0), 1)
            let ny = min(max((mousePanStart.y + t.y * mouseSpeed) / bounds.height, 0), 1)
            cursorNormPoint = CGPoint(x: nx, y: ny)
            layoutCursorFrame()
            renplay_send_virtual_mouse(Float(nx), Float(ny), 0, 0)
        default:
            break
        }
    }

    @objc private func handleMouseLeftClick(_ recognizer: UITapGestureRecognizer) {
        _ = recognizer
        let x = Float(cursorNormPoint.x)
        let y = Float(cursorNormPoint.y)
        renplay_send_virtual_mouse(x, y, 1, 1)
        renplay_send_virtual_mouse(x, y, 1, 2)
    }

    @objc private func handleMouseRightClick(_ recognizer: UITapGestureRecognizer) {
        _ = recognizer
        let x = Float(cursorNormPoint.x)
        let y = Float(cursorNormPoint.y)
        renplay_send_virtual_mouse(x, y, 3, 1)
        renplay_send_virtual_mouse(x, y, 3, 2)
    }

    private func startTimers() {
        pollTimer?.invalidate()
        weak let weakSelf = self
        let timer = Timer(timeInterval: 0.25, repeats: true) { t in
            guard let me = weakSelf else {
                t.invalidate()
                return
            }
            MainActor.assumeIsolated {
                me.pollEngineState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        let link = CADisplayLink(target: self, selector: #selector(handleDisplayTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func handleDisplayTick(_ link: CADisplayLink) {
        guard showFPS else { return }
        if fpsLastStamp == 0 {
            fpsLastStamp = link.timestamp
            return
        }
        fpsFrameCount += 1
        let dt = link.timestamp - fpsLastStamp
        if dt >= 0.5 {
            let fps = Int((Double(fpsFrameCount) / dt).rounded())
            fpsBadgeLabel.text = "\(fps) fps"
            fpsFrameCount = 0
            fpsLastStamp = link.timestamp
        }
    }

    private func pollEngineState() {
        if renplay_consume_hud_toggle_request() != 0 {
            toggleHUD()
        }

        let shouldShowPill = renplay_should_show_keyboard_pill() != 0
        if keyboardPillButton.isHidden == shouldShowPill {
            keyboardPillButton.isHidden = !shouldShowPill
        }

        var seen: Int32 = 0
        var total: Int32 = 0
        renplay_get_dialogue_stats(&seen, &total)
        if Int(seen) != seenDialogue || Int(total) != totalDialogue {
            seenDialogue = Int(seen)
            totalDialogue = Int(total)
            let frac = total > 0 ? min(1.0, max(0.0, CGFloat(seen) / CGFloat(total))) : 0
            progressRingLayer.strokeEnd = frac
            let pct = total > 0 ? Int(min(100, (seen * 100) / max(1, total))) : 0
            progressLabel.text = "\(pct)%"
        }

        var replyBuf = [CChar](repeating: 0, count: 16384)
        while renplay_poll_rpc_reply(&replyBuf, replyBuf.count) > 0 {
            let bytes = replyBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            if let dict = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
               let op = dict["op"] as? String {
                handleRPCReply(op: op, dict: dict)
            }
        }
    }

    private func handleRPCReply(op: String, dict: [String: Any]) {
        if op == "unlock_gallery" {
            let ok = (dict["ok"] as? Bool) == true
            if ok {
                let imgs = dict["images"] as? Int ?? 0
                let blks = dict["blocks"] as? Int ?? 0
                galleryStatusLabel?.text = "Unlocked \(imgs) images & \(blks) blocks"
                galleryStatusLabel?.textColor = .systemGreen
            } else {
                galleryStatusLabel?.text = (dict["error"] as? String) ?? "Failed to unlock"
                galleryStatusLabel?.textColor = .systemRed
            }
            galleryStatusLabel?.isHidden = false
            layoutAllFrames()
        } else if op == "list_vars" {
            guard let rawItems = dict["items"] as? [[String: Any]] else { return }
            varItems = rawItems.compactMap { row -> HudVarItem? in
                guard let name = row["name"] as? String else { return nil }
                return HudVarItem(
                    name: name,
                    kind: (row["kind"] as? String) ?? "object",
                    value: (row["value"] as? String) ?? "",
                    editable: (row["editable"] as? Bool) ?? false,
                    frozen: (row["frozen"] as? Bool) ?? false
                )
            }
            varTableView?.reloadData()
        }
    }

    // MARK: - Layout

    private func clampButtonOrigin() {
        let bounds = view.bounds
        guard bounds.width > 40, bounds.height > 40 else { return }
        let insets = view.safeAreaInsets
        let minX = insets.left + 8
        let maxX = max(minX, bounds.width - insets.right - 48)
        let minY = insets.top + 8
        let maxY = max(minY, bounds.height - insets.bottom - 48)
        buttonOrigin.x = min(max(buttonOrigin.x, minX), maxX)
        buttonOrigin.y = min(max(buttonOrigin.y, minY), maxY)
    }

    private func layoutCursorFrame() {
        let bounds = view.bounds
        let tipX = min(max(cursorNormPoint.x * bounds.width, 0), bounds.width)
        let tipY = min(max(cursorNormPoint.y * bounds.height, 0), bounds.height)
        cursorView.frame = CGRect(x: tipX - 1.5, y: tipY - 1.5, width: 16, height: 22)
    }

    private func layoutAllFrames() {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let insets = view.safeAreaInsets

        expandedBackdrop.frame = bounds
        mouseTrackpadView.frame = bounds
        layoutCursorFrame()

        toggleButton.frame = CGRect(origin: buttonOrigin, size: CGSize(width: 40, height: 40))

        let qbWidth: CGFloat = 172
        var qbX = toggleButton.frame.maxX + 8
        if qbX + qbWidth > bounds.width - insets.right - 8 {
            qbX = max(insets.left + 8, toggleButton.frame.minX - qbWidth - 8)
        }
        quickBarView.frame = CGRect(x: qbX, y: buttonOrigin.y, width: qbWidth, height: 40)

        let pillSize = keyboardPillButton.sizeThatFits(CGSize(width: 140, height: 34))
        let pillW = max(pillSize.width, 98)
        keyboardPillButton.frame = CGRect(x: buttonOrigin.x, y: toggleButton.frame.maxY + 8, width: pillW, height: 34)

        fpsBadgeLabel.frame = CGRect(x: (bounds.width - 62) * 0.5, y: max(8, insets.top + 4), width: 62, height: 20)

        let gridX = insets.left + 12
        let gridY = max(toggleButton.frame.maxY + 10, insets.top + 56)
        toolGridContainer.frame = CGRect(x: gridX, y: gridY, width: 106, height: 106)
        variantsBtn.frame = CGRect(x: 0, y: 0, width: 48, height: 48)
        galleryBtn.frame = CGRect(x: 56, y: 0, width: 48, height: 48)
        progressBtn.frame = CGRect(x: 0, y: 56, width: 48, height: 48)
        variablesBtn.frame = CGRect(x: 56, y: 56, width: 48, height: 48)

        let rightEdge = bounds.width - insets.right - 12
        let volW: CGFloat = min(196, max(140, bounds.width * 0.28))
        let topY = max(12, insets.top + 10)
        volumePill.frame = CGRect(x: rightEdge - volW, y: topY, width: volW, height: 44)
        mouseToggleButton.frame = CGRect(x: rightEdge - 48, y: volumePill.frame.maxY + 12, width: 48, height: 48)

        let dockW: CGFloat = min(310, bounds.width - 32)
        let dockH: CGFloat = 54
        bottomDock.frame = CGRect(
            x: (bounds.width - dockW) * 0.5,
            y: bounds.height - insets.bottom - dockH - 12,
            width: dockW,
            height: dockH
        )

        let modalW = min(bounds.width - 28, activeModal == .variables ? 460 : 370)
        let fit = modalContainer.systemLayoutSizeFitting(
            CGSize(width: modalW, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let maxModalH = max(220, bounds.height - insets.top - insets.bottom - 24)
        let modalH = min(fit.height, maxModalH)
        modalContainer.frame = CGRect(
            x: (bounds.width - modalW) * 0.5,
            y: max(insets.top + 8, (bounds.height - modalH) * 0.5),
            width: modalW,
            height: modalH
        )
    }
}
#endif
