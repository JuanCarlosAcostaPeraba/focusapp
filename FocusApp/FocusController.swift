import AppKit
import CoreGraphics

@MainActor
final class FocusController: NSObject {
    private var timer: Timer?
    private var panels: [CGDirectDisplayID: BlurPanel] = [:]
    private var lastFocusedWindowID: Int?
    private var stageManager = StageManagerStrip(enabled: false, onRight: false)
    private var nextStageManagerCheck = 0.0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    var isEnabled: Bool { timer != nil }

    var preferencesWindowNumber: Int?

    var scope: FocusScope = .window {
        didSet {
            if scope != oldValue { refreshFocus() }
        }
    }

    var displayScope: DisplayScope = .activeDisplay {
        didSet {
            if displayScope != oldValue { refreshFocus() }
        }
    }

    var blurStageManager = false {
        didSet {
            if blurStageManager != oldValue { refreshFocus() }
        }
    }

    var excludedBundleIdentifiers = Set<String>() {
        didSet {
            if excludedBundleIdentifiers != oldValue { refreshFocus() }
        }
    }

    var groupMembersByApplication: [String: Set<String>] = [:] {
        didSet {
            if groupMembersByApplication != oldValue { refreshFocus() }
        }
    }

    var effect = EffectSettings.subtle {
        didSet {
            for panel in panels.values { panel.apply(effect) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            nextStageManagerCheck = 0
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(
                self, selector: #selector(workspaceChanged(_:)),
                name: NSWorkspace.didActivateApplicationNotification, object: nil
            )
            workspace.addObserver(
                self, selector: #selector(workspaceChanged(_:)),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(workspaceChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            // App activation alone misses changes between windows of the same app.
            let timer = Timer(
                timeInterval: 0.15, target: self, selector: #selector(pollFocus(_:)),
                userInfo: nil, repeats: true
            )
            timer.tolerance = 0.03
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            refreshFocus()
        } else {
            timer?.invalidate()
            timer = nil
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            NotificationCenter.default.removeObserver(self)
            removePanels(except: [])
            lastFocusedWindowID = nil
        }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        if notification.name == NSWorkspace.activeSpaceDidChangeNotification ||
            notification.name == NSApplication.didChangeScreenParametersNotification {
            removePanels(except: [])
        }
        refreshFocus()
    }

    @objc private func pollFocus(_ timer: Timer) {
        refreshFocus()
    }

    private func refreshFocus() {
        guard isEnabled,
              let app = NSWorkspace.shared.frontmostApplication,
              let snapshot = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else {
            hidePanels()
            return
        }

        let visibleWindows = snapshot.compactMap(WindowInfo.init)
        let windows = visibleWindows.filter { $0.layer == 0 }
        let displays = FocusDisplay.current
        let stageWindows = stageManagerWindows(in: windows, displays: displays)
        let group = app.bundleIdentifier.flatMap { groupMembersByApplication[$0] } ?? []
        let active = windows.first {
            $0.owner == app.processIdentifier &&
                ($0.owner != ownPID || $0.id == preferencesWindowNumber) &&
                $0.isAppWindow && !stageWindows.contains($0.id)
        }
        // A floating group member is already above the normal window stack.
        let floating = active == nil && !group.isEmpty
            ? visibleWindows.first { $0.owner == app.processIdentifier && $0.isAppWindow && !stageWindows.contains($0.id) }
            : nil
        let previous = floating == nil && app.bundleIdentifier.map(excludedBundleIdentifiers.contains) == true
            ? windows.first { $0.id == lastFocusedWindowID }
            : nil
        let anchor = active ?? previous
        guard let bounds = (anchor ?? floating)?.bounds,
              let activeDisplay = FocusDisplay.containing(bounds, in: displays) else {
            hidePanels()
            return
        }

        if let anchor, anchor.owner != ownPID {
            lastFocusedWindowID = anchor.id
        }

        let targets = displayScope == .allDisplays ? displays : [activeDisplay]
        removePanels(except: Set(targets.map(\.id)))
        let clearBundles = excludedBundleIdentifiers.union(group)
        var clearOwners = Set(NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard let identifier = app.bundleIdentifier, clearBundles.contains(identifier) else { return nil }
            return app.processIdentifier
        })
        if scope == .application, let anchor, anchor.owner != ownPID {
            clearOwners.insert(anchor.owner)
        }

        for display in targets {
            updatePanel(
                on: display, windows: windows, clearOwners: clearOwners,
                protectedWindow: anchor?.id, anchorBelow: display.id == activeDisplay.id ? anchor?.id : nil,
                stageWindows: stageWindows
            )
        }
    }

    private func updatePanel(
        on display: FocusDisplay, windows: [WindowInfo], clearOwners: Set<pid_t>,
        protectedWindow: Int?, anchorBelow: Int?, stageWindows: Set<Int>
    ) {
        let panel = panels[display.id] ?? BlurPanel(effect: effect)
        panels[display.id] = panel
        if panel.frame != display.frame {
            panel.setFrame(display.frame, display: false)
        }

        let panelID = panel.windowNumber
        let localWindows = windows.filter {
            $0.bounds.intersects(display.windowBounds) &&
                ($0.owner != ownPID || $0.id == panelID || $0.id == preferencesWindowNumber)
        }
        let behind: ArraySlice<WindowInfo>
        let relativeTo: Int
        let placement: NSWindow.OrderingMode
        if let anchorBelow, let index = localWindows.firstIndex(where: { $0.id == anchorBelow }),
           !blurStageManager || !localWindows[..<index].contains(where: { stageWindows.contains($0.id) }) {
            behind = localWindows.dropFirst(index + 1)
            relativeTo = anchorBelow
            placement = .below
        } else {
            // Other monitors can have foreground windows ahead of the anchor in the
            // global stack. Place the panel above their local stack and mask clear windows.
            behind = localWindows[...]
            relativeTo = behind.first(where: { $0.id != panelID })?.id ?? 0
            placement = .above
        }

        panel.updateMask(backgroundWindows(
            behind, on: display, panelID: panelID, clearOwners: clearOwners,
            protectedWindow: protectedWindow, stageWindows: stageWindows
        ))
        if !panel.isVisible || behind.first?.id != panelID {
            panel.place(placement, relativeTo: relativeTo)
        }
    }

    private func backgroundWindows(
        _ windows: ArraySlice<WindowInfo>, on display: FocusDisplay,
        panelID: Int, clearOwners: Set<pid_t>, protectedWindow: Int?, stageWindows: Set<Int>
    ) -> [BackgroundWindow] {
        func staysClear(_ window: WindowInfo) -> Bool {
            if stageWindows.contains(window.id) { return !blurStageManager }
            return window.id == protectedWindow || clearOwners.contains(window.owner)
        }
        guard let last = windows.lastIndex(where: staysClear) else { return [] }
        return windows[...last].compactMap { window in
            guard window.id != panelID else { return nil }
            let rect = display.localBounds(of: window.bounds)
            guard !rect.isEmpty else { return nil }
            return BackgroundWindow(bounds: rect, keepsFocus: staysClear(window))
        }
    }

    private func stageManagerWindows(in windows: [WindowInfo], displays: [FocusDisplay]) -> Set<Int> {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextStageManagerCheck {
            stageManager = .readSystemPreferences()
            nextStageManagerCheck = now + 0.75
        }
        return stageManager.windowIDs(in: windows, displays: displays)
    }

    private func hidePanels() {
        for panel in panels.values where panel.isVisible { panel.orderOut(nil) }
    }

    private func removePanels(except displays: Set<CGDirectDisplayID>) {
        let obsolete = panels.keys.filter { !displays.contains($0) }
        for id in obsolete {
            panels.removeValue(forKey: id)?.orderOut(nil)
        }
    }
}

struct FocusDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let desktopTop: CGFloat

    // Quartz uses the primary display's top-left as its origin.
    var windowBounds: CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }

    @MainActor
    static var current: [Self] {
        let screens = NSScreen.screens
        guard let desktopTop = screens.first?.frame.maxY else { return [] }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return Self(id: number.uint32Value, frame: screen.frame, desktopTop: desktopTop)
        }
    }

    static func containing(_ window: CGRect, in displays: [Self]) -> Self? {
        var best: Self?
        var bestArea: CGFloat = 0
        for display in displays {
            let overlap = window.intersection(display.windowBounds)
            guard !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                best = display
                bestArea = area
            }
        }
        return best
    }

    func localBounds(of window: CGRect) -> CGRect {
        let clipped = window.intersection(windowBounds)
        guard !clipped.isEmpty else { return .null }
        return CGRect(
            x: clipped.minX - windowBounds.minX, y: windowBounds.maxY - clipped.maxY,
            width: clipped.width, height: clipped.height
        )
    }
}

struct WindowInfo {
    let id: Int
    let owner: pid_t
    let layer: Int
    let ownerName: String?
    let name: String?
    let bounds: CGRect

    var isAppWindow: Bool { bounds.width >= 32 && bounds.height >= 32 }

    init?(_ entry: [String: Any]) {
        guard let layer = entry[kCGWindowLayer as String] as? Int,
              (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = entry[kCGWindowNumber as String] as? Int,
              let owner = entry[kCGWindowOwnerPID as String] as? pid_t,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        self.id = id
        self.owner = owner
        self.layer = layer
        ownerName = entry[kCGWindowOwnerName as String] as? String
        name = entry[kCGWindowName as String] as? String
        self.bounds = bounds
    }
}

struct StageManagerStrip {
    let enabled: Bool
    let onRight: Bool

    static func readSystemPreferences() -> Self {
        let manager = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(manager)
        guard CFPreferencesCopyAppValue("GloballyEnabled" as CFString, manager) as? Bool == true else {
            return Self(enabled: false, onRight: false)
        }
        let dock = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(dock)
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, dock) as? String
        return Self(enabled: true, onRight: orientation == "left")
    }

    func windowIDs(in windows: [WindowInfo], displays: [FocusDisplay]) -> Set<Int> {
        guard enabled else { return [] }
        var result: Set<Int> = []
        for (index, window) in windows.enumerated() where window.ownerName == "WindowManager" && window.layer == 0 {
            let name = window.name ?? ""
            guard name.isEmpty || name == "App Icon Window" || name == "Gesture Blocking Overlay",
                  displays.contains(where: { isAtStripEdge(window.bounds, of: $0.windowBounds) }) else { continue }
            result.insert(window.id)

            // The gesture surface sits directly over the app-owned thumbnail.
            // Titles can be absent without Screen Recording permission.
            guard name != "App Icon Window" else { continue }
            let thumbnailBounds = window.bounds.insetBy(dx: -5, dy: -5)
            for thumbnail in windows.dropFirst(index + 1) where
                thumbnail.ownerName != "WindowManager" && thumbnail.layer == 0 &&
                thumbnailBounds.contains(thumbnail.bounds) {
                result.insert(thumbnail.id)
            }
        }
        return result
    }

    private func isAtStripEdge(_ window: CGRect, of display: CGRect) -> Bool {
        let visible = window.intersection(display)
        guard !visible.isEmpty, (18...min(280, max(150, display.width * 0.19))).contains(window.width),
              (24...max(125, display.height * 0.36)).contains(window.height) else { return false }
        let offset = onRight ? display.maxX - visible.maxX : visible.minX - display.minX
        return offset <= max(42, display.width * 0.035)
    }
}
