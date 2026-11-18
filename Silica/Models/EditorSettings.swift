import AppKit
import Observation

extension Notification.Name {
    static let editorFontSizeDidChange = Notification.Name("EditorFontSizeDidChange")
    static let editorWrapDidChange = Notification.Name("EditorWrapDidChange")
    /// Font, tab width, line numbers, indent guides, glass amount, or the minimap changed.
    static let editorSettingsDidChange = Notification.Name("EditorSettingsDidChange")
    static let syntaxThemeDidChange = Notification.Name("SyntaxThemeDidChange")
}

/// App-wide editor preferences, saved in UserDefaults. Each value is stored only
/// while it differs from its default.
@Observable
final class EditorSettings {
    static let shared = EditorSettings()

    static let defaultFontSize: CGFloat = 13
    static let fontSizeRange: ClosedRange<CGFloat> = 9...36
    /// The text size of the sidebar list's small rows (`.subheadline`).
    static let defaultSidebarFontSize: CGFloat = 11
    static let sidebarFontSizeRange: ClosedRange<CGFloat> = 9...20
    static let tabWidths = [2, 4, 8]
    static let defaultEditorGlassAmount: CGFloat = 0.5
    
    private enum Key {
        static let fontSize = "editorFontSize"
        static let fontFamily = "editorFontFamily"
        static let sidebarFontSize = "sidebarFontSize"
        static let wrapsLines = "editorWrapsLines"
        static let tabWidth = "editorTabWidth"
        static let indentsWithTabs = "editorIndentsWithTabs"
        static let showsLineNumbers = "editorShowsLineNumbers"
        static let showsIndentGuides = "editorShowsIndentGuides"
        static let showsMinimap = "editorShowsMinimap"
        static let editorGlassAmount = "editorGlassAmount"
        static let syntaxTheme = "syntaxTheme"
        static let appearance = "appearance"
        static let windowBackground = "windowBackground"
        static let usesGlassEffect = "usesGlassEffect"
        static let restoresTabs = "restoresOpenTabs"
        static let pinsParentFolders = "fileTreePinsParentFolders"
    }

    /// Font size of the editor text; the line-number gutter scales with it.
    private(set) var fontSize: CGFloat

    /// A monospaced font family, or `nil` for the system's (SF Mono).
    var fontFamily: String? {
        didSet {
            guard fontFamily != oldValue else { return }
            store(fontFamily, Key.fontFamily, isDefault: fontFamily == nil)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }

    /// Font size of the sidebar's file tree and search results, apart from the editor's.
    var sidebarFontSize: CGFloat {
        didSet {
            guard sidebarFontSize != oldValue else { return }
            store(Double(sidebarFontSize), Key.sidebarFontSize, isDefault: sidebarFontSize == Self.defaultSidebarFontSize)
        }
    }

    /// The width of a file icon beside sidebar text: 16pt at the default size,
    /// growing with the text so larger icons don't run into the names.
    var sidebarIconWidth: CGFloat {
        (sidebarFontSize * 16 / Self.defaultSidebarFontSize).rounded()
    }

    /// Long lines wrap to the editor's width; off, they scroll sideways.
    var wrapsLines: Bool {
        didSet {
            guard wrapsLines != oldValue else { return }
            store(wrapsLines, Key.wrapsLines, isDefault: wrapsLines)
            NotificationCenter.default.post(name: .editorWrapDidChange, object: self)
        }
    }

    /// Columns a tab character advances, and the indent step for new files.
    var tabWidth: Int {
        didSet {
            guard tabWidth != oldValue else { return }
            store(tabWidth, Key.tabWidth, isDefault: tabWidth == 4)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }

    /// How files with no indentation yet are indented; others keep their own style.
    var indentsWithTabs: Bool {
        didSet {
            guard indentsWithTabs != oldValue else { return }
            store(indentsWithTabs, Key.indentsWithTabs, isDefault: !indentsWithTabs)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }

    var showsLineNumbers: Bool {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            store(showsLineNumbers, Key.showsLineNumbers, isDefault: showsLineNumbers)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }

    var showsIndentGuides: Bool {
        didSet {
            guard showsIndentGuides != oldValue else { return }
            store(showsIndentGuides, Key.showsIndentGuides, isDefault: showsIndentGuides)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }

    /// An overview of the file down the editor's right edge.
    var showsMinimap: Bool {
        didSet {
            guard showsMinimap != oldValue else { return }
            store(showsMinimap, Key.showsMinimap, isDefault: !showsMinimap)
            NotificationCenter.default.post(name: .editorSettingsDidChange, object: self)
        }
    }
    
    /// The editor's glass effect amount.
    var editorGlassAmount: CGFloat {
        didSet {
            guard editorGlassAmount != oldValue else { return }
            store(
                Double(editorGlassAmount),
                Key.editorGlassAmount,
                isDefault: editorGlassAmount == Self.defaultEditorGlassAmount
            )
            NotificationCenter.default.post(
                name: .editorSettingsDidChange,
                object: self
            )
        }
    }

    /// Colors for highlighted code, in the editor and in Markdown previews.
    var syntaxTheme: SyntaxTheme {
        didSet {
            guard syntaxTheme != oldValue else { return }
            store(syntaxTheme.rawValue, Key.syntaxTheme, isDefault: syntaxTheme == .default)
            NotificationCenter.default.post(name: .syntaxThemeDidChange, object: self)
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
    }

    var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            store(appearance.rawValue, Key.appearance, isDefault: appearance == .system)
            applyAppearance()
        }
    }

    enum WindowBackground: String, CaseIterable, Identifiable {
        case translucent, opaque
        var id: Self { self }

        /// What the window's `VisualEffectView` is filled with: a frosted blur of
        /// whatever is behind the window, or the solid window background.
        var material: NSVisualEffectView.Material {
            switch self {
            case .translucent: .menu
            case .opaque: .windowBackground
            }
        }
    }

    /// Whether project and welcome windows let the desktop show through.
    var windowBackground: WindowBackground {
        didSet {
            guard windowBackground != oldValue else { return }
            store(windowBackground.rawValue, Key.windowBackground, isDefault: windowBackground == .translucent)
        }
    }

    /// Cards, tabs and buttons sit on Liquid Glass; off, a border and a shadow
    /// set them apart instead.
    var usesGlassEffect: Bool {
        didSet {
            guard usesGlassEffect != oldValue else { return }
            store(usesGlassEffect, Key.usesGlassEffect, isDefault: usesGlassEffect)
        }
    }

    /// Reopen a project's tabs where they were left.
    var restoresTabs: Bool {
        didSet {
            guard restoresTabs != oldValue else { return }
            store(restoresTabs, Key.restoresTabs, isDefault: restoresTabs)
        }
    }

    /// The file tree keeps the folders around its first visible row at the top
    /// while it scrolls.
    var pinsParentFolders: Bool {
        didSet {
            guard pinsParentFolders != oldValue else { return }
            store(pinsParentFolders, Key.pinsParentFolders, isDefault: pinsParentFolders)
        }
    }

    var canIncreaseFontSize: Bool { fontSize < Self.fontSizeRange.upperBound }
    var canDecreaseFontSize: Bool { fontSize > Self.fontSizeRange.lowerBound }
    var isDefaultFontSize: Bool { fontSize == Self.defaultFontSize }

    private init() {
        let defaults = UserDefaults.standard
        let storedSize = defaults.double(forKey: Key.fontSize)
        fontSize = storedSize > 0 ? Self.clamped(CGFloat(storedSize)) : Self.defaultFontSize
        fontFamily = defaults.string(forKey: Key.fontFamily)
        let storedSidebarSize = defaults.double(forKey: Key.sidebarFontSize)
        sidebarFontSize = storedSidebarSize > 0
            ? Self.clamped(CGFloat(storedSidebarSize), to: Self.sidebarFontSizeRange)
            : Self.defaultSidebarFontSize
        wrapsLines = defaults.object(forKey: Key.wrapsLines) as? Bool ?? true
        let storedTabWidth = defaults.integer(forKey: Key.tabWidth)
        tabWidth = Self.tabWidths.contains(storedTabWidth) ? storedTabWidth : 4
        indentsWithTabs = defaults.bool(forKey: Key.indentsWithTabs)
        showsLineNumbers = defaults.object(forKey: Key.showsLineNumbers) as? Bool ?? true
        showsIndentGuides = defaults.object(forKey: Key.showsIndentGuides) as? Bool ?? true
        showsMinimap = defaults.bool(forKey: Key.showsMinimap)
        syntaxTheme = defaults.string(forKey: Key.syntaxTheme).flatMap(SyntaxTheme.init(rawValue:)) ?? .default
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        windowBackground = defaults.string(forKey: Key.windowBackground)
            .flatMap(WindowBackground.init(rawValue:)) ?? .translucent
        usesGlassEffect = defaults.object(forKey: Key.usesGlassEffect) as? Bool ?? true
        restoresTabs = defaults.object(forKey: Key.restoresTabs) as? Bool ?? true
        pinsParentFolders = defaults.object(forKey: Key.pinsParentFolders) as? Bool ?? true
        let storedGlassAmount = defaults.object(forKey: Key.editorGlassAmount) as? Double ?? Self.defaultEditorGlassAmount
        editorGlassAmount = min(1, max(0, storedGlassAmount))
    }

    private func store(_ value: Any?, _ key: String, isDefault: Bool) {
        if isDefault || value == nil {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    // MARK: Font

    func increaseFontSize() { setFontSize(fontSize + 1) }
    func decreaseFontSize() { setFontSize(fontSize - 1) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }

    func setFontSize(_ size: CGFloat) {
        let size = Self.clamped(size)
        guard size != fontSize else { return }
        fontSize = size
        store(Double(size), Key.fontSize, isDefault: size == Self.defaultFontSize)
        NotificationCenter.default.post(name: .editorFontSizeDidChange, object: self)
    }

    private static func clamped(_ size: CGFloat, to range: ClosedRange<CGFloat> = fontSizeRange) -> CGFloat {
        min(max(size.rounded(), range.lowerBound), range.upperBound)
    }

    /// The editor font at `size`: the chosen family, or the system monospaced font.
    func editorFont(ofSize size: CGFloat) -> NSFont {
        if let fontFamily,
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch font families, for the font picker.
    static let monospacedFamilies: [String] = {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
            // Hidden system families start with a dot.
            .filter { !$0.hasPrefix(".") }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }()

    // MARK: Appearance

    /// Light, dark, or following the system, for every window.
    func applyAppearance() {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Keyboard

    private var keyMonitor: Any?

    /// Lets ⌘= (no Shift) zoom in too, the way most apps treat it, and ⌥Z toggle
    /// word wrap.
    ///
    /// The View menu's "Increase Font Size" item is bound to ⌘+, which on a US
    /// keyboard needs Shift; menus can't also match the unshifted key.
    func installKeyboardShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard let self else { return event }
            if flags == .command, event.charactersIgnoringModifiers == "=" {
                self.increaseFontSize()
                return nil
            }
            // ⌥Z, as in VS Code. Also in the View menu, but an editor with focus would
            // otherwise type "Ω".
            if flags == .option, event.charactersIgnoringModifiers?.lowercased() == "z",
               event.window?.attachedSheet == nil, NSApp.modalWindow == nil,
               event.window?.firstResponder is EditorTextView {
                self.wrapsLines.toggle()
                return nil
            }
            return event
        }
    }
}
