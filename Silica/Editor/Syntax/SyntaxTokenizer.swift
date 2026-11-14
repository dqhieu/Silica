import Foundation

/// Produces syntax highlight tokens from an immutable text snapshot.
///
/// Implementations must be thread-safe and stateless per call: `SyntaxHighlighter` runs them
/// off the main thread on `NSString` copies, and `MarkdownHTMLRenderer` calls them synchronously
/// for fenced code blocks.
nonisolated protocol SyntaxTokenizer: Sendable {
    /// Tokenizes `text` into UTF-16 `NSRange` tokens bounded by `text.length`.
    /// Where emitted ranges overlap, later tokens in the array take precedence.
    func tokenize(_ text: NSString) -> [SyntaxToken]
}
