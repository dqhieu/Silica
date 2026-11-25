import Foundation
import Observation

/// One row in the Quick Open list.
struct QuickOpenResult: Identifiable {
    let item: QuickOpenItem
    /// Matched scalar indices into `item.path`, for highlighting.
    let positions: [Int]
    let isRecent: Bool

    var id: URL { item.url }
}

/// State behind Quick Open (⌘P): a background-built index of the project's files,
/// the query, the ranked results and the keyboard selection.
@Observable
final class QuickOpenModel {
    static let resultLimit = 60

    let rootURL: URL

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            updateResults()
        }
    }
    private(set) var results: [QuickOpenResult] = []
    var selectedIndex = 0
    private(set) var isIndexing = false

    @ObservationIgnored private var items: [QuickOpenItem] = [] {
        didSet { indexedURLs = Set(items.map(\.url)) }
    }
    @ObservationIgnored private var indexedURLs: Set<URL> = []
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// Most recently opened files first.
    @ObservationIgnored private(set) var recentFiles: [URL] = []

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    var selectedResult: QuickOpenResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Sets the query (usually empty, ":" for Go to Line) and rescans the project;
    /// the previous index is shown meanwhile.
    func prepareForPresentation(activeFile: URL?, query: String = "") {
        self.activeFile = activeFile
        if self.query == query {
            updateResults()
        } else {
            self.query = query
        }
        presentationCount += 1
        reindex(activeFile: activeFile)
    }

    /// Follows renamed files in the recent list.
    func noteMoved(_ transform: (URL) -> URL?) {
        recentFiles = recentFiles.map { transform($0) ?? $0 }
    }

    /// From a trailing ":42" in the query: the line to go to.
    private(set) var lineTarget: Int?
    /// The query is only ":" and a number: Go to Line in the current file.
    private(set) var isGoToLine = false
    /// Bumped each time the panel is shown, to put the cursor after any prefilled text.
    private(set) var presentationCount = 0

    func noteOpened(_ url: URL) {
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 30 { recentFiles.removeLast() }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    // MARK: Results

    @ObservationIgnored private var activeFile: URL?

    private func updateResults(activeFile: URL? = nil) {
        if let activeFile { self.activeFile = activeFile }
        var text = self.query
        if let suffix = text.range(of: #":\d*$"#, options: .regularExpression) {
            lineTarget = Int(text[suffix].dropFirst())
            text = String(text[..<suffix.lowerBound])
        } else {
            lineTarget = nil
        }
        isGoToLine = text.isEmpty && self.query.hasPrefix(":")
        guard !isGoToLine else {
            results = []
            selectedIndex = 0
            return
        }
        let query = FuzzyMatcher.prepare(text)

        if query.isEmpty {
            results = defaultResults()
        } else {
            var matches: [(QuickOpenItem, FuzzyMatch)] = []
            for item in items + ignoredRecentItems() {
                if let match = FuzzyMatcher.match(query, in: item) {
                    matches.append((item, match))
                }
            }
            matches.sort { lhs, rhs in
                if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
                if lhs.0.path.count != rhs.0.path.count { return lhs.0.path.count < rhs.0.path.count }
                return lhs.0.path < rhs.0.path
            }
            results = matches.prefix(Self.resultLimit).map {
                QuickOpenResult(item: $0.0, positions: $0.1.positions, isRecent: false)
            }
        }
        selectedIndex = 0
    }

    /// With no query: recently opened files (except the current one), then the rest by path.
    private func defaultResults() -> [QuickOpenResult] {
        let byURL = Dictionary((items + ignoredRecentItems()).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = recentFiles
            .filter { $0 != activeFile }
            .compactMap { byURL[$0] }
        let recentSet = Set(recent.map(\.url))
        let rest = items.lazy.filter { !recentSet.contains($0.url) && $0.url != self.activeFile }
        return (recent.map { QuickOpenResult(item: $0, positions: [], isRecent: true) }
            + rest.prefix(Self.resultLimit).map { QuickOpenResult(item: $0, positions: [], isRecent: false) })
            .prefix(Self.resultLimit)
            .map { $0 }
    }

    /// Recently opened files the index left out (e.g. gitignored), so they can still
    /// be found again, as in VS Code.
    private func ignoredRecentItems() -> [QuickOpenItem] {
        let rootPath = rootURL.path(percentEncoded: false).trimmingTrailingSlash
        return recentFiles.compactMap { url in
            guard !indexedURLs.contains(url) else { return nil }
            let path = url.path(percentEncoded: false)
            guard path.hasPrefix(rootPath + "/"), FileManager.default.fileExists(atPath: path) else { return nil }
            return QuickOpenItem(url: url, path: String(path.dropFirst(rootPath.count + 1)))
        }
    }

    // MARK: Index

    private func reindex(activeFile: URL?) {
        indexTask?.cancel()
        isIndexing = true
        let root = rootURL
        indexTask = Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) {
                ProjectFileIndex.scan(root: root)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.items = items
            self.isIndexing = false
            let selected = self.selectedResult?.id
            self.updateResults()
            // Keep the highlighted row if it is still there after the refresh.
            if let selected, let index = self.results.firstIndex(where: { $0.id == selected }) {
                self.selectedIndex = index
            }
        }
    }
}

/// Lists a project's files for Quick Open, leaving out what git would ignore.
nonisolated enum ProjectFileIndex {
    static let maxFiles = 50_000

    /// Always skipped, even without a .gitignore: version-control metadata,
    /// dependencies and build output.
    static let skippedFolders: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", ".build", ".swiftpm", "DerivedData", "Pods",
    ]

    static func scan(root: URL) -> [QuickOpenItem] {
        let rootPath = root.path(percentEncoded: false).trimmingTrailingSlash
        guard let enumerator = FileManager().enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        // Ignore rules in effect inside each folder, keyed by project-relative path.
        // The enumerator visits a folder before its contents, so a parent's entry
        // always exists when a child needs it.
        let rootRules = GitIgnoreStack.project(at: root)
            .adding(GitIgnoreFile(base: "", url: root.appending(path: ".gitignore")))
        var rulesByFolder: [String: GitIgnoreStack] = ["": rootRules]

        var items: [QuickOpenItem] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { return [] }
            // Folder URLs from the enumerator end in "/"; rules and keys expect none.
            let path = url.path(percentEncoded: false).trimmingTrailingSlash
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let name = url.lastPathComponent
            let parent = relative.lastIndex(of: "/").map { String(relative[..<$0]) } ?? ""
            let rules = rulesByFolder[parent] ?? rootRules

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if skippedFolders.contains(name) || rules.isIgnored(relative, isDirectory: true) {
                    enumerator.skipDescendants()
                } else {
                    rulesByFolder[relative] = rules.adding(
                        GitIgnoreFile(base: relative, url: url.appending(path: ".gitignore"))
                    )
                }
                continue
            }
            if name == ".DS_Store" || rules.isIgnored(relative, isDirectory: false) { continue }

            // Same form as the explorer tree's URLs, so tabs aren't opened twice.
            let normalized = URL(filePath: path, directoryHint: .notDirectory)
            items.append(QuickOpenItem(url: normalized, path: relative))
            if items.count >= maxFiles { break }
        }
        items.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return items
    }
}
