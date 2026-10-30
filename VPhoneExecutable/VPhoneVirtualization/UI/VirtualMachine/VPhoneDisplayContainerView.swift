import AppKit
import QuartzCore
import VPhoneCoreKit

// MARK: - Display Container

/// The window's content view. It holds the VM view turned to the guest's
/// interface orientation, at the panel's aspect ratio, as large as fits.
///
/// The VM view keeps its portrait bounds under the turn, so touch mapping,
/// which converts window points into those bounds, needs no change: AppKit's
/// conversion undoes the rotation.
final class VPhoneDisplayContainerView: NSView {
    let displayView: NSView
    var isPhoneGuest = false {
        didSet { needsLayout = true }
    }
    var isPadGuest = false {
        didSet { needsLayout = true }
    }
    var isDuoGuest = false {
        didSet { needsLayout = true }
    }
    var isDuoInnerDisplay = false {
        didSet { needsLayout = true }
    }
    var isDuoCoverDisplay = true {
        didSet { needsLayout = true }
    }
    var hasRoundedScreen: Bool { isPhoneGuest || isPadGuest }
    private let phoneOverlay = CAShapeLayer()
    private let screenMask = CAShapeLayer()
    /// Approximately 3 mm in AppKit points, independent of the guest's scale.
    var titlebarGap: CGFloat { hasRoundedScreen ? 3 * 72 / 25.4 : 0 }
    private let viewportView = NSView()
    var backingPanelSize: NSSize = .zero { didSet { needsLayout = true } }
    /// The guest panel's size in points, portrait.
    var panelSize: NSSize = .zero {
        didSet { needsLayout = true }
    }

    private(set) var orientation: VPhoneDisplayOrientation = .portrait
    /// The drawn turn, counterclockwise in degrees. It differs from
    /// `orientation.viewRotation` only during a turn, and may leave 0...360.
    private var angle: CGFloat = 0
    private var turn: Turn?
    private var displayLink: CADisplayLink?

    private static let turnDuration: CFTimeInterval = 0.35

    /// Black over the panel, above the VM view's layer rather than in its
    /// place, so clicks still reach the VM view (a tap wakes the guest).
    private let darkLayer = CALayer()

    /// Covers the panel while the guest's screen is off: coming on, the
    /// guest's display shows its last frame from before until it draws again,
    /// which after a fold made asleep was the other panel's picture.
    var isScreenDark = false {
        didSet {
            guard isScreenDark != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            darkLayer.opacity = isScreenDark ? 1 : 0
            CATransaction.commit()
        }
    }

    /// One animated turn: the panel's angle and the window frame move
    /// together, so the window reshapes as the panel turns.
    private struct Turn {
        let fromAngle: CGFloat
        let toAngle: CGFloat
        let fromFrame: NSRect?
        let toFrame: NSRect?
        let start: CFTimeInterval
    }

    init(displayView: NSView) {
        self.displayView = displayView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayView.autoresizingMask = []
        viewportView.wantsLayer = true
        viewportView.layer?.masksToBounds = true
        addSubview(viewportView)
        viewportView.addSubview(displayView)
        darkLayer.backgroundColor = NSColor.black.cgColor
        darkLayer.opacity = 0
        darkLayer.zPosition = 1000
        viewportView.layer?.addSublayer(darkLayer)
        installFoldChrome()
        displayView.wantsLayer = true
        phoneOverlay.fillColor = NSColor.black.cgColor
        phoneOverlay.zPosition = 1
        displayView.layer?.addSublayer(phoneOverlay)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Turning

    /// Turns to `orientation`, moving the window to `windowFrame` alongside.
    /// A turn already running continues from where it is drawn.
    func turn(to orientation: VPhoneDisplayOrientation, windowFrame: NSRect?, animated: Bool) {
        self.orientation = orientation
        let target = VPhoneDisplayOrientation.turnTarget(from: angle, to: orientation.viewRotation)
        guard animated, window?.isVisible == true else {
            finishTurn(angle: target, windowFrame: windowFrame)
            return
        }
        turn = Turn(
            fromAngle: angle,
            toAngle: target,
            fromFrame: windowFrame == nil ? nil : window?.frame,
            toFrame: windowFrame,
            start: CACurrentMediaTime(),
        )
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let turning = stepTurn(now: now)
        let folding = stepFold(now: now)
        guard turning || folding else {
            stopDisplayLink()
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Advances the running turn; returns whether one is still running.
    private func stepTurn(now: CFTimeInterval) -> Bool {
        guard let turn else { return false }
        let progress = (now - turn.start) / Self.turnDuration
        guard progress < 1 else {
            self.turn = nil
            finishTurn(angle: turn.toAngle, windowFrame: turn.toFrame)
            return false
        }
        let eased = CGFloat(VPhoneDisplayOrientation.easedProgress(progress))
        angle = turn.fromAngle + (turn.toAngle - turn.fromAngle) * eased
        if let from = turn.fromFrame, let to = turn.toFrame, let window {
            window.setFrame(Self.interpolate(from, to, eased), display: false)
        }
        return true
    }

    private func finishTurn(angle target: CGFloat, windowFrame: NSRect?) {
        angle = target.truncatingRemainder(dividingBy: 360)
        if angle < 0 {
            angle += 360
        }
        if let windowFrame, let window {
            window.setFrame(windowFrame, display: true)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private static func interpolate(_ from: NSRect, _ to: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(
            x: (from.minX + (to.minX - from.minX) * t).rounded(),
            y: (from.minY + (to.minY - from.minY) * t).rounded(),
            width: (from.width + (to.width - from.width) * t).rounded(),
            height: (from.height + (to.height - from.height) * t).rounded(),
        )
    }

    // MARK: - Folding

    /// The fold chrome a foldable guest drives through `display.posture`:
    /// the spine swallowing the screen. The guest's pixels are never scaled
    /// — a single-display guest has no second layout to switch to, and a
    /// host-side squeeze would read as a squashed wallpaper, not a fold.
    /// Instead an opaque spine band grows from the center by exactly the
    /// width a hinge at angle θ would hide from the viewer,
    /// 1 − cos((180−θ)/2): 180° leaves the panel untouched, 100° covers the
    /// middle ~23% (each visible half keeps its native scale, like a book's
    /// angled pages), and 0° closes the band over everything. Touches keep
    /// mapping through the band to the untouched panel underneath.
    private var foldAngle: CGFloat = 180
    private var fold: Fold?
    private let creaseLayer = CAGradientLayer()
    private static let foldDurationFallback: CFTimeInterval = 1.2

    private struct Fold {
        let fromAngle: CGFloat
        let toAngle: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }

    private func installFoldChrome() {
        creaseLayer.frame = .zero
        creaseLayer.startPoint = CGPoint(x: 0, y: 0.5)
        creaseLayer.endPoint = CGPoint(x: 1, y: 0.5)
        // Soft shoulders into an opaque core, so the band reads as a fold
        // shadow rather than a rectangle.
        creaseLayer.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.97).cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.97).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]
        creaseLayer.locations = [0, 0.3, 0.5, 0.7, 1]
        creaseLayer.opacity = 0
        layer?.addSublayer(creaseLayer)
    }

    /// The fraction of the panel's width a hinge at `angle` hides from the
    /// viewer: one minus the cosine of each half's tilt.
    private static func hiddenFraction(for angle: CGFloat) -> CGFloat {
        let tilt = (180 - angle) * .pi / 180 / 2
        return 1 - max(cos(tilt), 0)
    }

    /// Folds the chrome to `angle` (0 closed … 180 open) over `duration`
    /// seconds, in step with the guest's own sweep.
    func setFold(angle: Double, duration: Double) {
        let target = CGFloat(min(max(angle, 0), 180))
        let seconds = duration > 0 ? duration : Self.foldDurationFallback
        guard window?.isVisible == true, seconds >= 0.15 else {
            foldAngle = target
            fold = nil
            applyFold()
            return
        }
        fold = Fold(
            fromAngle: foldAngle,
            toAngle: target,
            start: CACurrentMediaTime(),
            duration: seconds,
        )
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Draws the current `foldAngle`: grow or shrink the spine band. The
    /// panel itself is never transformed.
    private func applyFold() {
        creaseLayer.opacity = foldAngle < 179.5 ? 1 : 0
        needsLayout = true
    }

    private func stepFold(now: CFTimeInterval) -> Bool {
        guard let fold else { return false }
        let progress = min(max((now - fold.start) / fold.duration, 0), 1)
        let eased = CGFloat(VPhoneDisplayOrientation.easedProgress(progress))
        foldAngle = fold.fromAngle + (fold.toAngle - fold.fromAngle) * eased
        applyFold()
        if progress >= 1 {
            self.fold = nil
            return false
        }
        return true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        var screenBounds = bounds
        screenBounds.size.height = max(0, screenBounds.height - titlebarGap)
        if isFlipped { screenBounds.origin.y += titlebarGap }
        let size = panelSize.width > 0
            ? VPhoneDisplayOrientation.fittedSize(panel: panelSize, angle: angle, in: screenBounds.size)
            : screenBounds.size
        // Sized unturned, then turned about its center.
        viewportView.frameCenterRotation = 0
        viewportView.frame = NSRect(
            x: screenBounds.midX - size.width / 2,
            y: screenBounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        let backing = backingPanelSize.width > 0 ? backingPanelSize : panelSize
        let scale = panelSize.width > 0 ? size.width / panelSize.width : 1
        let full = NSSize(width: backing.width * scale, height: backing.height * scale)
        displayView.frameCenterRotation = 0
        displayView.frame = NSRect(x: 0, y: size.height - full.height, width: full.width, height: full.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        darkLayer.frame = viewportView.bounds
        CATransaction.commit()
        viewportView.frameCenterRotation = angle
        if let vmView = displayView as? VPhoneVirtualMachineView {
            vmView.enclosingDisplayRotation = angle
            vmView.activePanelPixels = NSSize(width: panelSize.width * vmView.screenScale,
                                               height: panelSize.height * vmView.screenScale)
        }
        // The spine band hides the folded fraction of the panel and turns
        // with it: laid out in the panel's unturned space, then rotated
        // about the shared center, exactly as the panel is.
        let hidden = Self.hiddenFraction(for: foldAngle)
        let bandWidth = viewportView.frame.width * hidden
        // Animate the frame along the angle steps; keep a hairline floor so
        // the band never flickers between zero-width and the soft shoulder.
        creaseLayer.frame = NSRect(
            x: viewportView.frame.midX - max(bandWidth, 1) / 2,
            y: viewportView.frame.minY,
            width: max(bandWidth, 1),
            height: viewportView.frame.height,
        )
        creaseLayer.transform = CATransform3DMakeRotation(angle * .pi / 180, 0, 0, 1)
        updatePhoneOverlay()
    }

    /// Draw in the unturned panel's coordinates so the hardware silhouette
    /// follows the display through resizing, full screen and orientation changes.
    private func updatePhoneOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        phoneOverlay.isHidden = !isPhoneGuest || isDuoGuest
        updateScreenMask()
        guard isPhoneGuest, !isDuoGuest else { return }
        let rect = displayView.bounds
        guard rect.width > 0, rect.height > 0 else { return }
        phoneOverlay.frame = rect
        let local = CGRect(origin: .zero, size: rect.size)
        let path = CGMutablePath()
        // Proportions of the reference iPhone screen; scale with the panel,
        // rather than with the Mac's backing scale or titlebar height.
        let width = local.width * 0.214
        let height = local.width * 0.08
        let inset = local.width * 0.034
        let island = CGRect(
            x: (local.width - width) / 2,
            y: displayView.isFlipped ? inset : local.height - inset - height,
            width: width,
            height: height,
        )
        path.addRoundedRect(in: island, cornerWidth: height / 2, cornerHeight: height / 2)
        phoneOverlay.path = path
    }

    /// Clip the entire panel, including its hosted VM sublayers, in the
    /// container's coordinates. Converting the unturned rounded path keeps all
    /// four physical corners aligned during rotation and window resizing.
    /// A clear window behind it makes the removed corners transparent.
    private func updateScreenMask() {
        layer?.backgroundColor = (hasRoundedScreen ? NSColor.clear : NSColor.black).cgColor
        guard hasRoundedScreen else {
            layer?.mask = nil
            return
        }
        let rect = viewportView.bounds
        guard rect.width > 0, rect.height > 0 else {
            layer?.mask = nil
            return
        }
        // iPad panels have much tighter physical corners than iPhone panels.
        // Use a proportional approximation so the outline scales with the VM.
        let radius: CGFloat
        if isDuoInnerDisplay || (isDuoGuest && !isDuoCoverDisplay),
           panelSize.width > 0, panelSize.height > 0 {
            // display1's native corner is 55 guest points (165 pixels at 3x).
            // panelSize comes from the final scanout / guest scale: fixed-inner
            // currently renders 2007 x 2853, or 669 x 951 points. Scaling from
            // the old 626-point donor width instead would enlarge the corner.
            // Both sizes are unturned, so one uniform scale works in all poses.
            let scale = min(rect.width / panelSize.width, rect.height / panelSize.height)
            radius = min(55 * scale, min(rect.width, rect.height) / 2)
        } else {
            radius = min(rect.width, rect.height) * (isPadGuest ? 0.035 : 0.12)
        }
        let origin = viewportView.convert(rect.origin, to: self)
        let xAxis = viewportView.convert(NSPoint(x: rect.minX + 1, y: rect.minY), to: self)
        let yAxis = viewportView.convert(NSPoint(x: rect.minX, y: rect.minY + 1), to: self)
        var transform = CGAffineTransform(
            a: xAxis.x - origin.x, b: xAxis.y - origin.y,
            c: yAxis.x - origin.x, d: yAxis.y - origin.y,
            tx: origin.x, ty: origin.y,
        )
        let panel: CGPath
        if isDuoGuest && isDuoCoverDisplay {
            // The outer panel meets the hinge on its physical left edge.
            // Build the silhouette in panel coordinates so the straight edge
            // follows that edge when the guest rotates.
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            panel = path
        } else {
            panel = CGPath(
                roundedRect: CGRect(origin: .zero, size: rect.size),
                cornerWidth: radius, cornerHeight: radius, transform: nil,
            )
        }
        screenMask.frame = bounds
        screenMask.path = panel.copy(using: &transform)
        layer?.mask = screenMask
    }
}
