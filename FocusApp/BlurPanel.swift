import AppKit

@MainActor
final class BlurPanel: NSPanel {
    private let backdrop = BackdropFilters.make()
    private lazy var fallback = NSVisualEffectView()
    private let texture = GrainView()
    private let focusMask = CAShapeLayer()
    private var previousBackground: [BackgroundWindow] = []
    private var previousMaskBounds = CGRect.null
    private var maskIsEmpty = false
    private var fadeTimer: Timer?
    private var fade: Fade?
    private var onDismiss: (() -> Void)?

    private struct Fade {
        let start: CGFloat
        let target: CGFloat
        var startedAt: TimeInterval?
        var duration: TimeInterval { 0.22 * abs(target - start) }
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
        for view in [effectView, texture] {
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
        backdrop?.apply(blur: effect.blur)
        if backdrop == nil {
            fallback.alphaValue = min(effect.blur * 3.12, 1)
            fallback.isHidden = effect.blur <= 0
        }
        texture.isHidden = effect.grain <= 0
        texture.intensity = Float(effect.grain)
        CATransaction.commit()
    }

    func updateMask(_ windows: [BackgroundWindow]) {
        guard let contentView else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        guard windows != previousBackground || bounds != previousMaskBounds else { return }
        previousBackground = windows
        previousMaskBounds = bounds

        let path = BackgroundWindow.effectMask(for: windows, in: bounds)
        maskIsEmpty = path?.isEmpty == true
        guard !maskIsEmpty else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let path {
            focusMask.frame = bounds
            focusMask.path = path
            contentView.layer?.mask = focusMask
        } else {
            contentView.layer?.mask = nil
        }
        CATransaction.commit()
    }

    func present(_ mode: NSWindow.OrderingMode, relativeTo windowNumber: Int, needsPlacement: Bool) {
        // Fully protected displays have no pixels for the compositor to blur.
        if maskIsEmpty {
            if isVisible { hideImmediately() }
            return
        }
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

    func dismiss(completion: @escaping () -> Void) {
        guard isVisible else {
            completion()
            return
        }
        if fade?.target != 0 { startFade(to: 0) }
        if fade == nil { completion() } else { onDismiss = completion }
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
        onDismiss = nil
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
            let completion = onDismiss
            stopFade()
            if fade.target == 0 {
                orderOut(nil)
                completion?()
            }
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
    private let filterType: NSObject.Type
    private var lastBlur: Double?

    private init(layer: CALayer, filterType: NSObject.Type) {
        self.layer = layer
        self.filterType = filterType
    }

    static func make() -> BackdropFilters? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              filter("gaussianBlur", key: "inputRadius", type: filterType) != nil else { return nil }

        let layer = backdropType.init()
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        return BackdropFilters(layer: layer, filterType: filterType)
    }

    func apply(blur radius: Double) {
        guard radius != lastBlur else { return }
        lastBlur = radius

        // Replace the filter so Core Animation submits the new radius to the compositor.
        guard radius > 0, let filter = Self.filter("gaussianBlur", key: "inputRadius", type: filterType) else {
            layer.isHidden = true
            layer.filters = nil
            return
        }

        filter.setValue(radius * 48, forKey: "inputRadius")
        // Preserve the backdrop's coverage at window edges as the radius increases.
        let normalization = "inputNormalizeEdges"
        if let keys = filter.value(forKey: "inputKeys") as? [String], keys.contains(normalization) {
            filter.setValue(true, forKey: normalization)
        }
        layer.filters = [filter]
        layer.isHidden = false
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
    private var renderer: NSView?

    var intensity: Float = 0 {
        didSet {
            if oldValue == 0 { updateRenderer() }
            renderer?.layer?.opacity = intensity
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderer()
    }

    private func updateRenderer() {
        guard intensity > 0, let window else { return }
        let usesTiles = window.backingScaleFactor == 2 && GrainTexture.repeatedImage != nil
        if let renderer, (renderer is TiledGrainView) == usesTiles { return }

        renderer?.removeFromSuperview()
        let view: NSView = usesTiles ? TiledGrainView(frame: bounds) : PatternGrainView(frame: bounds)
        view.wantsLayer = true
        view.layer?.opacity = intensity
        view.autoresizingMask = [.width, .height]
        renderer = view
        addSubview(view)
    }
}

@MainActor
private final class PatternGrainView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let pattern = GrainTexture.pattern else { return }
        pattern.setFill()
        dirtyRect.fill()
    }
}

@MainActor
private final class TiledGrainView: NSView {
    private static let tileLength = CGFloat(GrainTexture.tilePixels * GrainTexture.repetitions) / 2
    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rows.masksToBounds = true
        // The copies do not overlap, so each can blend at the requested opacity.
        rows.allowsGroupOpacity = false
        columns.allowsGroupOpacity = false
        rows.addSublayer(columns)
        layer = rows
        wantsLayer = true

        let tile = CALayer()
        tile.contents = GrainTexture.repeatedImage
        tile.contentsScale = 2
        let length = Self.tileLength
        tile.frame = CGRect(x: 0, y: 0, width: length, height: length)
        columns.addSublayer(tile)
        columns.instanceTransform = CATransform3DMakeTranslation(length, 0, 0)
        rows.instanceTransform = CATransform3DMakeTranslation(0, length, 0)
        updateTiles()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTiles()
    }

    private func updateTiles() {
        let length = Self.tileLength
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rows.frame = frame
        columns.frame = CGRect(x: 0, y: 0, width: bounds.width, height: length)
        columns.instanceCount = max(1, Int(ceil(bounds.width / length)))
        rows.instanceCount = max(1, Int(ceil(bounds.height / length)))
        CATransaction.commit()
    }
}

@MainActor
private enum GrainTexture {
    static let tilePixels = 128
    static let repetitions = 4

    private static let bitmap = makeBitmap()
    static let pattern: NSColor? = {
        guard let bitmap else { return nil }
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return NSColor(patternImage: image)
    }()

    // Repeat the unchanged pattern inside a larger image to reduce the number of copies.
    static let repeatedImage: CGImage? = {
        guard let bitmap, let pixels = bitmap.bitmapData else { return nil }
        let size = tilePixels
        let side = size * repetitions
        guard let repeated = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        ), let output = repeated.bitmapData else { return nil }
        let tileRowBytes = size * 4
        for row in 0..<side {
            let source = pixels.advanced(by: (row % size) * tileRowBytes)
            for column in 0..<repetitions {
                output.advanced(by: row * repeated.bytesPerRow + column * tileRowBytes)
                    .update(from: source, count: tileRowBytes)
            }
        }
        return repeated.cgImage
    }()

    private static func makeBitmap() -> NSBitmapImageRep? {
        // A reusable transparent tile, generated independently of the backdrop.
        let size = tilePixels
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32
        ), let pixels = bitmap.bitmapData else { return nil }
        var random = SystemRandomNumberGenerator()
        for index in 0..<(size * size) {
            let sample = UInt8.random(in: 0..<68, using: &random)
            let alpha = sample / 2
            let shade = sample.isMultiple(of: 2) ? alpha : 0
            let offset = index * 4
            pixels[offset] = shade
            pixels[offset + 1] = shade
            pixels[offset + 2] = shade
            pixels[offset + 3] = alpha
        }
        bitmap.size = NSSize(width: size / 2, height: size / 2)
        return bitmap
    }
}
