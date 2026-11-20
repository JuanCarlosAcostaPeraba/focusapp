import SwiftUI

enum FocusScope: String, CaseIterable, Identifiable {
    case window, application

    var id: Self { self }

    var title: String {
        switch self {
        case .window: "Ventana activa"
        case .application: "App activa"
        }
    }
}

enum DisplayScope: String, CaseIterable, Identifiable {
    case activeDisplay, allDisplays

    var id: Self { self }

    var title: String {
        switch self {
        case .activeDisplay: "Pantalla activa"
        case .allDisplays: "Todas las pantallas"
        }
    }
}

struct ApplicationReference: Codable, Equatable, Identifiable {
    static let teleprompter = Self(id: "local.apunte.teleprompter", name: "Teleprompter")

    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        self.id = id
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

struct ApplicationGroup: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Nuevo grupo"
    var applications: [ApplicationReference] = []
}

enum ApplicationDestination {
    case exclusions
    case group(UUID)
}

enum TintColor: String, Codable, CaseIterable, Identifiable {
    case black, white, accent, custom

    var id: Self { self }

    var title: String {
        switch self {
        case .black: "Negro"
        case .white: "Blanco"
        case .accent: "Acento del sistema"
        case .custom: "Personalizado"
        }
    }
}

struct EffectSettings: Codable, Equatable {
    static let maximumDimming = 0.65
    static let subtle = Self()
    static let strong = Self(blur: 0.68, monochrome: 0.18, dimming: 0.18, grain: 0.35)
    static let tintOnly = Self(blur: 0, dimming: 0.25, grain: 0)

    var blur = 0.25
    var monochrome = 0.0
    var dimming = 0.0
    var grain = 0.50
    var tint: TintColor = .black
    var customTint: UInt32 = 0x688BEE

    var customColor: NSColor {
        NSColor(
            srgbRed: CGFloat((customTint >> 16) & 255) / 255,
            green: CGFloat((customTint >> 8) & 255) / 255,
            blue: CGFloat(customTint & 255) / 255,
            alpha: 1
        )
    }

    var tintColor: NSColor {
        switch tint {
        case .black: .black
        case .white: .white
        case .accent: .controlAccentColor
        case .custom: customColor
        }
    }
}

@MainActor
final class EffectPreferences: ObservableObject {
    private static let key = "effectPreferences"
    private static let exclusionsKey = "excludedApplications"
    private static let groupsKey = "applicationGroups"
    private static let scopeKey = "focusScope"
    private static let displayScopeKey = "displayScope"
    private static let stageManagerBlurKey = "blurStageManager"
    private let defaults: UserDefaults

    @Published var effect: EffectSettings {
        didSet {
            guard effect != oldValue else { return }
            if let data = try? JSONEncoder().encode(effect) {
                defaults.set(data, forKey: Self.key)
            }
            onChange?(effect)
        }
    }
    @Published var isEnabled = false
    @Published var focusScope: FocusScope {
        didSet {
            guard focusScope != oldValue else { return }
            defaults.set(focusScope.rawValue, forKey: Self.scopeKey)
            onFocusScopeChange?(focusScope)
        }
    }
    @Published var displayScope: DisplayScope {
        didSet {
            guard displayScope != oldValue else { return }
            defaults.set(displayScope.rawValue, forKey: Self.displayScopeKey)
            onDisplayScopeChange?(displayScope)
        }
    }
    @Published var blurStageManager: Bool {
        didSet {
            guard blurStageManager != oldValue else { return }
            defaults.set(blurStageManager, forKey: Self.stageManagerBlurKey)
            onStageManagerBlurChange?(blurStageManager)
        }
    }
    @Published var excludedApplications: [ApplicationReference] {
        didSet {
            guard excludedApplications != oldValue else { return }
            if let data = try? JSONEncoder().encode(excludedApplications) {
                defaults.set(data, forKey: Self.exclusionsKey)
            }
            onExclusionsChange?(excludedBundleIdentifiers)
        }
    }
    @Published var applicationGroups: [ApplicationGroup] {
        didSet {
            guard applicationGroups != oldValue else { return }
            if let data = try? JSONEncoder().encode(applicationGroups) {
                defaults.set(data, forKey: Self.groupsKey)
            }
            onGroupsChange?(groupMembersByApplication)
        }
    }
    var onChange: ((EffectSettings) -> Void)?
    var onFocusScopeChange: ((FocusScope) -> Void)?
    var onDisplayScopeChange: ((DisplayScope) -> Void)?
    var onStageManagerBlurChange: ((Bool) -> Void)?
    var onExclusionsChange: ((Set<String>) -> Void)?
    var onGroupsChange: (([String: Set<String>]) -> Void)?

    var excludedBundleIdentifiers: Set<String> {
        Set(excludedApplications.map(\.id))
    }

    var groupMembersByApplication: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for group in applicationGroups {
            let members = Set(group.applications.map(\.id))
            guard members.count > 1 else { continue }
            for identifier in members {
                result[identifier, default: []].formUnion(members)
            }
        }
        return result
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        focusScope = defaults.string(forKey: Self.scopeKey).flatMap(FocusScope.init(rawValue:)) ?? .window
        displayScope = defaults.string(forKey: Self.displayScopeKey).flatMap(DisplayScope.init(rawValue:)) ?? .activeDisplay
        blurStageManager = defaults.bool(forKey: Self.stageManagerBlurKey)
        excludedApplications = defaults.data(forKey: Self.exclusionsKey).flatMap {
            try? JSONDecoder().decode([ApplicationReference].self, from: $0)
        } ?? [.teleprompter]
        applicationGroups = defaults.data(forKey: Self.groupsKey).flatMap {
            try? JSONDecoder().decode([ApplicationGroup].self, from: $0)
        } ?? []
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(EffectSettings.self, from: data) {
            effect = saved
        } else {
            var initial = EffectSettings.subtle
            initial.dimming = min(max(defaults.double(forKey: "dimming"), 0), EffectSettings.maximumDimming)
            effect = initial
        }
    }

    func usePreset(_ preset: EffectSettings) {
        var settings = preset
        settings.customTint = effect.customTint
        effect = settings
    }

    func addApplications(_ urls: [URL], to destination: ApplicationDestination) {
        switch destination {
        case .exclusions:
            excludedApplications = mergedApplications(excludedApplications, with: urls)
        case .group(let id):
            guard let index = applicationGroups.firstIndex(where: { $0.id == id }) else { return }
            applicationGroups[index].applications = mergedApplications(applicationGroups[index].applications, with: urls)
        }
    }

    private func mergedApplications(_ existing: [ApplicationReference], with urls: [URL]) -> [ApplicationReference] {
        var known = Set(existing.map(\.id))
        let additions = urls.compactMap(ApplicationReference.init(url:)).filter { known.insert($0.id).inserted }
        return (existing + additions).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct PreferencesView: View {
    private enum SettingsPage: String, CaseIterable {
        case appearance = "Aspecto"
        case activation = "Activación"
        case exclusions = "Exclusiones"
        case groups = "Grupos"
        case updates = "Actualizaciones"
    }

    @State private var section: SettingsPage = .appearance
    @ObservedObject var preferences: EffectPreferences
    @ObservedObject var activation: ActivationControls
    let updater: AppUpdater
    let supportsMonochrome: Bool
    let onToggle: () -> Void
    let onChooseApplications: (ApplicationDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsPage.allCases, id: \.self) { item in
                    Button {
                        section = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 12, weight: section == item ? .semibold : .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                            .background {
                                if section == item {
                                    RoundedRectangle(cornerRadius: 6).fill(.background)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Group {
                switch section {
                case .appearance: appearance
                case .activation: activationSettings
                case .exclusions: exclusions
                case .groups: groups
                case .updates: UpdateSettingsView(updater: updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 540, height: 578)
    }

    private var exclusions: some View {
        Form {
            Section("Apps excluidas") {
                Text("Sus ventanas siguen nítidas aunque estén en segundo plano.")
                    .foregroundStyle(.secondary)
                if preferences.excludedApplications.isEmpty {
                    Text("Ninguna app excluida")
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.excludedApplications) { app in
                    applicationRow(app, removeLabel: "Quitar \(app.name) de las exclusiones") {
                        preferences.excludedApplications.removeAll { $0.id == app.id }
                    }
                }
                Button("Añadir apps…") { onChooseApplications(.exclusions) }
            }
        }
        .formStyle(.grouped)
    }

    private var groups: some View {
        Form {
            Section("Grupos de aplicaciones") {
                Text("Al enfocar una app de un grupo, las ventanas visibles de todo el grupo quedan nítidas.")
                    .foregroundStyle(.secondary)
                Button("Crear grupo") { preferences.applicationGroups.append(ApplicationGroup()) }
            }
            ForEach($preferences.applicationGroups) { $group in
                let groupID = group.id
                Section {
                    TextField("Nombre", text: $group.name)
                    if group.applications.count < 2 {
                        Text("Añade al menos dos apps para activar el grupo.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group.applications) { app in
                        applicationRow(app, removeLabel: "Quitar \(app.name) del grupo") {
                            group.applications.removeAll { $0.id == app.id }
                        }
                    }
                    HStack {
                        Button("Añadir apps…") { onChooseApplications(.group(groupID)) }
                        Spacer()
                        Button("Eliminar grupo", role: .destructive) {
                            preferences.applicationGroups.removeAll { $0.id == groupID }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applicationRow(_ app: ApplicationReference, removeLabel: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            applicationIcon(app)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(app.name)
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel(removeLabel)
                .help(removeLabel)
        }
    }

    private func applicationIcon(_ app: ApplicationReference) -> some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app").resizable()
            }
        }
        .scaledToFit()
    }

    private var appearance: some View {
        Form {
            Section {
                Toggle("Activar efecto", isOn: Binding(
                    get: { preferences.isEnabled },
                    set: { _ in onToggle() }
                ))
                Picker("Mantener nítida", selection: $preferences.focusScope) {
                    ForEach(FocusScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Picker("Pantallas", selection: $preferences.displayScope) {
                    ForEach(DisplayScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Toggle("Desenfocar miniaturas de Stage Manager", isOn: $preferences.blurStageManager)
                Menu("Preajustes") {
                    Button("Suave") { preferences.usePreset(.subtle) }
                    Button("Intenso") { preferences.usePreset(.strong) }
                    Button("Solo tinte") { preferences.usePreset(.tintOnly) }
                }
            }
            Section("Aspecto del fondo") {
                slider("Desenfoque", value: $preferences.effect.blur)
                slider("Monocromo", value: $preferences.effect.monochrome)
                    .disabled(!supportsMonochrome)
                if !supportsMonochrome {
                    Text("El modo de compatibilidad de macOS no ofrece monocromo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                slider("Grano", value: $preferences.effect.grain)
            }
            Section("Tinte") {
                Picker("Color", selection: $preferences.effect.tint) {
                    ForEach(TintColor.allCases) { tint in
                        Text(tint.title).tag(tint)
                    }
                }
                if preferences.effect.tint == .custom {
                    ColorPicker("Color personalizado", selection: customColor, supportsOpacity: false)
                }
                slider("Opacidad", value: $preferences.effect.dimming, max: EffectSettings.maximumDimming)
            }
        }
        .formStyle(.grouped)
    }

    private var activationSettings: some View {
        Form {
            Section("Teclado") {
                LabeledContent("Atajo global") {
                    HStack(spacing: 10) {
                        Text(activation.isRecording ? "Pulsa las teclas…" : activation.shortcutTitle)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if activation.isRecording {
                            Button("Cancelar", action: activation.cancelRecording)
                        } else {
                            Button(activation.hasShortcut ? "Cambiar…" : "Asignar…", action: activation.beginRecording)
                            if activation.hasShortcut {
                                Button("Quitar", action: activation.removeShortcut)
                            }
                        }
                    }
                }
                if let error = activation.shortcutError {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if activation.isRecording {
                    Text("Combina ⌘, ⌃ o ⌥ con otra tecla. Pulsa Esc para cancelar.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Gestos") {
                Toggle("Agitar el cursor para activar o desactivar", isOn: $activation.shakeEnabled)
                if activation.shakeEnabled {
                    Picker("Sensibilidad", selection: $activation.shakeSensitivity) {
                        ForEach(ShakeSensitivity.allCases) { sensitivity in
                            Text(sensitivity.title).tag(sensitivity)
                        }
                    }
                    Text("Mueve el cursor rápidamente de un lado a otro sin pulsar ningún botón.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: activation.cancelRecording)
    }

    private var customColor: Binding<Color> {
        Binding {
            Color(nsColor: preferences.effect.customColor)
        } set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let r = colorByte(rgb.redComponent)
            let g = colorByte(rgb.greenComponent)
            let b = colorByte(rgb.blueComponent)
            preferences.effect.customTint = (r << 16) | (g << 8) | b
        }
    }

    private func colorByte(_ component: CGFloat) -> UInt32 {
        UInt32((min(max(component, 0), 1) * 255).rounded())
    }

    private func slider(_ label: String, value: Binding<Double>, max: Double = 1) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                ContinuousEffectSlider(value: value, maximum: max, label: label)
                    .frame(width: 176)
                Text(value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct ContinuousEffectSlider: NSViewRepresentable {
    @Binding var value: Double
    let maximum: Double
    let label: String

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: maximum,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel(label)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) { self.value = value }

        @objc func changed(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
            if RunLoop.current.currentMode == .eventTracking {
                // AppKit tracks the drag in a nested run loop. Submit the backdrop update there.
                CATransaction.flush()
            }
        }
    }
}
