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
    var hasRoundedScreen: Bool { isPhoneGuest || isPadGuest }
    private let phoneOverlay = CAShapeLayer()
    private let screenMask = CAShapeLayer()
    /// Approximately 3 mm in AppKit points, independent of the guest's scale.
    var titlebarGap: CGFloat { hasRoundedScreen ? 3 * 72 / 25.4 : 0 }
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
        addSubview(displayView)
        // A layer adds no hit-test target: guest input keeps its existing mapping.
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
        guard let turn else {
            stopDisplayLink()
            return
        }
        let progress = (link.targetTimestamp - turn.start) / Self.turnDuration
        guard progress < 1 else {
            self.turn = nil
            stopDisplayLink()
            finishTurn(angle: turn.toAngle, windowFrame: turn.toFrame)
            return
        }
        let eased = CGFloat(VPhoneDisplayOrientation.easedProgress(progress))
        angle = turn.fromAngle + (turn.toAngle - turn.fromAngle) * eased
        if let from = turn.fromFrame, let to = turn.toFrame, let window {
            window.setFrame(Self.interpolate(from, to, eased), display: false)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
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
        displayView.frameCenterRotation = 0
        displayView.frame = NSRect(
            x: screenBounds.midX - size.width / 2,
            y: screenBounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
        displayView.frameCenterRotation = angle
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
        let rect = displayView.bounds
        guard rect.width > 0, rect.height > 0 else {
            layer?.mask = nil
            return
        }
        // iPad panels have much tighter physical corners than iPhone panels.
        // Use a proportional approximation so the outline scales with the VM.
        // Duo's display1 has a 55-point corner radius on a 626 x 890 panel.
        // Keep the physical radius/panel ratio when using a larger render mode
        // and when the user resizes or rotates the window.
        let radius = isDuoInnerDisplay
            ? min(rect.width, rect.height) * (55.0 / 626.0)
            : min(rect.width, rect.height) * (isPadGuest ? 0.035 : 0.12)
        let origin = displayView.convert(rect.origin, to: self)
        let xAxis = displayView.convert(NSPoint(x: rect.minX + 1, y: rect.minY), to: self)
        let yAxis = displayView.convert(NSPoint(x: rect.minX, y: rect.minY + 1), to: self)
        var transform = CGAffineTransform(
            a: xAxis.x - origin.x, b: xAxis.y - origin.y,
            c: yAxis.x - origin.x, d: yAxis.y - origin.y,
            tx: origin.x, ty: origin.y,
        )
        let panel: CGPath
        if isDuoGuest && !isDuoInnerDisplay {
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
