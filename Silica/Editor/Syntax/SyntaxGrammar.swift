import Foundation

/// What a highlighted range represents; mapped to a color by `SyntaxTheme`.
nonisolated enum TokenKind: Sendable, CaseIterable {
    case keyword
    case type
    case string
    case number
    case comment
    case attribute
    case preprocessor
    case function
    case property
    case tag
    case variable
    case heading
    case link
    /// Added and removed lines in a diff.
    case inserted
    case deleted
}

nonisolated struct SyntaxToken: Sendable {
    let range: NSRange
    let kind: TokenKind
}

nonisolated struct SyntaxPattern: Sendable {
    let kind: TokenKind
    let pattern: String
    /// Capture group to color; 0 colors the whole match.
    let group: Int

    init(_ kind: TokenKind, _ pattern: String, group: Int = 0) {
        self.kind = kind
        self.pattern = pattern
        self.group = group
    }
}

/// A small regex-based grammar.
///
/// Tokenizing runs in two phases:
/// 1. `rules` are matched independently, in order; later rules win where they overlap.
/// 2. `spans` (comments and strings) are matched as one combined, left-to-right scan,
///    so whichever starts first wins (`"//"` inside a string stays a string), and they
///    override everything from phase 1.
///
/// Span patterns must only use non-capturing groups `(?:…)`.
nonisolated struct SyntaxGrammar: SyntaxTokenizer, @unchecked Sendable {
    private struct Rule {
        let kind: TokenKind
        let regex: NSRegularExpression
        let group: Int
    }

    private let rules: [Rule]
    private let spanRegex: NSRegularExpression?
    private let spanKinds: [TokenKind]

    init(rules: [SyntaxPattern] = [], spans: [SyntaxPattern] = []) {
        let options: NSRegularExpression.Options = [.anchorsMatchLines]
        self.rules = rules.map { pattern in
            Rule(
                kind: pattern.kind,
                // Grammars are static and covered by tests; a bad pattern is a programmer error.
                regex: try! NSRegularExpression(pattern: pattern.pattern, options: options),
                group: pattern.group
            )
        }
        if spans.isEmpty {
            spanRegex = nil
        } else {
            let combined = spans.map { "(\($0.pattern))" }.joined(separator: "|")
            spanRegex = try! NSRegularExpression(pattern: combined, options: options)
        }
        spanKinds = spans.map(\.kind)
    }

    /// Thread-safe; call with an immutable snapshot of the text.
    func tokenize(_ text: NSString) -> [SyntaxToken] {
        let string = text as String
        let fullRange = NSRange(location: 0, length: text.length)
        var tokens: [SyntaxToken] = []

        for rule in rules {
            rule.regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                guard let range = match?.range(at: rule.group), range.location != NSNotFound, range.length > 0 else { return }
                tokens.append(SyntaxToken(range: range, kind: rule.kind))
            }
        }

        if let spanRegex {
            spanRegex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                guard let match else { return }
                for (index, kind) in spanKinds.enumerated() {
                    let range = match.range(at: index + 1)
                    if range.location != NSNotFound {
                        if range.length > 0 {
                            tokens.append(SyntaxToken(range: range, kind: kind))
                        }
                        break
                    }
                }
            }
        }

        return tokens
    }
}
