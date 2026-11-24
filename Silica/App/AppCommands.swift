import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    /// The project in the key window. Tracked from AppKit key-window changes, since
    /// `focusedSceneValue` came back nil while the editor's NSTextView had focus.
    @ObservedObject private var keyWorkspace = KeyWorkspace.shared
    private var workspace: WorkspaceModel? { keyWorkspace.current }
    @ObservedObject private var updater = AppUpdater.shared

    private var recents: RecentProjectsStore { .shared }
    private var settings: EditorSettings { .shared }
    private var keybinds: MenuKeybinds {
        MenuKeybinds(settings: .shared, terminalHasFocus: workspace?.terminal?.isFocused == true)
    }
    private var opener: ProjectOpener { ProjectOpener(openWindow: openWindow) }

    /// "Show Markdown", "Show CSV" or "Show HTML" while the preview is up, to go back to the source.
    private var previewToggleTitle: String {
        guard let workspace, let buffer = workspace.activeBuffer, workspace.showsPreview(buffer, in: workspace.focusedPane),
              let format = buffer.previewFormat else { return "Show Preview" }
        return "Show \(format.sourceName)"
    }

    var body: some Commands {
        // Lets Finder's open requests at launch open windows before any exists.
        let _ = ExternalOpener.shared.provide(openWindow)

        // About lives in Settings, next to the open-source licenses.
        CommandGroup(replacing: .appInfo) {
            Button("About Silica") {
                UserDefaults.standard.set(SettingsView.Pane.about.rawValue, forKey: SettingsView.paneKey)
                openWindow(id: WindowID.settings)
            }

            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }

        // Settings is a regular Window scene (so it can resize), which doesn't get
        // the Settings… item on its own.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: WindowID.settings) }
                .keybindShortcut(for: .settings, keybinds)
        }

        CommandGroup(replacing: .newItem) {
            Button("New File") { workspace?.newUntitledFile() }
                .keybindShortcut(for: .newFile, keybinds)
                .disabled(workspace == nil)

            Button("New File in Project…") { workspace?.beginNewItem(isDirectory: false) }
                .disabled(workspace == nil)

            Button("New Folder") { workspace?.beginNewItem(isDirectory: true) }
                .keybindShortcut(for: .newFolder, keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Open…") { opener.chooseAndOpen() }
                .keybindShortcut(for: .open, keybinds)

            Menu("Open Recent") {
                ForEach(recents.projects) { project in
                    Button(project.name) { opener.open(project) }
                }
                Divider()
                Button("Clear Menu") { recents.clear() }
                    .disabled(recents.projects.isEmpty)
            }

            Divider()

            Button("Quick Open…") { workspace?.toggleQuickOpen() }
                .keybindShortcut(for: .quickOpen, keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Welcome Window") { openWindow(id: WindowID.welcome) }
                .keybindShortcut(for: .welcomeWindow, keybinds)
        }

        // No printing; ⌘P is Quick Open, as in other code editors.
        CommandGroup(replacing: .printItem) {}

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspace?.saveActive() }
                .keybindShortcut(for: .save, keybinds)
                .disabled(workspace?.activeBuffer.map { $0.isDirty || $0.isUntitled } != true)

            Button("Save As…") { workspace?.saveActiveAs() }
                .keybindShortcut(for: .saveAs, keybinds)
                .disabled(workspace?.activeBuffer?.textController == nil)

            Button("Save All") { workspace?.saveAll() }
                .keybindShortcut(for: .saveAll, keybinds)
                .disabled(workspace?.hasUnsavedChanges != true)

            Divider()

            // As in VS Code: ⌘W closes the tab, a pane that has none left, and the
            // window once the last pane has none.
            Button("Close Tab") {
                if let workspace, workspace.activeTab != nil {
                    workspace.closeActiveTab()
                } else if let workspace, workspace.layout.isSplit {
                    workspace.closePane()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keybindShortcut(for: .closeTab, keybinds)

            // Its keybind is also handled by KeyWorkspace.installKeyboardShortcuts().
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keybindShortcut(for: .closeWindow, keybinds)
        }

        CommandGroup(replacing: .sidebar) {
            Button(workspace?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                workspace?.toggleSidebar()
            }
            .keybindShortcut(for: .toggleSidebar, keybinds)
            .disabled(workspace == nil)

            // Explorer's, Find in Project's and Save As's keybinds are also handled by
            // KeyWorkspace.installKeyboardShortcuts().
            Button("Explorer") { workspace?.showExplorer() }
                .keybindShortcut(for: .explorer, keybinds)
                .disabled(workspace == nil)

            Button("Find in Project") { workspace?.showSearch() }
                .keybindShortcut(for: .findInProject, keybinds)
                .disabled(workspace == nil)

            Button("Source Control") { workspace?.showChanges() }
                .keybindShortcut(for: .sourceControl, keybinds)
                .disabled(workspace?.git.isRepository != true)

            Button("Filter Files") { workspace?.focusTreeFilter() }
                .keybindShortcut(for: .filterTreeFiles, keybinds)
                .disabled(workspace == nil)

            Button("Refresh Explorer") { workspace?.refresh() }
                .keybindShortcut(for: .refreshExplorer, keybinds)
                .disabled(workspace == nil)

            Divider()

            Button("Terminal") { workspace?.toggleTerminal() }
                .keybindShortcut(for: .toggleTerminal, keybinds)
                .disabled(workspace == nil)

            Button("New Terminal") { workspace?.newTerminal() }
                .keybindShortcut(for: .newTerminal, keybinds)
                .disabled(workspace == nil)

            Button("Clear Terminal") { workspace?.terminal?.clear() }
                .keybindShortcut(for: .clearTerminal, keybinds)
                .disabled(workspace?.terminal?.isFocused != true)

            Divider()

            // Its keybind is also handled by KeyWorkspace.installKeyboardShortcuts().
            Button(previewToggleTitle) {
                workspace?.togglePreview()
            }
            .keybindShortcut(for: .togglePreview, keybinds)
            .disabled(workspace?.activeBuffer?.previewFormat == nil)

            // In the focused pane: another pane with the file open may be showing them.
            let showsChanges = workspace.flatMap { workspace in
                workspace.activeBuffer.map { workspace.showsChanges($0, in: workspace.focusedPane) }
            } == true

            Button(showsChanges ? "Hide Changes" : "Show Changes") {
                workspace?.toggleChanges()
            }
            .disabled(!showsChanges && workspace?.activeBuffer.map { workspace?.hasChanges($0) == true } != true)

            Toggle("Changes Side by Side", isOn: Binding(
                get: { settings.showsChangesSideBySide },
                set: { settings.showsChangesSideBySide = $0 }
            ))

            Button("Show File History") {
                if let url = workspace?.activeBuffer?.url { workspace?.showFileHistory(url) }
            }
            .disabled(workspace?.git.isRepository != true || workspace?.activeBuffer?.isUntitled != false)

            Toggle("Line Blame", isOn: Binding(
                get: { settings.showsLineBlame },
                set: { settings.showsLineBlame = $0 }
            ))

            Divider()

            // The file tabs: Silica's windows don't have macOS window tabs (see
            // AppDelegate), so ⌃Tab is free for them. ⇧⌘] and ⇧⌘[ do the same unless
            // a keybind uses them; see KeyWorkspace.installKeyboardShortcuts().
            // From a terminal with others beside it, they step through the terminals.
            let hasOtherTabs = workspace?.canSelectOtherTab == true

            Button("Select Next Tab") { workspace?.selectTab(offsetBy: 1) }
                .keybindShortcut(for: .selectNextTab, keybinds)
                .disabled(!hasOtherTabs)

            Button("Select Previous Tab") { workspace?.selectTab(offsetBy: -1) }
                .keybindShortcut(for: .selectPreviousTab, keybinds)
                .disabled(!hasOtherTabs)

            Divider()

            // The panes' keybinds are also handled by KeyWorkspace.installKeyboardShortcuts().
            let isSplit = workspace?.layout.isSplit == true

            Button("Split Right") { workspace?.splitPane(.horizontal) }
                .keybindShortcut(for: .splitRight, keybinds)
                .disabled(workspace == nil)

            Button("Split Down") { workspace?.splitPane(.vertical) }
                .keybindShortcut(for: .splitDown, keybinds)
                .disabled(workspace == nil)

            Button("Focus Next Pane") { workspace?.focusPane(offsetBy: 1) }
                .keybindShortcut(for: .focusNextPane, keybinds)
                .disabled(!isSplit)

            Button("Focus Previous Pane") { workspace?.focusPane(offsetBy: -1) }
                .keybindShortcut(for: .focusPreviousPane, keybinds)
                .disabled(!isSplit)

            Button("Close Pane") { workspace?.closePane() }
                .keybindShortcut(for: .closePane, keybinds)
                .disabled(!isSplit)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            Toggle("Word Wrap", isOn: Binding(
                get: { settings.wrapsLines },
                set: { settings.wrapsLines = $0 }
            ))
            .keybindShortcut(for: .toggleWordWrap, keybinds)

            Toggle("Minimap", isOn: Binding(
                get: { settings.showsMinimap },
                set: { settings.showsMinimap = $0 }
            ))

            Divider()

            // ⌘= also zooms in when nothing else uses it; see
            // EditorSettings.installKeyboardShortcuts().
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keybindShortcut(for: .increaseFontSize, keybinds)
                .disabled(!settings.canIncreaseFontSize)

            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keybindShortcut(for: .decreaseFontSize, keybinds)
                .disabled(!settings.canDecreaseFontSize)

            Button("Reset Font Size") { settings.resetFontSize() }
                .keybindShortcut(for: .resetFontSize, keybinds)
                .disabled(settings.isDefaultFontSize)
        }

        CommandMenu("Editor") {
            let hasText = workspace?.activeBuffer?.textController != nil

            Button("Go to Line…") { workspace?.showGoToLine() }
                .keybindShortcut(for: .goToLine, keybinds)
                .disabled(!hasText)

            Divider()

            configurableEditorAction("Toggle Comment", .toggleComment, #selector(EditorTextView.toggleComment(_:)))
            fixedEditorAction("Indent", .indent, #selector(EditorTextView.indentLines(_:)))
            fixedEditorAction("Outdent", .outdent, #selector(EditorTextView.outdentLines(_:)))

            Divider()

            configurableEditorAction("Move Line Up", .moveLineUp, #selector(EditorTextView.moveLinesUp(_:)))
            configurableEditorAction("Move Line Down", .moveLineDown, #selector(EditorTextView.moveLinesDown(_:)))
            configurableEditorAction("Duplicate Line Up", .duplicateLineUp, #selector(EditorTextView.duplicateLinesUp(_:)))
            configurableEditorAction("Duplicate Line Down", .duplicateLineDown, #selector(EditorTextView.duplicateLinesDown(_:)))
        }
    }
    
    private func fixedEditorAction(
        _ title: String,
        _ command: FixedKeyCommand,
        _ action: Selector
    ) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keybindShortcut(for: command, keybinds)
            .disabled(workspace?.activeBuffer?.textController == nil)
    }
    
    private func configurableEditorAction(
        _ title: String,
        _ command: ConfigKeyCommand,
        _ action: Selector
    ) -> some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keybindShortcut(for: command, keybinds)
            .disabled(workspace?.activeBuffer?.textController == nil)
    }
}

/// The keybinds as the menus apply them. While the terminal has focus, a keybind
/// without ⌘ is left to the shell (⌃R searches its history, ⌃G cancels that): the
/// terminal doesn't take key equivalents, so a menu item would get the key first.
private struct MenuKeybinds {
    let settings: KeybindSettings
    let terminalHasFocus: Bool

    func shortcut(for command: FixedKeyCommand) -> KeyboardShortcut? {
        settings.keybind(for: command).shortcut
    }

    func shortcut(for command: ConfigKeyCommand) -> KeyboardShortcut? {
        let keybind = settings.keybind(for: command)
        return terminalHasFocus && command.leavesToShell(keybind) ? nil : keybind.shortcut
    }
}

private extension View {
    func keybindShortcut(for command: FixedKeyCommand, _ keybinds: MenuKeybinds) -> some View {
        keyboardShortcut(keybinds.shortcut(for: command))
    }

    func keybindShortcut(for command: ConfigKeyCommand, _ keybinds: MenuKeybinds) -> some View {
        keyboardShortcut(keybinds.shortcut(for: command))
    }
}
