import Foundation

public enum SyntaxTokenKind: String, CaseIterable, Sendable {
    case keyword, type, key, string, number, literal, comment, variable, meta, inserted, deleted
}

public struct SyntaxToken: Equatable, Sendable {
    public let kind: SyntaxTokenKind
    /// Offsets into `code.utf16`; maps 1:1 to an `NSRange`.
    public let utf16Range: Range<Int>

    public init(kind: SyntaxTokenKind, utf16Range: Range<Int>) {
        self.kind = kind
        self.utf16Range = utf16Range
    }
}

/// A hand-written, colour-only tokenizer for the languages that show up in agent
/// messages' fenced code blocks. Pure Foundation, no regex engine, never executes
/// or fetches anything.
///
/// Guarantees: tokens are sorted, non-overlapping, non-empty and inside
/// `0..<code.utf16.count`; every boundary falls on a Unicode-scalar boundary
/// (boundaries sit next to ASCII delimiters or at the end); an unterminated string
/// or comment gets no token and scanning resumes right after its opener, so the
/// damage is bounded by the line (single-line forms) or the opener (multi-line
/// forms); the work is linear in the input (see `SyntaxScanner`).
public enum SyntaxHighlighter {
    public static let maxUTF16 = 20_000
    public static let maxLines = 1_000

    public static func tokens(in code: String, language: String?) -> [SyntaxToken] {
        var steps = 0
        return tokens(in: code, language: language, steps: &steps)
    }

    /// Same as the public entry, also reporting how many scanner steps it took (the
    /// linear-time tests assert on this rather than on wall-clock time).
    static func tokens(in code: String, language: String?, steps: inout Int) -> [SyntaxToken] {
        steps = 0
        guard let language,
              let spec = SyntaxLanguages.spec(for: language), !spec.isPlain,
              code.utf16.count <= maxUTF16 else { return [] }
        let units = Array(code.utf16)
        var newlines: [Int] = []
        for (index, unit) in units.enumerated() where unit == 10 { newlines.append(index) }
        guard newlines.count < maxLines else { return [] }

        let scanner = SyntaxScanner(units, newlines: newlines, spec: spec)
        scanner.run()
        steps = scanner.steps
        return scanner.tokens
    }
}

// MARK: - Scanner

/// ASCII code units the scanner cares about.
private enum U {
    static let tab: UInt16 = 9, nl: UInt16 = 10, cr: UInt16 = 13, space: UInt16 = 32
    static let bang: UInt16 = 33, dq: UInt16 = 34, hash: UInt16 = 35, dollar: UInt16 = 36
    static let amp: UInt16 = 38, sq: UInt16 = 39, lparen: UInt16 = 40, rparen: UInt16 = 41
    static let star: UInt16 = 42, plus: UInt16 = 43, comma: UInt16 = 44, minus: UInt16 = 45
    static let dot: UInt16 = 46, slash: UInt16 = 47, colon: UInt16 = 58, semi: UInt16 = 59
    static let lt: UInt16 = 60, eq: UInt16 = 61, gt: UInt16 = 62, question: UInt16 = 63
    static let at: UInt16 = 64, lbracket: UInt16 = 91, backslash: UInt16 = 92
    static let rbracket: UInt16 = 93, underscore: UInt16 = 95, backtick: UInt16 = 96
    static let lbrace: UInt16 = 123, pipe: UInt16 = 124, rbrace: UInt16 = 125, tilde: UInt16 = 126
}

/// A string form: how one kind of literal opens, escapes, interpolates and closes.
private struct StringForm {
    var quote: UInt16
    var triple = false
    var backslash = false          // `\` escapes (for Swift raw strings: `\` plus `rawHashes` `#`)
    var doubled = false            // a doubled quote is an escaped quote (SQL, YAML `'`)
    var multiline = true
    var rawHashes = 0              // the closer is the quote(s) plus this many `#`
    var interp = Interp.none
    var token: SyntaxTokenKind? = .string   // nil: consume without a token (SQL quoted identifier)
    var key: String                // names the form in the failure memo
}

private enum Interp { case none, swiftParen, dollarBrace, dollarParen, pythonBrace }

/// One shared loop over the UTF-16 units with language-specific branches gated by
/// the spec's features. It classifies only ASCII units; every non-ASCII unit is
/// part of an identifier or string, never a delimiter, so a surrogate pair is never
/// split.
///
/// **Linear time.** A failed search for a closer proves there is none in the
/// scanned region, so the failure is memoised per form (`failed`): any later scan
/// of that form starting inside the region fails at once. Single-line forms record
/// the line end as the region end, multi-line forms the end of the code. For
/// interpolating forms the memo is deliberately a little lossy (a nested string that
/// can't close makes the whole string fail, and later strings inside the broken
/// region stay plain), which keeps nesting from re-scanning. Interpolation recurses
/// to a depth of 8; past that the rest of a string is plain text up to its closer.
/// A global step budget is the last guard: if it is ever exceeded the scan stops
/// and the rest of the block stays plain.
final class SyntaxScanner {
    private(set) var steps = 0
    private(set) var tokens: [SyntaxToken] = []

    private let u: [UInt16]
    /// Positions of every `\n`, ascending (found once, with the line cap check).
    private let newlineIndices: [Int]
    private let n: Int
    private let spec: SyntaxLanguageSpec
    private let stepLimit: Int
    private static let maxInterpolationDepth = 8

    private let sql: Bool, php: Bool, bash: Bool, json: Bool, yaml: Bool
    private let swift: Bool, rust: Bool, python: Bool, js: Bool, diff: Bool
    private let lineComments: [[UInt16]]
    private let blockOpen: [UInt16]?
    private let blockClose: [UInt16]?

    private var lastEnd = 0
    private var aborted = false
    private var failed: [String: (from: Int, stop: Int)] = [:]
    private var lastFailStop = 0
    private var nestedCommentsBroken = false
    /// Heredoc bodies waiting for the end of the line that opened them.
    private var pendingEOL = -1
    private var pendingBodies: [Range<Int>] = []

    init(_ units: [UInt16], newlines: [Int], spec: SyntaxLanguageSpec) {
        u = units
        n = units.count
        newlineIndices = newlines
        self.spec = spec
        stepLimit = 32 * units.count + 1024
        let f = spec.features
        sql = f.contains(.sql); php = f.contains(.php); bash = f.contains(.bash)
        json = f.contains(.json); yaml = f.contains(.yaml); swift = f.contains(.swift)
        rust = f.contains(.rust); python = f.contains(.python); js = f.contains(.js)
        diff = f.contains(.diff)
        lineComments = spec.lineComments.map { Array($0.utf16) }
        blockOpen = spec.blockComment.map { Array($0.open.utf16) }
        blockClose = spec.blockComment.map { Array($0.close.utf16) }
    }

    func run() {
        if diff { runDiff(); return }
        if yaml { runYAML(); return }
        var i = 0
        while i < n && !aborted {
            tick()
            if !pendingBodies.isEmpty && i > pendingEOL { pendingBodies = []; pendingEOL = -1 }
            let c = u[i]
            if c == U.nl { i = newline(at: i); continue }
            if c == U.space || c == U.tab || c == U.cr { i += 1; continue }
            if let j = tryComment(i) ?? tryWord(i) ?? tryString(i) ?? trySpecific(i) ?? tryNumber(i) {
                i = j
            } else {
                i += 1
            }
        }
    }

    // MARK: Primitives

    private func tick() {
        steps += 1
        if steps > stepLimit { aborted = true }
    }

    private func at(_ j: Int) -> UInt16 { j >= 0 && j < n ? u[j] : 0 }

    private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private func isAlpha(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private func isSpace(_ c: UInt16) -> Bool { c == U.space || c == U.tab || c == U.cr }

    /// Non-ASCII units count as identifier characters, so they never become delimiters.
    private func isIdentStart(_ c: UInt16) -> Bool {
        isAlpha(c) || c == U.underscore || c >= 0x80 || (js && c == U.dollar)
    }
    private func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) }

    private func matches(_ pattern: [UInt16], at j: Int) -> Bool {
        guard j >= 0, j + pattern.count <= n else { return false }
        for k in 0..<pattern.count where u[j + k] != pattern[k] { return false }
        return true
    }

    private func emit(_ kind: SyntaxTokenKind, _ start: Int, _ end: Int) {
        guard start < end, start >= lastEnd, end <= n else { return }
        tokens.append(SyntaxToken(kind: kind, utf16Range: start..<end))
        lastEnd = end
    }

    /// Index of the `\n` ending the line that contains `from`, or `n`: a binary
    /// search over the newline positions, so asking about the same long line again
    /// and again (`<<EOF <<EOF ...`) stays cheap.
    private func lineEnd(from: Int) -> Int {
        tick()
        var low = 0
        var high = newlineIndices.count
        while low < high {
            let mid = (low + high) / 2
            if newlineIndices[mid] < from { low = mid + 1 } else { high = mid }
        }
        return low < newlineIndices.count ? newlineIndices[low] : n
    }

    private func scanWord(from i: Int) -> Int {
        var j = i
        while j < n && isIdentChar(u[j]) { tick(); j += 1 }
        return j
    }

    private func isKnownFailure(_ key: String, at p: Int) -> Bool {
        guard let f = failed[key] else { return false }
        return p >= f.from && p < f.stop
    }

    private func recordFailure(_ key: String, from p: Int, stop: Int) {
        if let old = failed[key], old.stop == stop {
            failed[key] = (min(old.from, p), stop)
        } else {
            failed[key] = (p, stop)
        }
    }

    /// Plain search for `pattern` from `p`, memoised on failure.
    private func findPattern(_ pattern: [UInt16], from p: Int, key: String) -> Int? {
        if isKnownFailure(key, at: p) { tick(); return nil }
        var j = p
        while j + pattern.count <= n {
            tick()
            if aborted { return nil }
            if u[j] == pattern[0] && matches(pattern, at: j) { return j }
            j += 1
        }
        recordFailure(key, from: p, stop: n)
        return nil
    }

    /// The index after the `close` matching an already-open `open`, on this line only.
    private func findMatching(open: UInt16, close: UInt16, from p: Int, key: String) -> Int? {
        if isKnownFailure(key, at: p) { tick(); return nil }
        var depth = 1
        var j = p
        while j < n {
            tick()
            let c = u[j]
            if c == U.nl { break }
            if c == open { depth += 1 } else if c == close {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        recordFailure(key, from: p, stop: j)
        return nil
    }

    private func atLineStart(_ i: Int) -> Bool {
        var j = i - 1
        while j >= 0 {
            let c = u[j]
            if c == U.nl { return true }
            if c != U.space && c != U.tab { return false }
            j -= 1
        }
        return true
    }

    // MARK: Comments

    private func tryComment(_ i: Int) -> Int? {
        let c = u[i]
        for marker in lineComments where c == marker[0] && matches(marker, at: i) {
            if bash && !isBashWordStart(i) { continue }
            if php && c == U.hash && at(i + 1) == U.lbracket { continue }
            let end = lineEnd(from: i)
            emit(.comment, i, end)
            return end
        }
        if let open = blockOpen, let close = blockClose, c == open[0], matches(open, at: i) {
            let contentStart = i + open.count
            let closeAt: Int?
            if spec.blockCommentsNest && !nestedCommentsBroken {
                closeAt = scanNestedComment(from: contentStart, open: open, close: close)
            } else {
                closeAt = findPattern(close, from: contentStart, key: "bc")
            }
            if let closeAt {
                emit(.comment, i, closeAt + close.count)
                return closeAt + close.count
            }
            return contentStart
        }
        return nil
    }

    /// Index of the closer matching the opener whose content starts at `p`. On
    /// failure, later `/*` in this block fall back to plain (non-nesting) search so
    /// that unterminated openers can't make the scan quadratic.
    private func scanNestedComment(from p: Int, open: [UInt16], close: [UInt16]) -> Int? {
        var depth = 1
        var j = p
        while j < n {
            tick()
            if aborted { return nil }
            if matches(open, at: j) { depth += 1; j += open.count }
            else if matches(close, at: j) {
                depth -= 1
                if depth == 0 { return j }
                j += close.count
            } else { j += 1 }
        }
        nestedCommentsBroken = true
        return nil
    }

    /// Bash: `#` starts a comment only at a word start.
    private func isBashWordStart(_ i: Int) -> Bool {
        if i == 0 { return true }
        let p = u[i - 1]
        return isSpace(p) || p == U.nl || p == U.semi || p == U.pipe || p == U.amp
            || p == U.lparen || p == U.rparen
    }

    // MARK: Words and numbers

    private static let pythonPrefixes: Set<String> = ["r", "b", "u", "f", "rb", "br", "fr", "rf"]

    private func tryWord(_ i: Int) -> Int? {
        guard isIdentStart(u[i]) else { return nil }
        let end = scanWord(from: i)
        let next = at(end)
        let length = end - i

        if python && length <= 2 && (next == U.sq || next == U.dq) {
            let prefix = String(decoding: u[i..<end], as: UTF16.self).lowercased()
            if Self.pythonPrefixes.contains(prefix) {
                return scanPythonString(from: i, quoteAt: end, interpolating: prefix.contains("f"))
            }
        }
        if rust && length <= 2 {
            let prefix = String(decoding: u[i..<end], as: UTF16.self)
            if (prefix == "r" || prefix == "br") && (next == U.dq || next == U.hash) {
                if let j = tryRustRawString(from: i, hashesAt: end) { return j }
            } else if prefix == "b" && next == U.dq {
                return runString(StringForm(quote: U.dq, backslash: true, multiline: false, key: "rs\""),
                                 tokenStart: i, content: end + 1)
            } else if prefix == "b" && next == U.sq, let closing = rustCharEnd(at: end) {
                emit(.string, i, closing)
                return closing
            }
        }
        if let kind = classifyWord(i, end) { emit(kind, i, end) }
        return end
    }

    private func classifyWord(_ s: Int, _ e: Int) -> SyntaxTokenKind? {
        var ascii = true
        var hasLower = false
        for k in s..<e {
            let c = u[k]
            if c >= 0x80 { ascii = false } else if c >= 97 && c <= 122 { hasLower = true }
        }
        if ascii && e - s <= 24 {
            var word = String(decoding: u[s..<e], as: UTF16.self)
            if spec.caseInsensitiveKeywords { word = word.lowercased() }
            if !isDetachedFromKeywords(s, e) {
                if spec.literals.contains(word) { return .literal }
                if spec.keywords.contains(word) { return .keyword }
            }
            if spec.builtinTypes.contains(word) { return .type }
        }
        if spec.capitalizedIdentifiersAreTypes, u[s] >= 65, u[s] <= 90, hasLower { return .type }
        return nil
    }

    /// `obj.type`, `a.from`, bash `--done`, `file.sh`: a word that is a member, a
    /// flag or part of a path isn't a keyword.
    private func isDetachedFromKeywords(_ s: Int, _ e: Int) -> Bool {
        let prev = at(s - 1)
        if prev == U.dot && at(s - 2) != U.dot { return true }
        if bash {
            let next = at(e)
            return prev == U.minus || prev == U.slash
                || next == U.minus || next == U.slash || next == U.dot
        }
        return false
    }

    private func tryNumber(_ i: Int) -> Int? {
        var j = i
        if json && u[j] == U.minus { j += 1 }
        guard isDigit(at(j)) else { return nil }
        if u[j] == 48, let radix = at(j + 1) as UInt16?, radix == 120 || radix == 88 || radix == 111
            || radix == 79 || radix == 98 || radix == 66 {
            j += 2
            while isDigit(at(j)) || isAlpha(at(j)) || at(j) == U.underscore { tick(); j += 1 }
        } else {
            while isDigit(at(j)) || at(j) == U.underscore { tick(); j += 1 }
            if at(j) == U.dot && isDigit(at(j + 1)) {
                j += 1
                while isDigit(at(j)) || at(j) == U.underscore { tick(); j += 1 }
            }
            let e = at(j)
            if e == 101 || e == 69 {
                let sign = at(j + 1)
                if isDigit(sign) { j += 1 } else if (sign == U.plus || sign == U.minus) && isDigit(at(j + 2)) { j += 2 }
                while isDigit(at(j)) || at(j) == U.underscore { tick(); j += 1 }
            }
            // A type suffix such as Rust's `1u8`.
            while isAlpha(at(j)) || isDigit(at(j)) || at(j) == U.underscore { tick(); j += 1 }
        }
        emit(.number, i, j)
        return j
    }

    // MARK: Strings

    private func tryString(_ i: Int) -> Int? {
        guard let (form, content) = stringForm(at: i) else { return nil }
        return runString(form, tokenStart: i, content: content)
    }

    /// Scans a string whose content starts at `content`; emits its token and returns
    /// the index after it, or (unterminated) emits nothing and returns `content`.
    private func runString(_ form: StringForm, tokenStart: Int, content: Int) -> Int {
        guard let end = scanStringMemo(form, content: content, depth: 0) else { return content }
        if var kind = form.token {
            if json && kind == .string && isJSONKey(after: end) { kind = .key }
            emit(kind, tokenStart, end)
        }
        return end
    }

    private func isJSONKey(after end: Int) -> Bool {
        var j = end
        while j < n && (isSpace(u[j]) || u[j] == U.nl) { tick(); j += 1 }
        return at(j) == U.colon
    }

    private func stringForm(at i: Int) -> (form: StringForm, content: Int)? {
        let c = u[i]
        let triple = at(i + 1) == c && at(i + 2) == c
        if sql {
            if c == U.sq { return (StringForm(quote: c, doubled: true, key: "sql'"), i + 1) }
            if c == U.dq || c == U.backtick {
                return (StringForm(quote: c, doubled: true, multiline: false, token: nil, key: "sql\(c)"), i + 1)
            }
        } else if json {
            if c == U.dq { return (StringForm(quote: c, backslash: true, multiline: false, key: "json"), i + 1) }
        } else if php {
            if c == U.sq || c == U.dq { return (StringForm(quote: c, backslash: true, key: "php\(c)"), i + 1) }
        } else if bash {
            if c == U.sq { return (StringForm(quote: c, key: "sh'"), i + 1) }
            if c == U.dq {
                return (StringForm(quote: c, backslash: true, interp: .dollarParen, key: "sh\""), i + 1)
            }
        } else if swift {
            if c == U.dq {
                if triple {
                    return (StringForm(quote: c, triple: true, backslash: true, interp: .swiftParen,
                                       key: "sw\"\"\""), i + 3)
                }
                return (StringForm(quote: c, backslash: true, multiline: false, interp: .swiftParen,
                                   key: "sw\""), i + 1)
            }
        } else if rust {
            if c == U.dq { return (StringForm(quote: c, backslash: true, multiline: false, key: "rs\""), i + 1) }
        } else if python {
            if c == U.sq || c == U.dq { return (pythonForm(quote: c, triple: triple, interpolating: false), i + (triple ? 3 : 1)) }
        } else if js {
            if c == U.sq || c == U.dq {
                return (StringForm(quote: c, backslash: true, multiline: false, key: "js\(c)"), i + 1)
            }
            if c == U.backtick {
                return (StringForm(quote: c, backslash: true, interp: .dollarBrace, key: "js`"), i + 1)
            }
        }
        return nil
    }

    private func pythonForm(quote: UInt16, triple: Bool, interpolating: Bool) -> StringForm {
        StringForm(quote: quote, triple: triple, backslash: true, multiline: triple,
                   interp: interpolating ? .pythonBrace : .none,
                   key: "py\(quote)\(triple)\(interpolating)")
    }

    /// A Python string with a prefix word at `start` and its opening quote at `quoteAt`.
    private func scanPythonString(from start: Int, quoteAt q: Int, interpolating: Bool) -> Int {
        let quote = u[q]
        let triple = at(q + 1) == quote && at(q + 2) == quote
        return runString(pythonForm(quote: quote, triple: triple, interpolating: interpolating),
                         tokenStart: start, content: q + (triple ? 3 : 1))
    }

    private func scanStringMemo(_ form: StringForm, content: Int, depth: Int) -> Int? {
        if isKnownFailure(form.key, at: content) {
            tick()
            lastFailStop = failed[form.key]?.stop ?? n
            return nil
        }
        if let end = scanString(form, from: content, depth: depth) { return end }
        recordFailure(form.key, from: content, stop: lastFailStop)
        return nil
    }

    /// The index after the closing delimiter, or nil (with `lastFailStop` set).
    private func scanString(_ f: StringForm, from start: Int, depth: Int) -> Int? {
        let interpolating = f.interp != .none && depth < Self.maxInterpolationDepth
        var j = start
        while j < n {
            tick()
            if aborted { lastFailStop = n; return nil }
            let c = u[j]
            if c == f.quote {
                if f.triple {
                    if at(j + 1) == c && at(j + 2) == c, let end = closerHashes(after: j + 3, f.rawHashes) { return end }
                } else if f.doubled && at(j + 1) == c {
                    j += 2
                    continue
                } else if let end = closerHashes(after: j + 1, f.rawHashes) {
                    return end
                }
                j += 1
                continue
            }
            if c == U.nl && !f.multiline { lastFailStop = j; return nil }
            if c == U.backslash && f.backslash {
                guard let after = escapeEnd(j, hashes: f.rawHashes) else { j += 1; continue }
                if interpolating && f.interp == .swiftParen && at(after) == U.lparen {
                    guard let end = scanInterpolation(open: U.lparen, close: U.rparen, from: after + 1,
                                                      depth: depth + 1, multiline: f.multiline) else { return nil }
                    j = end
                } else if after < n && !(u[after] == U.nl && !f.multiline) {
                    j = after + 1
                } else {
                    j = after
                }
                continue
            }
            if interpolating {
                switch f.interp {
                case .dollarBrace where c == U.dollar && at(j + 1) == U.lbrace:
                    guard let end = scanInterpolation(open: U.lbrace, close: U.rbrace, from: j + 2,
                                                      depth: depth + 1, multiline: f.multiline) else { return nil }
                    j = end
                    continue
                case .dollarParen where c == U.dollar && at(j + 1) == U.lparen:
                    guard let end = scanInterpolation(open: U.lparen, close: U.rparen, from: j + 2,
                                                      depth: depth + 1, multiline: f.multiline) else { return nil }
                    j = end
                    continue
                case .pythonBrace where c == U.lbrace:
                    if at(j + 1) == U.lbrace { j += 2; continue }
                    guard let end = scanInterpolation(open: U.lbrace, close: U.rbrace, from: j + 1,
                                                      depth: depth + 1, multiline: f.multiline) else { return nil }
                    j = end
                    continue
                default:
                    break
                }
            }
            j += 1
        }
        lastFailStop = n
        return nil
    }

    /// The index after a backslash escape's introducer (the backslash plus `hashes`
    /// `#`), or nil when the hashes are missing (the backslash is then plain).
    private func escapeEnd(_ j: Int, hashes: Int) -> Int? {
        var k = j + 1
        for _ in 0..<hashes {
            tick()
            guard at(k) == U.hash else { return nil }
            k += 1
        }
        return k
    }

    /// `index` if `hashes` `#` follow it... the end of the closer; nil if they don't.
    private func closerHashes(after index: Int, _ hashes: Int) -> Int? {
        var k = index
        for _ in 0..<hashes {
            tick()
            guard at(k) == U.hash else { return nil }
            k += 1
        }
        return k
    }

    /// Scans interpolated code up to the bracket matching an already-open `open`.
    /// A nested string that can't close fails the whole interpolation.
    private func scanInterpolation(open: UInt16, close: UInt16, from start: Int, depth: Int,
                                   multiline: Bool) -> Int? {
        var nesting = 1
        var j = start
        while j < n {
            tick()
            if aborted { lastFailStop = n; return nil }
            let c = u[j]
            if c == U.nl && !multiline { lastFailStop = j; return nil }
            if c == open {
                nesting += 1
            } else if c == close {
                nesting -= 1
                if nesting == 0 { return j + 1 }
            } else if let (form, content) = stringForm(at: j) {
                guard let end = scanStringMemo(form, content: content, depth: depth) else { return nil }
                j = end
                continue
            }
            j += 1
        }
        lastFailStop = n
        return nil
    }

    // MARK: Language-specific starts

    private func trySpecific(_ i: Int) -> Int? {
        let c = u[i]
        if sql { return nil }
        if php { return tryPHP(i, c) }
        if bash { return tryBash(i, c) }
        if swift { return trySwift(i, c) }
        if rust { return tryRust(i, c) }
        if python { return tryPython(i, c) }
        if json, c == U.minus { return tryNumber(i) }
        return nil
    }

    // PHP

    private func tryPHP(_ i: Int, _ c: UInt16) -> Int? {
        switch c {
        case U.lt:
            if at(i + 1) == U.question {
                if at(i + 2) == U.eq { emit(.meta, i, i + 3); return i + 3 }
                if matches(Array("php".utf16), at: i + 2) && !isIdentChar(at(i + 5)) {
                    emit(.meta, i, i + 5)
                    return i + 5
                }
            }
            if at(i + 1) == U.lt && at(i + 2) == U.lt { return tryPHPHeredoc(i) }
        case U.question:
            if at(i + 1) == U.gt { emit(.meta, i, i + 2); return i + 2 }
        case U.dollar:
            if isIdentStart(at(i + 1)) {
                let end = scanWord(from: i + 1)
                emit(.variable, i, end)
                return end
            }
        case U.hash:
            if at(i + 1) == U.lbracket { emit(.meta, i, i + 2); return i + 2 }
        default:
            break
        }
        return nil
    }

    private func tryPHPHeredoc(_ i: Int) -> Int? {
        var j = i + 3
        while at(j) == U.space || at(j) == U.tab { j += 1 }
        var quote: UInt16 = 0
        if at(j) == U.dq || at(j) == U.sq { quote = at(j); j += 1 }
        let idStart = j
        guard isAlpha(at(j)) || at(j) == U.underscore else { return nil }
        j = scanASCIIIdentifier(from: j)
        let id = Array(u[idStart..<j])
        if quote != 0 {
            guard at(j) == quote else { return nil }
            j += 1
        }
        let bodyStart = lineEnd(from: j) + 1
        if let end = findHeredocCloser(id, from: bodyStart, key: "php-hd:\(String(decoding: id, as: UTF16.self))",
                                       strip: .whitespace) {
            emit(.string, i, end)
            return end
        }
        return j
    }

    private func scanASCIIIdentifier(from p: Int) -> Int {
        var j = p
        while (isAlpha(at(j)) || isDigit(at(j)) || at(j) == U.underscore) { tick(); j += 1 }
        return j
    }

    private enum HeredocStrip { case none, tabs, whitespace }

    /// The end (exclusive) of the closing line's identifier, searching whole lines
    /// from `lineStart`. Bash closers are the identifier alone on a line; PHP's may
    /// be indented and followed by a non-identifier character.
    private func findHeredocCloser(_ id: [UInt16], from lineStart: Int, key: String,
                                   strip: HeredocStrip) -> Int? {
        if isKnownFailure(key, at: lineStart) { tick(); return nil }
        var ls = lineStart
        while ls < n {
            tick()
            if aborted { return nil }
            var p = ls
            switch strip {
            case .none: break
            case .tabs: while at(p) == U.tab { p += 1 }
            case .whitespace: while at(p) == U.space || at(p) == U.tab { p += 1 }
            }
            if matches(id, at: p) {
                let after = p + id.count
                let ok = strip == .whitespace
                    ? !isIdentChar(at(after))
                    : (after >= n || at(after) == U.nl || (at(after) == U.cr && at(after + 1) == U.nl))
                if ok { return after }
            }
            ls = lineEnd(from: ls) + 1
        }
        recordFailure(key, from: lineStart, stop: n)
        return nil
    }

    // Bash

    private func tryBash(_ i: Int, _ c: UInt16) -> Int? {
        switch c {
        case U.dollar:
            return tryBashDollar(i)
        case U.lt:
            guard at(i + 1) == U.lt else { return nil }
            if at(i + 2) == U.lt { return i + 3 }       // here-string, not a heredoc
            return tryBashHeredoc(i)
        default:
            return nil
        }
    }

    private func tryBashDollar(_ i: Int) -> Int? {
        let d = at(i + 1)
        if d == U.sq {
            return runString(StringForm(quote: U.sq, backslash: true, key: "sh$'"), tokenStart: i, content: i + 2)
        }
        if d == U.lparen { emit(.variable, i, i + 2); return i + 2 }
        if d == U.lbrace {
            let end = findMatching(open: U.lbrace, close: U.rbrace, from: i + 2, key: "sh${") ?? (i + 2)
            emit(.variable, i, end)
            return end
        }
        if isAlpha(d) || d == U.underscore {
            let end = scanASCIIIdentifier(from: i + 1)
            emit(.variable, i, end)
            return end
        }
        if isDigit(d) || d == U.hash || d == U.question || d == U.at || d == U.dollar
            || d == U.bang || d == U.star {
            emit(.variable, i, i + 2)
            return i + 2
        }
        return nil
    }

    private func tryBashHeredoc(_ i: Int) -> Int? {
        var j = i + 2
        var dash = false
        if at(j) == U.minus { dash = true; j += 1 }
        while at(j) == U.space || at(j) == U.tab { j += 1 }
        var quote: UInt16 = 0
        if at(j) == U.dq || at(j) == U.sq { quote = at(j); j += 1 } else if at(j) == U.backslash { j += 1 }
        let idStart = j
        guard isAlpha(at(j)) || at(j) == U.underscore else { return nil }
        j = scanASCIIIdentifier(from: j)
        let id = Array(u[idStart..<j])
        if quote != 0 {
            guard at(j) == quote else { return nil }
            j += 1
        }
        let eol = lineEnd(from: j)
        guard eol < n else { return j }
        if pendingEOL != eol { pendingEOL = eol; pendingBodies = [] }
        let bodyStart = (pendingBodies.last.map { $0.upperBound + 1 } ?? eol + 1)
        let key = "sh-hd:\(String(decoding: id, as: UTF16.self)):\(dash)"
        if let end = findHeredocCloser(id, from: bodyStart, key: key, strip: dash ? .tabs : .none) {
            pendingBodies.append(bodyStart..<end)
        }
        return j
    }

    /// At a `\n`: if a heredoc opened on this line, its body is next.
    private func newline(at i: Int) -> Int {
        guard i == pendingEOL, let last = pendingBodies.last else { return i + 1 }
        for body in pendingBodies { emit(.string, body.lowerBound, body.upperBound) }
        pendingBodies = []
        pendingEOL = -1
        return max(last.upperBound, i + 1)
    }

    // Swift

    private static let swiftDirectives: Set<String> = [
        "if", "else", "elseif", "endif", "available", "unavailable", "selector", "keyPath",
        "warning", "error", "sourceLocation", "file", "line", "function", "column", "colorLiteral",
        "imageLiteral", "fileLiteral", "line",
    ]

    private func trySwift(_ i: Int, _ c: UInt16) -> Int? {
        if c == U.at && isAlpha(at(i + 1)) {
            let end = scanWord(from: i + 1)
            emit(.meta, i, end)
            return end
        }
        guard c == U.hash else { return nil }
        var hashes = 0
        while at(i + hashes) == U.hash && hashes < 16 { tick(); hashes += 1 }
        if at(i + hashes) == U.dq {
            let quoteAt = i + hashes
            let triple = at(quoteAt + 1) == U.dq && at(quoteAt + 2) == U.dq
            let form = StringForm(quote: U.dq, triple: triple, backslash: true, multiline: triple,
                                  rawHashes: hashes, interp: .swiftParen,
                                  key: "sw#\(hashes)\(triple)")
            return runString(form, tokenStart: i, content: quoteAt + (triple ? 3 : 1))
        }
        if hashes == 1 && isAlpha(at(i + 1)) {
            let end = scanWord(from: i + 1)
            if Self.swiftDirectives.contains(String(decoding: u[(i + 1)..<end], as: UTF16.self)) {
                emit(.meta, i, end)
            }
            return end
        }
        return i + hashes
    }

    // Rust

    private func tryRust(_ i: Int, _ c: UInt16) -> Int? {
        if c == U.hash {
            let bang = at(i + 1) == U.bang
            guard at(i + (bang ? 2 : 1)) == U.lbracket else { return nil }
            let opener = i + (bang ? 3 : 2)
            let end = findMatching(open: U.lbracket, close: U.rbracket, from: opener, key: "rs#[") ?? opener
            emit(.meta, i, end)
            return end
        }
        guard c == U.sq else { return nil }
        if let end = rustCharEnd(at: i) { emit(.string, i, end); return end }
        if isIdentStart(at(i + 1)) {
            let end = scanWord(from: i + 1)
            emit(.type, i, end)
            return end
        }
        return nil
    }

    /// The index after a char literal whose opening quote is at `i`, or nil (a lifetime).
    private func rustCharEnd(at i: Int) -> Int? {
        guard i + 1 < n else { return nil }
        let c1 = u[i + 1]
        var j: Int
        if c1 == U.backslash {
            let e = at(i + 2)
            if e == 120 { j = i + 5 }                       // \xNN
            else if e == 117 && at(i + 3) == U.lbrace {    // \u{...}
                var k = i + 4
                while k < n && u[k] != U.rbrace && k < i + 12 { tick(); k += 1 }
                guard at(k) == U.rbrace else { return nil }
                j = k + 1
            } else { j = i + 3 }
        } else if c1 == U.sq || c1 == U.nl {
            return nil
        } else if c1 >= 0xD800 && c1 <= 0xDBFF {
            j = i + 3
        } else {
            j = i + 2
        }
        return j < n && u[j] == U.sq ? j + 1 : nil
    }

    private func tryRustRawString(from start: Int, hashesAt: Int) -> Int? {
        var hashes = 0
        while at(hashesAt + hashes) == U.hash && hashes < 255 { tick(); hashes += 1 }
        guard at(hashesAt + hashes) == U.dq else { return nil }
        let form = StringForm(quote: U.dq, rawHashes: hashes, key: "rs-raw\(hashes)")
        return runString(form, tokenStart: start, content: hashesAt + hashes + 1)
    }

    // Python

    private func tryPython(_ i: Int, _ c: UInt16) -> Int? {
        guard c == U.at && atLineStart(i) else { return nil }
        var j = i + 1
        while isIdentChar(at(j)) || at(j) == U.dot { tick(); j += 1 }
        emit(.meta, i, j)
        return max(j, i + 1)
    }

    // MARK: Diff

    private func runDiff() {
        var ls = 0
        var inHeader = true
        while ls < n && !aborted {
            let le = lineEnd(from: ls)
            tick()
            if le > ls {
                let c = u[ls]
                if c == U.at && at(ls + 1) == U.at {
                    emit(.meta, ls, le)
                    inHeader = false
                } else if c == U.minus || c == U.plus {
                    let marker = c == U.minus ? "--- " : "+++ "
                    if matches(Array(marker.utf16), at: ls) {
                        if inHeader || startsFileHeader(at: ls, lineEnd: le) {
                            emit(.meta, ls, le)
                            inHeader = true
                        } else {
                            emit(c == U.minus ? .deleted : .inserted, ls, le)
                        }
                    } else {
                        emit(c == U.minus ? .deleted : .inserted, ls, le)
                    }
                } else if c == U.backslash {
                    emit(.meta, ls, le)
                } else if let isFileStart = diffHeaderKind(at: ls) {
                    emit(.meta, ls, le)
                    if isFileStart { inHeader = true }
                }
            }
            ls = le + 1
        }
    }

    private static let diffHeaderPrefixes: [[UInt16]] = [
        "diff --git", "index ", "new file mode", "deleted file mode", "old mode", "new mode",
        "similarity index", "dissimilarity index", "rename from", "rename to", "copy from",
        "copy to", "Binary files",
    ].map { Array($0.utf16) }

    /// nil if not a git header line; true if it starts a new file's header.
    private func diffHeaderKind(at ls: Int) -> Bool? {
        for (k, prefix) in Self.diffHeaderPrefixes.enumerated() where matches(prefix, at: ls) {
            return k == 0
        }
        return nil
    }

    /// A `--- ` line directly followed by `+++ ` and then `@@` begins another file's
    /// header (plain `diff -u` output has no `diff --git` line).
    private func startsFileHeader(at ls: Int, lineEnd le: Int) -> Bool {
        guard u[ls] == U.minus else { return false }
        let second = le + 1
        guard matches(Array("+++ ".utf16), at: second) else { return false }
        let third = lineEnd(from: second) + 1
        return matches(Array("@@".utf16), at: third)
    }

    // MARK: YAML

    private func runYAML() {
        var ls = 0
        var blockParentIndent: Int?
        var blockStart = -1
        var blockEnd = -1
        func flushBlock() {
            if blockStart >= 0 { emit(.string, blockStart, blockEnd) }
            blockStart = -1
            blockParentIndent = nil
        }
        while ls < n && !aborted {
            let le = lineEnd(from: ls)
            tick()
            var cs = ls
            while cs < le && (u[cs] == U.space || u[cs] == U.tab) { tick(); cs += 1 }
            let blank = cs >= le || (cs + 1 == le && u[cs] == U.cr)
            let indent = cs - ls
            if let parent = blockParentIndent {
                if blank { ls = le + 1; continue }
                if indent > parent {
                    if blockStart < 0 { blockStart = cs }
                    blockEnd = le
                    ls = le + 1
                    continue
                }
                flushBlock()
            }
            if !blank {
                if let parent = yamlLine(ls: ls, cs: cs, le: le, indent: indent) { blockParentIndent = parent }
            }
            ls = le + 1
        }
        flushBlock()
    }

    private static let yamlLiterals: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "~"]

    /// Tokenizes one YAML line. Returns the indent if the line ends with a block scalar header.
    private func yamlLine(ls: Int, cs: Int, le: Int, indent: Int) -> Int? {
        if u[cs] == U.hash { emit(.comment, cs, le); return nil }
        var p = cs
        if cs == ls && (matches(Array("---".utf16), at: cs) || matches(Array("...".utf16), at: cs))
            && (cs + 3 >= le || isSpace(u[cs + 3])) {
            emit(.meta, cs, cs + 3)
            p = cs + 3
        } else {
            while at(p) == U.minus && (p + 1 >= le || isSpace(u[p + 1])) {
                p += 1
                while p < le && isSpace(u[p]) { p += 1 }
            }
            if p >= le { return nil }
            if let (keyEnd, colon) = yamlKey(from: p, lineEnd: le) {
                emit(.key, p, keyEnd)
                p = colon + 1
            }
        }
        return yamlValue(from: p, lineStart: ls, lineEnd: le, indent: indent)
    }

    private func yamlKey(from p: Int, lineEnd le: Int) -> (keyEnd: Int, colon: Int)? {
        let c = u[p]
        if c == U.dq || c == U.sq {
            guard let end = scanStringMemo(yamlStringForm(c), content: p + 1, depth: 0) else { return nil }
            var q = end
            while q < le && isSpace(u[q]) { q += 1 }
            if q < le && u[q] == U.colon && (q + 1 >= le || isSpace(u[q + 1])) { return (end, q) }
            return nil
        }
        if c == U.lbrace || c == U.lbracket || c == U.pipe || c == U.gt || c == U.amp || c == U.star
            || c == U.bang || c == U.hash || c == 37 || c == U.at || c == U.backtick || c == U.question {
            return nil
        }
        var q = p
        while q < le {
            tick()
            let d = u[q]
            if d == U.colon && (q + 1 >= le || isSpace(u[q + 1])) {
                var keyEnd = q
                while keyEnd > p && isSpace(u[keyEnd - 1]) { keyEnd -= 1 }
                return keyEnd > p ? (keyEnd, q) : nil
            }
            if d == U.hash && q > p && isSpace(u[q - 1]) { return nil }
            q += 1
        }
        return nil
    }

    private func yamlStringForm(_ quote: UInt16) -> StringForm {
        if quote == U.sq { return StringForm(quote: quote, doubled: true, multiline: false, key: "yaml'") }
        return StringForm(quote: quote, backslash: true, multiline: false, key: "yaml\"")
    }

    private func yamlValue(from start: Int, lineStart ls: Int, lineEnd le: Int, indent: Int) -> Int? {
        var p = start
        var flow = 0
        var atValueStart = true
        while p < le && !aborted {
            tick()
            let c = u[p]
            if isSpace(c) { p += 1; continue }
            if c == U.hash && (p == ls || isSpace(u[p - 1])) { emit(.comment, p, le); return nil }
            if c == U.dq || c == U.sq {
                if let end = scanStringMemo(yamlStringForm(c), content: p + 1, depth: 0) {
                    var kind = SyntaxTokenKind.string
                    if flow > 0 {
                        var q = end
                        while q < le && isSpace(u[q]) { q += 1 }
                        if at(q) == U.colon { kind = .key }
                    }
                    emit(kind, p, end)
                    p = end
                    atValueStart = false
                } else {
                    p += 1
                }
                continue
            }
            if c == U.amp || c == U.star || c == U.bang {
                var e = p + 1
                while e < le && !isSpace(u[e]) && !(flow > 0 && (u[e] == U.comma || u[e] == U.rbracket || u[e] == U.rbrace)) {
                    tick(); e += 1
                }
                emit(.meta, p, e)
                p = e
                continue
            }
            if (c == U.pipe || c == U.gt) && atValueStart && flow == 0 {
                var e = p + 1
                while e < le && (u[e] == U.minus || u[e] == U.plus || isDigit(u[e])) { e += 1 }
                var rest = e
                while rest < le && isSpace(u[rest]) { rest += 1 }
                if rest >= le { return indent }
                if u[rest] == U.hash && rest > e { emit(.comment, rest, le); return indent }
            }
            if c == U.lbrace || c == U.lbracket { flow += 1; atValueStart = false; p += 1; continue }
            if flow > 0 && (c == U.rbrace || c == U.rbracket) { flow -= 1; p += 1; continue }
            if flow > 0 && c == U.comma { p += 1; continue }
            // A plain scalar.
            var e = p
            var isKey = false
            while e < le {
                tick()
                let d = u[e]
                if isSpace(d) && at(e + 1) == U.hash { break }
                if flow > 0 && (d == U.comma || d == U.rbracket || d == U.rbrace) { break }
                if flow > 0 && d == U.colon
                    && (e + 1 >= le || isSpace(u[e + 1]) || u[e + 1] == U.comma || u[e + 1] == U.rbrace) {
                    isKey = true
                    break
                }
                e += 1
            }
            var scalarEnd = e
            while scalarEnd > p && isSpace(u[scalarEnd - 1]) { scalarEnd -= 1 }
            if scalarEnd > p {
                if isKey {
                    emit(.key, p, scalarEnd)
                } else if let kind = yamlScalarKind(p, scalarEnd) {
                    emit(kind, p, scalarEnd)
                }
            }
            atValueStart = false
            p = isKey ? e + 1 : max(e, p + 1)
        }
        return nil
    }

    private func yamlScalarKind(_ s: Int, _ e: Int) -> SyntaxTokenKind? {
        guard e - s <= 8 else { return isNumeric(s, e) ? .number : nil }
        var allASCII = true
        for k in s..<e where u[k] >= 0x80 { allASCII = false }
        if allASCII, Self.yamlLiterals.contains(String(decoding: u[s..<e], as: UTF16.self).lowercased()) {
            return .literal
        }
        return isNumeric(s, e) ? .number : nil
    }

    /// `-12`, `3.5`, `1e3`, `0x1F`, `0o17`: the whole scalar is a number.
    private func isNumeric(_ s: Int, _ e: Int) -> Bool {
        var j = s
        if at(j) == U.minus || at(j) == U.plus { j += 1 }
        guard j < e, isDigit(u[j]) else { return false }
        if u[j] == 48 && j + 1 < e && (u[j + 1] == 120 || u[j + 1] == 111) {
            j += 2
            while j < e && (isDigit(u[j]) || isAlpha(u[j])) { j += 1 }
            return j == e
        }
        while j < e && (isDigit(u[j]) || u[j] == U.underscore) { j += 1 }
        if j < e && u[j] == U.dot {
            j += 1
            while j < e && isDigit(u[j]) { j += 1 }
        }
        if j < e && (u[j] == 101 || u[j] == 69) {
            j += 1
            if j < e && (u[j] == U.plus || u[j] == U.minus) { j += 1 }
            guard j < e, isDigit(u[j]) else { return false }
            while j < e && isDigit(u[j]) { j += 1 }
        }
        return j == e
    }
}
