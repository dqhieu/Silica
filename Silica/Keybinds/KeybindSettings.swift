import Foundation
import SwiftUI

@Observable
final class KeybindSettings {

    typealias KeybindOverrideMap = [ConfigKeyCommand.ID: Keybind]

    private enum DefaultsKey {
        static let presetId = "keybinds.presetId"
        static let overrides = "keybinds.overrides"
    }

    static let shared = KeybindSettings(
        presets: KeybindFile.loadAllFromBundle(),
        defaults: .standard
    )

    let presets: [KeybindFile]
    private(set) var activePresetId: KeybindFile.ID
    private var overrides = KeybindOverrideMap()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let layout: KeyboardLayout

    /// The window of Settings' keybind recorder while it's open. The app's own key
    /// monitors let keys typed there through to the recorder instead of acting on
    /// them; other windows keep their shortcuts.
    @ObservationIgnored weak var recorderWindow: AnyObject?
    
    /// Bumped when the user switches keyboard layouts, so views showing clashes that
    /// depend on the layout look again.
    private var layoutVersion = 0
    @ObservationIgnored nonisolated(unsafe) private var layoutObserver: Any?

    var hasCustomKeybinds: Bool {
        !self.overrides.isEmpty
    }
    
    /// How many commands have a keybind of their own instead of the preset's.
    var customKeybindCount: Int {
        self.overrides.count
    }
    
    var activePreset: KeybindFile {
        getActivePreset()
    }

    init(presets: [KeybindFile], defaults: UserDefaults, layout: KeyboardLayout = CurrentKeyboardLayout.shared) {
        self.presets = presets
        self.defaults = defaults
        self.layout = layout

        self.activePresetId = if let presetId = defaults.string(forKey: DefaultsKey.presetId),
                                 presets.contains(where: { $0.id == presetId }) {
            presetId
        } else {
            KeybindFile.defaultFileId
        }

        if layout is CurrentKeyboardLayout {
            layoutObserver = NotificationCenter.default.addObserver(
                forName: .keyboardLayoutDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutVersion += 1 }
            }
        }

        guard let overrideData = defaults.data(forKey: DefaultsKey.overrides),
              let stored = try? JSONDecoder().decode([ConfigKeyCommand.ID: StoredKeybind].self, from: overrideData)
        else {
            self.overrides = [:]
            return
        }

        // Retain only valid overrides for commands the current app still supports.
        self.overrides = stored.compactMapValues(\.keybind).filter {
            ConfigKeyCommand(rawValue: $0.key) != nil
        }
        dropOverridesThatNoLongerFit()
    }
    
    deinit {
        if let layoutObserver { NotificationCenter.default.removeObserver(layoutObserver) }
    }
    
    /// A saved keybind, or nil when it can't be read, so one bad entry doesn't lose the rest.
    private struct StoredKeybind: Decodable {
        let keybind: Keybind?
        
        init(from decoder: Decoder) throws {
            self.keybind = try? Keybind(from: decoder)
        }
    }
    
    /// Drops saved keybinds that a newer version of a preset, or a newly reserved
    /// shortcut, now clashes with, so two commands never share a keystroke. A command
    /// whose keybind is dropped goes back to its preset's, which could clash in turn,
    /// so this repeats until nothing does.
    ///
    /// Only clashes on any layout count here (the keybinds as written). One that only
    /// the current layout has, such as ⇧⌘7 beside ⌘/ on a German layout, may be a
    /// keybind recorded on another layout: Settings shows it instead of dropping it.
    private func dropOverridesThatNoLongerFit() {
        var dropped = false
        while let command = ConfigKeyCommand.allCases.first(where: { command in
            self.overrides[command.id].map { problem(with: $0, for: command, onAnyLayout: true) != nil } ?? false
        }) {
            self.overrides.removeValue(forKey: command.id)
            dropped = true
        }
        if dropped { save() }
    }

    // Every preset binds every command to a valid keybind: KeybindFile's validation
    // checks that when the presets load.

    func keybind(for command: FixedKeyCommand) -> Keybind {
        presetBinding(for: command).asKeybind()!
    }

    func keybind(for command: ConfigKeyCommand) -> Keybind {
        self.overrides[command.id] ?? presetBinding(for: command).asKeybind()!
    }

    func title(for command: FixedKeyCommand) -> String {
        presetBinding(for: command).title
    }

    func title(for command: ConfigKeyCommand) -> String {
        presetBinding(for: command).title
    }

    func isDefaultKeybind(for command: ConfigKeyCommand) -> Bool {
        self.overrides[command.id] == nil
    }

    /// A tooltip naming the command's current keybind: "Quick Open (⌘P)".
    func help(_ title: String, for command: ConfigKeyCommand) -> String {
        "\(title) (\(keybind(for: command).displayName))"
    }
    
    func help(_ title: String, for command: FixedKeyCommand) -> String {
        "\(title) (\(keybind(for: command).displayName))"
    }
    
    /// Whether `window` is the keybind recorder's, so a key typed in it is being recorded.
    func isRecorderWindow(_ window: AnyObject?) -> Bool {
        window != nil && window === recorderWindow
    }
    
    /// Whether `a` and `b` are the same keystroke on the user's keyboard layout: on a
    /// German layout ⌘/ and ⇧⌘7 are, since "/" is ⇧7 there.
    func isSameKeystroke(_ a: Keybind, _ b: Keybind) -> Bool {
        a.keystroke(on: layout) == b.keystroke(on: layout)
    }
    
    /// Whether `pressed` is the keystroke `command` is bound to.
    func isKeybind(_ pressed: Keybind, of command: ConfigKeyCommand) -> Bool {
        isSameKeystroke(pressed, keybind(for: command))
    }
    
    func isKeybind(_ pressed: Keybind, of command: FixedKeyCommand) -> Bool {
        isSameKeystroke(pressed, keybind(for: command))
    }
    
    /// The command that `command`'s keybind is also the keystroke of on the current
    /// keyboard layout, if any: one recorded on another layout can clash here. Clashes
    /// between two of the preset's own keybinds aren't reported; see `setKeybind`.
    func layoutClash(for command: ConfigKeyCommand) -> String? {
        _ = layoutVersion // Looked at again when the user switches layouts.
        let isCustom = !isDefaultKeybind(for: command)
        return clashes(with: keybind(for: command), excluding: command)
            .first { isCustom || $0.isCustom }?.title
    }
    
    /// Whether any command, system ones included, runs on `keybind`.
    func isBound(_ keybind: Keybind) -> Bool {
        commandTitle(boundTo: keybind, excluding: nil) != nil
    }

    func setActivePreset(id: KeybindFile.ID) throws {
        guard let preset = self.presets.first(where: { $0.id == id }) else {
            throw Error.unknownPreset(id)
        }
        // Choosing the preset already in use keeps the keybinds set on top of it.
        guard preset.id != self.activePresetId else { return }
        self.activePresetId = preset.id
        self.overrides = [:]
        save()
    }

    func setKeybind(
        _ keybind: Keybind?,
        for command: ConfigKeyCommand
    ) throws {
        guard let keybind else {
            // Another command may have taken the preset's keystroke in the meantime. Only
            // a keybind someone set counts: two of the preset's own keybinds can be one
            // keystroke on some layouts (⌃` and ⌃⇧` on German, where ` needs Shift),
            // as they are in the editor the preset follows.
            let preset = presetBinding(for: command).asKeybind()!
            if let clash = clashes(with: preset, excluding: command).first(where: \.isCustom) {
                throw Error.commandConflict(preset, clash.title)
            }
            self.overrides.removeValue(forKey: command.id)
            save()
            return
        }
        if let problem = problem(with: keybind, for: command) {
            throw problem
        }
        if isSameKeystroke(keybind, presetBinding(for: command).asKeybind()!) {
            // If keybind is equal to our preset's default, remove the override.
            self.overrides.removeValue(forKey: command.id)
        }
        else {
            self.overrides[command.id] = keybind
        }
        save()
    }

    func reset() {
        guard !self.overrides.isEmpty else { return }
        self.overrides = [:]
        save()
    }

    // MARK: Private

    private func getActivePreset() -> KeybindFile {
        guard let preset = self.presets.first(where: { $0.id == self.activePresetId }) else {
            preconditionFailure("Current keybind preset is missing.")
        }
        return preset
    }

    private func presetBinding(for command: FixedKeyCommand) -> KeybindFile.Binding {
        guard let binding = getActivePreset().binding(for: command) else {
            preconditionFailure("Keybind preset has no binding for \(command.id).")
        }
        return binding
    }
    
    private func presetBinding(for command: ConfigKeyCommand) -> KeybindFile.Binding {
        guard let binding = getActivePreset().binding(for: command) else {
            preconditionFailure("Keybind preset has no binding for \(command.id).")
        }
        return binding
    }

    /// Why `command` can't have `keybind`, if it can't.
    /// With `onAnyLayout`, only clashes between keybinds as written count, not ones
    /// that depend on the current keyboard layout.
    private func problem(with keybind: Keybind, for command: ConfigKeyCommand, onAnyLayout: Bool = false) -> Error? {
        let same: (Keybind, Keybind) -> Bool
        if onAnyLayout {
            same = { $0 == $1 }
        } else {
            same = { [unowned self] in isSameKeystroke($0, $1) }
        }
        // Only Toggle Word Wrap is caught before the editor types the character; see
        // EditorSettings.installKeyboardShortcuts().
        if keybind.typesCharacter, command != .toggleWordWrap {
            return .typesCharacter(keybind)
        }
        if let conflict = commandTitle(boundTo: keybind, excluding: command, same: same) {
            return .commandConflict(keybind, conflict)
        }
        return nil
    }
    
    /// The title of the command that `candidate` runs, other than `excludedCommand`.
    private func commandTitle(
        boundTo candidate: Keybind,
        excluding excludedCommand: ConfigKeyCommand?,
        same: ((Keybind, Keybind) -> Bool)? = nil
    ) -> String? {
        clashes(with: candidate, excluding: excludedCommand, same: same).first?.title
    }
    
    /// A command that runs on a keystroke, and whether its keybind is one someone set.
    private struct Clash {
        let title: String
        let isCustom: Bool
    }
    
    /// Every command, system ones included, that `candidate` runs, other than
    /// `excludedCommand`.
    private func clashes(
        with candidate: Keybind,
        excluding excludedCommand: ConfigKeyCommand?,
        same: ((Keybind, Keybind) -> Bool)? = nil
    ) -> [Clash] {
        let same = same ?? { [unowned self] in isSameKeystroke($0, $1) }
        let system = SystemKeyCommand.allCases
            .filter { same($0.keybind, candidate) }
            .map { Clash(title: $0.title, isCustom: false) }
        let fixed = FixedKeyCommand.allCases
            .filter { same(keybind(for: $0), candidate) }
            .map { Clash(title: title(for: $0), isCustom: false) }
        let config = ConfigKeyCommand.allCases
            .filter { $0 != excludedCommand && same(keybind(for: $0), candidate) }
            .map { Clash(title: title(for: $0), isCustom: !isDefaultKeybind(for: $0)) }
        return system + fixed + config
    }

    private func save() {
        self.defaults.set(
            self.activePresetId,
            forKey: DefaultsKey.presetId
        )
        guard !self.overrides.isEmpty else {
            self.defaults.removeObject(forKey: DefaultsKey.overrides)
            return
        }
        do {
            let data = try JSONEncoder().encode(self.overrides)
            self.defaults.set(data, forKey: DefaultsKey.overrides)
        } catch {
            assertionFailure("Failed to save keybind overrides: \(error)")
        }
    }
}

// MARK: KeybindSettings.Error

extension KeybindSettings {

    enum Error: LocalizedError, Equatable {

        case unknownPreset(KeybindFile.ID)
        case commandConflict(Keybind, String)
        case typesCharacter(Keybind)

        var errorDescription: String? {
            switch self {
            case .unknownPreset(let id):
                "Keybind preset '\(id)' is missing."
            case let .commandConflict(keybind, existing):
                "\(keybind.displayName) is already used by \(existing)."
            case let .typesCharacter(keybind):
                "\(keybind.displayName) types a character in the editor. Add ⌘ or ⌃."
            }
        }
    }
}
