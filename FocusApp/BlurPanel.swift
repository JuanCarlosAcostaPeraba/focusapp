import AppKit

@MainActor
final class BlurPanel: NSPanel {
    private let backdrop = BackdropFilters.make()
    private let fallback = NSVisualEffectView()
    private let texture = GrainView()
    private let tint = CALayer()
    private let focusMask = CAShapeLayer()
    private var previousBackground: [BackgroundWindow] = []
    private var previousMaskBounds = CGRect.null
    private var fadeTimer: Timer?
    private var fade: Fade?

    private struct Fade {
        let start: CGFloat
        let target: CGFloat
        var startedAt: TimeInterval?
        var duration: TimeInterval { 0.22 * abs(target - start) }
    }

    static var supportsMonochrome: Bool {
        BackdropFilters.make()?.supportsSaturation == true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(effect: EffectSettings) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
        title = "FocusApp"

        let container = NSView()
        container.wantsLayer = true
        let effectView: NSView
        if let backdrop {
            let view = NSView()
            view.layer = backdrop.layer
            view.wantsLayer = true
            effectView = view
        } else {
            fallback.blendingMode = .behindWindow
            fallback.material = .underWindowBackground
            fallback.state = .active
            effectView = fallback
        }

        texture.wantsLayer = true
        let tintView = NSView()
        tintView.layer = tint
        tintView.wantsLayer = true
        for view in [effectView, texture, tintView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        contentView = container
        apply(effect)
    }

    func apply(_ effect: EffectSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.apply(effect)
        fallback.alphaValue = min(effect.blur * 3.12, 1)
        texture.layer?.opacity = Float(effect.grain)
        tint.backgroundColor = effect.tintColor.withAlphaComponent(effect.dimming).cgColor
        CATransaction.commit()
    }

    func updateMask(_ windows: [BackgroundWindow]) {
        guard let contentView else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        guard windows != previousBackground || bounds != previousMaskBounds else { return }
        previousBackground = windows
        previousMaskBounds = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let path = BackgroundWindow.effectMask(for: windows, in: bounds) {
            focusMask.frame = bounds
            focusMask.path = path
            contentView.layer?.mask = focusMask
        } else {
            contentView.layer?.mask = nil
        }
        CATransaction.commit()
    }

    func prepare(for frame: CGRect) {
        alphaValue = 0
        setFrame(frame, display: false)
        contentView?.layoutSubtreeIfNeeded()
        display()
    }

    func present(_ mode: NSWindow.OrderingMode, relativeTo windowNumber: Int, needsPlacement: Bool) {
        let wasVisible = isVisible
        if !wasVisible {
            alphaValue = 0
        }
        if !wasVisible || needsPlacement {
            order(mode, relativeTo: windowNumber)
        }
        if !wasVisible || fade?.target == 0 {
            startFade(to: 1)
        }
    }

    func dismiss() {
        if isVisible && fade?.target != 0 {
            startFade(to: 0)
        }
    }

    func hideImmediately() {
        stopFade()
        alphaValue = 0
        orderOut(nil)
    }

    private func stopFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        fade = nil
    }

    private func startFade(to target: CGFloat) {
        stopFade()
        let start = alphaValue
        if start == target || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = target
            if target == 0 { orderOut(nil) }
            return
        }

        fade = Fade(start: start, target: target)
        let timer = Timer(
            timeInterval: 1.0 / 60, target: self, selector: #selector(advanceFade(_:)),
            userInfo: nil, repeats: true
        )
        // Status menus and mouse tracking can run outside the default run loop mode.
        timer.fireDate = .now
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceFade(_ timer: Timer) {
        guard let fade else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // The first callback can be delayed while the backdrop is ordered and rendered.
        let startedAt = fade.startedAt ?? now
        if fade.startedAt == nil { self.fade?.startedAt = startedAt }
        let progress = min((now - startedAt) / fade.duration, 1)
        let eased = progress * progress * (3 - 2 * progress)
        alphaValue = fade.start + (fade.target - fade.start) * eased
        if progress == 1 {
            stopFade()
            if fade.target == 0 { orderOut(nil) }
        }
    }
}

struct BackgroundWindow: Equatable {
    let bounds: CGRect
    let keepsFocus: Bool

    // Windows are front to back. Clear only the visible area of protected windows.
    static func effectMask(for windows: [Self], in bounds: CGRect) -> CGPath? {
        let coveringWindows = CGMutablePath()
        let openings = CGMutablePath()
        for window in windows {
            if window.keepsFocus {
                let shape = CGPath(rect: window.bounds, transform: nil)
                openings.addPath(coveringWindows.isEmpty ? shape : shape.subtracting(coveringWindows))
            } else {
                coveringWindows.addRect(window.bounds)
            }
        }
        guard !openings.isEmpty else { return nil }
        return CGPath(rect: bounds, transform: nil).subtracting(openings)
    }
}

@MainActor
private final class BackdropFilters {
    let layer: CALayer
    let supportsSaturation: Bool
    private let filterType: NSObject.Type
    private var lastBlur: Double?
    private var lastMonochrome: Double?

    private init(layer: CALayer, filterType: NSObject.Type, supportsSaturation: Bool) {
        self.layer = layer
        self.filterType = filterType
        self.supportsSaturation = supportsSaturation
    }

    static func make() -> BackdropFilters? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              filter("gaussianBlur", key: "inputRadius", type: filterType) != nil else { return nil }

        let layer = backdropType.init()
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        return BackdropFilters(
            layer: layer, filterType: filterType,
            supportsSaturation: filter("colorSaturate", key: "inputAmount", type: filterType) != nil
        )
    }

    func apply(_ effect: EffectSettings) {
        guard effect.blur != lastBlur || effect.monochrome != lastMonochrome else { return }
        lastBlur = effect.blur
        lastMonochrome = effect.monochrome

        // Replace the filters so Core Animation submits the new values to the compositor.
        var filters: [NSObject] = []
        if effect.blur > 0, let blur = Self.filter("gaussianBlur", key: "inputRadius", type: filterType) {
            blur.setValue(effect.blur * 48, forKey: "inputRadius")
            filters.append(blur)
        }
        if supportsSaturation, effect.monochrome > 0,
           let saturation = Self.filter("colorSaturate", key: "inputAmount", type: filterType) {
            saturation.setValue(1 - effect.monochrome, forKey: "inputAmount")
            filters.append(saturation)
        }
        layer.isHidden = filters.isEmpty
        layer.opacity = effect.blur > 0 ? Float(max(0.78, effect.monochrome)) : 1
        layer.filters = filters
    }

    private static func filter(_ name: String, key: String, type: NSObject.Type) -> NSObject? {
        let factory = NSSelectorFromString("filterWithType:")
        guard type.responds(to: factory),
              let value = type.perform(factory, with: name)?.takeUnretainedValue() as? NSObject,
              value.responds(to: NSSelectorFromString("inputKeys")),
              let keys = value.value(forKey: "inputKeys") as? [String],
              keys.contains(key) else { return nil }
        return value
    }
}

@MainActor
private final class GrainView: NSView {
    private static let grain = makeGrain()

    override func draw(_ dirtyRect: NSRect) {
        guard let grain = Self.grain else { return }
        grain.setFill()
        dirtyRect.fill()
    }

    private static func makeGrain() -> NSColor? {
        // A reusable transparent tile, generated independently of the backdrop.
        let size = 128
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        ), let pixels = bitmap.bitmapData else { return nil }
        for index in 0..<(size * size) {
            let alpha = UInt8.random(in: 0...33)
            let shade = Bool.random() ? alpha : 0
            let offset = index * 4
            pixels[offset] = shade
            pixels[offset + 1] = shade
            pixels[offset + 2] = shade
            pixels[offset + 3] = alpha
        }
        bitmap.size = NSSize(width: size / 2, height: size / 2)
        let tile = NSImage(size: bitmap.size)
        tile.addRepresentation(bitmap)
        return NSColor(patternImage: tile)
    }
}
