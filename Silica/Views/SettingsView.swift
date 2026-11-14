import SwiftUI

/// Settings (⌘,), laid out like System Settings: a sidebar of panes on the
/// left and the chosen pane's grouped form on the right. About (also what
/// Silica › About Silica shows) is the last pane.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, fontsAndColors, editor, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .fontsAndColors: "Fonts & Colors"
            case .editor: "Editor"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .fontsAndColors: "textformat"
            case .editor: "text.cursor"
            case .about: "info"
            }
        }

        var tint: Color {
            switch self {
            case .general: .gray
            case .fontsAndColors: .blue
            case .editor: .orange
            case .about: .gray
            }
        }
    }

    @AppStorage(SettingsView.paneKey) private var pane: Pane = .general
    static let paneKey = "settingsTab"

    var body: some View {
        // Laid out by hand rather than with NavigationSplitView, which restores the
        // sidebar width it autosaved over the width set here. The window's title bar is
        // hidden, so the traffic lights sit over the sidebar.
        HStack(spacing: 0) {
            SettingsSidebar(selection: $pane)
                .frame(width: 215)
                .background(SettingsColors.sidebar)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Clear of the hidden title bar, so the first group title lines up with
                // the first sidebar item; content still scrolls up to the window's edge.
                .contentMargins(.top, Self.titleBarHeight + 8, for: .scrollContent)
                .background(SettingsColors.detail)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
               minHeight: 460, idealHeight: 560, maxHeight: .infinity)
    }

    /// Height of the hidden title bar, which the traffic lights center in.
    static let titleBarHeight: CGFloat = 32

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettingsPane()
        case .fontsAndColors: FontsAndColorsSettingsPane()
        case .editor: EditorSettingsPane()
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

/// The list of panes: a plain light column with a gray highlight on the chosen pane,
/// rather than the List sidebar's glass and accent-colored selection. Up and down
/// arrows move between panes while it has focus.
private struct SettingsSidebar: View {
    @Binding var selection: SettingsView.Pane
    @FocusState private var isFocused: Bool

    /// Panes in visual groups, split by a gap.
    private let groups: [[SettingsView.Pane]] = [[.general, .fontsAndColors, .editor], [.about]]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.self) { group in
                    VStack(spacing: 0) {
                        ForEach(group) { pane in
                            item(pane)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, SettingsView.titleBarHeight + 18)
            .padding(.bottom, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { step(by: -1) }
        .onKeyPress(.downArrow) { step(by: 1) }
    }

    private func item(_ pane: SettingsView.Pane) -> some View {
        let isSelected = pane == selection
        return Button {
            selection = pane
            isFocused = true
        } label: {
            HStack(spacing: 10) {
                SettingsIcon(pane: pane, size: 22)
                Text(pane.title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(0.07))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func step(by offset: Int) -> KeyPress.Result {
        let all = SettingsView.Pane.allCases
        guard let index = all.firstIndex(of: selection) else { return .ignored }
        let next = index + offset
        guard all.indices.contains(next) else { return .handled }
        selection = all[next]
        return .handled
    }
}

/// Appearance, how projects open and show their files, and update checks.
private struct GeneralSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        SettingsForm {
            SettingsGroup("Appearance") {
                SettingsRow("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("System").tag(EditorSettings.Appearance.system)
                        Text("Light").tag(EditorSettings.Appearance.light)
                        Text("Dark").tag(EditorSettings.Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup("Projects") {
                SettingsToggle("Reopen a project’s tabs where you left them", isOn: $settings.restoresTabs)
                SettingsToggle("Keep parent folders in view while scrolling the file tree", isOn: $settings.pinsParentFolders)
            }

            SettingsGroup("Updates") {
                SettingsToggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                SettingsRow("Version \(AppInfo.version) (\(AppInfo.build))") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
    }
}

/// Editor font and syntax colors, with a live sample, and the sidebar's font size.
/// Changes apply to open windows at once.
private struct FontsAndColorsSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        SettingsForm {
            SettingsGroup("Font") {
                Text(highlightedSample)
                    .font(Font(settings.editorFont(ofSize: settings.fontSize)))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.06)))
                    .padding(.vertical, 3)
                SettingsPicker("Font", selection: fontFamily) {
                    Text("SF Mono (System)").tag("")
                    Divider()
                    ForEach(EditorSettings.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                SettingsRow("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.fontSize)) pt")
                            .monospacedDigit()
                        Stepper("Size", value: fontSize, in: EditorSettings.fontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            SettingsGroup("Sidebar") {
                SettingsRow("Size") {
                    HStack(spacing: 8) {
                        Text("\(Int(settings.sidebarFontSize)) pt")
                            .monospacedDigit()
                        Stepper("Sidebar size", value: $settings.sidebarFontSize,
                                in: EditorSettings.sidebarFontSizeRange, step: 1)
                            .labelsHidden()
                    }
                }
            }

            SettingsGroup("Colors") {
                SettingsPicker("Syntax colors", selection: $settings.syntaxTheme) {
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

/// What the editor shows beside the text, and indentation for new files.
private struct EditorSettingsPane: View {
    @Bindable private var settings = EditorSettings.shared

    var body: some View {
        SettingsForm {
            SettingsGroup("Display") {
                SettingsToggle("Show line numbers", isOn: $settings.showsLineNumbers)
                SettingsToggle("Show indent guides", isOn: $settings.showsIndentGuides)
                SettingsToggle("Show minimap", isOn: $settings.showsMinimap)
                SettingsToggle("Wrap long lines", isOn: $settings.wrapsLines)
            }

            SettingsGroup("Indentation") {
                SettingsPicker("Tab width", selection: $settings.tabWidth) {
                    ForEach(EditorSettings.tabWidths, id: \.self) { width in
                        Text("\(width) spaces").tag(width)
                    }
                }
                SettingsPicker("Indent new files with", selection: $settings.indentsWithTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
            } footer: {
                Text("Files that are already indented keep their own style.")
            }
        }
    }
}
