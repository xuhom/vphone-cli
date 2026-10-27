import AppKit
import Foundation
import QuartzCore
import Virtualization
import VPhoneCoreKit

@MainActor
class VPhoneVirtualMachineWindowController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    private weak var control: VPhoneGuestControl?
    private weak var virtualMachineView: VPhoneVirtualMachineView?
    private(set) var homePodDisplayView: VPhoneHomePodDisplayView?
    private var homePodGuest = false
    private(set) var touchIDMonitor: VPhoneTouchIDMonitor?
    private var homeButton: NSButton?
    private var deviceButtons: [NSButton] = []
    private var deviceMenuItems: [NSMenuItem] = []
    /// An Apple TV's TV button: holding the titlebar button holds it in the
    /// guest, so a click goes Home and a hold opens Control Center.
    var homeButtonHoldsInGuest = false {
        didSet { applyHomeButtonHold() }
    }
    private var subtitleLabel: NSTextField?
    private var timers: [Timer] = []
    private var keyStateObservers: [NSObjectProtocol] = []
    private var frameRateTimer: Timer?
    private var frameRateSampledAt: CFTimeInterval = 0
    /// The guest's frame rate over the last second; nil while the display is off.
    private var frameRate: Int?

    var captureView: VPhoneVirtualMachineView? {
        virtualMachineView
    }

    var displayWindow: NSWindow? { windowController?.window }

    func showWindow(
        for vm: VZVirtualMachine,
        screenWidth: Int,
        screenHeight: Int,
        screenScale: Double,
        isPhoneGuest: Bool,
        isPadGuest: Bool,
        isDuoGuest: Bool,
        hardwareKeyboardEnabled: Bool,
        keySender: VPhoneVirtualMachineKeySender,
        control: VPhoneGuestControl,
        name: String,
        sceneIdentifier: String,
        homePodGuest: Bool = false,
    ) {
        self.control = control
        self.homePodGuest = homePodGuest
        homeButton = nil

        let view = VPhoneVirtualMachineView()
        view.virtualMachine = vm
        view.hardwareKeyboardEnabled = hardwareKeyboardEnabled
        view.capturesSystemKeys = hardwareKeyboardEnabled && !homePodGuest
        view.keySender = keySender
        view.control = control
        view.screenScale = CGFloat(screenScale)
        view.clipboardSync = VPhoneClipboardSync(control: control)
        virtualMachineView = view
        let scale = CGFloat(screenScale)
        let windowSize = homePodGuest ? VPhoneHomePodDisplayView.defaultContentSize : NSSize(
            width: CGFloat(screenWidth) / scale,
            height: CGFloat(screenHeight) / scale,
        )
        panelSize = windowSize
        let container: NSView
        if homePodGuest {
            let cap = VPhoneHomePodDisplayView()
            cap.onControlChange = { [weak self] event in
                guard let control = self?.control else { return }
                if event.down {
                    guard control.isConnected else { return }
                    control.sendHIDDown(page: 0x0C, usage: event.control.usage, longPress: event.longPress)
                } else {
                    control.sendHIDUp(page: 0x0C, usage: event.control.usage, minimumHold: event.minimumHold, longPress: event.longPress)
                }
            }
            // Keep the diagnostic framebuffer attached for host automation,
            // while the HomePod's visible output is its physical LED surface.
            view.frame = NSRect(origin: .zero, size: windowSize)
            view.isHidden = true
            cap.addSubview(view, positioned: .below, relativeTo: nil)
            homePodDisplayView = cap
            displayContainer = nil
            container = cap
        } else {
            let display = VPhoneDisplayContainerView(displayView: view)
            display.isPhoneGuest = isPhoneGuest
            display.isPadGuest = isPadGuest
            display.isDuoGuest = isDuoGuest
            display.panelSize = windowSize
            displayContainer = display
            homePodDisplayView = nil
            container = display
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )

        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .normal
        VPhoneAlert.hostWindow = window
        if displayContainer?.hasRoundedScreen != true { window.contentAspectRatio = windowSize }
        window.title = name
        window.contentView = container
        if displayContainer?.hasRoundedScreen == true {
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        // The scene belongs to the VM, not to the app: every VM directory keeps
        // its own window frame, and a newly created VM opens centered instead
        // of inheriting the last frame another VM saved.
        let sceneName = "vphone-scene-\(sceneIdentifier)"
        window.identifier = NSUserInterfaceItemIdentifier(sceneName)
        let restoredFrame = window.setFrameUsingName(sceneName)
        if !restoredFrame {
            window.center()
        }
        window.setFrameAutosaveName(sceneName)
        observeKeyState(of: window)
        // The titlebar accessory keeps device buttons visible while the title
        // truncates in a narrow window. HomePod uses its own display controls.
        let toolbar = NSToolbar(identifier: "vphone-toolbar")
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        var trailingInset: CGFloat = 0
        if !homePodGuest {
            let homeAccessory = makeHomeAccessory()
            window.addTitlebarAccessoryViewController(homeAccessory)
            window.contentMinSize.width = max(window.contentMinSize.width, homeAccessory.view.frame.width + 160)
            updateHomeButton(connected: false)
            trailingInset = homeAccessory.view.frame.width
        }
        pinWindowButtons(in: window)
        installTitle(name, in: window, trailingInset: trailingInset)

        // Size after installing the toolbar, which changes the content height.
        // A saved sideways frame starts in portrait until the guest reports it.
        applyOrientation(.portrait, to: window, force: true)

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        windowController = controller
        // AppKit constrains the initial frame when showing it. Fit the panel
        // after the toolbar and actual screen are known, including a wide TV
        // panel whose saved frame may otherwise be clamped out of proportion.
        // The guest starts unturned; the orientation poll follows it later.
        if !homePodGuest { applyOrientation(.portrait, to: window, force: true) }

        keySender.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        placeWindowButtons()
        if let homePodDisplayView {
            homePodDisplayView.focusControls()
        } else {
            window.makeFirstResponder(view)
            let monitor = VPhoneTouchIDMonitor()
            monitor.start(control: control, window: window)
            touchIDMonitor = monitor
        }

        // Poll vphoned status for the Home button and the subtitle
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let control = self.control else { return }
                self.updateHomeButton(connected: control.isConnected)
                self.updateSubtitle(control: control)
                self.captureView?.clipboardSync?.connectionChanged(connected: control.isConnected)
            }
        })

        // The menu sets the orientation before the guest turns, and the poll
        // after; either way the window follows it.
        if !homePodGuest {
            control.observeInterfaceOrientation { [weak self, weak window] orientation in
                guard let self, let window else { return }
                applyOrientation(orientation ?? .portrait, to: window)
            }
            timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollOrientation() }
            })
        }
        setFrameRateDisplay(VPhoneFrameRateDisplay.isEnabled)
    }

    // MARK: - HomePod Display

    func updateHomePodDisplay(geometry: VPhoneHomePodDisplayGeometry, frame: VPhoneHomePodDisplayFrame) {
        homePodDisplayView?.update(geometry: geometry, frame: frame)
    }

    func clearHomePodDisplay() {
        homePodDisplayView?.clearDisplay()
    }

    // MARK: - Close

    func windowDidEnterFullScreen(_: Notification) {
        displayContainer?.needsLayout = true
    }

    func windowDidExitFullScreen(_: Notification) {
        displayContainer?.needsLayout = true
        windowController?.window?.invalidateShadow()
    }

    func windowDidEndLiveResize(_: Notification) {
        windowController?.window?.invalidateShadow()
    }

    /// A fixed transparent gap cannot be represented by contentAspectRatio:
    /// only the screen scales, while the space below the titlebar stays fixed.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let container = displayContainer, container.hasRoundedScreen,
              !sender.styleMask.contains(.fullScreen)
        else { return frameSize }
        var proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let current = sender.contentRect(forFrameRect: sender.frame)
        let panel = container.orientation.displayedSize(panel: panelSize)
        let gap = container.titlebarGap
        if abs(proposed.width - current.width) >= abs(proposed.height - current.height) {
            proposed.size.height = proposed.width * panel.height / panel.width + gap
        } else {
            proposed.size.width = max(1, proposed.height - gap) * panel.width / panel.height
        }
        return sender.frameRect(forContentRect: proposed).size
    }

    /// Closing the display window stops the VM, so the close button asks the
    /// same question as ⌘Q, with the window still up, instead of closing
    /// first. `closeForRestart` closes without asking.
    func windowShouldClose(_: NSWindow) -> Bool {
        homePodDisplayView?.releaseControls()
        NSApp.terminate(nil)
        return false
    }

    /// Disconnect the old display and input devices before rebuilding the VM.
    func closeForRestart() {
        clearHomePodDisplay()
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        frameRateTimer?.invalidate()
        frameRateTimer = nil
        keyStateObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyStateObservers.removeAll()
        NotificationCenter.default.removeObserver(self)
        touchIDMonitor?.stop()
        touchIDMonitor = nil
        captureView?.virtualMachine = nil
        captureView?.keySender = nil
        captureView?.control = nil
        captureView?.clipboardSync = nil
        windowController?.close()
        windowController = nil
        homePodDisplayView = nil
        VPhoneHostHotKeys.shared.resume()
    }

    // MARK: - Orientation

    private weak var displayContainer: VPhoneDisplayContainerView?
    private var panelSize: NSSize = .zero
    private var orientationPollInFlight = false

    /// Asks vphoned for the interface orientation once a second. Guests
    /// without `display.orientation` stay portrait. A read that overlaps a
    /// rotation the menu started is dropped: it may predate the turn.
    private func pollOrientation() {
        guard !orientationPollInFlight,
              let control, control.isConnected, !control.isChangingOrientation,
              control.guestCapabilities.contains("display_orientation")
        else { return }
        orientationPollInFlight = true
        Task {
            defer { orientationPollInFlight = false }
            guard let result = try? await control.call("display.orientation"),
                  !control.isChangingOrientation,
                  let degrees = (result["degrees"] as? NSNumber)?.intValue,
                  let orientation = VPhoneDisplayOrientation(degrees: degrees)
            else { return }
            control.interfaceOrientation = orientation
        }
    }

    /// Turns the VM view and gives the window the turned panel's aspect
    /// ratio, in one animation. A windowed VM reshapes around its center; a
    /// full-screen one keeps the screen and letterboxes the turned panel.
    private func applyOrientation(_ orientation: VPhoneDisplayOrientation, to window: NSWindow, force: Bool = false) {
        guard let container = displayContainer, force || container.orientation != orientation else { return }
        if !container.hasRoundedScreen {
            window.contentAspectRatio = orientation.displayedSize(panel: panelSize)
        }
        var frame: NSRect?
        if !window.styleMask.contains(.fullScreen) {
            let current = window.contentRect(forFrameRect: window.frame)
            var screenRect = current
            var visible = window.screen.map { window.contentRect(forFrameRect: $0.visibleFrame) } ?? .zero
            let gap = container.titlebarGap
            screenRect.size.height = max(1, screenRect.height - gap)
            visible.size.height = max(0, visible.height - gap)
            var target = orientation.contentRect(from: screenRect, panel: panelSize, within: visible)
            target.size.height += gap
            if target != current {
                frame = window.frameRect(forContentRect: target)
            }
        }
        container.turn(to: orientation, windowFrame: frame, animated: !force)
    }

    // MARK: - Mac Shortcuts

    /// The Mac's own shortcuts on keys the guest uses are off while this window
    /// is key; see `VPhoneHostHotKeys`.
    private func observeKeyState(of window: NSWindow) {
        let center = NotificationCenter.default
        keyStateObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.homePodGuest == false, self?.captureView?.hardwareKeyboardEnabled == true {
                    VPhoneHostHotKeys.shared.suspend()
                }
            }
        })
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            keyStateObservers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { VPhoneHostHotKeys.shared.resume() }
            })
        }
        if window.isKeyWindow, !homePodGuest, captureView?.hardwareKeyboardEnabled == true {
            VPhoneHostHotKeys.shared.suspend()
        }

        // A guest copy made while this window is key reaches the Mac when it
        // resigns key; see `VPhoneClipboardSync`.
        keyStateObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureView?.clipboardSync?.adoptGuestClipboard() }
        })
        keyStateObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureView?.clipboardSync?.bringGuestCopyToMac() }
        })
    }

    // MARK: - Title

    /// The title bar uses one gap everywhere: before the close button, between
    /// the window buttons (AppKit's is 9 pt), after the zoom button and after
    /// the Home button.
    private static let titlebarSpacing: CGFloat = 12

    private weak var buttonWindow: NSWindow?
    private var observedButtons = Set<ObjectIdentifier>()
    private let deviceWindowMask = CAShapeLayer()

    /// AppKit insets the close button 19 pt, puts the buttons back there
    /// whenever it lays out the title bar, and may replace them when the
    /// window is shown. They are placed again after each of those.
    private func pinWindowButtons(in window: NSWindow) {
        buttonWindow = window
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didUpdateNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowButtonMoved), name: name, object: window,
            )
        }
        placeWindowButtons()
    }

    @objc private func windowButtonMoved() {
        placeWindowButtons()
    }

    private func placeWindowButtons() {
        guard let window = buttonWindow else { return }
        updateTitlebarCorners(in: window)
        var x = Self.titlebarSpacing
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            if observedButtons.insert(ObjectIdentifier(button)).inserted {
                button.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowButtonMoved), name: NSView.frameDidChangeNotification,
                    object: button,
                )
            }
            if button.frame.minX != x {
                button.setFrameOrigin(NSPoint(x: x, y: button.frame.minY))
            }
            x = button.frame.maxX + Self.titlebarSpacing
        }
    }

    /// Clip the frame view as well as the titlebar's material and separator;
    /// rounding only the button container leaves the system background square.
    private func updateTitlebarCorners(in window: NSWindow) {
        guard displayContainer?.hasRoundedScreen == true,
              let content = window.contentView, let frame = content.superview
        else { return }
        frame.wantsLayer = true
        guard let layer = frame.layer else { return }
        if window.styleMask.contains(.fullScreen) {
            if layer.mask === deviceWindowMask { layer.mask = nil }
            return
        }
        let contentRect = content.convert(content.bounds, to: frame)
        let bounds = frame.bounds
        let titlebar = CGRect(x: bounds.minX, y: contentRect.maxY,
                              width: bounds.width, height: bounds.maxY - contentRect.maxY)
        guard titlebar.height > 0 else { return }
        let systemRadius: CGFloat
        if #available(macOS 26.0, *) { systemRadius = 26 } else { systemRadius = 10 }
        let radius = min(layer.cornerRadius > 0 ? layer.cornerRadius : systemRadius, titlebar.height / 2)
        let path = CGMutablePath()
        path.addRect(contentRect)
        path.addRoundedRect(in: titlebar, cornerWidth: radius, cornerHeight: radius)
        // Let AppKit retain the native upper corners, including its curve.
        path.addRect(CGRect(x: titlebar.minX, y: titlebar.midY,
                            width: titlebar.width, height: titlebar.height / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        deviceWindowMask.frame = bounds
        deviceWindowMask.path = path
        layer.mask = deviceWindowMask
        CATransaction.commit()
    }

    /// The window's own title would sit AppKit's wider gap after the buttons,
    /// so the name and subtitle are drawn here. `window.title` and
    /// `window.subtitle` are still set for the Window menu and accessibility.
    private func installTitle(_ name: String, in window: NSWindow, trailingInset: CGFloat) {
        guard let zoom = window.standardWindowButton(.zoomButton),
              let titlebar = zoom.superview,
              let frame = window.contentView?.superview
        else { return }
        window.titleVisibility = .hidden

        let title = NSTextField(labelWithString: name)
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .bold)
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.isHidden = true
        for label in [title, subtitle] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        subtitleLabel = subtitle

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: Self.titlebarSpacing),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: frame.trailingAnchor, constant: -trailingInset - Self.titlebarSpacing,
            ),
            stack.centerYAnchor.constraint(equalTo: zoom.centerYAnchor),
        ])
    }

    /// OS version and address from vphoned's health report, which picks
    /// the IPv4 address first and falls back to IPv6; hidden until it connects.
    private func updateSubtitle(control: VPhoneGuestControl) {
        guard let window = windowController?.window else { return }
        var parts: [String] = []
        if control.isConnected {
            if let version = control.guestIOSVersion, !version.isEmpty {
                let osName = homePodGuest ? "HomePod" : homeButtonHoldsInGuest ? "tvOS" : "iOS"
                parts.append("\(osName) \(version)")
            }
            if let address = control.guestIPAddress, !address.isEmpty {
                parts.append(address)
            }
        }
        if let frameRate {
            parts.append(VPhoneLocalization.format("%ld fps", frameRate))
        }
        let subtitle = parts.joined(separator: " - ")
        if window.subtitle != subtitle {
            window.subtitle = subtitle
            subtitleLabel?.stringValue = subtitle
            subtitleLabel?.isHidden = subtitle.isEmpty
        }
    }

    // MARK: - Frame Rate

    /// Shows the guest's frame rate in the subtitle, sampled once a second.
    func setFrameRateDisplay(_ enabled: Bool) {
        frameRateTimer?.invalidate()
        frameRateTimer = nil
        frameRate = nil
        if enabled, !homePodGuest, VPhoneFrameRateMeter.isAvailable {
            _ = VPhoneFrameRateMeter.takeFrameCount()
            frameRateSampledAt = CACurrentMediaTime()
            frameRate = 0
            frameRateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sampleFrameRate() }
            }
        }
        if let control {
            updateSubtitle(control: control)
        }
    }

    private func sampleFrameRate() {
        guard frameRate != nil, let control else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - frameRateSampledAt
        guard elapsed > 0 else { return }
        frameRate = Int((Double(VPhoneFrameRateMeter.takeFrameCount()) / elapsed).rounded())
        frameRateSampledAt = now
        updateSubtitle(control: control)
    }

    // MARK: - Home Button

    /// Resize a copy so the shared Device menu symbols keep their original size.
    private static func titlebarImage(_ image: NSImage?) -> NSImage? {
        guard let image = image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: image.size.width * 1.8, height: image.size.height * 1.8)
        return image
    }

    private static let homeImage = NSImage(
        systemSymbolName: "circle.circle",
        accessibilityDescription: VPhoneLocalization.text("Home"),
    ) ?? NSImage()

    /// `circle.circle` with a slash drawn across it; SF Symbols has no
    /// `circle.circle.slash`. The slash cuts a gap in the circles like the
    /// system's own slashed symbols.
    private static let homeSlashImage: NSImage = {
        let base = homeImage
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 1))
            slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 1))
            slash.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            slash.lineWidth = 4
            slash.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            slash.lineWidth = 1.5
            slash.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = base.accessibilityDescription
        return image
    }()

    private func makeHomeAccessory() -> NSTitlebarAccessoryViewController {
        let button = VPhoneHomeButton(image: Self.homeImage, target: self, action: #selector(homePressed))
        button.toolTip = VPhoneLocalization.text("Home Button")
        homeButton = button
        applyHomeButtonHold()
        deviceButtons = (0..<5).map { _ in NSButton(image: NSImage(), target: nil, action: nil) }
        let buttons = deviceButtons + [button]
        for control in buttons {
            if #available(macOS 26.0, *) {
                control.bezelStyle = .glass
                control.borderShape = .circle
            } else {
                control.bezelStyle = .toolbar
            }
            control.controlSize = .large
            control.imageScaling = .scaleNone
            control.translatesAutoresizingMaskIntoConstraints = false
            control.isEnabled = false
        }

        // A titlebar accessory takes its width from the view's frame, so the
        // container is sized explicitly; otherwise the button collapses to 0.
        // The accessory clips to that frame, and the glass bezel's shadow and
        // press highlight reach past the button's frame, so the leading edge
        // keeps room for them.
        let leadingInset: CGFloat = 6
        let trailingInset = Self.titlebarSpacing
        // Approximately 3 mm between button hit areas, independent of VM scale.
        let spacing: CGFloat = 3 * 72 / 25.4
        let side = button.fittingSize.height * 1.2
        let container = NSView()
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        for control in buttons {
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(equalToConstant: side),
                control.heightAnchor.constraint(equalToConstant: side),
            ])
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -trailingInset),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        container.frame.size = NSSize(
            width: leadingInset + side * CGFloat(buttons.count) + spacing * CGFloat(buttons.count - 1) + trailingInset,
            height: side,
        )

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    func connectDeviceButtons(to menu: VPhoneMenuController) {
        deviceMenuItems = menu.titlebarDeviceItems
        for (index, pair) in zip(deviceButtons, deviceMenuItems).enumerated() {
            let (button, item) = pair
            button.image = Self.titlebarImage(item.image)
            button.target = item.target
            button.action = item.action
            let label = index == 3 ? VPhoneLocalization.text("Lock") : item.title
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        updateHomeButton(connected: control?.isConnected == true)
    }

    /// The button presses Home through vphoned, so it is disabled and slashed
    /// while vphoned is not connected.
    private func updateHomeButton(connected: Bool) {
        for (button, item) in zip(deviceButtons, deviceMenuItems) {
            button.isEnabled = connected && item.isEnabled
        }
        guard let homeButton else { return }
        homeButton.isEnabled = connected
        homeButton.image = Self.titlebarImage(connected ? Self.homeImage : Self.homeSlashImage)
    }

    // MARK: - Actions

    @objc private func homePressed() {
        // A held button already sent its press and release.
        guard !homeButtonHoldsInGuest else { return }
        control?.sendHIDPress(page: 0x0C, usage: 0x40)
    }

    private func applyHomeButtonHold() {
        (homeButton as? VPhoneHomeButton)?.onHold = homeButtonHoldsInGuest
            ? { [weak self] down in
                if down {
                    self?.control?.sendHIDDown(page: 0x0C, usage: 0x40)
                } else {
                    self?.control?.sendHIDUp(page: 0x0C, usage: 0x40)
                }
            }
            : nil
    }
}

// MARK: - Home Button

/// Reports the press and the release around AppKit's tracking loop, which
/// returns only when the mouse is released, inside the button or not.
private final class VPhoneHomeButton: NSButton {
    var onHold: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let onHold else {
            super.mouseDown(with: event)
            return
        }
        onHold(true)
        super.mouseDown(with: event)
        onHold(false)
    }
}
