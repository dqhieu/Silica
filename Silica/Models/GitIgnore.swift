import Foundation

/// The rules from one ignore file (a `.gitignore`, or `.git/info/exclude`), following
/// the pattern format in `man gitignore`:
///
/// - blank lines and `#` comments are skipped; `\#` and `\!` escape a leading `#` / `!`
/// - `!` re-includes what an earlier rule excluded
/// - a trailing `/` matches directories only
/// - a pattern with a `/` at its start or middle is relative to the ignore file's
///   folder; otherwise it matches a name at any depth below it
/// - `*`, `?` and `[…]` don't match `/`; `**/`, `/**/` and `/**` span folders
///
/// Matching is case-insensitive, like git's default (`core.ignorecase`) on macOS.
nonisolated struct GitIgnoreFile: @unchecked Sendable {
    /// Folder the rules are relative to, as a project-relative path ("" for the root).
    let base: String
    /// For a file in a folder above the project: the project's path below that
    /// folder, ending in "/". Its rules are written for paths from there.
    private let outerPath: String
    private let rules: [Rule]

    var isEmpty: Bool { rules.isEmpty }

    init(base: String, contents: String, outerPath: String = "") {
        self.base = base
        self.outerPath = outerPath
        self.rules = contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { Rule(line: String($0)) }
    }

    init?(base: String, url: URL, outerPath: String = "") {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(base: base, contents: String(decoding: data, as: UTF8.self), outerPath: outerPath)
    }

    /// `true` / `false` when a rule decides `path` (relative to `base`), `nil` if none matches.
    func decision(for path: String, isDirectory: Bool) -> Bool? {
        let lowered = (outerPath + path).lowercased()
        let name = lowered.split(separator: "/").last.map(String.init) ?? lowered
        var result: Bool?
        for rule in rules where rule.matches(path: lowered, name: name, isDirectory: isDirectory) {
            result = !rule.isNegated
        }
        return result
    }

    private struct Rule {
        enum Matcher {
            case name(String)
            case nameSuffix(String)
            case regex(NSRegularExpression)
        }

        let matcher: Matcher
        let isNegated: Bool
        let directoryOnly: Bool
        /// Anchored rules match the whole relative path; others match the last component.
        let isAnchored: Bool

        init?(line: String) {
            var pattern = Substring(line)
            if pattern.hasPrefix("#") { return nil }

            // Trailing spaces are dropped unless escaped with a backslash.
            while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") { pattern.removeLast() }
            if pattern.isEmpty { return nil }

            var negated = false
            if pattern.hasPrefix("!") {
                negated = true
                pattern.removeFirst()
            } else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") {
                pattern.removeFirst()
            }

            var directoryOnly = false
            if pattern.hasSuffix("/") {
                directoryOnly = true
                pattern = pattern.dropLast()
            }
            if pattern.isEmpty { return nil }

            let anchored = pattern.contains("/")
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.isEmpty { return nil }

            let lowered = pattern.lowercased()
            self.isNegated = negated
            self.directoryOnly = directoryOnly
            self.isAnchored = anchored

            if !anchored, !lowered.contains(where: { "*?[\\".contains($0) }) {
                matcher = .name(lowered)
            } else if !anchored, lowered.hasPrefix("*"),
                      !lowered.dropFirst().contains(where: { "*?[\\".contains($0) }) {
                matcher = .nameSuffix(String(lowered.dropFirst()))
            } else {
                guard let regex = try? NSRegularExpression(pattern: "^" + Self.regex(from: lowered) + "$") else {
                    return nil
                }
                matcher = .regex(regex)
            }
        }

        func matches(path: String, name: String, isDirectory: Bool) -> Bool {
            if directoryOnly, !isDirectory { return false }
            let subject = isAnchored ? path : name
            switch matcher {
            case .name(let literal):
                return subject == literal
            case .nameSuffix(let suffix):
                return subject.hasSuffix(suffix)
            case .regex(let regex):
                let range = NSRange(subject.startIndex..., in: subject)
                return regex.firstMatch(in: subject, range: range) != nil
            }
        }

        /// Translates a gitignore glob into a regular expression body.
        private static func regex(from glob: String) -> String {
            let chars = Array(glob)
            var out = ""
            var i = 0
            while i < chars.count {
                let c = chars[i]
                switch c {
                case "*":
                    if i + 1 < chars.count, chars[i + 1] == "*" {
                        let atStart = i == 0
                        let afterSlash = i > 0 && chars[i - 1] == "/"
                        let beforeSlash = i + 2 < chars.count && chars[i + 2] == "/"
                        let atEnd = i + 2 == chars.count
                        if atStart && atEnd {
                            // "**" or "/**" — everything.
                            out += ".*"
                            i += 2
                            continue
                        } else if (atStart || afterSlash) && beforeSlash {
                            // "**/" — zero or more leading folders.
                            out += "(?:.*/)?"
                            i += 3
                            continue
                        } else if afterSlash && atEnd {
                            // "/**" — everything inside.
                            out += ".*"
                            i += 2
                            continue
                        }
                        // Any other "**" behaves like "*".
                        out += "[^/]*"
                        i += 2
                        continue
                    }
                    out += "[^/]*"
                case "?":
                    out += "[^/]"
                case "[":
                    if let close = chars[(i + 1)...].firstIndex(of: "]"), close > i + 1 {
                        var body = String(chars[(i + 1)..<close])
                        if body.hasPrefix("!") { body = "^" + body.dropFirst() }
                        body = body.replacingOccurrences(of: "\\", with: "\\\\")
                        out += "[" + body + "]"
                        i = close + 1
                        continue
                    }
                    out += "\\["
                case "\\":
                    if i + 1 < chars.count {
                        out += NSRegularExpression.escapedPattern(for: String(chars[i + 1]))
                        i += 2
                        continue
                    }
                default:
                    out += NSRegularExpression.escapedPattern(for: String(c))
                }
                i += 1
            }
            return out
        }
    }
}

/// The ignore files that apply inside one folder, outermost first.
nonisolated struct GitIgnoreStack: Sendable {
    private(set) var files: [GitIgnoreFile] = []

    /// The rules in effect at a project's root, before its own .gitignore: the
    /// repository's `info/exclude`, and when the project is a folder inside its
    /// repository, the .gitignore files of the folders above it, which git applies
    /// there too.
    static func project(at root: URL) -> GitIgnoreStack {
        project(at: root, in: GitRepository.locate(containing: root)) ?? GitIgnoreStack()
    }

    /// The same, for a project whose repository has already been looked up; `nil`
    /// when git ignores the project folder or one above it. Git ignores all of the
    /// project then, but it was opened on purpose: it's treated as outside the
    /// repository, with only its own rules.
    static func project(at root: URL, in repository: GitRepository?) -> GitIgnoreStack? {
        guard let repository else { return GitIgnoreStack() }
        func read(_ url: URL) -> String? {
            (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        }
        let exclude = read(URL(filePath: repository.commonDirectory).appending(path: "info/exclude"))
        var stack = GitIgnoreStack()
            .adding(exclude.map { GitIgnoreFile(base: "", contents: $0, outerPath: repository.prefix) })
        guard !repository.prefix.isEmpty else { return stack }
        // The same rules relative to the repository's root, to check the folders on
        // the way down to the project.
        var fromRoot = GitIgnoreStack().adding(exclude.map { GitIgnoreFile(base: "", contents: $0) })

        // Named as `locate` names them: from where the folder really is.
        let folders = repository.prefix.split(separator: "/").map(String.init)
        var folder = URL(
            filePath: GitRepository.canonicalPath(root.path(percentEncoded: false)).trimmingTrailingSlash,
            directoryHint: .isDirectory
        )
        for _ in folders { folder = folder.deletingLastPathComponent() }
        for (depth, name) in folders.enumerated() {
            if let text = read(folder.appending(path: ".gitignore")) {
                let below = folders[depth...].joined(separator: "/") + "/"
                stack = stack.adding(GitIgnoreFile(base: "", contents: text, outerPath: below))
                fromRoot = fromRoot.adding(GitIgnoreFile(base: folders[..<depth].joined(separator: "/"), contents: text))
            }
            if fromRoot.isIgnored(folders[...depth].joined(separator: "/"), isDirectory: true) {
                return nil
            }
            folder = folder.appending(path: name, directoryHint: .isDirectory)
        }
        return stack
    }

    func adding(_ file: GitIgnoreFile?) -> GitIgnoreStack {
        guard let file, !file.isEmpty else { return self }
        var copy = self
        copy.files.append(file)
        return copy
    }

    /// Whether `path` (project-relative) is ignored. Deeper files and later rules win.
    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for file in files {
            let relative: String
            if file.base.isEmpty {
                relative = path
            } else if path.hasPrefix(file.base + "/") {
                relative = String(path.dropFirst(file.base.count + 1))
            } else {
                continue
            }
            if let decision = file.decision(for: relative, isDirectory: isDirectory) {
                ignored = decision
            }
        }
        return ignored
    }
}
