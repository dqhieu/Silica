# Contributing to Silica

Thanks for helping make Silica better. Bug reports, feature ideas and pull requests
are all welcome.

## Reporting bugs and asking for features

[Open an issue](https://github.com/dqhieu/Silica/issues/new). For a bug, include:

- your Silica version (Settings › About) and macOS version
- what you did, what you expected, and what happened instead
- a screenshot or screen recording if it's visual, and a sample file if it's about
  a particular kind of file

Please search the existing issues first, in case it's already reported.

## Before you write code

For anything bigger than a small fix, open an issue (or comment on an existing one)
first, so we can agree on the approach before you spend time on it. Silica aims to
stay small and focused, so not every feature will fit, and it's better to find that
out early.

## Setting up

You need Xcode 27 or later. Silica runs on macOS 26 and later.

1. Fork the repository and clone your fork.
2. Open `Silica.xcodeproj`.
3. In the Silica target's Signing & Capabilities, choose your own team (or "Sign to
   Run Locally"). Keep this change out of your commits.
4. Press ⌘R to build and run.

## How the code is organized

| Folder | What's in it |
|---|---|
| `Silica/App` | The app entry point, the app delegate and the menu commands |
| `Silica/Views` | SwiftUI views: the welcome window, the workspace, the file tree, Settings |
| `Silica/Editor` | The AppKit text view, line numbers, minimap, syntax highlighting and the Markdown, CSV and HTML previews |
| `Silica/Models` | Workspace state, open buffers, settings, recent projects, search |
| `Silica/Support` | Glue for AppKit, Finder, file watching and updates |
| `Config/Info.plist` | Keys merged into the generated Info.plist |

The app uses SwiftUI for windows and layout and AppKit (`NSTextView`) for the editor
itself. Code is main-actor isolated by default.

## Making a change

- **Match the code around you**: its naming, its structure, its use of SwiftUI and
  AppKit. Prefer platform APIs to new dependencies; ask in an issue before adding a
  package.
- **Comment the why, not the what.** If something is done in a non-obvious way
  (a workaround for a SwiftUI behavior, say), leave a short comment explaining why.
- **Keep pull requests focused** on one change. Unrelated cleanups go in their own PR.
- **Check it by hand.** There's no test suite yet, so run the app and try your
  change, in both light and dark appearance if it touches the UI. Include a
  screenshot or recording in the PR for visual changes.
- **Build without new warnings.**

## Commit messages

Write the subject in the imperative, describing the change as the user sees it
("Make editor tabs taller", not "Updated TabView padding"), and keep it under about
70 characters. Use the body to say what changed and why, when that's not obvious
from the subject.

## Pull requests

1. Create a branch from `main` in your fork.
2. Make your change and push the branch.
3. Open a pull request against `main`. Describe what it changes and how you tested
   it, and link the issue it addresses.

A maintainer will review it, and may ask for changes before merging.

## Releases

Releases are made by the maintainer with `scripts/release.sh`; see
[RELEASING.md](RELEASING.md). Pull requests shouldn't change the version number.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE), the same as the rest of Silica.
