import AppKit
import SwiftUI

/// Window root for a workspace: resolves the project bookmark, then shows the editor.
struct WorkspaceWindow: View {
    let projectID: RecentProject.ID?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceModel?
    @State private var errorMessage: String?

    @MainActor private static var openCount = 0

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(workspace: workspace)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can’t Open Project", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Open Project…") { ProjectOpener(openWindow: openWindow).chooseAndOpen() }
                        .glassButtonStyle(prominent: true)
                }
                .frame(minWidth: 500, minHeight: 360)
            } else {
                // Must be a real view: onAppear doesn't fire on an empty Group.
                ProgressView()
                    .frame(minWidth: 500, minHeight: 360)
            }
        }
        .onAppear {
            ExternalOpener.shared.openWindow = openWindow
            Self.openCount += 1
            dismissWindow(id: WindowID.welcome)
            load()
        }
        .onDisappear {
            if let workspace, KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
            if let workspace { ExternalOpener.shared.workspaceDidClose(workspace) }
            workspace?.close()
            Self.openCount -= 1
            if Self.openCount == 0 {
                openWindow(id: WindowID.welcome)
            }
        }
    }

    private func load() {
        guard workspace == nil else { return }
        guard let projectID else {
            // e.g. a restored window that never had a project: just close it, once
            // AppKit is done showing it. Closing a window while it's still being ordered
            // in can throw inside AppKit (issue #39, a new window tab).
            DispatchQueue.main.async { dismiss() }
            return
        }
        do {
            let url = try RecentProjectsStore.shared.resolveURL(for: projectID)
            let workspace = WorkspaceModel(rootURL: url)
            self.workspace = workspace
            ExternalOpener.shared.workspaceDidOpen(workspace, projectID: projectID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum WorkspaceLayout {
    /// Height of the title bar row that holds the traffic lights and the tabs.
    static let titleBarHeight: CGFloat = 36
    /// Room for the traffic lights when the sidebar is hidden.
    static let trafficLightsWidth: CGFloat = 78
    /// Smallest corner radius of the editor card; corners near the window's are concentric with it.
    static let cardCornerRadius: CGFloat = 10
    static let cardInset: CGFloat = 6
    /// How much of the sidebar list's built-in top inset to hide.
    static let sidebarListTopTrim: CGFloat = 8
    static let sidebarWidthRange: ClosedRange<Double> = 220...480
    static let editorMinWidth: CGFloat = 420
    /// Fits the narrowest sidebar beside the narrowest editor.
    static let windowMinWidth: CGFloat = sidebarWidthRange.lowerBound + editorMinWidth
    static let terminalHeightRange: ClosedRange<Double> = 100...1200
    /// What the terminal card leaves of the editor card at the least.
    static let minimumEditorHeight: CGFloat = 120
    /// The least a pane of a split editor keeps: its tab row and a few lines under it.
    static let paneMinimumSize = CGSize(width: 220, height: titleBarHeight + minimumEditorHeight)
    /// Between two panes: the card inset side by side, as between the editor and the
    /// terminal. One above another has the lower one's tab row between the cards.
    static let paneSpacing = PaneLayout.Spacing(horizontal: cardInset, vertical: 0)
    /// How panes come, go and change size when one is opened, closed or evened out:
    /// a spring without bounce, so the cards glide to their places.
    static let paneAnimation = Animation.smooth(duration: 0.3)
}

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    @State private var dragStartWidth: Double?
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if workspace.isSidebarVisible {
                FileTreeView(workspace: workspace)
                    .frame(width: shownSidebarWidth)
                    .overlay(alignment: .trailing) { resizeHandle }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            EditorArea(workspace: workspace)
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if workspace.isQuickOpenVisible {
                QuickOpenOverlay(workspace: workspace)
            }
        }
        .frame(minWidth: WorkspaceLayout.windowMinWidth, minHeight: 400)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .containerBackground(for: .window) {
            WindowBackgroundView()
        }
        .navigationTitle(workspace.name)
        .background(KeyWindowTracker(workspace: workspace))
        .background(UnsavedChangesGuard(workspace: workspace, hasUnsavedChanges: workspace.hasUnsavedChanges))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refresh()
        }
    }

    /// The widest the sidebar can be while the editor keeps its minimum width.
    private var widestSidebar: Double {
        let range = WorkspaceLayout.sidebarWidthRange
        // Before the first layout pass there's no width to go by.
        guard windowWidth > 0 else { return range.upperBound }
        return min(max(windowWidth - WorkspaceLayout.editorMinWidth, range.lowerBound), range.upperBound)
    }

    /// The stored width, narrowed while the window is too small for it. The stored
    /// width is kept, so the sidebar grows back when the window does.
    private var shownSidebarWidth: Double {
        min(max(sidebarWidth, WorkspaceLayout.sidebarWidthRange.lowerBound), widestSidebar)
    }

    /// Invisible strip on the sidebar's trailing edge that resizes it.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .offset(x: 4)
            .pointerStyle(.frameResize(position: .trailing))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? shownSidebarWidth
                        dragStartWidth = start
                        let proposed = start + value.translation.width
                        sidebarWidth = min(max(proposed, WorkspaceLayout.sidebarWidthRange.lowerBound), widestSidebar)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }
}

struct SidebarToggleButton: View {
    let workspace: WorkspaceModel

    var body: some View {
        Button {
            workspace.toggleSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        // Same icon style as the Collapse and Search buttons in the sidebar header.
        .buttonStyle(.titleBarIcon)
        .foregroundStyle(.secondary)
        .help(KeybindSettings.shared.help(workspace.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar", for: .toggleSidebar))
    }
}

/// A plain icon button for the title bar row that shows a soft rounded fill under
/// the pointer, darker while pressed, like the toolbar buttons of system apps.
struct TitleBarIconButtonStyle: ButtonStyle {
    /// The size of the button and of the fill under the pointer.
    var size = CGSize(width: 26, height: 22)
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration, size: size, cornerRadius: cornerRadius)
    }

    private struct IconLabel: View {
        let configuration: Configuration
        let size: CGSize
        let cornerRadius: CGFloat
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: size.width, height: size.height)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : isHovering ? 0.08 : 0),
                    in: .rect(cornerRadius: cornerRadius, style: .continuous)
                )
                .contentShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

extension ButtonStyle where Self == TitleBarIconButtonStyle {
    static var titleBarIcon: TitleBarIconButtonStyle { TitleBarIconButtonStyle() }

    /// The same, at the size of the status bar's text.
    static var statusBarIcon: TitleBarIconButtonStyle {
        TitleBarIconButtonStyle(size: CGSize(width: 22, height: 18), cornerRadius: 5)
    }
}
