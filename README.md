# Silica

A lightweight code editor for macOS, made of glass. Open a folder, find files fast,
and edit with syntax highlighting, a minimap and a Markdown and HTML preview, all
in a native SwiftUI and AppKit app.

![Silica editing a Swift project, with the file tree on the left and the editor on a glass card](.github/assets/screenshot.jpg)

## Download

Get the latest DMG from [Releases](https://github.com/dqhieu/Silica/releases/latest),
open it and drag Silica to Applications. Silica checks for updates once a day and
installs them for you; you can turn that off in Settings › General.

Silica needs macOS 26 or later.

## Features

- **Projects.** Open a folder to get a window with a file tree. Files and folders
  your `.gitignore` excludes are dimmed, and the tree updates as files change on disk.
  Create, rename and move files to the Trash right in the tree, and filter it as you type.
- **Quick Open and project search.** Jump to any file with fuzzy matching, or search
  the text of every file in the project.
- **Syntax highlighting** for 26 languages, including Swift, JavaScript, TypeScript,
  Python, Go, Rust, C, C++, Java, Kotlin, HTML, CSS, JSON, YAML and Markdown.
- **Nine color themes**, each with a light and a dark palette: Atom One, GitHub,
  Xcode, Solarized, Catppuccin, Gruvbox, Tokyo Night, Rosé Pine and Dracula.
- **Markdown preview**, with highlighted code blocks.
- **CSV preview.** See `.csv` and `.tsv` files as a table, and double-click a row to
  edit it.
- **HTML preview.** `.html` files render as in a browser, with their styles, images
  and scripts.
- **Editing tools.** Tabs, line numbers, indent guides, a minimap, word wrap, go to
  line, toggle comment, and moving or duplicating lines.
- **Picks up where you left off.** Projects reopen their tabs, and recent projects
  are on the welcome window.
- **Works with Finder.** Use Open With, drop files on the Dock icon, or run
  `open -a Silica <path>`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘P | Quick Open |
| ⇧⌘F | Find in Project |
| ⌥⌘J | Filter files in the tree |
| ⌘L | Go to Line |
| ⇧⌘V | Toggle Markdown, CSV or HTML preview |
| ⌃⌘S | Show or hide the sidebar |
| ⌘/ | Toggle comment |
| ⌥↑ / ⌥↓ | Move lines up or down |
| ⇧⌥↑ / ⇧⌥↓ | Duplicate lines up or down |
| ⌥Z | Word wrap |
| ⌘+ / ⌘− / ⌘0 | Increase, decrease or reset the font size |

## Building from source

You need Xcode 27 or later.

1. Clone the repository and open `Silica.xcodeproj`.
2. In the Silica target's Signing & Capabilities, choose your own team (or "Sign to
   Run Locally"). Please don't commit that change.
3. Press ⌘R. Xcode fetches the Swift packages on the first build.

## Contributing

Bug reports, ideas and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before you start on a change.

## License

Silica is released under the [MIT License](LICENSE). It includes
[swift-markdown](https://github.com/swiftlang/swift-markdown),
[swift-cmark](https://github.com/swiftlang/swift-cmark) and
[Sparkle](https://sparkle-project.org), whose licenses are in
`Silica/Resources/Licenses` and in Settings › About.
