import Foundation

/// How a file differs from the last commit, as the explorer tree shows it.
nonisolated enum GitFileStatus: Sendable, Equatable {
    case modified
    case added
    case renamed
    case untracked
    case deleted
    case conflicted

    /// Which status a folder takes from the files inside it: the one most worth
    /// a look.
    fileprivate var weight: Int {
        switch self {
        case .conflicted: 3
        case .modified, .deleted: 2
        case .added, .renamed, .untracked: 1
        }
    }

    /// Whether an unstaged change of this kind can be thrown away from the Changes
    /// panel: an edit or a deletion is undone, an untracked file goes to the Trash.
    /// A conflict has to be settled, not discarded.
    var isDiscardable: Bool {
        self == .modified || self == .deleted || self == .untracked
    }
}

/// The repository a project folder belongs to: its own, or one further up.
nonisolated struct GitRepository: Sendable, Equatable {
    /// Where this working tree's index and HEAD are: `.git` itself, or for a linked
    /// worktree or a submodule, the folder its `.git` file points to. Canonical, as
    /// file system events report paths.
    let gitDirectory: String
    /// The project folder's path inside the working tree, ending in "/", or ""
    /// when the project is the working tree's root.
    let prefix: String

    static func locate(containing root: URL) -> GitRepository? {
        let files = FileManager.default
        // From where the folder really is, as git looks from there too: reached
        // through a symlink, its place in the repository is the one git names
        // its files by, not the symlink's.
        var folder = canonicalPath(root.path(percentEncoded: false)).trimmingTrailingSlash
        var below: [String] = []
        while true {
            let dotGit = (folder as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                let directory = isDirectory.boolValue ? dotGit : linkedGitDirectory(in: dotGit, of: folder)
                guard let directory else { return nil }
                return GitRepository(
                    gitDirectory: canonicalPath(directory),
                    prefix: below.isEmpty ? "" : below.joined(separator: "/") + "/"
                )
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, !parent.isEmpty else { return nil }
            below.insert((folder as NSString).lastPathComponent, at: 0)
            folder = parent
        }
    }

    /// Where what every worktree shares is kept, such as `info/exclude`: the git
    /// directory itself, or for a linked worktree, the folder its `commondir` names.
    var commonDirectory: String {
        let file = (gitDirectory as NSString).appendingPathComponent("commondir")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return gitDirectory }
        let path = text.trimmingCharacters(in: .newlines)
        guard !path.isEmpty else { return gitDirectory }
        let full = path.hasPrefix("/") ? path : (gitDirectory as NSString).appendingPathComponent(path)
        // Resolved as git would: symlinks first, then "..".
        return Self.canonicalPath(full)
    }

    /// The folder a `.git` file names ("gitdir: <path>"), relative to its own folder.
    private static func linkedGitDirectory(in file: String, of folder: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
    }

    /// With symlinks resolved the way the kernel does (`/tmp` to `/private/tmp`,
    /// which `resolvingSymlinksInPath` undoes).
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Something git stopped in the middle of so that conflicts can be settled: it
/// goes on once they are, or is called off.
nonisolated struct GitPendingOperation: Sendable, Equatable {
    enum Kind: Sendable {
        case merge, rebase, cherryPick, revert

        /// The git command that continues or aborts it.
        var command: String {
            switch self {
            case .merge: "merge"
            case .rebase: "rebase"
            case .cherryPick: "cherry-pick"
            case .revert: "revert"
            }
        }
    }

    var kind: Kind
    /// For a rebase: the branch being rebased (HEAD is detached meanwhile), and
    /// which of its commits is being applied, out of how many.
    var branch: String?
    var step: Int?
    var stepCount: Int?

    /// Reads what git leaves in its directory while one is under way.
    static func find(in gitDirectory: String) -> GitPendingOperation? {
        let files = FileManager.default
        func path(_ name: String) -> String { (gitDirectory as NSString).appendingPathComponent(name) }
        func text(_ name: String) -> String? {
            (try? String(contentsOfFile: path(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A rebase first: it applies commits as cherry-picks, and leaves their
        // mark too. Its two ways of working keep their notes in different places.
        for (folder, step, count) in [("rebase-merge", "msgnum", "end"), ("rebase-apply", "next", "last")]
        where files.fileExists(atPath: path(folder)) {
            // `git am` keeps the patches it is applying in "rebase-apply" as well,
            // marked "applying". That is no rebase: `rebase --continue` and
            // `--abort` would find nothing to go on with or call off.
            if folder == "rebase-apply", files.fileExists(atPath: path(folder + "/applying")) { continue }
            var branch = text(folder + "/head-name")
            if let name = branch, name.hasPrefix("refs/heads/") { branch = String(name.dropFirst("refs/heads/".count)) }
            return GitPendingOperation(
                kind: .rebase, branch: branch,
                step: text(folder + "/" + step).flatMap(Int.init), stepCount: text(folder + "/" + count).flatMap(Int.init)
            )
        }
        if files.fileExists(atPath: path("MERGE_HEAD")) { return GitPendingOperation(kind: .merge) }
        if files.fileExists(atPath: path("CHERRY_PICK_HEAD")) { return GitPendingOperation(kind: .cherryPick) }
        if files.fileExists(atPath: path("REVERT_HEAD")) { return GitPendingOperation(kind: .revert) }
        return nil
    }
}

/// A file git reports as changed: in the index, staged for the next commit, or
/// in the working tree. A file with both kinds of change is listed once for each.
nonisolated struct GitChange: Sendable, Equatable, Identifiable {
    /// Path from the project root.
    let path: String
    let status: GitFileStatus
    let isStaged: Bool

    var id: String { (isStaged ? "staged:" : "changed:") + path }
}

/// What HEAD points to and how it stands against the branch it pushes to.
nonisolated struct GitBranch: Sendable, Equatable {
    /// `nil` when HEAD is detached.
    var name: String?
    /// False in a new repository, before its first commit.
    var hasCommits = true
    /// The commit HEAD is at.
    var head: String?
    /// The branch this one pushes to and pulls from ("origin/main"), if it has one.
    var upstream: String?
    /// Commits here that the upstream lacks, and the other way round; `nil`
    /// without an upstream, or when the upstream isn't there any more.
    var ahead: Int?
    var behind: Int?
    /// Without an upstream, the remote to fetch from and to publish the branch
    /// to: "origin", or the first remote there is.
    var remote: String?

    /// Whether there is something to push and somewhere to push it.
    var canPush: Bool {
        guard name != nil, hasCommits else { return false }
        if upstream != nil { return ahead.map { $0 > 0 } ?? true }
        return remote != nil
    }

    /// Whether there is a remote to ask for new commits.
    var canFetch: Bool { upstream != nil || remote != nil }

    /// Whether the branch has an upstream to take new commits from. How many
    /// there are is only known after a fetch, so not whether there are any.
    var canPull: Bool { name != nil && upstream != nil }
}

/// Reads what `git status` reports for a project folder.
nonisolated enum GitStatus {
    struct Snapshot: Sendable, Equatable {
        /// Changed files by project-relative path. A submodule or a nested
        /// repository is listed as a whole, under its folder's path.
        var files: [String: GitFileStatus] = [:]
        /// Every folder above a changed file, with the status that stands for them.
        var folders: [String: GitFileStatus] = [:]
        /// Where renamed files were in the last commit, by the path they have now.
        var renamedFrom: [String: String] = [:]
        /// The changes staged for the next commit and those that aren't, each in
        /// path order, as the Changes list shows them.
        var staged: [GitChange] = []
        var unstaged: [GitChange] = []
        /// Staged files in the repository but outside the project folder, which a
        /// commit takes along.
        var stagedElsewhere = 0
        var branch = GitBranch()
        /// The repository's branches, most recently committed to first, and the
        /// remotes' branches ("origin/main") that have no local branch of their name.
        var localBranches: [String] = []
        var remoteBranches: [String] = []
        /// Changes put aside with `git stash`, newest first.
        var stashes: [GitStash] = []
        /// A merge or rebase that stopped for conflicts and hasn't been finished.
        var pending: GitPendingOperation?

        /// Files with conflicts still to settle.
        var conflictCount: Int { unstaged.count { $0.status == .conflicted } }
    }

    /// What one run of `git status` says.
    struct Report {
        /// Each changed file's status against the last commit, whether staged or not.
        var files: [String: GitFileStatus] = [:]
        var renamedFrom: [String: String] = [:]
        var staged: [String: GitFileStatus] = [:]
        var unstaged: [String: GitFileStatus] = [:]
        var stagedElsewhere = 0
        var branch = GitBranch()
        var stashCount = 0
    }

    /// `nil` when the folder isn't in a repository or git isn't installed.
    static func load(root: URL) -> Snapshot? {
        guard let repository = GitRepository.locate(containing: root) else { return nil }
        // Without optional locks, `status` leaves the index alone: rewriting it
        // would look like a change to the repository and start the next refresh.
        // Every untracked file is listed, not just its folder, so each has a path
        // to match its row in the tree. Only the project folder is looked at: in a
        // folder of a larger repository (a home folder kept in git, a monorepo),
        // the rest can be very many files.
        guard let output = Git.run([
            "--no-optional-locks", "-C", root.path(percentEncoded: false),
            "status", "--porcelain=v2", "--branch", "--show-stash", "-z", "--untracked-files=all", "--", ".",
        ]) else { return nil }
        var report = parse(output, prefix: repository.prefix)
        // What is staged elsewhere in the repository, which a commit takes along,
        // is in the index: no files need looking at to count it.
        if !repository.prefix.isEmpty, let staged = Git.run([
            "--no-optional-locks", "-C", root.path(percentEncoded: false), "diff", "--cached", "--name-only", "-z",
        ]) {
            report.stagedElsewhere = staged.split(separator: 0).count {
                !String(decoding: $0, as: UTF8.self).hasPrefix(repository.prefix)
            }
        }
        if report.branch.upstream == nil,
           let remotes = Git.run(["-C", root.path(percentEncoded: false), "remote"]) {
            let names = String(decoding: remotes, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
            report.branch.remote = names.contains("origin") ? "origin" : names.first
        }
        var snapshot = snapshot(of: report)
        (snapshot.localBranches, snapshot.remoteBranches) = branches(root: root)
        // Listed only when status says there are any, which is seldom.
        if report.stashCount > 0 { snapshot.stashes = GitHistory.stashes(root: root) }
        snapshot.pending = GitPendingOperation.find(in: repository.gitDirectory)
        return snapshot
    }

    private static func branches(root: URL) -> (local: [String], remote: [String]) {
        guard let output = Git.run([
            "-C", root.path(percentEncoded: false),
            "for-each-ref", "--sort=-committerdate", "--format=%(refname)", "refs/heads", "refs/remotes",
        ]) else { return ([], []) }
        var local: [String] = []
        var remote: [String] = []
        for line in String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("refs/heads/") {
                local.append(String(line.dropFirst("refs/heads/".count)))
            } else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") {
                remote.append(String(line.dropFirst("refs/remotes/".count)))
            }
        }
        // "origin/topic" is how to get a "topic" there isn't one of yet. A remote's
        // name is taken to be the part before the first slash.
        let known = Set(local)
        remote.removeAll { name in
            name.firstIndex(of: "/").map { known.contains(String(name[name.index(after: $0)...])) } ?? false
        }
        return (local, remote)
    }

    /// Reads porcelain v2 output with NUL separators. Paths are relative to the
    /// working tree's root; only those under `prefix` are kept, with it removed.
    static func parse(_ output: Data, prefix: String) -> Report {
        var report = Report()
        var records = output.split(separator: 0).makeIterator()
        while let record = records.next() {
            let line = String(decoding: record, as: UTF8.self)
            let status: GitFileStatus
            // The change in the index and the one in the working tree, where
            // there is one.
            var staged: GitFileStatus?
            var unstaged: GitFileStatus?
            let path: Substring
            var original: String?
            switch line.first {
            case "#":
                // "# stash 2", among the lines about the branch.
                if line.hasPrefix("# stash ") {
                    report.stashCount = Int(line.dropFirst("# stash ".count)) ?? 0
                } else {
                    readHeader(line, into: &report.branch)
                }
                continue
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = line.split(separator: " ", maxSplits: 8)
                guard fields.count == 9 else { continue }
                status = Self.status(index: fields[1].first, workTree: fields[1].last)
                staged = Self.change(fields[1].first)
                unstaged = Self.change(fields[1].last)
                path = fields[8]
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path, then the old path as a record
                // of its own.
                let fields = line.split(separator: " ", maxSplits: 9)
                original = records.next().map { String(decoding: $0, as: UTF8.self) }
                guard fields.count == 10 else { continue }
                status = fields[1].last == "D" ? .deleted : .renamed
                staged = Self.change(fields[1].first)
                unstaged = Self.change(fields[1].last)
                path = fields[9]
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = line.split(separator: " ", maxSplits: 10)
                guard fields.count == 11 else { continue }
                status = .conflicted
                unstaged = .conflicted
                path = fields[10]
            case "?":
                status = .untracked
                unstaged = .untracked
                path = line.dropFirst(2)
            default:
                continue
            }
            guard path.hasPrefix(prefix) else { continue }
            // A nested repository is listed as a folder, with a trailing slash.
            let relative = String(path.dropFirst(prefix.count)).trimmingTrailingSlash
            guard !relative.isEmpty else { continue }
            report.files[relative] = status
            report.staged[relative] = staged
            report.unstaged[relative] = unstaged
            if let original, original.hasPrefix(prefix) {
                report.renamedFrom[relative] = String(original.dropFirst(prefix.count))
            }
        }
        return report
    }

    /// The "# branch.…" lines that come before the files.
    private static func readHeader(_ line: String, into branch: inout GitBranch) {
        let fields = line.split(separator: " ")
        guard fields.count >= 3 else { return }
        switch fields[1] {
        case "branch.oid":
            branch.hasCommits = fields[2] != "(initial)"
            branch.head = branch.hasCommits ? String(fields[2]) : nil
        case "branch.head":
            branch.name = fields[2] == "(detached)" ? nil : String(fields[2])
        case "branch.upstream":
            branch.upstream = String(fields[2])
        case "branch.ab":
            // +<ahead> -<behind>
            guard fields.count == 4 else { return }
            branch.ahead = Int(fields[2].dropFirst())
            branch.behind = Int(fields[3].dropFirst())
        default:
            break
        }
    }

    /// One side of XY as a change of its own; "." is no change.
    private static func change(_ code: Character?) -> GitFileStatus? {
        switch code {
        case ".", nil: nil
        case "A": .added
        case "D": .deleted
        case "R", "C": .renamed
        default: .modified
        }
    }

    /// X is the change staged in the index and Y the change in the working tree,
    /// each "." when there is none.
    private static func status(index: Character?, workTree: Character?) -> GitFileStatus {
        if index == "D" || workTree == "D" { return .deleted }
        // "A" in the working tree is a file added with `git add --intent-to-add`:
        // nothing of it is staged, and the last commit doesn't have it either.
        if index == "A" || workTree == "A" { return .added }
        if index == "R" || index == "C" { return .renamed }
        return .modified
    }

    private static func snapshot(of report: Report) -> Snapshot {
        var folders: [String: GitFileStatus] = [:]
        for (path, file) in report.files {
            // A folder that lost a file has changed; it isn't itself deleted.
            let status = file == .deleted ? .modified : file
            var folder = path[...]
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                let key = String(folder)
                if let known = folders[key], known.weight >= status.weight { break }
                folders[key] = status
            }
        }
        func changes(_ files: [String: GitFileStatus], isStaged: Bool) -> [GitChange] {
            files
                .map { GitChange(path: $0.key, status: $0.value, isStaged: isStaged) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return Snapshot(
            files: report.files, folders: folders, renamedFrom: report.renamedFrom,
            staged: changes(report.staged, isStaged: true), unstaged: changes(report.unstaged, isStaged: false),
            stagedElsewhere: report.stagedElsewhere, branch: report.branch
        )
    }
}

/// Lets whoever started git commands stop them: the one running is ended and
/// none after it starts. It reaches the commands through the task they run in.
nonisolated final class GitCancellation: @unchecked Sendable {
    @TaskLocal static var current: GitCancellation?

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    /// Takes note of a command that has started; ends it if this was cancelled
    /// just before.
    fileprivate func started(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = cancelled
        lock.unlock()
        if stop, process.isRunning { process.terminate() }
    }

    fileprivate func finished() {
        lock.lock()
        process = nil
        lock.unlock()
    }
}

/// What a command has written so far, gathered as it comes.
private nonisolated final class GitOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs the git command line tool.
nonisolated enum Git {
    /// `/usr/bin/git` is a stub that puts up the system's "install the command
    /// line developer tools" dialog on a Mac without them, so it's only run where
    /// they're installed; failing that, a Homebrew git.
    private static let executable: String? = {
        if run("/usr/bin/xcode-select", ["-p"]) != nil { return "/usr/bin/git" }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    /// git's output, or `nil` if there's no git to run or it ended with a status
    /// outside `success` (`diff` ends with 1 when it found differences).
    static func run(_ arguments: [String], success: ClosedRange<Int32> = 0...0) -> Data? {
        executable.flatMap { run($0, arguments, success: success) }
    }

    /// How a command that changes the repository went.
    struct Outcome: Sendable {
        let succeeded: Bool
        /// Everything git, and any hook it ran, had to say.
        let output: String
    }

    /// Runs a command for what it does, not what it prints, in `root`. Paths in
    /// `arguments` are taken as they are: a file may be named "*.txt".
    /// With `timeout`, git is stopped if it's still running after that many seconds.
    static func perform(_ arguments: [String], in root: URL, timeout: TimeInterval? = nil) -> Outcome {
        guard let executable else { return Outcome(succeeded: false, output: "git isn’t installed.") }
        var status: Int32 = -1
        let data = run(
            executable, ["--literal-pathspecs", "-C", root.path(percentEncoded: false)] + arguments,
            success: 0...0, mergingErrors: true, status: &status, timeout: timeout
        )
        let output = String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Outcome(succeeded: status == 0, output: output)
    }

    /// What git and the hooks it runs see. An app opened from the Finder has only
    /// the system's folders in PATH, so Homebrew's are added: that's where a hook's
    /// tools (git-lfs, node) tend to be. There is no terminal to answer a question
    /// in, so git doesn't ask for a password there; it fails instead.
    private static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        let path = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let added = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.contains($0) }
        environment["PATH"] = (path + added).joined(separator: ":")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Nor is there anywhere to show an editor: a pull that merges takes the
        // message git wrote for it.
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["GIT_EDITOR"] = "true"
        return environment
    }()

    /// The command's output, or `nil` if it couldn't start or failed. With
    /// `mergingErrors`, what it wrote as errors is part of the output, in order,
    /// and the output is returned however it ended.
    private static func run(
        _ executable: String, _ arguments: [String], success: ClosedRange<Int32> = 0...0,
        mergingErrors: Bool = false, status: UnsafeMutablePointer<Int32>? = nil, timeout: TimeInterval? = nil
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = mergingErrors ? output : FileHandle.nullDevice
        let cancellation = GitCancellation.current
        guard cancellation?.isCancelled != true else { return nil }
        // Read as it comes: a long status fills the pipe, and git would block on
        // it forever.
        let collected = GitOutput()
        let reachedEnd = DispatchSemaphore(value: 0)
        let reading = output.fileHandleForReading
        reading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                reachedEnd.signal()
            } else {
                collected.append(chunk)
            }
        }
        do { try process.run() } catch {
            reading.readabilityHandler = nil
            return nil
        }
        cancellation?.started(process)
        defer { cancellation?.finished() }
        // For what nobody is waiting on: a connection that never answers shouldn't
        // keep git, and what waits for it, going without end.
        var deadline: DispatchWorkItem?
        if let timeout {
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: stop)
            deadline = stop
        }
        defer { deadline?.cancel() }
        process.waitUntilExit()
        // git is done when it has exited, not when the pipe closes: something it
        // started (a hook, a connection being torn down after a cancel) can hold
        // the pipe open long after. What's left in it comes at once.
        if reachedEnd.wait(timeout: .now() + 0.5) == .timedOut { reading.readabilityHandler = nil }
        let data = collected.value
        status?.pointee = process.terminationStatus
        return mergingErrors || success.contains(process.terminationStatus) ? data : nil
    }
}

/// Something the Changes panel does to the repository.
nonisolated enum GitOperation: Sendable {
    /// Adds the files' changes, deletions included, to the index.
    case stage([String])
    /// Takes the files' changes out of the index, leaving the files as they are.
    case unstage([String], hasCommits: Bool)
    /// Commits what is staged; with `stagingAll`, everything in the project folder.
    case commit(message: String, stagingAll: Bool)
    /// Pushes the branch to its upstream, or with `publishing`, to a branch of
    /// its name on that remote, which becomes its upstream.
    case push(publishing: (remote: String, branch: String)?)
    /// Asks the branch's remote, or `remote`, for its new commits, changing no file.
    case fetch(remote: String?)
    /// Fetches, then merges or rebases as the repository is set up to.
    case pull
    /// Checks out a local branch.
    case switchTo(String)
    /// Makes a local branch of a remote's ("origin/topic" gives "topic"), tracking
    /// it, and checks that out.
    case track(String)
    /// Makes a branch from where HEAD is and checks it out, taking along any
    /// uncommitted changes.
    case create(String)
    /// Deletes a local branch; `force` even with commits that are nowhere else.
    case deleteBranch(String, force: Bool)
    case renameBranch(String, to: String)
    /// Merges a branch into the current one.
    case merge(String)
    /// Puts tracked files back as they are in the index: as staged, or else as
    /// last committed. What was changed in them since is lost.
    case discard([String])
    /// Puts every change in the project folder aside, untracked files included,
    /// leaving the files as last committed.
    case stash(message: String?)
    /// Brings a stash's changes back, keeping the stash.
    case applyStash(hash: String)
    /// Brings a stash's changes back and, unless that ran into a conflict,
    /// deletes the stash.
    case popStash(GitStash)
    /// Deletes a stash and the changes in it.
    case dropStash(GitStash)
    /// Makes the index hold `content` for a file it already has, leaving the file
    /// itself alone: how one change in a file is staged or unstaged.
    case setIndexContent(path: String, content: Data)
    /// Replaces the last commit with one that also has what is staged, under a
    /// new message if one is given.
    case amend(message: String?)
    /// Takes the last commit back, leaving what it changed staged.
    case undoLastCommit
    /// Goes on with a merge or rebase whose conflicts have been settled and staged.
    case continuePending(GitPendingOperation.Kind)
    /// Calls a merge or rebase off, putting the files back as they were before it.
    case abortPending(GitPendingOperation.Kind)

    func run(in root: URL) -> Git.Outcome {
        switch self {
        case .stage(let paths):
            return Git.perform(["add", "-A", "--"] + paths, in: root)
        case .unstage(let paths, let hasCommits):
            // Before the first commit there is nothing to restore the index from,
            // so the entry is removed. Forced: git otherwise refuses a file edited
            // since it was staged. With `--cached` the file itself is left alone.
            return Git.perform((hasCommits ? ["restore", "--staged", "--"] : ["rm", "--cached", "-f", "-q", "--"]) + paths, in: root)
        case .commit(let message, let stagingAll):
            if stagingAll {
                let staging = Git.perform(["add", "-A", "--", "."], in: root)
                guard staging.succeeded else { return staging }
            }
            return Git.perform(["commit", "-m", message], in: root)
        case .push(let publishing):
            if let publishing {
                return Git.perform(["push", "-u", publishing.remote, publishing.branch], in: root)
            }
            return Git.perform(["push"], in: root)
        case .fetch(let remote):
            return Git.perform(["fetch"] + (remote.map { [$0] } ?? []), in: root)
        case .pull:
            return Git.perform(["pull"], in: root)
        case .switchTo(let branch):
            return Git.perform(["switch", branch], in: root)
        case .track(let branch):
            return Git.perform(["switch", "--track", branch], in: root)
        case .create(let branch):
            return Git.perform(["switch", "-c", branch], in: root)
        case .deleteBranch(let branch, let force):
            return Git.perform(["branch", force ? "-D" : "-d", branch], in: root)
        case .renameBranch(let branch, let name):
            return Git.perform(["branch", "-m", branch, name], in: root)
        case .merge(let branch):
            return Git.perform(["merge", branch], in: root)
        case .discard(let paths):
            return Git.perform(["restore", "--worktree", "--"] + paths, in: root)
        case .stash(let message):
            return Git.perform(
                ["stash", "push", "--include-untracked"] + (message.map { ["-m", $0] } ?? []) + ["--", "."], in: root
            )
        case .applyStash(let hash):
            return Git.perform(["stash", "apply", hash], in: root)
        case .popStash(let stash):
            let applying = Git.perform(["stash", "apply", stash.commit.hash], in: root)
            guard applying.succeeded else { return applying }
            return Self.drop(stash, in: root)
        case .dropStash(let stash):
            return Self.drop(stash, in: root)
        case .setIndexContent(let path, let content):
            return Self.setIndexContent(of: path, to: content, in: root)
        case .amend(let message):
            return Git.perform(["commit", "--amend"] + (message.map { ["-m", $0] } ?? ["--no-edit"]), in: root)
        case .undoLastCommit:
            return Git.perform(["reset", "--soft", "HEAD~1"], in: root)
        case .continuePending(let kind):
            // The commit it makes takes the message git wrote: see the editor in
            // `Git.environment`.
            return Git.perform([kind.command, "--continue"], in: root)
        case .abortPending(let kind):
            return Git.perform([kind.command, "--abort"], in: root)
        }
    }

    private static func setIndexContent(of path: String, to content: Data, in root: URL) -> Git.Outcome {
        guard let repository = GitRepository.locate(containing: root) else {
            return Git.Outcome(succeeded: false, output: "This folder isn’t in a git repository.")
        }
        // "100644 <hash> 0<tab><path>": the entry keeps its mode.
        let entry = Git.perform(["ls-files", "--stage", "--", path], in: root)
        guard entry.succeeded, let mode = entry.output.split(separator: " ").first, mode.count == 6, mode.allSatisfy(\.isNumber) else {
            return Git.Outcome(succeeded: false, output: "The file isn’t in the index.")
        }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "silica-index-" + UUID().uuidString)
        defer { try? files.removeItem(at: folder) }
        let file = folder.appending(path: "content")
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try content.write(to: file)
        } catch {
            return Git.Outcome(succeeded: false, output: error.localizedDescription)
        }
        // As `git add` would store the file at that path: line endings converted,
        // filters applied.
        let stored = Git.perform(["hash-object", "-w", "--path", path, file.path(percentEncoded: false)], in: root)
        // The hash is the last line; a warning about line endings may come before it.
        guard stored.succeeded, let hash = stored.output.split(whereSeparator: \.isNewline).last,
              hash.count >= 40, hash.allSatisfy(\.isHexDigit) else {
            return Git.Outcome(succeeded: false, output: stored.output)
        }
        return Git.perform(["update-index", "--cacheinfo", "\(mode),\(hash),\(repository.prefix)\(path)"], in: root)
    }

    /// A stash can only be dropped by its place in the list, which a stash made or
    /// dropped in a terminal meanwhile would have moved: checked first, so it's
    /// never another stash that goes.
    private static func drop(_ stash: GitStash, in root: URL) -> Git.Outcome {
        let name = "stash@{\(stash.index)}"
        let found = Git.perform(["rev-parse", "--verify", "--quiet", name], in: root)
        guard found.succeeded, found.output == stash.commit.hash else {
            return Git.Outcome(succeeded: false, output: "The list of stashes has changed. Try again.")
        }
        return Git.perform(["stash", "drop", "--quiet", name], in: root)
    }
}
