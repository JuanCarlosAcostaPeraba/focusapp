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

    static var supportsMonochrome: Bool {
        BackdropFilters.make()?.saturation != nil
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
        texture.alphaValue = effect.grain
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

    func place(_ mode: NSWindow.OrderingMode, relativeTo windowNumber: Int) {
        // Keep the material steady while the panel moves between windows.
        let fadeIn = !isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fadeIn {
            alphaValue = 0
        }
        order(mode, relativeTo: windowNumber)
        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
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
private struct BackdropFilters {
    let layer: CALayer
    let blur: NSObject
    let saturation: NSObject?

    static func make() -> Self? {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
              let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              let blur = filter("gaussianBlur", key: "inputRadius", type: filterType) else { return nil }

        let layer = backdropType.init()
        guard layer.responds(to: NSSelectorFromString("setWindowServerAware:")) else { return nil }
        layer.setValue(true, forKey: "windowServerAware")
        return Self(layer: layer, blur: blur, saturation: filter(
            "colorSaturate", key: "inputAmount", type: filterType
        ))
    }

    func apply(_ effect: EffectSettings) {
        var filters: [NSObject] = []
        if effect.blur > 0 {
            blur.setValue(effect.blur * 48, forKey: "inputRadius")
            filters.append(blur)
        }
        if let saturation, effect.monochrome > 0 {
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
