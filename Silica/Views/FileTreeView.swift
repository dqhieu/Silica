import SwiftUI

/// The sidebar: a header on the title bar row, then the file tree or, in search
/// mode, Find in Project.
struct FileTreeView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var pinnedFolders = PinnedFolderTracker()
    @State private var draggedURL: URL?
    @State private var isRestoringSelection = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar row: traffic lights, then the header, then the toggle.
            // The buttons' hover fills sit side by side, so no spacing between them,
            // and the trailing padding leaves the last icon about 8pt from the edge.
            HStack(spacing: 0) {
                header
                SidebarToggleButton(workspace: workspace)
            }
            .frame(height: WorkspaceLayout.titleBarHeight)
            .padding(.leading, WorkspaceLayout.trafficLightsWidth)
            .padding(.trailing, 4)
            // Above the list, which reaches up underneath this row (see below).
            .zIndex(1)

            switch workspace.sidebarMode {
            case .explorer:
                tree
                    // The filter floats over the bottom of the list, and rows scroll
                    // under it (the list ends with room to scroll them clear).
                    .overlay(alignment: .bottom) {
                        TreeFilterField(workspace: workspace)
                            .padding(8)
                    }
            case .search:
                ProjectSearchView(workspace: workspace, model: workspace.search)
            }
        }
        .onChange(of: workspace.selection) { old, new in
            if let dragged = draggedURL {
                draggedURL = nil
                if new == dragged {
                    isRestoringSelection = true
                    workspace.selection = old
                    return
                }
            }
            if isRestoringSelection {
                isRestoringSelection = false
                return
            }
            workspace.handleSelectionChange()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            Text(workspace.sidebarMode == .search ? "Search" : workspace.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.headline)
                .help(workspace.rootURL.path(percentEncoded: false))

            Spacer(minLength: 8)

            if workspace.sidebarMode == .explorer {
                Button {
                    withAnimation { workspace.collapseAll() }
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .help("Collapse Folders")
            }

            // Last, so it stays in place when the Collapse button hides in search mode.
            Button {
                if workspace.sidebarMode == .search { workspace.showExplorer() } else { workspace.showSearch() }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(workspace.sidebarMode == .search ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(workspace.sidebarMode == .search ? "Show Explorer (⇧⌘E)" : "Find in Project (⇧⌘F)")
        }
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(.secondary)
    }

    // MARK: Tree

    /// The filter field's height plus its padding, so the last row ends up just
    /// above the field.
    private static let filterFieldClearance: CGFloat = 44

    /// How far the list reaches left past the sidebar's edge, which moves the
    /// selection highlight from 10pt to the card inset (6pt) from the window's edge.
    static let listLeadingOutset: CGFloat = 4

    private var tree: some View {
        let rows = visibleRows()
        return ScrollViewReader { proxy in
            List(selection: $workspace.selection) {
                if rows.isEmpty {
                    Text(workspace.isFilteringTree ? "No files match “\(workspace.treeFilter)”" : "This project is empty")
                        .font(.system(size: EditorSettings.shared.sidebarFontSize))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    // A flat list of the visible nodes, each indented by its depth, so the
                    // rows can draw their own compact disclosure chevrons.
                    ForEach(rows) { row in
                        switch row.kind {
                        case .node(let node):
                            FileNodeRow(node: node, depth: row.depth, workspace: workspace)
                                .id(node.url)
                        case .draft(let folder, let isDirectory):
                            NewItemRow(folder: folder, isDirectory: isDirectory, depth: row.depth, workspace: workspace)
                                .selectionDisabled()
                        }
                    }
                }
                // Room to scroll the last rows up from under the filter field
                // (`contentMargins` and `safeAreaInset` don't work for this list).
                Color.clear
                    .frame(height: Self.filterFieldClearance)
                    .listRowInsets(EdgeInsets())
                    .selectionDisabled()
                    .accessibilityHidden(true)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            // ← / → collapse and expand folders, as the system outline did.
            .onKeyPress(.rightArrow) { workspace.setSelectedFolderExpanded(true) ? .handled : .ignored }
            .onKeyPress(.leftArrow) { workspace.setSelectedFolderExpanded(false) ? .handled : .ignored }
            // Return renames and ⌘⌫ moves to the Trash, as in Finder.
            .onKeyPress(.return) {
                guard workspace.treeEdit == nil, let selection = workspace.selection else { return .ignored }
                workspace.beginRename(selection)
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers == .command, workspace.treeEdit == nil,
                      let selection = workspace.selection else { return .ignored }
                workspace.moveToTrash(selection)
                return .handled
            }
            .contextMenu {
                Button("New File…") { workspace.beginNewItem(isDirectory: false, in: workspace.rootURL) }
                Button("New Folder…") { workspace.beginNewItem(isDirectory: true, in: workspace.rootURL) }
            }
            // Compact, editor-style rows, 22pt high at the default font size.
            .environment(\.sidebarRowSize, .small)
            .environment(\.defaultMinListRowHeight, EditorSettings.shared.sidebarFontSize + 11)
            // The sidebar list style has a fixed top inset that content margins don't
            // change. Pull the list up by most of it and clip, so rows start closer to
            // the title bar and scrolled rows still disappear at its bottom edge.
            .padding(.top, -WorkspaceLayout.sidebarListTopTrim)
            // Its row inset is fixed too: widen the list to the left so the selection
            // highlight starts at the card inset, leaving the chevrons room inside it.
            .padding(.leading, -Self.listLeadingOutset)
            .clipped()
            // The folders around the first visible row stay pinned over the top of
            // the list, which is hidden where they are: the sidebar has no opaque
            // background for them to cover the rows with.
            // Turned off in Settings, the tracker gets no rows to pin.
            .modifier(PinnedFolderMask(tracker: pinnedFolders))
            .background(PinnedFolderAnchor(
                tracker: pinnedFolders,
                rows: EditorSettings.shared.pinsParentFolders ? rows.map(\.pinnedFolderRow) : []
            ))
            .background(FileTreeDragSource(rows: rows, isEnabled: workspace.treeEdit == nil) { url in
                draggedURL = workspace.selection == url ? nil : url
            })
            .overlay(alignment: .top) {
                PinnedFolders(rows: rows, tracker: pinnedFolders, workspace: workspace)
            }
            // Quick Open reveals the file it opened; wait a turn so newly
            // expanded folders have rows to scroll to.
            .onChange(of: workspace.revealCount) {
                guard let url = workspace.revealedURL else { return }
                DispatchQueue.main.async {
                    withAnimation(.snappy) { proxy.scrollTo(url, anchor: .center) }
                }
            }
            // A file revealed before the tree existed: the active tab of a new
            // window (restored, or opened from Finder). onChange only sees later
            // reveals, so scroll to it once the list has its rows.
            .onAppear {
                guard let url = workspace.revealedURL else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(url, anchor: .center)
                }
            }
        }
    }

    fileprivate struct TreeRow: Identifiable {
        enum Kind {
            case node(FileNode)
            /// The name field for a new file or folder.
            case draft(folder: URL, isDirectory: Bool)
        }

        let kind: Kind
        let depth: Int
        /// A folder shown with its contents.
        var isOpenFolder = false

        var pinnedFolderRow: PinnedFolderTracker.Row {
            PinnedFolderTracker.Row(depth: depth, isOpenFolder: isOpenFolder)
        }

        var id: String {
            switch kind {
            case .node(let node): node.url.absoluteString
            case .draft: "silica-new-item"
            }
        }

        /// The file or folder the row shows.
        var url: URL? {
            if case .node(let node) = kind { node.url } else { nil }
        }
    }

    private func visibleRows() -> [TreeRow] {
        var rows: [TreeRow] = []
        var draftFolder: URL?
        var draftIsDirectory = false
        if case .create(let folder, let isDirectory) = workspace.treeEdit {
            draftFolder = folder
            draftIsDirectory = isDirectory
        }

        // While filtering: only matches and the folders above them, all open.
        let filtered = workspace.isFilteringTree ? workspace.treeFilterResult?.visiblePaths : nil
        if workspace.isFilteringTree && filtered == nil { return [] }

        func add(_ nodes: [FileNode], depth: Int, in folder: URL) {
            // A new item's name field goes first in its folder.
            if folder == draftFolder {
                rows.append(TreeRow(kind: .draft(folder: folder, isDirectory: draftIsDirectory), depth: depth))
            }
            for node in nodes {
                if let filtered, !filtered.contains(node.relativePath) { continue }
                let isOpen = node.isDirectory && (filtered != nil || node.isExpanded)
                rows.append(TreeRow(kind: .node(node), depth: depth, isOpenFolder: isOpen))
                if isOpen, let children = node.children {
                    add(children, depth: depth + 1, in: node.url)
                }
            }
        }
        add(workspace.root.children ?? [], depth: 0, in: workspace.root.url)
        return rows
    }
}

// MARK: - Pinned folders

/// Hides the top of the list where the pinned folders are drawn.
private struct PinnedFolderMask: ViewModifier {
    let tracker: PinnedFolderTracker

    func body(content: Content) -> some View {
        content.mask {
            Rectangle().padding(.top, tracker.coveredHeight)
        }
    }
}

/// The open folders that contain the first visible row, pinned over the top of the
/// tree while their contents scroll (see `PinnedFolderTracker`). Clicking one
/// scrolls back to it.
private struct PinnedFolders: View {
    let rows: [FileTreeView.TreeRow]
    let tracker: PinnedFolderTracker
    let workspace: WorkspaceModel

    var body: some View {
        let layout = tracker.contentLayout
        VStack(spacing: 0) {
            ForEach(tracker.pinned, id: \.index) { pinned in
                if let node = node(at: pinned.index) {
                    FileNodeRow(node: node, depth: rows[pinned.index].depth, workspace: workspace, isPinned: true)
                        .frame(height: layout.height)
                        .padding(.leading, layout.leading)
                        .padding(.trailing, layout.trailing)
                        .padding(.top, layout.top)
                        .frame(height: pinned.height, alignment: .top)
                        .background {
                            if workspace.selection == node.url {
                                SelectionHighlightShape()
                                    .padding(.leading, 10 - FileTreeView.listLeadingOutset)
                                    .padding(.trailing, 10)
                            }
                        }
                        .contentShape(.rect)
                        .onTapGesture { tracker.reveal(pinned) }
                        // On the whole row, as in the list; the row's own menu only
                        // covers its icon and name out here.
                        .contextMenu { FileNodeMenu(node: node, workspace: workspace) }
                        // A folder scrolling out slides up under the one above it.
                        .offset(y: pinned.top - pinned.slotTop)
                        .frame(height: pinned.height)
                        .clipped()
                }
            }
        }
        // A hairline between the pinned folders and the rows scrolling under them.
        .overlay(alignment: .top) {
            if !tracker.pinned.isEmpty {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .padding(.leading, 10 - FileTreeView.listLeadingOutset)
                    .padding(.trailing, 10)
                    .offset(y: tracker.coveredHeight)
                    .allowsHitTesting(false)
            }
        }
        // Names are typed in the list's own rows: bring the folder's row back.
        .onChange(of: workspace.treeEdit) { _, edit in
            let url: URL? = switch edit {
            case .rename(let url): url
            case .create(let folder, _): folder
            case nil: nil
            }
            guard let url, let pinned = tracker.pinned.first(where: { node(at: $0.index)?.url == url }) else { return }
            tracker.reveal(pinned)
        }
        // The arrow keys can move the selection up under the pinned folders.
        .onChange(of: workspace.selection) { _, selection in
            guard let selection, !tracker.pinned.isEmpty,
                  let index = rows.firstIndex(where: { $0.url == selection }) else { return }
            // After the list has scrolled the row into view itself.
            DispatchQueue.main.async { tracker.uncover(row: index) }
        }
    }

    private func node(at index: Int) -> FileNode? {
        guard rows.indices.contains(index), case .node(let node) = rows[index].kind else { return nil }
        return node
    }
}

// MARK: - Filter

/// The filter field under the explorer tree: shows only files whose names contain
/// the text, in their folders. ⌥⌘J focuses it; Escape clears it.
private struct TreeFilterField: View {
    @Bindable var workspace: WorkspaceModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(workspace.isFilteringTree ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            TextField("Filter", text: $workspace.treeFilter)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onKeyPress(.escape) {
                    guard !workspace.treeFilter.isEmpty else { return .ignored }
                    workspace.treeFilter = ""
                    return .handled
                }
            if let result = workspace.treeFilterResult, workspace.isFilteringTree {
                Text(result.matchCount.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(result.matchCount == 1 ? "1 matching file" : "\(result.matchCount.formatted()) matching files")
            }
            if !workspace.treeFilter.isEmpty {
                Button {
                    workspace.treeFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: workspace.treeFilterFocusRequest) { isFocused = true }
    }
}

private struct FileTreeDragSource: NSViewRepresentable {
    let rows: [FileTreeView.TreeRow]
    let isEnabled: Bool
    let onDragStart: (URL) -> Void

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) {
        view.rows = rows
        view.isEnabled = isEnabled
        view.onDragStart = onDragStart
    }

    static func dismantleNSView(_ view: SourceView, coordinator: ()) {
        view.stopWatching()
    }

    final class SourceView: NSView, NSDraggingSource {
        var rows: [FileTreeView.TreeRow] = []
        var isEnabled = true
        var onDragStart: (URL) -> Void = { _ in }
        private var monitor: Any?
        private var press: Press?
        private var draggedPress: Press?

        private struct Press {
            let row: Int
            let url: URL
            let table: NSTableView
            let event: NSEvent
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            press = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                press = pressedRow(event)
            case .leftMouseDragged:
                guard let press else { break }
                let location = event.locationInWindow
                let dx = location.x - press.event.locationInWindow.x, dy = location.y - press.event.locationInWindow.y
                guard dx * dx + dy * dy >= 9 else { break }
                self.press = nil
                startDrag(press, with: event)
                return nil
            default:
                press = nil
            }
            return event
        }

        private func pressedRow(_ event: NSEvent) -> Press? {
            guard isEnabled, !rows.isEmpty, event.clickCount == 1, !event.modifierFlags.contains(.control),
                  let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  bounds.contains(convert(event.locationInWindow, from: nil))
            else { return nil }
            var view = window.contentView?.superview?.hitTest(event.locationInWindow)
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView else { return nil }
            let row = table.row(at: table.convert(event.locationInWindow, from: nil))
            guard rows.indices.contains(row), let url = rows[row].url else { return nil }
            return Press(row: row, url: url, table: table, event: event)
        }

        private func startDrag(_ press: Press, with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: press.url as NSURL)
            item.setDraggingFrame(press.table.rect(ofRow: press.row), contents: image(ofRow: press.row, in: press.table))
            draggedPress = press
            onDragStart(press.url)
            press.table.beginDraggingSession(with: [item], event: event, source: self)
        }

        private func image(ofRow row: Int, in table: NSTableView) -> NSImage? {
            guard let view = table.rowView(atRow: row, makeIfNecessary: false),
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            let image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
            return image
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let down = draggedPress?.event else { return }
            draggedPress = nil
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: down.windowNumber,
                                           context: nil, eventNumber: down.eventNumber, clickCount: down.clickCount, pressure: 0) {
                NSApp.postEvent(up, atStart: true)
            }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link] : []
        }
    }
}

// MARK: - Rows

private struct FileNodeRow: View {
    let node: FileNode
    let depth: Int
    let workspace: WorkspaceModel
    /// A copy pinned over the top of the tree, outside the list.
    var isPinned = false

    /// The extra leading space for each nesting level.
    static let indentWidth: CGFloat = 14
    /// How far the top level moves left of the sidebar list's own row inset, so its
    /// chevrons line up under the window's close button. The list itself already
    /// sits `listLeadingOutset` further left.
    static let firstLevelShift: CGFloat = 7 - FileTreeView.listLeadingOutset

    /// The leading padding for a row at `depth`.
    static func leadingPadding(depth: Int) -> CGFloat {
        CGFloat(depth) * indentWidth - firstLevelShift
    }

    /// Names are typed in the list's own row, never in a pinned copy.
    private var isRenaming: Bool {
        !isPinned && workspace.treeEdit == .rename(node.url)
    }

    /// Drawn open: expanded, or shown with its matches while filtering.
    private var isOpen: Bool {
        node.isExpanded || workspace.isFilteringTree
    }

    /// The name, with the filter text in bold on a soft accent background.
    private var highlightedName: AttributedString {
        var name = AttributedString(node.name)
        guard workspace.isFilteringTree,
              let range = TreeFilter.matchRange(of: workspace.treeFilter.trimmingCharacters(in: .whitespaces), in: node.name),
              let lower = AttributedString.Index(range.lowerBound, within: name),
              let upper = AttributedString.Index(range.upperBound, within: name) else { return name }
        name[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        name[lower..<upper].backgroundColor = Color.accentColor.opacity(0.25)
        return name
    }

    var body: some View {
        HStack(spacing: 4) {
            disclosureChevron
            Group {
                FileIcon(url: node.url, isDirectory: node.isDirectory, isExpanded: isOpen,
                         width: EditorSettings.shared.sidebarIconWidth)
                    .padding(.trailing, 2)
                if isRenaming {
                    NameField(initialName: node.name, selectsExtension: node.isDirectory) { name in
                        if let name { workspace.rename(node.url, to: name) } else { workspace.cancelTreeEdit() }
                    }
                } else {
                    Text(highlightedName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            // Dotfiles and gitignored items fade back but stay clickable.
            .opacity(node.isDimmed && !isRenaming ? 0.5 : 1)
            Spacer(minLength: 0)
            if workspace.buffers[node.url]?.isDirty == true {
                Circle()
                    .fill(.primary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
        }
        .padding(.leading, Self.leadingPadding(depth: depth))
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
        .tag(node.url)
        .listRowBackground(SelectionHighlight(isSelected: workspace.selection == node.url))
        .contextMenu { FileNodeMenu(node: node, workspace: workspace) }
    }

    /// A smaller chevron than the system outline's; files get the same width of space.
    @ViewBuilder
    private var disclosureChevron: some View {
        if node.isDirectory {
            // A button, so the click toggles the folder without also selecting the row
            // (selecting a folder row toggles it too).
            Button {
                workspace.toggleExpansion(of: node)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12, height: 16)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The filter decides what's shown while it's on.
            .disabled(workspace.isFilteringTree)
        } else {
            Color.clear.frame(width: 12, height: 16)
        }
    }
}

/// The context menu of a file or folder in the tree.
private struct FileNodeMenu: View {
    let node: FileNode
    let workspace: WorkspaceModel

    var body: some View {
        if !node.isDirectory {
            Button("Open") { workspace.open(node.url) }
            Divider()
        }
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        Button("New File…") { workspace.beginNewItem(isDirectory: false, in: folder) }
        Button("New Folder…") { workspace.beginNewItem(isDirectory: true, in: folder) }
        Divider()
        Button("Rename…") { workspace.beginRename(node.url) }
        Button("Duplicate") { workspace.duplicate(node.url) }
        Button("Move to Trash") { workspace.moveToTrash(node.url) }
        Divider()
        Button("Show in Finder") { Finder.reveal(node.url) }
        Button("Copy Path") { Finder.copyPath(node.url) }
        Button("Copy Relative Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.relativePath(of: node.url), forType: .string)
        }
    }
}

/// The selected row's highlight, drawn here so it's always grey. The list's own is
/// grey after a click, which doesn't give the list keyboard focus, but turns the
/// accent colour whenever the list does have focus (after a rename, say).
private struct SelectionHighlight: View {
    let isSelected: Bool

    var body: some View {
        if isSelected {
            // The shape, inset and shade of the list's own unfocused highlight. A
            // `Color`, as the `.primary` style can turn white on a selected row.
            SelectionHighlightShape()
                .padding(.horizontal, 10)
                .background(SystemHighlightRemover())
        } else {
            Color.clear
        }
    }
}

private struct SelectionHighlightShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.115))
    }
}

/// Turns off the selection highlight of the AppKit table behind the list this is
/// in, leaving `SelectionHighlight` as the only one. Selection itself still works.
private struct SystemHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoverView {
        RemoverView()
    }

    func updateNSView(_ nsView: RemoverView, context: Context) {
        nsView.removeHighlight()
    }

    final class RemoverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeHighlight()
        }

        func removeHighlight() {
            var ancestor = superview
            while let view = ancestor {
                if let table = view as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

/// The row where a new file or folder gets its name.
private struct NewItemRow: View {
    let folder: URL
    let isDirectory: Bool
    let depth: Int
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 12, height: 16)
            FileIcon(url: folder.appending(path: "untitled"), isDirectory: isDirectory,
                     width: EditorSettings.shared.sidebarIconWidth)
                .padding(.trailing, 2)
            NameField(initialName: "", selectsExtension: true) { name in
                if let name {
                    workspace.createItem(named: name, in: folder, isDirectory: isDirectory)
                } else {
                    workspace.cancelTreeEdit()
                }
            }
        }
        .padding(.leading, FileNodeRow.leadingPadding(depth: depth))
        .font(.system(size: EditorSettings.shared.sidebarFontSize))
    }
}

/// An inline name field: Return or clicking away commits, Escape cancels
/// (`onFinish(nil)`). Renaming a file selects the name without its extension.
private struct NameField: View {
    let initialName: String
    let selectsExtension: Bool
    let onFinish: (String?) -> Void

    @State private var name = ""
    @State private var selection: TextSelection?
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Name", text: $name, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onSubmit { finish(name) }
            .onKeyPress(.escape) {
                finish(nil)
                return .handled
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    selectStem()
                } else {
                    finish(name.isEmpty ? nil : name)
                }
            }
            .onAppear {
                name = initialName
                // After the row is in the list, or the focus doesn't take; once more a
                // moment later in case the list was still laying out (e.g. just after launch).
                DispatchQueue.main.async { isFocused = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !isFocused && !isFinished { isFocused = true }
                }
            }
    }

    /// Selects the name, without the extension when renaming a file. Done once focus
    /// lands, since focusing a field selects all of it.
    private func selectStem() {
        DispatchQueue.main.async {
            let stemEnd = selectsExtension
                ? name.endIndex
                : (name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : $0 } ?? name.endIndex)
            selection = TextSelection(range: name.startIndex..<stemEnd)
        }
    }

    private func finish(_ result: String?) {
        guard !isFinished else { return }
        isFinished = true
        onFinish(result)
    }
}
