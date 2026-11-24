import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window shows, so none flashes in the other appearance.
        EditorSettings.shared.applyAppearance()
        // No macOS window tabs: files have their own tabs, a new window tab would be a
        // window without a project, and the tab bar would cover the top of the sidebar,
        // which sits in the title bar. This also drops Show Tab Bar and the like from
        // the menus, whatever "Prefer tabs" says in System Settings.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Files and folders from Finder's Open With, the Dock icon or `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpener.shared.open(urls)
    }

    /// Quitting asks about unsaved files in each project window first, in a sheet,
    /// so the answer comes back later.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard UnsavedChangesGuard.GuardView.hasUnsavedChanges else { return .terminateNow }
        UnsavedChangesGuard.GuardView.confirmQuitting { proceed in
            NSApp.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }
}
