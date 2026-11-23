import AppKit
import CoreGraphics

@MainActor
final class FocusController: NSObject {
    private var timer: Timer?
    private var panels: [CGDirectDisplayID: BlurPanel] = [:]
    private var displays: [FocusDisplay] = []
    private var screenIsAwake = true
    private var fastPollingUntil = 0.0
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var runningAppsObserver: NSKeyValueObservation?
    private var frontmostApp: (pid: pid_t, bundleIdentifier: String?)?
    private var ownersByBundle: [String: Set<pid_t>] = [:]
    private var previousWindows: [WindowInfo]?
    private var lastFocusedWindowID: Int?
    private var stageManager = StageManagerStrip(enabled: false, onRight: false)
    private var nextStageManagerCheck = 0.0
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private(set) var isEnabled = false
    private var hasVisibleEffect: Bool { effect.blur > 0 || effect.grain > 0 }

    var preferencesWindowNumber: Int? {
        didSet {
            if preferencesWindowNumber != oldValue { refreshFocus() }
        }
    }

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
            guard effect != oldValue else { return }
            for panel in panels.values { panel.apply(effect) }
            if isEnabled, hasVisibleEffect != (oldValue.blur > 0 || oldValue.grain > 0) {
                updateTracking()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                         NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                         NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
                workspace.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(workspaceChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil
            )
            updateTracking()
        } else {
            stopTracking()
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            NotificationCenter.default.removeObserver(self)
            for (id, panel) in panels {
                panel.dismiss { [weak self, weak panel] in
                    guard let self, let panel, self.panels[id] === panel else { return }
                    self.panels.removeValue(forKey: id)
                }
            }
            lastFocusedWindowID = nil
            screenIsAwake = true
        }
    }

    private func updateTracking() {
        guard isEnabled, hasVisibleEffect, screenIsAwake else {
            stopTracking()
            removePanels(except: [])
            return
        }
        displays = FocusDisplay.current
        if runningAppsObserver == nil {
            // This also covers apps without a Dock icon.
            runningAppsObserver = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.runningAppsChanged() }
            }
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked() }
            }
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
                self?.clicked()
                return event
            }
        }
        nextStageManagerCheck = 0
        refreshFocus()
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        runningAppsObserver = nil
        frontmostApp = nil
        ownersByBundle.removeAll()
        displays = []
        previousWindows = nil
    }

    private func runningAppsChanged() {
        frontmostApp = nil
        ownersByBundle.removeAll()
        previousWindows = nil
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification:
            screenIsAwake = notification.name == NSWorkspace.screensDidWakeNotification
            updateTracking()
        case NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
             NSApplication.didChangeScreenParametersNotification:
            removePanels(except: [])
            updateTracking()
        default:
            frontmostApp = nil
            refreshFocus()
        }
    }

    private func clicked() {
        fastPollingUntil = ProcessInfo.processInfo.systemUptime + 0.6
        schedulePoll(after: 0.06)
    }

    private func schedulePoll(after delay: TimeInterval) {
        let date = Date(timeIntervalSinceNow: delay)
        if let timer, timer.fireDate <= date { return }
        timer?.invalidate()
        let timer = Timer(fireAt: date, interval: 0, target: self, selector: #selector(pollFocus(_:)),
                          userInfo: nil, repeats: false)
        timer.tolerance = delay * 0.15
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshFocus() {
        guard isEnabled, hasVisibleEffect, screenIsAwake else { return }
        previousWindows = nil
        pollFocus()
    }

    @objc private func pollFocus(_ firedTimer: Timer) {
        guard firedTimer === timer else { return }
        timer = nil
        pollFocus()
    }

    private func pollFocus() {
        let now = ProcessInfo.processInfo.systemUptime
        if readStageManager(at: now) { previousWindows = nil }
        if reconcileWindows() { fastPollingUntil = now + 0.6 }
        // Quartz has no notification for window changes within another app.
        schedulePoll(after: now < fastPollingUntil ? 0.15 : 0.45)
    }

    private func reconcileWindows() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let snapshot = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else {
            previousWindows = nil
            removePanels(except: [])
            return false
        }

        let pid = app.processIdentifier
        if frontmostApp?.pid != pid {
            frontmostApp = (pid, app.bundleIdentifier)
            previousWindows = nil
        }
        let bundleID = frontmostApp?.bundleIdentifier
        let group = bundleID.flatMap { groupMembersByApplication[$0] } ?? []
        let visibleWindows = snapshot.compactMap {
            WindowInfo($0, floatingOwner: group.isEmpty ? nil : pid, includeStageManager: stageManager.enabled)
        }
        guard visibleWindows != previousWindows else { return false }
        previousWindows = visibleWindows
        let windows = visibleWindows.filter { $0.layer == 0 }
        let stageWindows = stageManager.windowIDs(in: windows, displays: displays)
        let active = windows.first {
            $0.owner == pid &&
                ($0.owner != ownPID || $0.id == preferencesWindowNumber) &&
                $0.isAppWindow && !stageWindows.contains($0.id)
        }
        // A floating group member is already above the normal window stack.
        let floating = active == nil && !group.isEmpty
            ? visibleWindows.first { $0.owner == pid && $0.isAppWindow && !stageWindows.contains($0.id) }
            : nil
        let previous = floating == nil && bundleID.map(excludedBundleIdentifiers.contains) == true
            ? windows.first { $0.id == lastFocusedWindowID }
            : nil
        let anchor = active ?? previous
        guard let bounds = (anchor ?? floating)?.bounds,
              let activeDisplay = FocusDisplay.containing(bounds, in: displays) else {
            removePanels(except: [])
            return true
        }

        if let anchor, anchor.owner != ownPID {
            lastFocusedWindowID = anchor.id
        }

        let targets = displayScope == .allDisplays ? displays : [activeDisplay]
        removePanels(except: Set(targets.map(\.id)))
        var clearOwners: Set<pid_t> = []
        for bundle in excludedBundleIdentifiers.union(group) {
            if ownersByBundle[bundle] == nil {
                ownersByBundle[bundle] = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                    .map(\.processIdentifier))
            }
            clearOwners.formUnion(ownersByBundle[bundle, default: []])
        }
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
        return true
    }

    private func updatePanel(
        on display: FocusDisplay, windows: [WindowInfo], clearOwners: Set<pid_t>,
        protectedWindow: Int?, anchorBelow: Int?, stageWindows: Set<Int>
    ) {
        let panel = panel(for: display.id)
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
        panel.present(placement, relativeTo: relativeTo, needsPlacement: behind.first?.id != panelID)
    }

    private func panel(for display: CGDirectDisplayID) -> BlurPanel {
        if let panel = panels[display] { return panel }
        let panel = BlurPanel(effect: effect)
        panels[display] = panel
        return panel
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

    private func readStageManager(at now: TimeInterval) -> Bool {
        guard now >= nextStageManagerCheck else { return false }
        nextStageManagerCheck = now + 0.75
        let current = StageManagerStrip.readSystemPreferences()
        defer { stageManager = current }
        return current != stageManager
    }

    private func removePanels(except displays: Set<CGDirectDisplayID>) {
        let obsolete = panels.keys.filter { !displays.contains($0) }
        for id in obsolete {
            panels.removeValue(forKey: id)?.hideImmediately()
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

struct WindowInfo: Equatable {
    let id: Int
    let owner: pid_t
    let layer: Int
    let ownerName: String?
    let name: String?
    let bounds: CGRect

    var isAppWindow: Bool { bounds.width >= 32 && bounds.height >= 32 }

    init?(_ entry: [String: Any], floatingOwner: pid_t?, includeStageManager: Bool) {
        guard let layer = entry[kCGWindowLayer as String] as? Int,
              let owner = entry[kCGWindowOwnerPID as String] as? pid_t,
              layer == 0 || owner == floatingOwner,
              (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let id = entry[kCGWindowNumber as String] as? Int,
              let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        self.id = id
        self.owner = owner
        self.layer = layer
        ownerName = includeStageManager ? entry[kCGWindowOwnerName as String] as? String : nil
        name = ownerName == "WindowManager" ? entry[kCGWindowName as String] as? String : nil
        self.bounds = bounds
    }
}

struct StageManagerStrip: Equatable {
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
