import AppKit
import Carbon
import Combine

private struct ToggleShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let label = Self.label(for: event) else { return nil }
        var bits: UInt32 = 0
        for (flag, mask) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                             (.shift, shiftKey), (.command, cmdKey)] where flags.contains(flag) {
            bits |= UInt32(mask)
        }
        keyCode = UInt32(event.keyCode)
        modifiers = bits
        keyLabel = label
    }

    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }
            .map(\.1).joined() + keyLabel
    }

    private static func label(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Espacio"
        case kVK_Tab: return "Tab"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        default: break
        }

        guard let text = event.characters(byApplyingModifiers: []),
              let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 else { return nil }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSF1FunctionKey...NSF35FunctionKey: return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default: return CharacterSet.controlCharacters.contains(scalar) ? nil : text.uppercased()
        }
    }
}

@MainActor
final class ActivationControls: NSObject, ObservableObject {
    private static let shortcutKey = "toggleShortcut"
    private static let shakeEnabledKey = "shakeToToggle"
    private static let shakeSensitivityKey = "shakeSensitivity"
    private static let identifier = EventHotKeyID(signature: 0x464F4353, id: 1) // FOCS

    private let defaults: UserDefaults
    private var onToggle: (() -> Void)?
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var hotKeyIsDown = false
    private var keyMonitor: Any?
    private var globalShakeMonitor: Any?
    private var localShakeMonitor: Any?
    private var shake = CursorShake()
    private var lastShakeSample = -Double.infinity

    @Published private var shortcut: ToggleShortcut?
    @Published private(set) var isRecording = false
    @Published private(set) var shortcutError: String?
    @Published var shakeEnabled: Bool {
        didSet {
            defaults.set(shakeEnabled, forKey: Self.shakeEnabledKey)
            updateShakeMonitors()
        }
    }
    @Published var shakeSensitivity: ShakeSensitivity {
        didSet {
            defaults.set(shakeSensitivity.rawValue, forKey: Self.shakeSensitivityKey)
            resetShake()
        }
    }

    var shortcutTitle: String { shortcut?.title ?? "Sin asignar" }
    var hasShortcut: Bool { shortcut != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: Self.shortcutKey).flatMap {
            try? JSONDecoder().decode(ToggleShortcut.self, from: $0)
        }
        shakeEnabled = defaults.bool(forKey: Self.shakeEnabledKey)
        shakeSensitivity = defaults.string(forKey: Self.shakeSensitivityKey)
            .flatMap(ShakeSensitivity.init(rawValue:)) ?? .medium
        super.init()
    }

    func start(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        registerSavedShortcut()
        updateShakeMonitors()
    }

    func stop() {
        onToggle = nil
        endRecording()
        unregisterShortcut()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        updateShakeMonitors()
    }

    func beginRecording() {
        guard !isRecording else { return }
        shortcutError = nil
        unregisterShortcut()
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.record(event)
            }
            return nil
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        endRecording()
        shortcutError = nil
        registerSavedShortcut()
    }

    func removeShortcut() {
        endRecording()
        unregisterShortcut()
        shortcut = nil
        shortcutError = nil
        defaults.removeObject(forKey: Self.shortcutKey)
    }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
            return
        }
        guard !event.isARepeat else { return }
        guard let candidate = ToggleShortcut(event: event) else {
            shortcutError = "Usa al menos ⌘, ⌃ o ⌥ junto a otra tecla."
            return
        }
        let status = register(candidate)
        guard status == noErr else {
            shortcutError = errorMessage(status)
            return
        }
        shortcut = candidate
        shortcutError = nil
        defaults.set(try? JSONEncoder().encode(candidate), forKey: Self.shortcutKey)
        endRecording()
    }

    private func endRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
    }

    private func registerSavedShortcut() {
        guard let shortcut, onToggle != nil else { return }
        let status = register(shortcut)
        shortcutError = status == noErr ? nil : errorMessage(status)
    }

    private func register(_ shortcut: ToggleShortcut) -> OSStatus {
        if handler == nil {
            let specs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                let kind = GetEventKind(event)
                return MainActor.assumeIsolated {
                    guard status == noErr, id.signature == ActivationControls.identifier.signature,
                          id.id == ActivationControls.identifier.id else { return OSStatus(eventNotHandledErr) }
                    let controls = Unmanaged<ActivationControls>.fromOpaque(context).takeUnretainedValue()
                    guard !controls.isRecording, controls.hotKey != nil else { return noErr }
                    if kind == UInt32(kEventHotKeyPressed) {
                        controls.hotKeyIsDown = true
                    } else if controls.hotKeyIsDown {
                        controls.hotKeyIsDown = false
                        controls.onToggle?()
                    }
                    return noErr
                }
            }, specs.count, specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }
        return RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, Self.identifier, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey
        )
    }

    private func unregisterShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        hotKeyIsDown = false
    }

    private func errorMessage(_ status: OSStatus) -> String {
        status == eventHotKeyExistsErr
            ? "Esa combinación ya está en uso. Elige otra."
            : "macOS no pudo registrar ese atajo. Prueba otra combinación."
    }

    private func updateShakeMonitors() {
        if let globalShakeMonitor { NSEvent.removeMonitor(globalShakeMonitor) }
        if let localShakeMonitor { NSEvent.removeMonitor(localShakeMonitor) }
        globalShakeMonitor = nil
        localShakeMonitor = nil
        resetShake()
        guard shakeEnabled, onToggle != nil else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalShakeMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.handleShakeEvent(event) }
        }
        localShakeMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handleShakeEvent(event)
            return event
        }
    }

    private func resetShake() {
        shake = CursorShake()
        lastShakeSample = -.infinity
    }

    private func handleShakeEvent(_ event: NSEvent) {
        guard event.type == .mouseMoved else {
            resetShake()
            return
        }
        let now = event.timestamp
        guard now - lastShakeSample >= 0.025 else { return }
        lastShakeSample = now
        let position = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if shake.sample(
            position, at: now,
            dragging: NSEvent.pressedMouseButtons != 0, sensitivity: shakeSensitivity
        ), !isRecording {
            onToggle?()
        }
    }
}
