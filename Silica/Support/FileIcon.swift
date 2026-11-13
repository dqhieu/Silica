import SwiftUI
import UniformTypeIdentifiers

/// SF Symbol + tint for a file, colored like Xcode's project navigator. Folders
/// get the icon Finder shows for them.
struct FileIcon: View {
    let url: URL
    var isDirectory = false
    var isExpanded = false
    var width: CGFloat = 16

    var body: some View {
        if isDirectory {
            Image(nsImage: FolderIcons.shared.icon(for: url))
                .resizable()
                .interpolation(.high)
                .frame(width: width, height: width)
        } else {
            let (symbol, color) = Self.style(for: url, isDirectory: false, isExpanded: isExpanded)
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: width)
        }
    }

    static func style(for url: URL, isDirectory: Bool, isExpanded: Bool) -> (String, Color) {
        typealias C = FileIconPalette
        if isDirectory {
            return ("folder", C.folder)
        }
        let code = "chevron.left.forwardslash.chevron.right"
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "package.swift": return ("swift", C.swift)
        case "dockerfile": return ("shippingbox", C.blue)
        case "makefile": return ("hammer", C.brown)
        case "license", "license.md", "license.txt": return ("checkmark.seal", C.yellow)
        case ".gitignore", ".gitattributes": return ("arrow.triangle.branch", C.red)
        default: break
        }
        switch url.pathExtension.lowercased() {
        case "swift": return ("swift", C.swift)
        case "js", "mjs", "cjs", "jsx": return ("curlybraces", C.yellow)
        case "ts", "tsx": return ("curlybraces", C.blue)
        case "json", "jsonc": return ("curlybraces.square", C.amber)
        case "md", "markdown", "mdx": return ("text.alignleft", C.indigo)
        case "html", "htm", "xml", "svg", "vue": return (code, C.pink)
        case "css", "scss", "sass", "less": return ("paintbrush", C.purple)
        case "py": return (code, C.teal)
        case "go": return (code, C.cyan)
        case "rb", "java": return (code, C.red)
        case "rs": return (code, C.brown)
        case "kt", "cs": return (code, C.purple)
        case "php": return (code, C.indigo)
        case "c", "h", "m", "mm", "cpp", "hpp": return (code, C.blue)
        case "sh", "zsh", "bash", "fish": return ("terminal", C.green)
        case "yml", "yaml", "toml", "ini", "plist", "xcconfig", "env": return ("gearshape", C.steel)
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "ico", "icns": return ("photo", C.mint)
        case "pdf": return ("doc.richtext", C.red)
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg", "3gp": return ("film", C.purple)
        case "zip", "gz", "tar", "rar", "7z": return ("archivebox", C.brown)
        case "diff", "patch", "rej": return ("plusminus", C.green)
        case "lock", "resolved": return ("lock", C.neutral)
        case "txt", "log": return ("doc.plaintext", C.neutral)
        default: return ("doc", C.neutral)
        }
    }
}

/// Finder's icons for folders: custom icons, packages and the system's special
/// folders look as they do there. Kept until files change on disk.
@MainActor @Observable
final class FolderIcons {
    static let shared = FolderIcons()

    /// Read by every folder icon, so they are all fetched again after `reload()`.
    private var generation = 0
    @ObservationIgnored private var icons: [URL: NSImage] = [:]

    func icon(for url: URL) -> NSImage {
        _ = generation
        if let icon = icons[url] { return icon }
        let path = url.path(percentEncoded: false)
        // A folder still being named isn't on disk yet: the plain folder.
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .folder)
        icons[url] = icon
        return icon
    }

    /// Forgets every icon; a folder's icon may have been changed in Finder.
    func reload() {
        guard !icons.isEmpty else { return }
        icons.removeAll()
        generation += 1
    }
}

/// Xcode-style icon colors: blue folders and orange Swift files, plus a hue per
/// file family, each with a deeper light-mode and a brighter dark-mode shade.
enum FileIconPalette {
    static let folder = dynamic(light: 0x3B8EEA, dark: 0x5AA5F5)
    static let swift = dynamic(light: 0xF05138, dark: 0xF4693F)

    static let blue = dynamic(light: 0x2F74C0, dark: 0x5E9BEA)
    static let cyan = dynamic(light: 0x0089AD, dark: 0x3EC3E6)
    static let teal = dynamic(light: 0x1F8A8A, dark: 0x4CC2C2)
    static let mint = dynamic(light: 0x2E9C78, dark: 0x5CC9A2)
    static let green = dynamic(light: 0x3A9150, dark: 0x63C27A)
    static let yellow = dynamic(light: 0xB88A00, dark: 0xEAC04A)
    static let amber = dynamic(light: 0xC26F0F, dark: 0xF09A45)
    static let red = dynamic(light: 0xCC3D3D, dark: 0xF06C66)
    static let pink = dynamic(light: 0xC2357F, dark: 0xF06AAE)
    static let purple = dynamic(light: 0x8A45C4, dark: 0xB582EE)
    static let indigo = dynamic(light: 0x5653C9, dark: 0x8784F5)
    static let brown = dynamic(light: 0x976236, dark: 0xC9976A)
    static let steel = dynamic(light: 0x5F7C9B, dark: 0x92ADC9)
    static let neutral = dynamic(light: 0x8A8D94, dark: 0xA2A5AC)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
