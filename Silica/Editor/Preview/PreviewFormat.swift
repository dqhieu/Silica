import Foundation

/// The kinds of file that can be shown rendered as well as in source.
nonisolated enum PreviewFormat: Sendable {
    case markdown
    /// Comma-separated values, or semicolon-separated as some spreadsheets export them.
    case csv
    /// Tab-separated values.
    case tsv
    /// A web page, shown as a browser would show it.
    case html

    init?(url: URL) {
        if SyntaxLanguage(url: url) == .markdown {
            self = .markdown
            return
        }
        switch url.pathExtension.lowercased() {
        case "csv": self = .csv
        case "tsv": self = .tsv
        // Not every file highlighted as HTML (Vue, Svelte) is a page.
        case "html", "htm", "xhtml": self = .html
        default: return nil
        }
    }

    /// What the source side of the preview is called, as in "Show Markdown".
    var sourceName: String {
        switch self {
        case .markdown: "Markdown"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .html: "HTML"
        }
    }

    /// Shown as a table that can be wider than the window, not as a column of text.
    var isTable: Bool {
        self == .csv || self == .tsv
    }

    /// The body of the preview page for the file's `text`. An HTML file is its own
    /// page, shown as it is.
    func html(for text: String) -> String {
        switch self {
        case .markdown: MarkdownHTMLRenderer.render(text)
        case .csv: CSVHTMLRenderer.render(text)
        case .tsv: CSVHTMLRenderer.render(text, delimiter: "\t")
        case .html: text
        }
    }
}
