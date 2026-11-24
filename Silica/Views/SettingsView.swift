import SwiftUI

/// Settings (⌘,), laid out like System Settings: a NavigationSplitView with a sidebar
/// of panes and the chosen pane's grouped Form as its detail. About (also what
/// Silica › About Silica shows) is the last pane.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general
        case keybinds
        case fontsAndColors
        case editor
        case about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .keybinds: "Keybinds"
            case .fontsAndColors: "Fonts & Colors"
            case .editor: "Editor"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .keybinds: "keyboard"
            case .fontsAndColors: "textformat"
            case .editor: "text.cursor"
            case .about: "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: .gray
            case .keybinds: .mint
            case .fontsAndColors: .blue
            case .editor: .orange
            case .about: .gray
            }
        }
    }

    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general
    static let paneKey = "settingsTab"

    /// Panes in the sidebar's sections.
    private static let sections: [[Pane]] = [[.general, .keybinds, .fontsAndColors, .editor], [.about]]

    var body: some View {
        // A fixed sidebar: always shown, one width, no toggle button.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $pane) {
                ForEach(Self.sections, id: \.self) { panes in
                    Section {
                        ForEach(panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                SettingsIcon(pane: pane, size: 20)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
            .toolbar(removing: .sidebarToggle)
            // Last, or the column ignores the width and comes out narrower.
            .navigationSplitViewColumnWidth(min: 215, ideal: 215, max: 215)
        } detail: {
            detail
                .formStyle(.grouped)
        }
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .fontsAndColors: FontsAndColorsSettingsPane()
        case .editor: EditorSettingsPane()
        case .keybinds: KeybindSettingsPane()
        case .about: AboutSettingsView()
        }
    }
}

/// A pane's symbol in white on a tinted rounded square, as System Settings draws them.
struct SettingsIcon: View {
    let pane: SettingsView.Pane
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(pane.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: General

/// Appearance, how projects open and show their files, and update checks.
private struct GeneralSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    @ObservedObject private var updater = AppUpdater.shared
    /// The link on PATH that runs this copy's `silica` script, once installed.
    @State private var commandPath = CommandLineTool.installedPath
    /// While the password prompt is up, so a second click doesn't raise another.
    @State private var isInstallingCommand = false

    private let commandHint = "Open a project from the terminal with “silica .”, or a file with “silica <file>”."

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag(EditorSettings.Appearance.system)
                    Text("Light").tag(EditorSettings.Appearance.light)
                    Text("Dark").tag(EditorSettings.Appearance.dark)
                }
                .tabsPickerStyle()
                Picker("Background", selection: $settings.windowBackground) {
                    Text("Translucent").tag(EditorSettings.WindowBackground.translucent)
                    Text("Opaque").tag(EditorSettings.WindowBackground.opaque)
                }
                .tabsPickerStyle()
                // Liquid Glass came with macOS 26; earlier versions always get the plain cards.
                if #available(macOS 26.0, *) {
                    Toggle("Glass effect", isOn: $settings.usesGlassEffect)
                }
            }

            Section("Projects") {
                Toggle("Reopen a project’s tabs where you left them", isOn: $settings.restoresTabs)
                Toggle("Keep parent folders in view while scrolling the file tree", isOn: $settings.pinsParentFolders)
                Toggle("Fetch from a project’s git remote every few minutes", isOn: $settings.fetchesAutomatically)
                    .help("Keeps the count of commits to pull current without pressing Fetch. If you approve each use of your SSH key, you’d be asked each time.")
            }

            Section {
                LabeledContent("“\(CommandLineTool.name)” command") {
                    if let commandPath {
                        Text("Installed in \((commandPath as NSString).deletingLastPathComponent)")
                    } else {
                        Button("Install") {
                            isInstallingCommand = true
                            Task {
                                await CommandLineTool.install()
                                commandPath = CommandLineTool.installedPath
                                isInstallingCommand = false
                            }
                        }
                        .disabled(isInstallingCommand || CommandLineTool.unavailableReason != nil)
                    }
                }
            } header: {
                Text("Command Line")
            } footer: {
                Text(commandPath == nil ? CommandLineTool.unavailableReason ?? commandHint : commandHint)
            }
            // Coming back from Terminal, where the command may just have been installed.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                commandPath = CommandLineTool.installedPath
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(AppInfo.version) (\(AppInfo.build))") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }
}

// MARK: Fonts & Colors

/// Editor font and syntax colors, with a live sample, and the sidebar's font size.
/// Changes apply to open windows at once.
private struct FontsAndColorsSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section("Font") {
                Text(highlightedSample)
                    .font(Font(settings.editorFont(ofSize: settings.fontSize)))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.06)))
                    .padding(.vertical, 3)
                Picker("Font", selection: fontFamily) {
                    Text("SF Mono (System)").tag("")
                    Divider()
                    ForEach(EditorSettings.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                        Stepper("Size", value: fontSize, in: EditorSettings.fontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            Section("Sidebar") {
                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.sidebarFontSize)) pt")
                            .monospacedDigit()
                        Stepper("Sidebar size", value: $settings.sidebarFontSize,
                                in: EditorSettings.sidebarFontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            Section("Colors") {
                Picker("Syntax colors", selection: $settings.syntaxTheme) {
                    ForEach(SyntaxTheme.allCases) { theme in
                        Text(theme.name).tag(theme)
                    }
                }
            }
        }
    }

    private var sample: String {
        let indent = String(repeating: " ", count: settings.tabWidth)
        return "// Says hello.\nfunc greet(_ name: String) -> String {\n"
            + indent + "let count = 2\n"
            + indent + "return \"Hello, \\(name)!\"\n}"
    }

    /// The sample, colored by the chosen theme the way the editor colors Swift.
    private var highlightedSample: AttributedString {
        let text = sample
        var result = AttributedString(text)
        let theme = settings.syntaxTheme
        for token in SyntaxLanguage.swift.tokenizer.tokenize(text as NSString) {
            guard let range = Range(token.range, in: result) else { continue }
            result[range].foregroundColor = Color(nsColor: theme.color(for: token.kind))
        }
        return result
    }

    /// "" stands for the system font in the picker.
    private var fontFamily: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "" },
            set: { settings.fontFamily = $0.isEmpty ? nil : $0 }
        )
    }

    private var fontSize: Binding<CGFloat> {
        Binding(
            get: { settings.fontSize },
            set: { settings.setFontSize($0) }
        )
    }
}

// MARK: Editor

/// What the editor shows beside the text, and indentation for new files.
private struct EditorSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show line numbers", isOn: $settings.showsLineNumbers)
                Toggle("Show indent guides", isOn: $settings.showsIndentGuides)
                Toggle("Show minimap", isOn: $settings.showsMinimap)
                Toggle("Wrap long lines", isOn: $settings.wrapsLines)
            }

            Section {
                Picker("Tab width", selection: $settings.tabWidth) {
                    ForEach(EditorSettings.tabWidths, id: \.self) { width in
                        Text("\(width) spaces").tag(width)
                    }
                }
                Picker("Indent new files with", selection: $settings.indentsWithTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
            } header: {
                Text("Indentation")
            } footer: {
                Text("Files that are already indented keep their own style.")
            }
        }
    }
}

// MARK: Keybinds

/// Keybind configuration and options.
private struct KeybindSettingsPane: View {
    @Bindable private var keybinds = KeybindSettings.shared
    @State private var recording: ConfigKeyCommand?
    @State private var restoreError: String?
    /// A preset chosen while some keybinds are custom, waiting for the user to confirm
    /// that switching drops them.
    @State private var pendingPreset: KeybindFile?
    
    /// The active preset, and whether keybinds have been changed on top of it.
    private var presetLabel: String {
        let title = keybinds.activePreset.title
        return keybinds.hasCustomKeybinds ? "\(title) (Custom)" : title
    }
    
    /// Switches presets, asking first if that would drop custom keybinds.
    private var presetSelection: Binding<KeybindFile.ID> {
        Binding {
            keybinds.activePresetId
        } set: { id in
            guard id != keybinds.activePresetId,
                  let preset = keybinds.presets.first(where: { $0.id == id }) else { return }
            if keybinds.hasCustomKeybinds {
                pendingPreset = preset
            } else {
                try? keybinds.setActivePreset(id: id)
            }
        }
    }
    
    var body: some View {
        Form {
            Section {
                LabeledContent("Preset") {
                    HStack {
                        Menu(presetLabel) {
                            // A picker, so the active preset has a checkmark.
                            Picker("Preset", selection: presetSelection) {
                                ForEach(keybinds.presets) { preset in
                                    Text(preset.title).tag(preset.id)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
            Section("Configurable") {
                ForEach(ConfigKeyCommand.allCases) { command in
                    LabeledContent(keybinds.title(for: command)) {
                        HStack(spacing: 8) {
                            Button(keybinds.keybind(for: command).displayName) {
                                recording = command
                            }
                            .buttonStyle(.bordered)
                            
                            if let clash = keybinds.layoutClash(for: command) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("Same keystroke as \(clash) on this keyboard layout")
                                    .accessibilityLabel("Same keystroke as \(clash) on this keyboard layout")
                            }
                            
                            if !keybinds.isDefaultKeybind(for: command) {
                                Button {
                                    do {
                                        try keybinds.setKeybind(nil, for: command)
                                    } catch {
                                        restoreError = error.localizedDescription
                                    }
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Restore Default")
                                .accessibilityLabel("Restore Default for \(keybinds.title(for: command))")
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        keybinds.reset()
                    }
                    .disabled(ConfigKeyCommand.allCases.allSatisfy {
                        keybinds.isDefaultKeybind(for: $0)
                    })
                }
            }
            Section("Fixed") {
                ForEach(FixedKeyCommand.allCases) { command in
                    fixedRow(keybinds.title(for: command), keybinds.keybind(for: command))
                }
            }
            Section("Reserved") {
                ForEach(SystemKeyCommand.allCases) { command in
                    fixedRow(command.title, command.keybind)
                }
            }
        }
        .sheet(item: $recording) {
            KeybindRecorderView(
                command: $0,
                keybinds: keybinds
            )
        }
        .alert(
            pendingPreset.map { "Switch to the \($0.title) Preset?" } ?? "",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            presenting: pendingPreset
        ) { preset in
            Button("Switch", role: .destructive) {
                try? keybinds.setActivePreset(id: preset.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(keybinds.customKeybindCount == 1
                 ? "Your custom keybind will be replaced by the preset’s."
                 : "Your \(keybinds.customKeybindCount) custom keybinds will be replaced by the preset’s.")
        }
        .alert(
            "Can’t Restore the Default Keybind",
            isPresented: Binding(get: { restoreError != nil }, set: { if !$0 { restoreError = nil } }),
            presenting: restoreError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text("\(message) Change that command’s keybind first.")
        }
    }
    
    private func fixedRow(_ title: String, _ keybind: Keybind) -> some View {
        LabeledContent(title) {
            Button(keybind.displayName) {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
    }
}

private struct KeybindRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var eventMonitor: Any?
    @State private var errorMessage: String?
    /// The sheet's window. Only keys typed there are recorded; the project windows stay
    /// usable while the sheet is open.
    @State private var window: NSWindow?
    
    let command: ConfigKeyCommand
    let keybinds: KeybindSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record Keybind")
                .font(.headline)

            Text("Press a key combination for “\(keybinds.title(for: command))”, or Esc to cancel.")
                .foregroundStyle(.secondary)
            
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(WindowReader { newWindow in
            window = newWindow
            if let newWindow { keybinds.recorderWindow = newWindow }
        })
        .onAppear(perform: startEventMonitor)
        .onDisappear(perform: stopEventMonitor)
    }
    
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            record($0)
        }
    }
    
    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        if keybinds.isRecorderWindow(window) { keybinds.recorderWindow = nil }
    }
    
    private func record(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.isEmpty, event.keyCode == 53 { // Esc
            dismiss()
            return nil
        }
        guard let keybind = Keybind(event: event) else {
            errorMessage = "Keybind must contain ⌘, ⌥ or ⌃, and a valid key."
            return nil
        }

        do {
            try keybinds.setKeybind(keybind, for: command)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        // Prevent the captured shortcut from invoking
        // a menu command while recording.
        return nil
    }
}

// MARK: Helpers

/// Reports the window its view is in, and nil when the view leaves it.
private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onChange: onChange)
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let onChange: (NSWindow?) -> Void

        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// A turn later: this can be reached during a SwiftUI update, where changing
        /// the recorder's state isn't allowed.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onChange] in onChange(window) }
        }
    }
}

private extension View {
    /// The capsule tabs treatment macOS 27 gives a picker, or plain segments before it.
    @ViewBuilder
    func tabsPickerStyle() -> some View {
        if #available(macOS 27.0, *) {
            pickerStyle(.tabs)
                .buttonBorderShape(.capsule)
        } else {
            pickerStyle(.segmented)
        }
    }
}
