import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The rendered view of one Markdown, CSV or HTML buffer, kept alive with its tab so
/// switching back and forth is instant.
///
/// A Markdown or CSV page is HTML from the format's renderer (`MarkdownHTMLRenderer`,
/// `CSVHTMLRenderer`), styled to match the editor and drawn on a transparent
/// background so the glass card shows through. Scripts in the document itself never
/// run; Silica's own small script (scroll position, double-click) runs in a separate
/// script world. Relative images load from disk through the `silica-preview:` scheme,
/// links to project files open in Silica, and web links open in the browser.
///
/// An HTML file is shown as a browser would show it: on its own background, with its
/// scripts running and the keyboard going to the page. It loads as a `file:` page, so
/// WebKit's rules for local files apply, as in Safari: the page can load the images,
/// styles and scripts around it, but its scripts can't read local files. The
/// `silica-preview:` scheme, which serves any file, isn't used for it.
final class DocumentPreview: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: PreviewWebView

    /// Opens another file in the project (a link to it was clicked).
    var onOpenFile: ((URL) -> Void)?
    /// Double-click: edit the source at this 1-based line.
    var onEditLine: ((Int) -> Void)?
    /// A character was typed; switch to the source and insert it.
    var onType: ((String) -> Void)?

    private let fileURL: URL
    private let format: PreviewFormat
    /// The folder an HTML page may load files from.
    private let readAccessURL: URL
    private var pendingLine: Int?
    private var renderTask: Task<Void, Never>?
    /// HTML to show once the web content process may read `readAccessURL` (see `show(html:)`).
    private var pendingHTML: String?
    /// The load that gives the web content process access to `readAccessURL`.
    private var accessNavigation: WKNavigation?
    /// The web content process has been given access to `readAccessURL`, which it
    /// keeps until it exits.
    private var hasReadAccess = false
    /// The last load of the editor's text as the HTML page.
    private var pageNavigation: WKNavigation?
    /// `pageNavigation` has been asked for and hasn't committed yet. Only then may the
    /// page's own URL load, so a self-link, form or script can't swap the page for the
    /// file on disk.
    private var isStartingPage = false
    /// Where to scroll an HTML page to once it has loaded.
    private var pendingScroll: CGPoint?
    /// Where an HTML page was scrolled to when it was taken down (see `unloadPage()`).
    private var savedScroll: CGPoint?
    private var isUnloaded = false
    private var baseURL: URL {
        URL(string: Self.scheme + "://local" + Self.encodedPath(fileURL.deletingLastPathComponent().path(percentEncoded: false)))!
    }

    static let scheme = "silica-preview"

    /// `readAccessURL` is the folder an HTML page may load files from, which should
    /// contain `fileURL`; it defaults to the file's own folder.
    init(fileURL: URL, format: PreviewFormat, readAccessURL: URL? = nil) {
        self.fileURL = fileURL
        self.format = format
        self.readAccessURL = readAccessURL ?? fileURL.deletingLastPathComponent()

        let configuration = WKWebViewConfiguration()
        if format == .html {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        } else {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: Self.scheme)
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient
            ))
        }
        webView = PreviewWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self

        // An HTML page keeps the web view's own background, and the keyboard, as in a browser.
        guard format != .html else { return }
        // Through a weak proxy: the content controller retains its handlers.
        configuration.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "silica")
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.onType = { [weak self] characters in self?.onType?(characters) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(syntaxThemeDidChange),
            name: .syntaxThemeDidChange, object: nil
        )
    }

    /// Swaps in the new code colors without reloading, so the scroll position stays.
    @objc private func syntaxThemeDidChange() {
        guard let data = try? JSONEncoder().encode(Self.css), let css = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("{ const style = document.querySelector('head > style'); if (style) style.textContent = \(css); }", in: nil, in: .defaultClient) { _ in }
    }

    /// Renders the file's `text` and, once loaded, scrolls to the block nearest `line`.
    /// An HTML page has no source lines to match, and comes back to where it was.
    func show(_ text: String, line: Int) {
        guard format != .html else {
            show(html: text)
            return
        }
        // Off the main actor, as a large file takes a while to turn into HTML. A newer
        // call takes over from one that is still rendering.
        renderTask?.cancel()
        renderTask = Task { [weak self, format] in
            let body = await Task.detached(priority: .userInitiated) {
                format.html(for: text)
            }.value
            guard let self, !Task.isCancelled else { return }
            // Set with the load it belongs to, not before: a page still loading from
            // an earlier call would take it when it finishes.
            self.pendingLine = line
            self.webView.loadHTMLString(Self.page(body: body, isTable: format.isTable), baseURL: self.baseURL)
        }
    }

    /// Shows `html` as if it were the file. The text comes from the editor, not the
    /// disk, so unsaved changes show and it's read in the editor's encoding: WebKit
    /// takes a file without a `<meta charset>` to be Latin-1.
    ///
    /// WebKit only lets an HTML string load local files once the process has been
    /// given access by loading a file URL, and only a load that gets as far as showing
    /// the file gives access to the whole of `readAccessURL`. So the first time, the
    /// file itself is loaded from disk with its scripts off, and the editor's text
    /// takes its place as soon as that's begun.
    private func show(html: String) {
        isUnloaded = false
        // Coming back to the same place in the page, as a Markdown preview comes back
        // to the editor's line.
        scrollPosition { [weak self] position in
            // Not if the source was shown again in the meantime.
            guard let self, !isUnloaded else { return }
            // A place the page hasn't got to yet, or had when it was taken down,
            // comes before where it is now.
            pendingScroll = pendingScroll ?? savedScroll ?? position
            savedScroll = nil
            load(html: html)
        }
    }

    /// Takes an HTML page down while the source is showing, so its scripts, timers,
    /// sound and video don't carry on unseen. `show(_:line:)` brings it back from the
    /// editor's text, at the same place.
    func unloadPage() {
        guard format == .html, !isUnloaded else { return }
        isUnloaded = true
        scrollPosition { [weak self] position in
            // Not if the preview was shown again in the meantime.
            guard let self, isUnloaded else { return }
            savedScroll = pendingScroll ?? savedScroll ?? position
            pendingScroll = nil
            // An empty page at the same address, which the process may already load.
            load(html: "")
        }
    }

    private func scrollPosition(_ completion: @escaping (CGPoint?) -> Void) {
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) { result in
            let offset = (try? result.get()) as? [Double]
            completion(offset.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil })
        }
    }

    private func load(html: String) {
        if pendingHTML != nil {
            // Still being given access; show this text when it's done instead.
            pendingHTML = html
        } else if hasReadAccess {
            loadPage(html)
        } else {
            hasReadAccess = true
            pendingHTML = html
            accessNavigation = webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    private func loadPage(_ html: String) {
        isStartingPage = true
        pageNavigation = webView.loadHTMLString(html, baseURL: fileURL)
    }

    /// Loads the page that was waiting for access to the folder.
    private func showPendingHTML() {
        guard let html = pendingHTML else { return }
        pendingHTML = nil
        accessNavigation = nil
        loadPage(html)
    }

    /// The file couldn't be loaded from disk (it's gone, say), so the process has no
    /// access. The page still shows, without the files around it, and the next time
    /// asks again.
    private func accessDidFail(_ navigation: WKNavigation) {
        guard navigation === accessNavigation else { return }
        hasReadAccess = false
        showPendingHTML()
    }

    /// The 1-based source line of the first block visible at the top.
    func topVisibleLine(_ completion: @escaping (Int) -> Void) {
        webView.evaluateJavaScript("silica.topLine()", in: nil, in: .defaultClient) { result in
            completion((try? result.get()) as? Int ?? 1)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if format == .html {
            if navigation === pageNavigation, let scroll = pendingScroll {
                pendingScroll = nil
                webView.evaluateJavaScript("window.scrollTo(\(scroll.x), \(scroll.y))", in: nil, in: .defaultClient) { _ in }
            }
            return
        }
        guard let line = pendingLine else { return }
        pendingLine = nil
        webView.evaluateJavaScript("silica.scrollToLine(\(line))", in: nil, in: .defaultClient) { _ in }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if navigation === accessNavigation {
            // The process has its access; no need to show the file as it is on disk.
            showPendingHTML()
        } else if navigation === pageNavigation {
            // From here the page's own scripts run, and may not load its URL again.
            isStartingPage = false
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === pageNavigation { isStartingPage = false }
        accessDidFail(navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        // A load that a newer one took over from fails here too; the newer one is
        // still starting.
        if navigation === pageNavigation { isStartingPage = false }
        accessDidFail(navigation)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Only the page itself loads in place (and subframes, e.g. an embedded video);
        // every other navigation is a link and is handled here instead.
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame != false,
              url.absoluteString != baseURL.absoluteString, url.scheme != "about",
              !loadsInPlace(url, navigationAction.navigationType) else {
            // The file as it is on disk, loaded for access to its folder, runs nothing.
            if pendingHTML != nil { preferences.allowsContentJavaScript = false }
            decisionHandler(.allow, preferences)
            return
        }
        decisionHandler(.cancel, preferences)

        if format == .html {
            // Only a click opens anything, not a page's script sending it elsewhere.
            guard navigationAction.navigationType == .linkActivated else { return }
            if url.isFileURL {
                let target = URL(filePath: url.path(percentEncoded: false))
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: target.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
                    onOpenFile?(target)
                }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        if url.scheme == Self.scheme {
            let path = url.path(percentEncoded: false)
            if let fragment = url.fragment, path == baseURL.path(percentEncoded: false) || path == fileURL.path(percentEncoded: false) {
                // An #anchor in this document.
                let id = fragment.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                webView.evaluateJavaScript("document.getElementById('\(id)')?.scrollIntoView()", in: nil, in: .defaultClient) { _ in }
                return
            }
            let target = URL(filePath: path)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
                onOpenFile?(target)
            }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased()) {
            NSWorkspace.shared.open(url)
        }
    }

    /// For an HTML file: the page while Silica is loading it, and a place in it
    /// (`#anchor`). Any other navigation to the page itself would load the file from
    /// disk, without unsaved edits and in the wrong encoding, so it's cancelled with
    /// the rest.
    private func loadsInPlace(_ url: URL, _ type: WKNavigationType) -> Bool {
        guard format == .html, url.isFileURL, url.query == nil,
              url.standardizedFileURL.path(percentEncoded: false) == fileURL.standardizedFileURL.path(percentEncoded: false) else { return false }
        // A jump within the page, which doesn't reload it.
        if url.fragment != nil { return true }
        // Silica's own loads, which are neither a reload, a link nor a form: the file
        // from disk for access, then the editor's text. That one is let through for
        // as long as it's starting, not once: when two loads follow closely, either's
        // check may come first, or only the second's.
        return type == .other && (pendingHTML != nil || isStartingPage)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A new process starts without the access the old one was given.
        hasReadAccess = false
        pendingHTML = nil
        accessNavigation = nil
        isStartingPage = false
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let line = message.body as? Int {
            onEditLine?(line)
        }
    }

    // MARK: Page

    private static func encodedPath(_ path: String) -> String {
        let directory = path.hasSuffix("/") ? path : path + "/"
        return directory.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? directory
    }

    private static func page(body: String, isTable: Bool) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>\(css)</style></head>
        <body\(isTable ? " class=\"csv\"" : "")><article>\(body)</article></body></html>
        """
    }

    private static func hex(_ value: UInt32) -> String {
        String(format: "#%06X", value)
    }

    private static var tokenCSS: (light: String, dark: String) {
        var light = "", dark = ""
        let theme = EditorSettings.shared.syntaxTheme
        for kind in TokenKind.allCases {
            let pair = theme.hexPair(for: kind)
            light += ".tok-\(kind) { color: \(hex(pair.light)); }\n"
            dark += ".tok-\(kind) { color: \(hex(pair.dark)); }\n"
        }
        return (light, dark)
    }

    private static var css: String {
        let size = Int(EditorSettings.shared.fontSize) + 1
        // Code in the editor's font, when one is chosen in Settings.
        let codeFont = EditorSettings.shared.fontFamily.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\", " } ?? ""
        let link = EditorSettings.shared.syntaxTheme.linkPair
        let tokens = tokenCSS
        return """
        :root { color-scheme: light dark; }
        html, body { background: transparent; margin: 0; }
        body {
          font: \(size)px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
          color: rgba(0, 0, 0, 0.86);
          -webkit-font-smoothing: antialiased;
        }
        article { max-width: 860px; margin: 0 auto; padding: 24px 32px 48px; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.6em; font-weight: 650; }
        h1 { font-size: 1.9em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid rgba(128, 128, 128, 0.25); }
        article > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        a { color: \(hex(link.light)); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre { font-family: \(codeFont)ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.88em; }
        :not(pre) > code { padding: 0.15em 0.35em; border-radius: 4px; background: rgba(128, 128, 128, 0.14); }
        pre { padding: 12px 14px; border-radius: 8px; background: rgba(128, 128, 128, 0.10); overflow-x: auto; line-height: 1.45; }
        blockquote { margin-left: 0; padding: 0 1em; border-left: 3px solid rgba(128, 128, 128, 0.35); color: rgba(0, 0, 0, 0.6); }
        ul, ol { padding-left: 1.6em; }
        li > p { margin: 0 0 0.4em; }
        li.task { list-style: none; margin-left: -1.3em; }
        li.task input { margin: 0 0.45em 0 0; vertical-align: -1px; }
        li.task > p:first-of-type { display: inline; }
        /* Leave a little room above whatever block the preview scrolls to. */
        [data-line] { scroll-margin-top: 20px; }
        /* No scroll bar, like the rest of Silica. */
        ::-webkit-scrollbar { display: none; }
        hr { border: none; border-top: 1px solid rgba(128, 128, 128, 0.3); margin: 1.6em 0; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid rgba(128, 128, 128, 0.3); padding: 6px 12px; }
        th { font-weight: 600; background: rgba(128, 128, 128, 0.08); }
        img { max-width: 100%; }
        /* CSV: a table as wide as its columns. The page scrolls both ways, under a
           header row that stays at the top. Borders are drawn per cell, as collapsed
           ones don't move with a sticky row. */
        .csv article { max-width: none; width: max-content; margin: 0; padding: 16px 20px 40px; }
        .csv table { display: table; overflow: visible; border-collapse: separate; border-spacing: 0; font-size: 0.92em; line-height: 1.45; }
        .csv th, .csv td { border-width: 0 1px 1px 0; padding: 5px 12px; vertical-align: top; }
        .csv th > div, .csv td > div { max-width: 32em; overflow: hidden; text-overflow: ellipsis; white-space: pre; }
        .csv tr > :first-child { border-left-width: 1px; }
        .csv th { position: sticky; top: 0; border-top-width: 1px; text-align: left; background: rgba(244, 244, 245, 0.94); -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px); }
        .csv .num { text-align: right; font-variant-numeric: tabular-nums; }
        .note { color: rgba(0, 0, 0, 0.5); font-size: 0.92em; }
        ::selection { background: rgba(64, 120, 242, 0.25); }
        \(tokens.light)
        @media (prefers-color-scheme: dark) {
          body { color: rgba(255, 255, 255, 0.88); }
          a { color: \(hex(link.dark)); }
          blockquote { color: rgba(255, 255, 255, 0.6); }
          .csv th { background: rgba(44, 44, 46, 0.94); }
          .note { color: rgba(255, 255, 255, 0.5); }
          \(tokens.dark)
        }
        """
    }

    /// Runs in Silica's own script world, not the document's.
    private static let script = """
    window.silica = {
      blocks() { return Array.from(document.querySelectorAll('[data-line]')); },
      // A CSV table's header row stays at the top, over the rows scrolled under it.
      headerHeight() {
        const header = document.querySelector('.csv thead');
        return header ? header.getBoundingClientRect().height : 0;
      },
      scrollToLine(line) {
        let target = null;
        const blocks = this.blocks();
        for (const el of blocks) { if (+el.dataset.line <= line) target = el; else break; }
        const header = this.headerHeight();
        if (!target || target === blocks[0]) window.scrollTo(0, 0);
        else if (header) window.scrollTo(window.scrollX, window.scrollY + target.getBoundingClientRect().top - header);
        else target.scrollIntoView({ block: 'start' });
      },
      topLine() {
        // At the top, the source starts from its first line too, not the first block's.
        if (window.scrollY < 1) return 1;
        const top = this.headerHeight() + 1;
        for (const el of this.blocks()) { if (el.getBoundingClientRect().bottom > top) return +el.dataset.line; }
        return 1;
      }
    };
    document.addEventListener('dblclick', (event) => {
      const block = event.target.closest('[data-line]');
      window.webkit.messageHandlers.silica.postMessage(block ? +block.dataset.line : 1);
    });
    """
}

/// The preview's web view: printable keys hand control back to the editor, when
/// `onType` is set.
final class PreviewWebView: WKWebView {
    var onType: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control])
        if let onType, modifiers.isEmpty, let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            onType(characters)
            return
        }
        // Space, arrows and page keys keep scrolling the preview.
        super.keyDown(with: event)
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Serves local files (images next to the document) to the preview.
private final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let data = try? Data(contentsOf: URL(filePath: url.path(percentEncoded: false))) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Hosts a buffer's preview web view in the editor card.
struct PreviewHost: NSViewRepresentable {
    let preview: DocumentPreview

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if preview.webView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        let webView = preview.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        DispatchQueue.main.async {
            webView.window?.makeFirstResponder(webView)
        }
    }
}
