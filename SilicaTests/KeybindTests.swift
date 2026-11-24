import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing

private let presetsFolder = URL(filePath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Silica/Keybinds/Presets")

private func preset(_ id: String) throws -> KeybindFile {
    try KeybindFile.load(from: presetsFolder.appending(path: "\(id).silicakb"))
}

private func keybind(_ key: String, _ modifiers: Keybind.Modifiers) -> Keybind {
    Keybind(key: key, modifiers: modifiers)!
}

/// `file` with one configurable binding changed.
private func replacing(_ id: ConfigKeyCommand, in file: KeybindFile, key: String, mods: [KeybindFile.Binding.Modifier]) -> KeybindFile {
    KeybindFile(
        id: file.id,
        version: file.version,
        title: file.title,
        fixed: file.fixed,
        configurable: file.configurable.map {
            $0.id == id.id ? .init(id: $0.id, title: $0.title, key: key, mods: mods) : $0
        }
    )
}

/// A key press as AppKit would deliver it, for the key with `keyCode` on this Mac's layout.
private func keyDown(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
    )!
}

/// Whether this Mac's layout puts 1 and V where a U.S. keyboard does, which the event
/// tests assume.
private let hasUSKeys = keyDown(18, []).characters(byApplyingModifiers: []) == "1"
    && keyDown(9, []).characters(byApplyingModifiers: []) == "v"
    && keyDown(24, []).characters(byApplyingModifiers: []) == "="

/// A layout given as the characters of its keys, unshifted and shifted, in the same
/// order, so tests don't depend on the Mac's own layout.
private struct FakeLayout: KeyboardLayout {
    let unshifted: [Character]
    let shifted: [Character]

    func key(typing character: Character, withCommand: Bool) -> (keyCode: UInt16, modifiers: Keybind.Modifiers)? {
        if let index = unshifted.firstIndex(of: character) { return (UInt16(index), []) }
        if let index = shifted.firstIndex(of: character) { return (UInt16(index), .shift) }
        return nil
    }

    static let us = FakeLayout(
        unshifted: Array("1234567890-=qwertyuiop[]\\asdfghjkl;'`zxcvbnm,./"),
        shifted: Array("!@#$%^&*()_+qwertyuiop{}|asdfghjkl:\"~zxcvbnm<>?")
    )
    static let german = FakeLayout(
        unshifted: Array("1234567890ßqwertzuiopü+asdfghjklöä#<yxcvbnm,.-"),
        shifted: Array("!\"§$%&/()=?qwertzuiopü*asdfghjklöä'>yxcvbnm;:_")
    )
}

@Suite("Keybind")
struct KeybindTests {
    @Test(.enabled("needs a layout with U.S. key positions") { await hasUSKeys })
    func eventsGiveTheUnshiftedKey() {
        // ⇧⌘1 is "1" with ⇧⌘, as presets write it, not "!".
        #expect(Keybind(event: keyDown(18, [.shift, .command])) == keybind("1", [.shift, .command]))
        #expect(Keybind(event: keyDown(18, [.shift, .command]))?.key == "1")
        #expect(Keybind(event: keyDown(9, .command)) == keybind("v", .command))
        #expect(Keybind(event: keyDown(9, [.option, .command])) == keybind("v", [.option, .command]))
        // ⇧⌘= is the same keystroke as the menus' ⌘+.
        #expect(Keybind(event: keyDown(24, [.shift, .command])) == keybind("+", .command))
    }

    @Test(.enabled("needs a layout with U.S. key positions") { await hasUSKeys })
    func eventsWithoutCommandOptionOrControlAreNotKeybinds() {
        #expect(Keybind(event: keyDown(9, [])) == nil)
        #expect(Keybind(event: keyDown(9, .shift)) == nil)
    }

    @Test(.enabled("needs a layout with U.S. key positions") { await hasUSKeys })
    func currentLayoutFindsKeys() {
        let layout = CurrentKeyboardLayout.shared
        #expect(layout.key(typing: "/", withCommand: true)?.keyCode == 44)
        #expect(layout.key(typing: "/", withCommand: true)?.modifiers == [])
        #expect(layout.key(typing: "?", withCommand: true)?.modifiers == .shift)
        #expect(layout.key(typing: "=", withCommand: false)?.keyCode == 24)
        // Not the keypad's "+": the menus' ⌘+ is ⇧ and the = key.
        #expect(layout.key(typing: "+", withCommand: true)?.keyCode == 24)
        // A Latin layout reads keys from the event itself.
        #expect(layout.latinCharacter(forKeyCode: 5, withCommand: false) == nil)
    }

    @Test func decodingRejectsAnUnusableKey() throws {
        let json = Data(#"{"key":"","modifiers":1}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Keybind.self, from: json) }
        let good = try JSONDecoder().decode(Keybind.self, from: Data(#"{"key":"p","modifiers":1}"#.utf8))
        #expect(good == keybind("p", .command))
    }

    @Test func onlyTerminalCommandsKeepKeysWithoutCommand() {
        #expect(ConfigKeyCommand.goToLine.leavesToShell(keybind("g", .control)))
        #expect(!ConfigKeyCommand.goToLine.leavesToShell(keybind("l", .command)))
        #expect(!ConfigKeyCommand.toggleTerminal.leavesToShell(keybind("`", .control)))
        #expect(!ConfigKeyCommand.selectNextTab.leavesToShell(Keybind(key: .tab, modifiers: .control)!))
    }

    @Test func sameKeystrokeIsEqual() {
        // How menus write a shifted key, and how the recorder sees it on a US keyboard.
        #expect(keybind("+", .command) == keybind("=", [.shift, .command]))
        #expect(keybind("!", .command) == keybind("1", [.shift, .command]))
        #expect(keybind("}", .command) == keybind("]", [.shift, .command]))
        #expect(keybind("P", .command) == keybind("p", .command))
        #expect(Set([keybind("+", .command), keybind("=", [.shift, .command])]).count == 1)
    }

    @Test func differentKeystrokesDiffer() {
        #expect(keybind("+", .command) != keybind("=", .command))
        #expect(keybind("1", .command) != keybind("1", [.shift, .command]))
    }

    @Test func displayNameUsesMenuOrder() {
        #expect(keybind("1", [.command, .shift]).displayName == "⇧⌘1")
        #expect(keybind("s", [.command, .control]).displayName == "⌃⌘S")
        #expect(keybind("n", [.command, .option]).displayName == "⌥⌘N")
        #expect(Keybind(key: .tab, modifiers: [.shift, .control])!.displayName == "⌃⇧Tab")
        // Return as macOS menus write it.
        #expect(Keybind(key: .return, modifiers: [.option, .command])!.displayName == "⌥⌘↩")
    }

    @Test func optionWithLetterTypesCharacter() {
        #expect(keybind("z", .option).typesCharacter)
        #expect(keybind("z", [.option, .shift]).typesCharacter)
        #expect(!keybind("z", [.option, .command]).typesCharacter)
        #expect(!Keybind(key: .upArrow, modifiers: .option)!.typesCharacter)
        // A no-break space, a tab and a line break: only the arrows are function keys.
        #expect(Keybind(key: .space, modifiers: .option)!.typesCharacter)
        #expect(Keybind(key: .tab, modifiers: .option)!.typesCharacter)
        #expect(Keybind(key: .return, modifiers: [.option, .shift])!.typesCharacter)
    }

    @Test func needsCommandOptionOrControl() {
        #expect(Keybind(key: "a", modifiers: []) == nil)
        #expect(Keybind(key: "a", modifiers: .shift) == nil)
    }
}

@Suite("KeybindFile")
struct KeybindFileTests {
    @Test(arguments: ["silica", "vscode", "xcode"])
    func bundledPresetLoads(id: String) throws {
        let file = try preset(id)
        #expect(file.id == id)
    }

    @Test func rejectsTwoCommandsOnOneKeystroke() throws {
        // ⇧⌘+ is ⌘+ (Increase Font Size) on a US keyboard.
        let file = replacing(.resetFontSize, in: try preset("silica"), key: "+", mods: [.shift, .command])
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(file) }
    }

    @Test func rejectsAnOptionKeyThatTypes() throws {
        let file = replacing(.quickOpen, in: try preset("silica"), key: "p", mods: [.option])
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(file) }
    }

    @Test func rejectsAFixedKeyWithoutCommand() throws {
        let file = try preset("silica")
        let fixed = file.fixed.map {
            $0.id == FixedKeyCommand.save.id ? .init(id: $0.id, title: $0.title, key: "s", mods: [.control]) : $0
        }
        let changed = KeybindFile(id: file.id, version: file.version, title: file.title, fixed: fixed, configurable: file.configurable)
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(changed) }
    }

    @Test func rejectsASystemShortcut() throws {
        let file = replacing(.quickOpen, in: try preset("silica"), key: "c", mods: [.command])
        #expect(throws: KeybindFile.LoadError.self) { try KeybindFile.validateFile(file) }
    }
}

@Suite("KeybindSettings")
final class KeybindSettingsTests {
    let suiteName = "KeybindSettingsTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let presets: [KeybindFile]

    init() throws {
        defaults = UserDefaults(suiteName: suiteName)!
        presets = try ["silica", "vscode", "xcode"].map(preset)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func settings(layout: KeyboardLayout = FakeLayout.us) -> KeybindSettings {
        KeybindSettings(presets: presets, defaults: defaults, layout: layout)
    }

    @Test func keystrokesCompareThroughTheLayout() throws {
        // On a German layout "/" is ⇧7, so a recorded ⇧⌘7 is Toggle Comment's ⌘/.
        let shiftCommand7 = keybind("7", [.shift, .command])
        let german = settings(layout: FakeLayout.german)
        #expect(german.isSameKeystroke(keybind("/", .command), shiftCommand7))
        #expect(throws: KeybindSettings.Error.commandConflict(shiftCommand7, "Toggle Comment")) {
            try german.setKeybind(shiftCommand7, for: .quickOpen)
        }
        // On a U.S. layout ⇧⌘7 is ⌘&, which nothing uses.
        let us = settings(layout: FakeLayout.us)
        #expect(!us.isSameKeystroke(keybind("/", .command), shiftCommand7))
        try us.setKeybind(shiftCommand7, for: .quickOpen)
        #expect(us.keybind(for: .quickOpen) == shiftCommand7)
    }

    @Test func recordedShiftedDigitConflicts() {
        // The recorder sees ⇧⌘1 as "1" with ⇧⌘; a menu-style "!" with ⌘ is the same key.
        let settings = settings()
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("1", [.shift, .command]), "Welcome Window")) {
            try settings.setKeybind(keybind("1", [.shift, .command]), for: .quickOpen)
        }
        #expect(throws: KeybindSettings.Error.self) {
            try settings.setKeybind(keybind("!", .command), for: .quickOpen)
        }
    }

    @Test func systemShortcutConflicts() {
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("c", .command), "Copy")) {
            try settings().setKeybind(keybind("c", .command), for: .quickOpen)
        }
    }

    // Keys and modifiers as preset files write them: the arguments are built off the
    // main actor, where Keybind can't be.
    @Test(arguments: [
        ("f", ["cmd"], "Find"),
        ("g", ["shift", "cmd"], "Find Previous"),
        (";", ["shift", "cmd"], "Show Spelling and Grammar"),
        ("f", ["ctrl", "cmd"], "Enter Full Screen"),
        ("q", ["opt", "cmd"], "Quit and Keep Windows"),
        ("⏎", ["cmd"], "Commit (in the commit message)"),
        ("space", ["ctrl", "cmd"], "Emoji & Symbols"),
        ("/", ["shift", "cmd"], "Silica Help"),
    ])
    func editAndWindowMenuShortcutsConflict(key: String, mods: [String], title: String) throws {
        let binding = KeybindFile.Binding(id: "", title: "", key: key, mods: mods.compactMap { .init(rawValue: $0) })
        let keybind = try #require(binding.asKeybind())
        #expect(throws: KeybindSettings.Error.commandConflict(keybind, title)) {
            try settings().setKeybind(keybind, for: .goToLine)
        }
    }

    @Test func controlTabIsFreeForAnyCommand() throws {
        // Without window tabs, nothing keeps ⌃Tab back for the Window menu.
        let settings = settings()
        try settings.setActivePreset(id: "vscode") // ⌃Tab is free there.
        let controlTab = Keybind(key: .tab, modifiers: .control)!
        try settings.setKeybind(controlTab, for: .quickOpen)
        #expect(settings.keybind(for: .quickOpen) == controlTab)
    }

    @Test(.enabled("needs a layout with U.S. key positions") { await hasUSKeys })
    func shiftedMenuKeysClashOnTheRealLayout() {
        // The ⌘ table ignores Shift, so ⌘+ and ⌘? have to come from the Shift table.
        let settings = settings(layout: CurrentKeyboardLayout.shared)
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("=", [.shift, .command]), "Increase Font Size")) {
            try settings.setKeybind(keybind("=", [.shift, .command]), for: .quickOpen)
        }
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("/", [.shift, .command]), "Silica Help")) {
            try settings.setKeybind(keybind("/", [.shift, .command]), for: .quickOpen)
        }
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("1", [.shift, .command]), "Welcome Window")) {
            try settings.setKeybind(keybind("1", [.shift, .command]), for: .quickOpen)
        }
    }

    /// A layout macOS has installed, enabled or not.
    private static func installed(_ id: String) throws -> KeyboardLayoutTable {
        try #require(KeyboardLayoutTable(inputSourceID: "com.apple.keylayout.\(id)"))
    }

    @Test func realLayoutsPutKeysWhereTheyAre() throws {
        // German: "/" is ⇧7 and "]" is ⌥6.
        let german = settings(layout: try Self.installed("German"))
        #expect(german.isSameKeystroke(keybind("/", .command), keybind("7", [.shift, .command])))
        #expect(german.isSameKeystroke(keybind("]", .command), keybind("6", [.option, .command])))
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("6", [.option, .command]), "Indent")) {
            try german.setKeybind(keybind("6", [.option, .command]), for: .quickOpen)
        }
        // French types digits with Shift, even with ⌘ held.
        let french = settings(layout: try Self.installed("French"))
        #expect(french.isSameKeystroke(keybind("1", .command), keybind("&", [.shift, .command])))
        // "Dvorak – QWERTY ⌘": with ⌘ held the keys are QWERTY's, so ⌘: is ⇧⌘ and the
        // QWERTY ; key, and not ⇧⌘Z (Redo).
        let dvorak = settings(layout: try Self.installed("DVORAK-QWERTYCMD"))
        #expect(dvorak.isSameKeystroke(keybind(":", .command), keybind(";", [.shift, .command])))
        #expect(!dvorak.isSameKeystroke(keybind(":", .command), keybind("z", [.shift, .command])))
    }

    @Test func aPresetsOwnClashesAreNotFlagged() throws {
        // On German, ` needs Shift, so Toggle Terminal's ⌃` and New Terminal's ⌃⇧` are
        // one keystroke, as they are in the editors the presets follow.
        let german = settings(layout: try Self.installed("German"))
        #expect(german.isKeybind(keybind("`", [.control, .shift]), of: .toggleTerminal))
        #expect(german.layoutClash(for: .toggleTerminal) == nil)
        #expect(german.layoutClash(for: .newTerminal) == nil)
        // Restoring one of them isn't blocked by the other.
        try german.setKeybind(keybind("t", [.control, .command]), for: .toggleTerminal)
        try german.setKeybind(nil, for: .toggleTerminal)
        #expect(german.isDefaultKeybind(for: .toggleTerminal))
        // A keybind someone records still can't take that keystroke.
        #expect(throws: KeybindSettings.Error.self) {
            try german.setKeybind(keybind("`", [.control, .shift]), for: .quickOpen)
        }
    }

    @Test func noPresetIsFlaggedOnAnyInstalledLatinLayout() throws {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        var checked = 0
        for source in sources {
            let latin = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
                .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
            guard latin, let layout = KeyboardLayoutTable(source: source) else { continue }
            checked += 1
            for preset in presets {
                let settings = settings(layout: layout)
                try settings.setActivePreset(id: preset.id)
                let flagged = ConfigKeyCommand.allCases.filter { settings.layoutClash(for: $0) != nil }
                #expect(flagged.isEmpty, "\(preset.id) on \(source)")
                try settings.setActivePreset(id: "silica")
            }
        }
        #expect(checked > 0)
    }

    @Test func aClashOnlyThisLayoutHasIsKeptAndShown() {
        // ⇧⌘7, recorded on a U.S. layout, is Toggle Comment's ⌘/ on a German one.
        defaults.set(Data(#"{"quick_open":{"key":"7","modifiers":9}}"#.utf8), forKey: "keybinds.overrides")
        let german = settings(layout: FakeLayout.german)
        #expect(german.keybind(for: .quickOpen) == keybind("7", [.shift, .command]))
        #expect(german.layoutClash(for: .quickOpen) == "Toggle Comment")
        #expect(settings(layout: FakeLayout.us).layoutClash(for: .quickOpen) == nil)
    }

    @Test func savedKeybindsThatSwapStillLoad() {
        // Toggle Sidebar moved off ⌃⌘S, and Go to Line took it.
        defaults.set(Data(#"{"toggle_sidebar":{"key":"b","modifiers":5},"go_to_line":{"key":"s","modifiers":5}}"#.utf8),
                     forKey: "keybinds.overrides")
        let settings = settings()
        #expect(settings.keybind(for: .toggleSidebar) == keybind("b", [.control, .command]))
        #expect(settings.keybind(for: .goToLine) == keybind("s", [.control, .command]))
    }

    @Test func savedKeybindsThatNoLongerFitAreDropped() {
        defaults.set(Data(#"""
            {"quick_open":{"key":"f","modifiers":1},
             "filter_tree_files":{"key":"x","modifiers":2},
             "source_control":{"key":"","modifiers":1},
             "new_terminal":{"key":"t","modifiers":5}}
            """#.utf8), forKey: "keybinds.overrides")
        let settings = settings()
        // ⌘F is Find, ⌥X types "≈", and an empty key can't be read; ⌃⌘T is fine.
        #expect(settings.keybind(for: .quickOpen) == keybind("p", .command))
        #expect(settings.keybind(for: .filterTreeFiles) == keybind("j", [.option, .command]))
        #expect(settings.keybind(for: .sourceControl) == keybind("g", [.control, .shift]))
        #expect(settings.keybind(for: .newTerminal) == keybind("t", [.control, .command]))
        #expect(settings.customKeybindCount == 1)
        // The cleaned-up list is what's saved now.
        #expect(self.settings().customKeybindCount == 1)
    }

    @Test func optionLetterOnlyForWordWrap() throws {
        let settings = settings()
        #expect(throws: KeybindSettings.Error.typesCharacter(keybind("x", .option))) {
            try settings.setKeybind(keybind("x", .option), for: .quickOpen)
        }
        try settings.setKeybind(keybind("x", .option), for: .toggleWordWrap)
        #expect(settings.keybind(for: .toggleWordWrap) == keybind("x", .option))
    }

    @Test func presetKeybindClearsOverride() throws {
        let settings = settings()
        try settings.setKeybind(keybind("p", [.control, .command]), for: .quickOpen)
        #expect(!settings.isDefaultKeybind(for: .quickOpen))
        try settings.setKeybind(keybind("p", .command), for: .quickOpen)
        #expect(settings.isDefaultKeybind(for: .quickOpen))
    }

    @Test func restoringADefaultChecksForConflicts() throws {
        let settings = settings()
        try settings.setKeybind(keybind("b", [.control, .command]), for: .toggleSidebar)
        try settings.setKeybind(keybind("s", [.control, .command]), for: .goToLine)
        #expect(throws: KeybindSettings.Error.commandConflict(keybind("s", [.control, .command]), "Go to Line")) {
            try settings.setKeybind(nil, for: .toggleSidebar)
        }
        #expect(settings.keybind(for: .toggleSidebar) == keybind("b", [.control, .command]))

        try settings.setKeybind(nil, for: .goToLine)
        try settings.setKeybind(nil, for: .toggleSidebar)
        #expect(!settings.hasCustomKeybinds)
    }

    @Test func choosingTheActivePresetKeepsCustomKeybinds() throws {
        let settings = settings()
        try settings.setKeybind(keybind("p", [.control, .command]), for: .quickOpen)
        try settings.setActivePreset(id: "silica")
        #expect(settings.customKeybindCount == 1)
        #expect(settings.keybind(for: .quickOpen) == keybind("p", [.control, .command]))
    }

    @Test func overridesPersistAndPresetChangeClearsThem() throws {
        try settings().setKeybind(keybind("p", [.control, .command]), for: .quickOpen)
        let reloaded = settings()
        #expect(reloaded.keybind(for: .quickOpen) == keybind("p", [.control, .command]))

        try reloaded.setActivePreset(id: "xcode")
        #expect(!reloaded.hasCustomKeybinds)
        #expect(settings().activePresetId == "xcode")
        #expect(settings().keybind(for: .quickOpen) == keybind("o", [.shift, .command]))
    }

    @Test func tooltipsFollowThePresetAndOverrides() throws {
        let settings = settings()
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌃⌘S)")
        try settings.setActivePreset(id: "vscode")
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌘B)")
        try settings.setKeybind(keybind("t", [.control, .command]), for: .toggleTerminal)
        #expect(settings.help("Show Terminal", for: .toggleTerminal) == "Show Terminal (⌃⌘T)")
        try settings.setActivePreset(id: "xcode")
        #expect(settings.help("Refresh", for: .refreshExplorer) == "Refresh (⇧⌘R)")
        #expect(settings.help("Show Explorer", for: .explorer) == "Show Explorer (⌘1)")
        // As in Xcode: ⌘0 hides the navigator, ⇧⌘1 opens the Welcome window.
        #expect(settings.help("Hide Sidebar", for: .toggleSidebar) == "Hide Sidebar (⌘0)")
        #expect(settings.keybind(for: .welcomeWindow) == keybind("1", [.shift, .command]))
    }

    @Test func tabAliasIsFreeOnlyWhenUnbound() throws {
        let settings = settings()
        #expect(!settings.isBound(keybind("]", [.shift, .command])))
        try settings.setActivePreset(id: "xcode")
        #expect(settings.isBound(keybind("]", [.shift, .command])))
    }
}
