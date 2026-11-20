import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let focus = FocusController()
    private let preferences = EffectPreferences()
    private let activation = ActivationControls()
    private let updater = AppUpdater()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let toggle = NSMenuItem(
        title: "Activar desenfoque",
        action: #selector(toggleFocus),
        keyEquivalent: ""
    )
    private let percentage = NSTextField(labelWithString: "")
    private var dimmingSlider: NSSlider?
    private var preferencesWindow: NSWindow?
    private var settingsItem: NSMenuItem?
    private var updateTimer: AnyCancellable?
    private var updateBadgeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activation.start { [weak self] in self?.toggleFocus() }
        let dimming = preferences.effect.dimming
        focus.effect = preferences.effect
        focus.scope = preferences.focusScope
        preferences.onFocusScopeChange = { [weak self] scope in
            self?.focus.scope = scope
        }
        focus.displayScope = preferences.displayScope
        preferences.onDisplayScopeChange = { [weak self] scope in
            self?.focus.displayScope = scope
        }
        focus.blurStageManager = preferences.blurStageManager
        preferences.onStageManagerBlurChange = { [weak self] enabled in
            self?.focus.blurStageManager = enabled
        }
        focus.excludedBundleIdentifiers = preferences.excludedBundleIdentifiers
        preferences.onExclusionsChange = { [weak self] bundleIdentifiers in
            self?.focus.excludedBundleIdentifiers = bundleIdentifiers
        }
        focus.groupMembersByApplication = preferences.groupMembersByApplication
        preferences.onGroupsChange = { [weak self] groups in
            self?.focus.groupMembersByApplication = groups
        }
        updatePercentage(dimming)
        preferences.onChange = { [weak self] effect in
            self?.focus.effect = effect
            self?.updatePercentage(effect.dimming)
            self?.dimmingSlider?.doubleValue = effect.dimming
        }

        toggle.target = self
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(makeDimmingItem(dimming))
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: "Ajustes…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        settings.target = self
        settingsItem = settings
        let quit = menu.addItem(
            withTitle: "Salir de FocusApp",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        statusItem.menu = menu
        updateBadgeObserver = updater.$available
            .map { $0 != nil }.removeDuplicates()
            .sink { [weak self] hasUpdate in self?.updateStatusButton(hasUpdate: hasUpdate) }
        updateTimer = Timer.publish(every: 86_400, tolerance: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.updater.check(automatically: true) }
        DispatchQueue.main.async { [weak self] in self?.focus.prepareInitialPanel() }
        updater.check(automatically: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        activation.stop()
        updateTimer?.cancel()
        updateBadgeObserver?.cancel()
    }

    func windowDidResignKey(_ notification: Notification) {
        activation.cancelRecording()
    }

    @objc private func showPreferences() {
        let window: NSWindow
        if let preferencesWindow {
            window = preferencesWindow
        } else {
            let content = PreferencesView(
                preferences: preferences,
                activation: activation,
                updater: updater,
                supportsMonochrome: BlurPanel.supportsMonochrome,
                onToggle: { [weak self] in self?.toggleFocus() },
                onChooseApplications: { [weak self] destination in self?.chooseApplications(for: destination) }
            )
            let host = NSHostingController(rootView: content)
            window = NSWindow(contentViewController: host)
            window.title = "Ajustes de FocusApp"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            preferencesWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        focus.preferencesWindowNumber = window.windowNumber
        NSApp.activate()
    }

    private func chooseApplications(for destination: ApplicationDestination) {
        guard let preferencesWindow else { return }
        let chooser = NSOpenPanel()
        switch destination {
        case .exclusions: chooser.title = "Añadir apps excluidas"
        case .group: chooser.title = "Añadir apps al grupo"
        }
        chooser.prompt = "Añadir"
        chooser.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        chooser.allowedContentTypes = [.applicationBundle]
        chooser.allowsMultipleSelection = true
        chooser.beginSheetModal(for: preferencesWindow) { [weak self] response in
            guard response == .OK else { return }
            self?.preferences.addApplications(chooser.urls, to: destination)
        }
    }

    private func makeDimmingItem(_ dimming: Double) -> NSMenuItem {
        let heading = NSTextField(labelWithString: "Oscurecimiento")
        heading.font = .menuFont(ofSize: 0)
        percentage.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentage.textColor = .secondaryLabelColor

        let slider = NSSlider(
            value: dimming,
            minValue: 0,
            maxValue: EffectSettings.maximumDimming,
            target: self,
            action: #selector(changeDimming(_:))
        )
        dimmingSlider = slider
        slider.isContinuous = true
        slider.setAccessibilityLabel("Oscurecimiento")

        let controls = NSStackView(views: [slider, percentage])
        controls.spacing = 10
        controls.alignment = .centerY
        let content = NSStackView(views: [heading, controls])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 6, left: 15, bottom: 6, right: 15)
        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 150),
            percentage.widthAnchor.constraint(equalToConstant: 34)
        ])
        content.setFrameSize(content.fittingSize)

        let item = NSMenuItem()
        item.view = content
        return item
    }

    @objc private func toggleFocus() {
        focus.setEnabled(!focus.isEnabled)
        preferences.isEnabled = focus.isEnabled
        toggle.title = focus.isEnabled ? "Desactivar desenfoque" : "Activar desenfoque"
        updateStatusButton()
    }

    @objc private func changeDimming(_ slider: NSSlider) {
        preferences.effect.dimming = slider.doubleValue
    }

    private func updatePercentage(_ value: Double) {
        percentage.stringValue = "\(Int((value * 100).rounded())) %"
    }

    private func updateStatusButton(hasUpdate: Bool? = nil) {
        let available = hasUpdate ?? (updater.available != nil)
        var description = focus.isEnabled
            ? "FocusApp, desenfoque activado"
            : "FocusApp, desenfoque desactivado"
        if available {
            description += ". Actualización disponible"
        }
        let symbol = focus.isEnabled ? "dot.viewfinder" : "viewfinder"
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: description)
        let image = if available, let base {
            NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
                base.draw(in: NSRect(x: 0, y: 1, width: 16, height: 16))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: 13, width: 4, height: 4)).fill()
                return true
            }
        } else {
            base
        }
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
        settingsItem?.title = available ? "Ajustes… · Actualización disponible" : "Ajustes…"
    }
}
