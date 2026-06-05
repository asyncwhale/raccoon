import SwiftUI
import AppKit
import KeyboardShortcuts
import RaccoonCore

/// The Settings window (⌘,). Edits the app-wide `Settings` in place and persists every
/// change to JSON via `AppModel.saveSettings()`.
///
/// All controls bind to `model.settings`; a single `.onChange(of: model.settings)` saves
/// after any edit (`Settings` is `Equatable`). `enabledTools` changes take effect on the
/// next sync; the records directory note warns that it only re-homes the store on relaunch.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    /// The four retention presets surfaced in the Picker. `.custom` reveals a day stepper.
    private enum RetentionChoice: Hashable {
        case days7
        case days30
        case forever
        case custom

        /// Map a stored `retentionDays` (nil = forever) onto a preset. Any non-7/30 finite
        /// value is treated as a custom value.
        init(retentionDays: Int?) {
            switch retentionDays {
            case .none: self = .forever
            case 7:     self = .days7
            case 30:    self = .days30
            default:    self = .custom
            }
        }
    }

    /// The retention preset derived from the current `retentionDays`. Held as view state so
    /// switching to "自定义" can show the stepper without first mutating `retentionDays`.
    @State private var retentionChoice: RetentionChoice = .forever

    /// The day count shown by the custom stepper. Initialized from settings; only written
    /// back to `settings.retentionDays` while `retentionChoice == .custom`.
    @State private var customDays: Int = 14

    var body: some View {
        @Bindable var model = model

        Form {
            retentionSection(model: $model)
            directoriesSection(model: $model)
            behaviorSection(model: $model)
            toolsSection(model: $model)
            shortcutSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // Initialize the local picker/stepper state from the loaded settings.
        .onAppear {
            retentionChoice = RetentionChoice(retentionDays: model.settings.retentionDays)
            if let days = model.settings.retentionDays, retentionChoice == .custom {
                customDays = days
            }
        }
        // Single source of truth for persistence: any change to the (Equatable) Settings
        // value is written straight back to JSON.
        .onChange(of: model.settings) {
            model.saveSettings()
        }
    }

    // MARK: Section header helper

    private func sectionHeader(_ title: String) -> some View {
        Text(title).dsSectionHeader()
    }

    // MARK: Retention

    @ViewBuilder
    private func retentionSection(model: Bindable<AppModel>) -> some View {
        Section {
            Picker(selection: retentionBinding(model: model)) {
                Text("settings.retention.7days").tag(RetentionChoice.days7)
                Text("settings.retention.30days").tag(RetentionChoice.days30)
                Text("settings.retention.forever").tag(RetentionChoice.forever)
                Text("settings.retention.custom").tag(RetentionChoice.custom)
            } label: {
                Text("settings.retention.choice").font(DS.Font.settingsLabel)
            }
            .pickerStyle(.menu)

            if retentionChoice == .custom {
                Stepper(value: $customDays, in: 1...3650) {
                    Text("settings.retention.keepDays \(customDays)").font(DS.Font.settingsLabel)
                }
                .onChange(of: customDays) { _, newValue in
                    // Keep settings in sync while in custom mode.
                    model.wrappedValue.settings.retentionDays = newValue
                }
            }

            Text("settings.retention.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)
        } header: {
            sectionHeader(String(localized: "settings.section.retention"))
        }
    }

    /// Bridges the `RetentionChoice` picker to `settings.retentionDays`. Selecting a preset
    /// writes the mapped value immediately; selecting Custom seeds `retentionDays` from the
    /// current custom stepper value so the change is captured even before the user nudges it.
    private func retentionBinding(model: Bindable<AppModel>) -> Binding<RetentionChoice> {
        Binding(
            get: { retentionChoice },
            set: { choice in
                retentionChoice = choice
                switch choice {
                case .days7:   model.wrappedValue.settings.retentionDays = 7
                case .days30:  model.wrappedValue.settings.retentionDays = 30
                case .forever: model.wrappedValue.settings.retentionDays = nil
                case .custom:  model.wrappedValue.settings.retentionDays = customDays
                }
            }
        )
    }

    // MARK: Directories

    @ViewBuilder
    private func directoriesSection(model: Bindable<AppModel>) -> some View {
        Section {
            directoryRow(
                title: String(localized: "settings.dir.records"),
                url: model.wrappedValue.settings.recordsDir
            ) { picked in
                model.wrappedValue.settings.recordsDir = picked
            }

            Text("settings.dir.records.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)

            directoryRow(
                title: String(localized: "settings.dir.notes"),
                url: model.wrappedValue.settings.notesDir
            ) { picked in
                model.wrappedValue.settings.notesDir = picked
            }
        } header: {
            sectionHeader(String(localized: "settings.section.directories"))
        }
    }

    /// One labeled path row with a "Choose…" button opening an `NSOpenPanel` (dirs only).
    @ViewBuilder
    private func directoryRow(
        title: String,
        url: URL,
        onPick: @escaping (URL) -> Void
    ) -> some View {
        LabeledContent {
            HStack(spacing: DS.Spacing.sm) {
                Text(url.path)
                    .font(DS.Font.settingsPath)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(url.path)
                Button("settings.dir.choose") {
                    if let picked = chooseDirectory(startingAt: url) {
                        onPick(picked)
                    }
                }
                .controlSize(.small)
            }
        } label: {
            Text(title).font(DS.Font.settingsLabel)
        }
    }

    /// Present a directory-only `NSOpenPanel` and return the chosen URL, or `nil` if the
    /// user cancels. Runs modally on the main actor.
    private func chooseDirectory(startingAt current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = current
        panel.prompt = String(localized: "settings.dir.choose.prompt")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Behavior

    @ViewBuilder
    private func behaviorSection(model: Bindable<AppModel>) -> some View {
        Section {
            Toggle(isOn: model.settings.autoCleanOnPaste) {
                Text("settings.behavior.autoclean").font(DS.Font.settingsLabel)
            }
            Text("settings.behavior.autoclean.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)

            Toggle(isOn: model.settings.autoTidyProseOnPaste) {
                Text("settings.behavior.tidyprose").font(DS.Font.settingsLabel)
            }
            .disabled(!model.wrappedValue.settings.autoCleanOnPaste)
            Text("settings.behavior.tidyprose.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)

            Toggle(isOn: menuBarModeBinding(model: model)) {
                Text("settings.behavior.menubar").font(DS.Font.settingsLabel)
            }
            Text("settings.behavior.menubar.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)
        } header: {
            sectionHeader(String(localized: "settings.section.behavior"))
        }
    }

    /// Binding for the menu-bar-mode toggle. Writes the new value into `settings`
    /// (which the shared `.onChange(of: model.settings)` persists to JSON) and then
    /// applies the activation policy live so the Dock icon appears/disappears
    /// immediately, no relaunch required.
    private func menuBarModeBinding(model: Bindable<AppModel>) -> Binding<Bool> {
        Binding(
            get: { model.wrappedValue.settings.menuBarMode },
            set: { isOn in
                model.wrappedValue.settings.menuBarMode = isOn
                model.wrappedValue.applyActivationPolicy()
            }
        )
    }

    // MARK: Enabled tools

    @ViewBuilder
    private func toolsSection(model: Bindable<AppModel>) -> some View {
        Section {
            Toggle(isOn: toolBinding(.claudeCode, model: model)) {
                Text(Tool.claudeCode.label).font(DS.Font.settingsLabel)
            }
            Toggle(isOn: toolBinding(.codex, model: model)) {
                Text(Tool.codex.label).font(DS.Font.settingsLabel)
            }

            soonRow(Tool.gemini.label)
            soonRow(Tool.cursor.label)

            Text("settings.tools.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)
        } header: {
            sectionHeader(String(localized: "settings.section.tools"))
        }
    }

    /// A clearly-dimmed disabled tool row with a "Soon" badge.
    private func soonRow(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(DS.Font.settingsLabel)
                .foregroundStyle(DS.Color.textTertiary)
            Spacer()
            Text("settings.tools.soon")
                .font(DS.Font.chip)
                .foregroundStyle(DS.Color.textTertiary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .fill(DS.Color.chipFill)
                )
        }
    }

    /// A `Bool` binding that adds/removes `tool` in the `Set<Tool>`.
    private func toolBinding(_ tool: Tool, model: Bindable<AppModel>) -> Binding<Bool> {
        Binding(
            get: { model.wrappedValue.settings.enabledTools.contains(tool) },
            set: { isOn in
                if isOn {
                    model.wrappedValue.settings.enabledTools.insert(tool)
                } else {
                    model.wrappedValue.settings.enabledTools.remove(tool)
                }
            }
        )
    }

    // MARK: Global shortcut

    @ViewBuilder
    private var shortcutSection: some View {
        Section {
            KeyboardShortcuts.Recorder(String(localized: "settings.shortcut.recorder"), name: .summonRaccoon)
            Text("settings.shortcut.footer")
                .font(DS.Font.settingsPath)
                .foregroundStyle(DS.Color.textSecondary)
        } header: {
            sectionHeader(String(localized: "settings.section.shortcut"))
        }
    }
}
