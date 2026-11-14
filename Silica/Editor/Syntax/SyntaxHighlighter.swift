import AppKit

/// Colors an NSTextView's text using a `SyntaxTokenizer`.
///
/// Only the foreground color attribute is touched, directly on the text storage,
/// so highlighting never marks the document dirty or adds undo steps. After an edit,
/// the whole document is re-tokenized off the main thread once typing pauses briefly;
/// meanwhile newly typed text inherits the color of the text around it.
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private let tokenizer: any SyntaxTokenizer
    private var pending: Task<Void, Never>?
    private var generation = 0

    /// Above this many UTF-16 units, highlighting is skipped entirely.
    private static let maxLength = 2_000_000
    /// Up to this size the first pass runs synchronously, so files open already colored.
    private static let synchronousLength = 100_000
    private static let editDelay: Duration = .milliseconds(120)

    init(textView: NSTextView, language: SyntaxLanguage) {
        self.textView = textView
        self.tokenizer = language.tokenizer
    }

    deinit {
        pending?.cancel()
    }

    /// Highlights the current text immediately (used when a file is opened).
    func highlightNow() {
        guard let storage = textView?.textStorage, storage.length <= Self.maxLength else { return }
        if storage.length <= Self.synchronousLength {
            generation += 1
            apply(tokenizer.tokenize(snapshot(of: storage)))
        } else {
            schedule(after: .zero)
        }
    }

    func textDidChange() {
        schedule(after: Self.editDelay)
    }

    private func schedule(after delay: Duration) {
        generation += 1
        let expected = generation
        let tokenizer = tokenizer
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, let storage = self.textView?.textStorage,
                  storage.length <= Self.maxLength else { return }

            let text = self.snapshot(of: storage)
            let tokens = await Task.detached(priority: .userInitiated) {
                tokenizer.tokenize(text)
            }.value

            guard !Task.isCancelled, expected == self.generation else { return }
            self.apply(tokens)
        }
    }

    /// An immutable copy; the storage's own string is mutable and owned by the main thread.
    private func snapshot(of storage: NSTextStorage) -> NSString {
        (storage.string as NSString).copy() as! NSString
    }

    private func apply(_ tokens: [SyntaxToken]) {
        guard let textView, let storage = textView.textStorage else { return }
        // Recoloring under in-progress IME composition would disturb the marked text.
        if textView.hasMarkedText() {
            schedule(after: Self.editDelay)
            return
        }

        let theme = EditorSettings.shared.syntaxTheme
        let length = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: SyntaxTheme.plain, range: NSRange(location: 0, length: length))
        for token in tokens where NSMaxRange(token.range) <= length {
            storage.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }
}
