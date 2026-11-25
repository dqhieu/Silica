import Foundation
import Testing

/// A folder to lay out like a repository, with the files git would leave there.
/// No git is run.
private nonisolated struct ScratchFolder {
    let url: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory.appending(path: "silica-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // As the kernel names it: /private/var, not /var.
        url = URL(filePath: GitRepository.canonicalPath(made.path(percentEncoded: false)), directoryHint: .isDirectory)
    }

    func url(_ name: String) -> URL { url.appending(path: name, directoryHint: .isDirectory) }

    func folder(_ name: String) throws {
        try FileManager.default.createDirectory(at: url(name), withIntermediateDirectories: true)
    }

    /// Writes a file, making the folders above it.
    func file(_ name: String, _ text: String = "") throws {
        let file = url.appending(path: name, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// A repository at `name`, with the git directory files `locate` looks for.
    func repository(_ name: String) throws {
        try file(name + "/.git/HEAD", "ref: refs/heads/main\n")
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The node at `path` in the tree, expanding the folders on the way.
private func node(_ path: String, in root: FileNode) -> FileNode? {
    var current = root
    for name in path.split(separator: "/") {
        current.loadChildrenIfNeeded()
        guard let next = current.children?.first(where: { $0.name == name }) else { return nil }
        current = next
    }
    return current
}

@Suite("GitIgnoreStack.project: rules from outside the project")
struct GitIgnoreProjectTests {
    @Test func aFolderInsideARepositoryUsesTheRepositorysGitignore() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", ".next/\n*.tsbuildinfo\n")
        try scratch.file("repository/apps/web/.next/server/page.js")
        try scratch.file("repository/apps/web/tsconfig.tsbuildinfo")
        try scratch.file("repository/apps/web/src/page.tsx")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored(".next", isDirectory: true))
        #expect(rules.isIgnored("tsconfig.tsbuildinfo", isDirectory: false))
        #expect(!rules.isIgnored("src/page.tsx", isDirectory: false))
    }

    @Test func anchoredRulesAboveAreReadFromTheirOwnFolder() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "/apps/web/generated/\n/build/\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("generated", isDirectory: true))
        // "/build/" is the repository's own build folder, not the project's.
        #expect(!rules.isIgnored("build", isDirectory: true))
    }

    @Test func aGitignoreInAFolderBetweenAppliesToo() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/apps/.gitignore", "*.log\n/web/cache/\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("server.log", isDirectory: false))
        #expect(rules.isIgnored("cache", isDirectory: true))
    }

    @Test func aDeeperGitignoreAboveWinsOverTheRepositoryRoots() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "*.log\n")
        try scratch.file("repository/apps/.gitignore", "!keep.log\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("other.log", isDirectory: false))
        #expect(!rules.isIgnored("keep.log", isDirectory: false))
    }

    /// "/**" ignores everything; the folders on the way are let back in.
    @Test func everythingIgnoredFromAboveExceptTheWayDown() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "/**\n!/apps/\n!/apps/web/\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("index.js", isDirectory: false))
        #expect(rules.isIgnored("src/page.tsx", isDirectory: false))
    }

    /// Git would ignore all of it; opened on purpose, it keeps only its own rules.
    @Test(arguments: ["apps/\n", "/apps/web/\n", "apps/*\n", "/*\n", "apps/**/\n", "*\n!apps/web/keep.txt\n"])
    func aProjectInAnIgnoredFolderGetsNoRulesFromAbove(gitignore: String) throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", gitignore)
        try scratch.folder("repository/apps/web")

        #expect(GitIgnoreStack.project(at: scratch.url("repository/apps/web")).files.isEmpty)
    }

    /// The root's own .gitignore is read with the project's, not as one from above.
    @Test func aProjectAtTheRepositoryRootGetsOnlyInfoExclude() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "*.log\n")
        try scratch.file("repository/.git/info/exclude", "notes.md\n")

        let rules = GitIgnoreStack.project(at: scratch.url("repository"))
        #expect(rules.files.count == 1)
        #expect(rules.isIgnored("notes.md", isDirectory: false))
        #expect(!rules.isIgnored("server.log", isDirectory: false))
    }

    @Test func infoExcludeIsReadFromTheRepositorysRoot() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.git/info/exclude", "scratch/\n/apps/web/notes.md\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("scratch", isDirectory: true))
        #expect(rules.isIgnored("notes.md", isDirectory: false))
    }

    @Test func aGitignoreAboveWinsOverInfoExclude() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.git/info/exclude", "*.log\n")
        try scratch.file("repository/.gitignore", "!keep.log\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("other.log", isDirectory: false))
        #expect(!rules.isIgnored("keep.log", isDirectory: false))
    }

    /// A slash in the middle anchors a pattern to its own folder, as one at the start does.
    @Test func aPatternWithASlashInTheMiddleIsReadFromItsOwnFolder() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "apps/web/generated/\nweb/cache/\n")
        try scratch.folder("repository/apps/web")

        let rules = GitIgnoreStack.project(at: scratch.url("repository/apps/web"))
        #expect(rules.isIgnored("generated", isDirectory: true))
        #expect(!rules.isIgnored("generated", isDirectory: false))
        #expect(!rules.isIgnored("cache", isDirectory: true))
    }

    /// A linked worktree keeps `info/exclude` in the main repository's git directory.
    @Test func aLinkedWorktreeUsesTheSharedInfoExclude() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("main")
        try scratch.file("main/.git/info/exclude", "notes.md\n")
        try scratch.file("main/.git/worktrees/linked/HEAD", "ref: refs/heads/feature\n")
        try scratch.file("main/.git/worktrees/linked/commondir", "../..\n")
        try scratch.file("linked/.git", "gitdir: ../main/.git/worktrees/linked\n")

        let rules = GitIgnoreStack.project(at: scratch.url("linked"))
        #expect(rules.isIgnored("notes.md", isDirectory: false))
    }

    @Test func aProjectOutsideARepositoryHasNoRulesFromOutside() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.file(".gitignore", "*\n")
        try scratch.folder("project")

        let rules = GitIgnoreStack.project(at: scratch.url("project"))
        #expect(rules.files.isEmpty)
    }
}

@Suite("FileNode: a project that is a folder inside its repository")
struct FileNodeIgnoreTests {
    @Test func itemsTheRepositoryIgnoresAreDimmed() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "node_modules/\n.next/\n")
        try scratch.file("repository/apps/web/node_modules/react/index.js")
        try scratch.file("repository/apps/web/.next/server/page.js")
        try scratch.file("repository/apps/web/src/page.tsx")

        let root = FileNode(root: scratch.url("repository/apps/web"))
        #expect(node("node_modules", in: root)?.isDimmed == true)
        #expect(node(".next/server/page.js", in: root)?.isDimmed == true)
        #expect(node("src/page.tsx", in: root)?.isDimmed == false)
    }

    @Test func theProjectsOwnGitignoreStillWinsOverTheRepositorys() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/.gitignore", "*.log\n")
        try scratch.file("repository/apps/web/.gitignore", "!keep.log\n")
        try scratch.file("repository/apps/web/keep.log")
        try scratch.file("repository/apps/web/other.log")

        let root = FileNode(root: scratch.url("repository/apps/web"))
        #expect(node("keep.log", in: root)?.isDimmed == false)
        #expect(node("other.log", in: root)?.isDimmed == true)
    }

    @Test func reloadingReadsTheRepositorysRulesAgain() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/apps/web/server.log")

        let root = FileNode(root: scratch.url("repository/apps/web"))
        #expect(node("server.log", in: root)?.isDimmed == false)
        try scratch.file("repository/.gitignore", "*.log\n")
        root.reload()
        #expect(node("server.log", in: root)?.isDimmed == true)
    }

    /// Git ignores all of it; it's shown as a folder outside a repository instead.
    @Test func aProjectInAnIgnoredFolderIsShownAsOutsideTheRepository() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("home")
        try scratch.file("home/.gitignore", "*\n")
        try scratch.file("home/projects/web/.github/workflows/ci.yml")
        try scratch.file("home/projects/web/src/page.tsx")

        let root = FileNode(root: scratch.url("home/projects/web"))
        #expect(node("src/page.tsx", in: root)?.isDimmed == false)
        #expect(node(".github", in: root)?.isDimmed == true)
    }

    /// As in a project at the repository's root, tracked dotfolders aren't dimmed.
    @Test func dotfilesAreNotDimmedInsideARepository() throws {
        let scratch = try ScratchFolder()
        defer { scratch.remove() }
        try scratch.repository("repository")
        try scratch.file("repository/apps/web/.github/workflows/ci.yml")
        try scratch.file("outside/.github/workflows/ci.yml")

        #expect(node(".github", in: FileNode(root: scratch.url("repository/apps/web")))?.isDimmed == false)
        #expect(node(".github", in: FileNode(root: scratch.url("outside")))?.isDimmed == true)
    }
}
