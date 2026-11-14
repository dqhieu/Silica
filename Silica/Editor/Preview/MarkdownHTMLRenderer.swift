import Foundation
import Markdown

/// Turns Markdown (GitHub flavored: tables, task lists, strikethrough) into HTML for
/// the preview.
///
/// Compared with swift-markdown's own `HTMLFormatter`, this escapes code, keeps
/// inline formatting in headings, gives headings `id`s for `#anchor` links, colors
/// fenced code with Silica's syntax highlighter, and tags each block with
/// `data-line` (its 1-based source line) so the preview can scroll to, and report,
/// a position in the source.
nonisolated struct MarkdownHTMLRenderer: MarkupWalker {
    private(set) var result = ""
    private var usedAnchors: [String: Int] = [:]
    private var tableAlignments: [Table.ColumnAlignment?] = []
    private var inTableHead = false
    private var column = 0

    static func render(_ markdown: String) -> String {
        var renderer = MarkdownHTMLRenderer()
        renderer.visit(Document(parsing: markdown))
        return renderer.result
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p\(line(paragraph))>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let tag = "h\(heading.level)"
        result += "<\(tag) id=\"\(anchor(for: heading.plainText))\"\(line(heading))>"
        descendInto(heading)
        result += "</\(tag)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote\(line(blockQuote))>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language.flatMap(SyntaxLanguage.init(fenceName:))
        let languageClass = codeBlock.language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        result += "<pre\(line(codeBlock))><code\(languageClass)>"
        result += Self.highlight(codeBlock.code, language: language)
        result += "</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr\(line(thematicBreak)) />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Shown as written, like GitHub; the preview doesn't run scripts.
        result += html.rawHTML
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)\(line(orderedList))>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul\(line(unorderedList))>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task\"\(line(listItem))><input type=\"checkbox\" disabled"
            result += checkbox == .checked ? " checked" : ""
            result += " /> "
        } else {
            result += "<li\(line(listItem))>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        tableAlignments = table.columnAlignments
        result += "<table\(line(table))>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ head: Table.Head) {
        inTableHead = true
        column = 0
        result += "<thead><tr>"
        descendInto(head)
        result += "</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ body: Table.Body) {
        guard !body.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(body)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) {
        column = 0
        result += "<tr\(line(row))>"
        descendInto(row)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) {
        guard cell.colspan > 0, cell.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        var attributes = ""
        if column < tableAlignments.count, let alignment = tableAlignments[column] {
            let value = switch alignment {
            case .left: "left"
            case .center: "center"
            case .right: "right"
            }
            attributes += " style=\"text-align: \(value)\""
        }
        if cell.colspan > 1 { attributes += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { attributes += " rowspan=\"\(cell.rowspan)\"" }
        result += "<\(tag)\(attributes)>"
        descendInto(cell)
        result += "</\(tag)>"
        column += Int(cell.colspan)
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        result += Self.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a href=\"\(Self.escape(link.destination ?? ""))\""
        if let title = link.title, !title.isEmpty { result += " title=\"\(Self.escape(title))\"" }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img src=\"\(Self.escape(image.source ?? ""))\" alt=\"\(Self.escape(image.plainText))\""
        if let title = image.title, !title.isEmpty { result += " title=\"\(Self.escape(title))\"" }
        result += " />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    // MARK: Helpers

    private func line(_ markup: Markup) -> String {
        markup.range.map { " data-line=\"\($0.lowerBound.line)\"" } ?? ""
    }

    /// GitHub-style heading anchors: lowercase, spaces to dashes, punctuation dropped,
    /// with -1, -2… added to repeats.
    private mutating func anchor(for title: String) -> String {
        let slug = String(title.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return character == " " ? "-" : nil
        })
        let count = usedAnchors[slug, default: 0]
        usedAnchors[slug] = count + 1
        return Self.escape(count == 0 ? slug : "\(slug)-\(count)")
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Wraps highlighted ranges in `<span class="tok-…">`, letting later tokens win
    /// where they overlap, as the editor does.
    private static func highlight(_ code: String, language: SyntaxLanguage?) -> String {
        guard let language else { return escape(code) }
        let text = code as NSString
        var kinds = [TokenKind?](repeating: nil, count: text.length)
        for token in language.tokenizer.tokenize(text) where NSMaxRange(token.range) <= text.length {
            for index in token.range.location..<NSMaxRange(token.range) { kinds[index] = token.kind }
        }
        var html = ""
        var start = 0
        while start < text.length {
            var end = start + 1
            while end < text.length, kinds[end] == kinds[start] { end += 1 }
            let piece = escape(text.substring(with: NSRange(location: start, length: end - start)))
            if let kind = kinds[start] {
                html += "<span class=\"tok-\(kind)\">\(piece)</span>"
            } else {
                html += piece
            }
            start = end
        }
        return html
    }
}
